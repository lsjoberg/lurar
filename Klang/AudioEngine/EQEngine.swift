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
    /// True while the EQ is running the A/B comparison slot mode (two presets
    /// pre-loaded, toggling between them). Editor sliders watch this to gate
    /// per-band edits — those calls no-op against the processor while slot
    /// mode is active, but the UI shouldn't pretend the slider is live.
    @Published private(set) var isInComparisonMode: Bool = false
    /// True while bypass is active: the EQ is in slot mode with the user's
    /// current preset in slot A and the bundled `Flat` preset in slot B, and
    /// slot B is selected — so audio still flows through Klang but the
    /// cascades produce a flat response (modulo loudness-match attenuation).
    /// Exits by routing through `apply(preset:)` so the cascades return to a
    /// coherent single-preset state.
    @Published private(set) var isBypassed: Bool = false
    /// Loudness-compensation slider value in dB phon offset below the 83-phon
    /// mastering reference. 0 = off, more negative = quieter listening,
    /// more lift. Clamped to `loudnessOffsetRange`. Global setting persisted
    /// in UserDefaults — independent of the active preset.
    @Published private(set) var loudnessOffsetDB: Float = 0

    static let loudnessOffsetRange: ClosedRange<Float> = -40...0
    private static let loudnessOffsetDefaultsKey = "klang.loudnessOffsetDB"

    // Signal flow:
    //   ProcessTap (system audio, excl. own process) → aggregate device
    //     → input AU → EQProcessor (10-band vDSP biquad + preamp) → ring buffer
    //                                                                ↓
    //                                                             HALOutput (DAC)
    //
    // Process Taps (macOS 14.2+) capture system output at the HAL layer without going
    // through an input device, so the orange microphone privacy indicator stays off.
    private let tapInput = ProcessTapInput()
    private let eqProcessor = EQProcessor()
    private let crossfeed = Crossfeed()
    let spectrumAnalyzer = SpectrumAnalyzer()
    let clipMeter = ClipMeter()
    private let ringBuffer = StereoFloatRingBuffer(capacityFrames: 96_000) // ~2 s @ 48k stereo
    private lazy var halOutput = HALOutput(ringBuffer: ringBuffer)

    /// Owned here so it's retained for the engine's (i.e. the app's) lifetime
    /// without relying on SwiftUI @State binding semantics. Created lazily
    /// via `wireUpBypassHotkey()` after the App's StateObject machinery has
    /// finished setting up.
    private var bypassHotkey: BypassHotkey?

    private var activeSampleRate: Double?
    private var activeOutput: AudioDevice?

    /// User's per-app exclusion list. Read at tap-creation time in `fullStart`
    /// and after every change via `reEnumerateTapTargets`. Weak because the
    /// store is owned by the App (same lifetime as the engine, so this is just
    /// to avoid a retain cycle, not to handle real teardown).
    weak var excludedAppsStore: ExcludedAppsStore?

    // Per-device sample-rate listeners. When the system output rate changes on a track
    // change, the aggregate device wrapping the tap follows; we re-reconcile and restart.
    private var inputRateListener: AudioDevicePropertyListener?
    private var outputRateListener: AudioDevicePropertyListener?
    private var pendingRestart: DispatchWorkItem?
    private var restartCooldownUntil: Date = .distantPast

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.loudnessOffsetDefaultsKey) as? Double
        self.loudnessOffsetDB = Self.clampLoudness(Float(stored ?? 0))
        // Prime the processor so its `loudnessActive` snapshot matches the
        // persisted value before the first audio callback. Idempotent at
        // offset 0 (publishes an inactive identity).
        eqProcessor.publishLoudness(offsetDB: loudnessOffsetDB)
        // Wire up the global ⌥B hotkey here, NOT from `KlangApp.init`. Calling
        // methods on a `@StateObject`'s wrappedValue from an App's init operates
        // on a transient instance that SwiftUI later discards before binding the
        // persistent storage — anything async we scheduled there fires after the
        // throwaway is deallocated. Doing it from EQEngine's own init guarantees
        // `self` is the instance being constructed.
        wireUpBypassHotkey()
    }

    // MARK: - Lifecycle

    func start(output: AudioDevice) {
        log.info("start output=\(output.name)/\(output.uid) prev=\(self.activeOutput?.uid ?? "nil") running=\(self.isRunning)")

        // Fast path: engine is already running and only the output device is changing.
        // The tap + aggregate + input AU don't depend on the output, so leave them up
        // and only re-bind HALOutput. Rebuilding the tap takes ~hundreds of ms and
        // would hang the picker.
        if isRunning, let sampleRate = activeSampleRate, tapInput.deviceID != 0 {
            if rebindOutput(output: output, sampleRate: sampleRate) {
                return
            }
            log.info("Fast-path output rebind failed; falling back to full restart")
        }

        fullStart(output: output)
    }

    private func rebindOutput(output: AudioDevice, sampleRate: Double) -> Bool {
        outputRateListener = nil
        do {
            try halOutput.stop()
            if try CoreAudioSampleRate.nominal(for: output.id) != sampleRate {
                try CoreAudioSampleRate.setNominal(sampleRate, for: output.id)
            }
            guard let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 2,
                interleaved: false
            ) else {
                return false
            }
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeOutput = output
            statusMessage = "Running · System → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine output rebound: \(self.statusMessage)")
            installOutputRateListener(output: output)
            restartCooldownUntil = Date().addingTimeInterval(0.5)
            return true
        } catch {
            log.error("rebindOutput failed: \(String(describing: error))")
            try? halOutput.stop()
            return false
        }
    }

    private func fullStart(output: AudioDevice) {
        tearDownListeners()
        try? tapInput.stop()
        try? halOutput.stop()
        ringBuffer.reset()

        // 0. Process Tap API requires the private TCC service kTCCServiceAudioCapture.
        //    Without it the tap silently delivers zero buffers. Prompt the user if
        //    not yet authorized.
        if !AudioCapturePermission.ensureAuthorized() {
            isRunning = false
            statusMessage = "Audio capture permission denied. Grant in System Settings → Privacy & Security."
            log.error("Engine start aborted: TCC audio capture not authorized")
            return
        }

        // 1. Create the process tap + aggregate device. The aggregate's nominal rate
        //    follows the tap (system audio rate). Conform the output device to that
        //    rate if it differs and the output supports it.
        let inputDeviceID: AudioDeviceID
        let sampleRate: Double
        do {
            let excludedBundleIDs = excludedAppsStore?.excludedBundleIDs ?? []
            let prepared = try tapInput.prepare(excludedBundleIDs: excludedBundleIDs)
            inputDeviceID = prepared.deviceID
            sampleRate = prepared.sampleRate
            if try CoreAudioSampleRate.nominal(for: output.id) != sampleRate {
                if CoreAudioSampleRate.supports(sampleRate, for: output.id) {
                    try CoreAudioSampleRate.setNominal(sampleRate, for: output.id)
                } else {
                    log.info("Output \(output.name) does not support tap rate \(sampleRate); leaving as-is and relying on HAL conversion")
                }
            }
            activeSampleRate = sampleRate
        } catch {
            try? tapInput.stop()
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Tap setup failed: \(String(describing: error))")
            return
        }

        // 2. Client format for the output side. Tap input feeds the EQ at the tap's
        //    native format; HALOutput pulls Float32 stereo from the ring buffer.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            try? tapInput.stop()
            statusMessage = "Error: could not build client format"
            return
        }
        log.info("Client format: \(clientFormat)")

        // 3. Push current preset into the EQ processor so coefficients are ready before
        //    the first input callback fires. Crossfeed and the spectrum analyzer are
        //    configured against the same sample rate so their per-sample math (ITD
        //    delay, FFT bin → Hz mapping) is correct.
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: sampleRate)
        }
        crossfeed.reset()
        crossfeed.configure(sampleRate: sampleRate)
        spectrumAnalyzer.reset()
        spectrumAnalyzer.configure(sampleRate: sampleRate)
        clipMeter.reset()
        clipMeter.configure(sampleRate: sampleRate)

        // 4. Start the tap IOProc. Its callback runs on the audio thread: crossfeed
        //    first (so EQ shapes the summed signal), EQ in-place on scratch buffers,
        //    hand the post-EQ samples to the spectrum analyzer for visualization,
        //    then write to the ring buffer.
        do {
            try tapInput.start { [eqProcessor, crossfeed, spectrumAnalyzer, clipMeter, ringBuffer] left, right, frames in
                crossfeed.process(left: left, right: right, frames: frames)
                eqProcessor.process(left: left, right: right, frames: frames)
                spectrumAnalyzer.submit(left: left, right: right, frames: frames)
                // Post-loudness, pre-output: this is the last point at which we
                // can measure what the user actually hears before the ring
                // buffer hands it to the output device.
                clipMeter.submit(left: left, right: right, frames: frames)
                ringBuffer.write(left: left, right: right, frames: frames)
            }

            // 5. Start the output AU on the user's chosen device.
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeOutput = output
            isRunning = true
            statusMessage = "Running · System → \(output.name) @ \(Int(sampleRate)) Hz"
            log.info("Engine started: \(self.statusMessage)")

            restartCooldownUntil = Date().addingTimeInterval(0.5)

            installListeners(inputDeviceID: inputDeviceID, output: output)
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? tapInput.stop()
            try? halOutput.stop()
        }
    }

    func stop() {
        tearDownListeners()
        try? tapInput.stop()
        try? halOutput.stop()
        ringBuffer.reset()
        if isInComparisonMode {
            eqProcessor.exitSlotMode()
            isInComparisonMode = false
        }
        if isBypassed {
            eqProcessor.exitSlotMode()
            isBypassed = false
        }
        activeOutput = nil
        activeSampleRate = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - Runtime change handling

    private func installListeners(inputDeviceID: AudioDeviceID, output: AudioDevice) {
        inputRateListener = AudioDevicePropertyListener(
            deviceID: inputDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in self?.scheduleRestart(reason: "tap rate change") }
        }
        installOutputRateListener(output: output)
    }

    private func installOutputRateListener(output: AudioDevice) {
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

    private func scheduleRestart(reason: String, force: Bool = false) {
        guard isRunning, activeOutput != nil else { return }
        if !force, Date() < restartCooldownUntil {
            log.info("Ignoring \(reason) during cooldown")
            return
        }
        log.info("Scheduling engine restart: \(reason)")
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning, let output = self.activeOutput else { return }
                // SR changed: the input AU's client format is stale, so a fast-path
                // output-only rebind is not enough. Force a full teardown + rebuild.
                self.fullStart(output: output)
            }
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Rebuild the process tap so a changed exclusion list takes effect.
    /// Tap targets are fixed at tap-creation time — there's no way to add or
    /// remove a target on a live tap, so we tear down and rebuild via the
    /// existing debounced restart path. No-op when the engine is stopped.
    /// Bypasses `restartCooldownUntil` because this is user-initiated; the
    /// cooldown exists to suppress restart loops from system events.
    func reEnumerateTapTargets() {
        guard isRunning else { return }
        scheduleRestart(reason: "excluded apps changed", force: true)
    }

    func reportStartFailure(_ message: String) {
        isRunning = false
        statusMessage = message
        log.error("Start blocked: \(message)")
    }

    // MARK: - Preset / band updates

    func apply(preset: EQPreset) {
        if isInComparisonMode {
            // The user picked a preset somewhere (menu bar / editor dropdown) —
            // honour that by exiting comparison mode silently. The session view
            // observes `isInComparisonMode` and resets itself.
            eqProcessor.exitSlotMode()
            isInComparisonMode = false
        }
        if isBypassed {
            // Same idea for bypass: any explicit preset apply takes the engine
            // out of slot mode. Hold-to-bypass observers (the hotkey, the menu
            // bar Bypass toggle) watch `isBypassed` and reflect the new state.
            eqProcessor.exitSlotMode()
            isBypassed = false
        }
        currentPreset = preset
        eqProcessor.configure(preset: preset, sampleRate: activeSampleRate ?? 48_000)
    }

    func updateBand(index: Int, band: EQBand) {
        // Per-band edits are gated in the editor UI while comparison is active,
        // but defend the audio path too: don't let a stray slider drag desync
        // from the playing slot. Same guard for bypass — slot A holds a frozen
        // snapshot of the preset at bypass-entry, so editing while bypassed
        // would silently desync `currentPreset` from what unbypass will play.
        guard !isInComparisonMode, !isBypassed else { return }
        eqProcessor.updateBand(index: index, band: band)
        if var p = currentPreset, p.bands.indices.contains(index) {
            p.bands[index] = band
            currentPreset = p
        }
    }

    func setPreamp(_ dB: Float) {
        guard !isInComparisonMode, !isBypassed else { return }
        eqProcessor.setPreamp(dB: dB)
        if var p = currentPreset {
            p.preamp = dB
            currentPreset = p
        }
    }

    // MARK: - Crossfeed

    func setCrossfeedIntensity(_ value: Float) {
        crossfeed.setIntensity(value)
    }

    func setCrossfeedCutoff(_ hz: Float) {
        crossfeed.setCutoff(hz)
    }

    // MARK: - Loudness compensation

    /// Update the loudness offset (dB, clamped to [−40, 0]) and persist. The
    /// processor recomputes the six-biquad cascade, the active flag, and a
    /// headroom attenuation in a single lock acquisition; the audio thread
    /// picks the new state up on its next callback.
    func setLoudnessOffset(_ dB: Float) {
        let clamped = Self.clampLoudness(dB)
        if clamped == loudnessOffsetDB { return }
        loudnessOffsetDB = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.loudnessOffsetDefaultsKey)
        eqProcessor.publishLoudness(offsetDB: clamped)
    }

    private static func clampLoudness(_ dB: Float) -> Float {
        min(max(dB, loudnessOffsetRange.lowerBound), loudnessOffsetRange.upperBound)
    }

    // MARK: - A/B comparison

    /// Load two presets into the EQ's slot mode. `matchGain*` are dB attenuations
    /// (≤ 0) from `LoudnessMatcher` so neither preset has a perceived loudness
    /// advantage. Caller must ensure both presets are fully hydrated snapshots.
    func loadComparisonSlots(
        presetA: EQPreset,
        presetB: EQPreset,
        matchGainA: Float,
        matchGainB: Float
    ) {
        // Comparison and bypass share the slot infrastructure. Starting a
        // comparison takes ownership: the previous bypass slots are about to
        // be overwritten with comparison presets, so clear the flag so
        // observers don't think bypass is still in effect.
        if isBypassed { isBypassed = false }
        let sr = activeSampleRate ?? 48_000
        eqProcessor.loadSlots(
            presetA: presetA,
            presetB: presetB,
            sampleRate: sr,
            extraGainDBA: matchGainA,
            extraGainDBB: matchGainB
        )
        isInComparisonMode = true
    }

    func setComparisonSlot(_ slot: EQProcessor.Slot) {
        guard isInComparisonMode else { return }
        eqProcessor.setActiveSlot(slot)
    }

    /// Briefly mute the output (post-cascade) so the comparison flow can hide
    /// the audible swap between trials. Caller schedules the unmute.
    func setComparisonMute(_ muted: Bool) {
        guard isInComparisonMode else { return }
        eqProcessor.setMute(muted)
    }

    /// Leave comparison mode and re-publish the engine's `currentPreset` so the
    /// cascades are coherent with whatever the rest of the UI thinks is selected.
    func exitComparisonMode() {
        guard isInComparisonMode else { return }
        eqProcessor.exitSlotMode()
        isInComparisonMode = false
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: activeSampleRate ?? 48_000)
        }
    }

    // MARK: - Bypass (EQ ↔ Flat)

    /// Idempotently install the global ⌥B hotkey. Called from EQEngine.init
    /// so it operates on the real, persisted engine instance (not a transient
    /// `@StateObject` wrappedValue throwaway). The BypassHotkey holds a weak
    /// reference back to the engine — no retain cycle.
    func wireUpBypassHotkey() {
        guard bypassHotkey == nil else { return }
        bypassHotkey = BypassHotkey(engine: self)
    }

    /// Apply or remove the Flat-preset bypass while the engine keeps running.
    /// Uses the same A/B slot infrastructure as comparison mode so the swap
    /// is sample-accurate and loudness-matched: enters slot mode with the
    /// user's current preset in slot A and the bundled Flat preset in slot B,
    /// then selects slot B. Exit goes back through `apply(preset:)` so the
    /// cascades return to the regular single-preset path.
    ///
    /// No-op when the engine isn't running, when there's no current preset,
    /// or when an A/B comparison session is in progress — the comparison
    /// owns slot mode for the duration of the session.
    func setBypassed(_ on: Bool) {
        if on == isBypassed { return }
        if isInComparisonMode { return }
        if on {
            guard isRunning, let preset = currentPreset else { return }
            let flat = EQPreset.flat
            let (gA, gB) = LoudnessMatcher.equalAttenuationsDB(presetA: preset, presetB: flat)
            eqProcessor.loadSlots(
                presetA: preset,
                presetB: flat,
                sampleRate: activeSampleRate ?? 48_000,
                extraGainDBA: gA,
                extraGainDBB: gB
            )
            eqProcessor.setActiveSlot(.b)
            isBypassed = true
        } else if let preset = currentPreset {
            // apply(preset:) handles `exitSlotMode` + `configure` + flag reset.
            apply(preset: preset)
        } else {
            eqProcessor.exitSlotMode()
            isBypassed = false
        }
    }
}
