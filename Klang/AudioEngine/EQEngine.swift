import Foundation
import AVFoundation
import CoreAudio
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "EQEngine")

@MainActor
final class EQEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var currentPreset: EQPreset?

    // Signal flow:
    //   inputNode (AUHAL bound to BlackHole) → EQ1 → EQ2 → EQ3 → EQ4 → mainMixer (muted)
    //                                                      ↓
    //                                                  installTap → ringBuffer
    //                                                                    ↓
    //                                                              HALOutput (chosen device)
    //
    // We don't use engine.outputNode for actual output because AVAudioEngine on macOS rebinds
    // its CurrentDevice to the system default during init and rejects post-init changes. The
    // engine's outputNode still exists in the graph (mainMixer auto-connects to it) but its
    // signal is muted so nothing audible leaks through it (which would feed BlackHole and loop).
    private var engine = AVAudioEngine()
    private var eqNodes: [AVAudioUnitEQ] = (0..<4).map { _ in AVAudioUnitEQ(numberOfBands: 1) }

    private let ringBuffer = StereoFloatRingBuffer(capacityFrames: 96_000) // ~2 sec @ 48k stereo
    private lazy var halOutput = HALOutput(ringBuffer: ringBuffer)

    private var activeSampleRate: Double?

    // MARK: - Lifecycle

    func start(input: AudioDevice, output: AudioDevice) {
        // 1. Tear down prior engine + HAL output.
        if engine.isRunning { engine.stop() }
        engine.reset()
        try? halOutput.stop()

        // 2. Reconcile sample rates between input and output devices.
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

        // 3. Client format that flows through the chain AND that the HAL output expects.
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

        // 4. Fresh AVAudioEngine for input + EQ.
        engine = AVAudioEngine()

        do {
            // 5. Bind input device on the engine's input node. (Output node intentionally left
            //    alone — it'll default to system output, which we then mute.)
            try AUHAL.bindInput(input.id, to: engine.inputNode, clientFormat: clientFormat)

            // 6. Build the EQ chain.
            eqNodes = (0..<4).map { _ in AVAudioUnitEQ(numberOfBands: 1) }
            for eq in eqNodes { engine.attach(eq) }
            engine.connect(engine.inputNode, to: eqNodes[0], format: clientFormat)
            for i in 0..<(eqNodes.count - 1) {
                engine.connect(eqNodes[i], to: eqNodes[i + 1], format: clientFormat)
            }
            engine.connect(eqNodes.last!, to: engine.mainMixerNode, format: clientFormat)

            // 7. Mute the mainMixer so the engine's accidental output (to system default = BlackHole)
            //    doesn't loop back into the input.
            engine.mainMixerNode.outputVolume = 0

            // 8. Re-apply current preset.
            if let preset = currentPreset { applyPresetToNodes(preset) }

            // 9. Install the tap that ferries processed audio into the ring buffer.
            eqNodes.last?.removeTap(onBus: 0)
            eqNodes.last?.installTap(onBus: 0, bufferSize: 1024, format: clientFormat) { [ringBuffer] buffer, _ in
                Self.feedRingBuffer(buffer, ringBuffer: ringBuffer)
            }

            // 10. Start the AVAudioEngine (drives input + EQ processing).
            engine.prepare()
            try engine.start()

            // 11. Start the HAL Output AU on the user's chosen device.
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            isRunning = true
            statusMessage = "Running · \(input.name) → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine started: \(self.statusMessage)")
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? halOutput.stop()
            if engine.isRunning { engine.stop() }
        }
    }

    func stop() {
        eqNodes.last?.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        try? halOutput.stop()
        ringBuffer.reset()
        isRunning = false
        statusMessage = "Stopped"
    }

    func reportStartFailure(_ message: String) {
        isRunning = false
        statusMessage = message
        log.error("Start blocked: \(message)")
    }

    // MARK: - Preset / band updates

    func apply(preset: EQPreset) {
        currentPreset = preset
        applyPresetToNodes(preset)
    }

    private func applyPresetToNodes(_ preset: EQPreset) {
        eqNodes[0].globalGain = preset.preamp
        for i in 1..<eqNodes.count {
            eqNodes[i].globalGain = 0
        }
        for (i, band) in preset.bands.prefix(eqNodes.count).enumerated() {
            applyBand(band, to: eqNodes[i].bands[0])
        }
    }

    func updateBand(index: Int, band: EQBand) {
        guard eqNodes.indices.contains(index) else { return }
        applyBand(band, to: eqNodes[index].bands[0])
        if var p = currentPreset, p.bands.indices.contains(index) {
            p.bands[index] = band
            currentPreset = p
        }
    }

    func setPreamp(_ dB: Float) {
        eqNodes[0].globalGain = dB
        if var p = currentPreset {
            p.preamp = dB
            currentPreset = p
        }
    }

    private func applyBand(_ band: EQBand, to auBand: AVAudioUnitEQFilterParameters) {
        auBand.filterType = band.type.auFilterType
        auBand.frequency = band.frequency
        auBand.gain = band.gain
        auBand.bandwidth = band.q.qToBandwidthOctaves
        auBand.bypass = false
    }

    // MARK: - Tap → ring buffer

    private static func feedRingBuffer(_ buffer: AVAudioPCMBuffer, ringBuffer: StereoFloatRingBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = Int(buffer.format.channelCount)
        if channels >= 2 {
            ringBuffer.write(left: data[0], right: data[1], frames: frames)
        } else if channels == 1 {
            ringBuffer.write(left: data[0], right: data[0], frames: frames)
        }
    }
}
