import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "EQEngine")

@MainActor
final class EQEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var currentPreset: EQPreset?

    // Signal flow:
    //   HALInput (BlackHole) → EQProcessor (4-band vDSP biquad + preamp) → ring buffer
    //                                                                          ↓
    //                                                                       HALOutput (DAC)
    //
    // No AVAudioEngine anywhere. The two HAL Audio Units are clock-independent: input is
    // driven by BlackHole's clock, output by the DAC's clock, with the ring buffer
    // bridging the small drift between them.
    private let halInput = HALInput()
    private let eqProcessor = EQProcessor()
    private let ringBuffer = StereoFloatRingBuffer(capacityFrames: 96_000) // ~2 s @ 48k stereo
    private lazy var halOutput = HALOutput(ringBuffer: ringBuffer)

    private var activeSampleRate: Double?
    private var activeInput: AudioDevice?
    private var activeOutput: AudioDevice?

    // Per-device sample-rate listeners. When a music app changes BlackHole's rate on a
    // track change, we re-reconcile and restart both AUs. (Replaces the old
    // AVAudioEngineConfigurationChange dance — that notification only existed on
    // AVAudioEngine, which we no longer use.)
    private var inputRateListener: AudioDevicePropertyListener?
    private var outputRateListener: AudioDevicePropertyListener?
    private var pendingRestart: DispatchWorkItem?
    private var restartCooldownUntil: Date = .distantPast

    // MARK: - Lifecycle

    func start(input: AudioDevice, output: AudioDevice) {
        log.info("start input=\(input.name)/\(input.uid) output=\(output.name)/\(output.uid) prev=\(self.activeInput?.uid ?? "nil")→\(self.activeOutput?.uid ?? "nil") running=\(self.isRunning)")

        tearDownListeners()
        try? halInput.stop()
        try? halOutput.stop()
        ringBuffer.reset()

        // 1. Reconcile sample rates between input and output devices.
        let sampleRate: Double
        do {
            sampleRate = try CoreAudioSampleRate.reconcile(input: input.id, output: output.id)
            if try CoreAudioSampleRate.nominal(for: input.id) != sampleRate {
                try CoreAudioSampleRate.setNominal(sampleRate, for: input.id)
            }
            if try CoreAudioSampleRate.nominal(for: output.id) != sampleRate {
                try CoreAudioSampleRate.setNominal(sampleRate, for: output.id)
            }
            activeSampleRate = sampleRate
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Sample-rate reconciliation failed: \(String(describing: error))")
            return
        }

        // 2. Client format for the whole chain.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            statusMessage = "Error: could not build client format"
            return
        }
        log.info("Client format: \(clientFormat)")

        // 3. Push current preset into the EQ processor so coefficients are ready before
        //    the first input callback fires.
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: sampleRate)
        }

        // 4. Start the input AU. Its callback runs on the audio thread: EQ in-place on
        //    the scratch buffers, then write to the ring buffer.
        do {
            try halInput.start(deviceID: input.id, clientFormat: clientFormat) { [eqProcessor, ringBuffer] left, right, frames in
                eqProcessor.process(left: left, right: right, frames: frames)
                ringBuffer.write(left: left, right: right, frames: frames)
            }

            // 5. Start the output AU on the user's chosen device.
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeInput = input
            activeOutput = output
            isRunning = true
            statusMessage = "Running · \(input.name) → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine started: \(self.statusMessage)")

            // Cooldown swallows the storm of property-change notifications that the OS
            // emits while the AUs settle into their device's clock.
            restartCooldownUntil = Date().addingTimeInterval(0.5)

            installListeners(input: input, output: output)
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? halInput.stop()
            try? halOutput.stop()
        }
    }

    func stop() {
        tearDownListeners()
        try? halInput.stop()
        try? halOutput.stop()
        ringBuffer.reset()
        activeInput = nil
        activeOutput = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - Runtime change handling

    private func installListeners(input: AudioDevice, output: AudioDevice) {
        inputRateListener = AudioDevicePropertyListener(
            deviceID: input.id,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in self?.scheduleRestart(reason: "input rate change") }
        }
        outputRateListener = AudioDevicePropertyListener(
            deviceID: output.id,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in self?.scheduleRestart(reason: "output rate change") }
        }
    }

    private func tearDownListeners() {
        pendingRestart?.cancel()
        pendingRestart = nil
        inputRateListener = nil
        outputRateListener = nil
    }

    private func scheduleRestart(reason: String) {
        guard isRunning, activeInput != nil, activeOutput != nil else { return }
        if Date() < restartCooldownUntil {
            log.info("Ignoring \(reason) during cooldown")
            return
        }
        log.info("Scheduling engine restart: \(reason)")
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning,
                      let input = self.activeInput,
                      let output = self.activeOutput else { return }
                self.start(input: input, output: output)
            }
        }
        pendingRestart = work
        // Track changes fire a burst of property notifications — debounce so one burst
        // produces one restart.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func reportStartFailure(_ message: String) {
        isRunning = false
        statusMessage = message
        log.error("Start blocked: \(message)")
    }

    // MARK: - Preset / band updates

    func apply(preset: EQPreset) {
        currentPreset = preset
        if let sampleRate = activeSampleRate {
            eqProcessor.configure(preset: preset, sampleRate: sampleRate)
        } else {
            // Engine not started yet — coefficients will be set when start() runs.
            eqProcessor.configure(preset: preset, sampleRate: 48_000)
        }
    }

    func updateBand(index: Int, band: EQBand) {
        eqProcessor.updateBand(index: index, band: band)
        if var p = currentPreset, p.bands.indices.contains(index) {
            p.bands[index] = band
            currentPreset = p
        }
    }

    func setPreamp(_ dB: Float) {
        eqProcessor.setPreamp(dB: dB)
        if var p = currentPreset {
            p.preamp = dB
            currentPreset = p
        }
    }
}
