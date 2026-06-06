import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "EQEngine")

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
    /// slot B is selected — so audio still flows through Lurar but the
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
    private static let loudnessOffsetDefaultsKey = "lurar.loudnessOffsetDB"

    // Signal flow:
    //   ProcessTap (system audio, excl. own process, at tapSR)
    //     → crossfeed + EQProcessor (DSP at tapSR)
    //     → analyzer + clip meter
    //     → StereoResampler (tapSR → halSR)
    //     → ring buffer (halSR)
    //     → HALOutput AU (client format pinned at halSR) → DAC
    //
    // halSR is locked to the output device's nominal rate at engine start and
    // never changes for the lifetime of the run. When the tap rate changes
    // (a hi-res streaming app switching tracks), only the resampler and DSP
    // coefficients reconfigure — the tap, the ring buffer, and the HAL AU
    // keep running. That's what makes track switches seamless.
    //
    // Process Taps (macOS 14.2+) capture system output at the HAL layer without going
    // through an input device, so the orange microphone privacy indicator stays off.
    private let tapInput = ProcessTapInput()
    private let eqProcessor = EQProcessor()
    private let crossfeed = Crossfeed()
    /// Detects sustained silence on the tap input so the audio thread can skip
    /// crossfeed + the biquad cascades while nothing is playing — the bulk of
    /// the remaining idle-CPU cost after the resampler work in #101.
    private let silenceGate = SilenceGate()
    let spectrumAnalyzer = SpectrumAnalyzer()
    let clipMeter = ClipMeter()
    private let ringBuffer = StereoFloatRingBuffer(capacityFrames: 96_000) // ~2 s @ 48k stereo
    private lazy var halOutput = HALOutput(ringBuffer: ringBuffer)
    /// Lazily created the first time `fullStart` runs (we need to know halSR
    /// to size the converter's output format). Rebuilt only when halSR
    /// changes, which is rare — output device's nominal rate doesn't move
    /// once we've pinned it.
    private var resampler: StereoResampler?

    /// Owned here so it's retained for the engine's (i.e. the app's) lifetime
    /// without relying on SwiftUI @State binding semantics. Created lazily
    /// via `wireUpBypassHotkey()` after the App's StateObject machinery has
    /// finished setting up.
    private var bypassHotkey: BypassHotkey?

    /// Tap's current native rate. Updates on every soft reconfig.
    private var activeSampleRate: Double?
    /// HAL Output's pinned client-format rate for the current run. Set once
    /// in `fullStart` (from the output device's nominal rate at that moment)
    /// and held until the engine stops or the user picks a different output
    /// device with a different preferred rate. `activeSampleRate` ≠ this is
    /// the steady state during hi-res streaming.
    private var halSampleRate: Double?
    /// Output device the engine is currently driving, or nil when idle.
    /// Published so observers (e.g. `BurnInTracker`) can react to rebinds
    /// without polling.
    @Published private(set) var activeOutput: AudioDevice?

    /// User's per-app exclusion list. Read at tap-creation time in `fullStart`
    /// and after every change via `reEnumerateTapTargets`. Weak because the
    /// store is owned by the App (same lifetime as the engine, so this is just
    /// to avoid a retain cycle, not to handle real teardown).
    weak var excludedAppsStore: ExcludedAppsStore?

    // Tap-side sample-rate listener. Fires on every tap-rate change (hi-res
    // track switches when the listening DAC tracks the system default) and
    // triggers a soft reconfigure that keeps the chain running. There's a
    // diagnostic-only listener on the output side too — it logs device-rate
    // moves so we can correlate them with audible artifacts, but it doesn't
    // act on them. The HAL Output AU's internal SRC handles device-rate
    // changes; we're keeping the listener purely to surface what's happening.
    private var inputRateListener: AudioDevicePropertyListener?
    private var outputRateListener: AudioDevicePropertyListener?
    private var pendingRestart: DispatchWorkItem?
    private var restartCooldownUntil: Date = .distantPast
    /// Periodic ring-buffer state dump, ~every 3 s while running.
    /// Surfaces underruns (HAL reading from empty ring), drift, and
    /// rate mismatches we can't catch from the listeners alone.
    private var diagnosticTimer: Timer?

    /// Last-known nominal sample rate of the active output device. Used
    /// by the output-rate listener to tell a real device-rate move apart
    /// from a notification fired with no change (so the diagnostic log
    /// and the fade-mute trigger are both anchored to the right
    /// reference, not to our halSR pin).
    private var lastDeviceRate: Double = 0
    /// In-flight fade-in scheduled after a device-rate fade-mute. Tracked
    /// so that a second device-rate notification arriving during the
    /// mute window can cancel the pending un-mute and re-mute cleanly.
    private var pendingFadeInWork: DispatchWorkItem?
    /// In-flight teardown scheduled after a stop fade-out. Tracked so
    /// that a new start() arriving during the fade can finalize the
    /// pending teardown before rebuilding the chain.
    private var pendingStopWork: DispatchWorkItem?
    /// In-flight fade-in scheduled after the post-start mute hold.
    /// Tracked so a stop or rapid restart during the mute window can
    /// cancel it instead of unmuting a now-dead or rebuilt chain.
    private var pendingStartFadeInWork: DispatchWorkItem?

    /// User-defaults key for the "fade-mute on output device rate change"
    /// toggle (exposed in Settings → General). Defaults to `true` — the
    /// fade masks an audible artifact from the HAL Output AU's internal
    /// SRC re-tuning when the DAC's nominal rate changes mid-stream.
    static let muteOnDeviceRateChangeKey = "muteOnDeviceRateChange"

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.loudnessOffsetDefaultsKey) as? Double
        self.loudnessOffsetDB = Self.clampLoudness(Float(stored ?? 0))
        // Prime the processor so its `loudnessActive` snapshot matches the
        // persisted value before the first audio callback. Idempotent at
        // offset 0 (publishes an inactive identity).
        eqProcessor.publishLoudness(offsetDB: loudnessOffsetDB)
        // Wire up the global ⌥B hotkey here, NOT from `LurarApp.init`. Calling
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
        if isRunning, tapInput.deviceID != 0 {
            if rebindOutput(output: output) {
                return
            }
            log.info("Fast-path output rebind failed; falling back to full restart")
        }

        fullStart(output: output)
    }

    private func rebindOutput(output: AudioDevice) -> Bool {
        // Cancel any pending restart from a previous SR notification — picking
        // a new output device supersedes it. The fade-out that notification
        // armed is undone by the fade-in below.
        pendingRestart?.cancel()
        pendingRestart = nil
        do {
            // The new device may support a different max rate than the one
            // we pinned. If so, bail to fullStart so the resampler can be
            // rebuilt for the new output rate.
            let newMaxRate = Self.preferredHalSR(for: output.id) ?? halSampleRate ?? 0
            guard let pinnedHalSR = halSampleRate, abs(newMaxRate - pinnedHalSR) < 0.5 else {
                log.info("rebindOutput: device max rate differs (\(self.halSampleRate ?? 0) → \(newMaxRate)); falling back to full restart")
                return false
            }
            try halOutput.stop()
            guard let clientFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: pinnedHalSR,
                channels: 2,
                interleaved: false
            ) else {
                return false
            }
            try halOutput.start(deviceID: output.id, clientFormat: clientFormat)

            activeOutput = output
            log.info("Engine output rebound: → \(output.name) @ \(Int(pinnedHalSR)) Hz (halSR unchanged)")
            // Restore unity gain (a no-op if a fade-out wasn't in flight). Use
            // a short ramp so the first samples on the new device get the same
            // soft entry as a full restart.
            ringBuffer.setOutputGain(1, rampFrames: Int(Self.fadeInSeconds * pinnedHalSR))
            restartCooldownUntil = Date().addingTimeInterval(0.5)
            return true
        } catch {
            log.error("rebindOutput failed: \(String(describing: error))")
            try? halOutput.stop()
            return false
        }
    }

    /// Pick the HAL Output AU's pinned client rate for the given device.
    /// Strategy: pin to the device's *current nominal* rate, NOT its maximum.
    ///
    /// The earlier design pinned to the device max (capped at 192 kHz) on the
    /// theory that our resampler should "only ever upsample." But upsampling
    /// every buffer to 192 kHz with a long mastering-quality filter — plus
    /// moving 4× the samples through the ring buffer and HAL render callback —
    /// is the *expensive* direction, and it runs continuously even on silence.
    /// That was the dominant contributor to high idle CPU (issue #101).
    ///
    /// Pinning to the current rate makes the common case (tap 48k → hal 48k) a
    /// 1:1 passthrough with no SRC cost at all. If the device rate later moves
    /// (a hi-res app switching tracks on a DAC that follows the system
    /// default), the HAL Output AU's own internal SRC bridges halSR → device
    /// rate; we don't re-pin mid-run. Falls back to the max supported rate
    /// (capped at 192 kHz) only if the nominal rate can't be read.
    private static func preferredHalSR(for deviceID: AudioDeviceID) -> Double? {
        if let nominal = try? CoreAudioSampleRate.nominal(for: deviceID), nominal > 0 {
            return nominal
        }
        let ranges = CoreAudioSampleRate.available(for: deviceID)
        if let m = ranges.map(\.upperBound).max(), m > 0 {
            return min(m, 192_000)
        }
        return nil
    }

    private func fullStart(output: AudioDevice) {
        // Snapshot pre-teardown state so we can decide further down whether the
        // HAL Output AU needs to bounce. Bouncing costs ~tens of ms of AU
        // init + a DAC re-lock click on many devices; skipping it when the
        // client format is unchanged turns a tap-only rebuild (excluded-apps
        // toggle, same-rate spurious notification) into a near-silent
        // transition.
        let previousHalSampleRate = halSampleRate
        let outputUnchanged = (activeOutput?.id == output.id)
        let halWasRunning = (halOutput.deviceID != 0)

        // If a fade-then-stop was in flight, finalize it synchronously so the
        // pending teardown work won't fire later and tear down our brand-new
        // chain. (A start arriving during the fade window should rebuild
        // cleanly, not race against the scheduled stop.)
        if pendingStopWork != nil {
            finishStopSynchronously()
        }

        tearDownListeners()
        try? tapInput.stop()
        // Snap the ring buffer's output gain to silence before the audio
        // chain starts producing samples. The fade-in below ramps from
        // 0 → 1; without this pre-mute, a cold start (currentGain == 1
        // from RingBuffer init) makes the ramp a no-op and the first
        // samples land at full amplitude — audible on quiet content.
        // Safe on the restart path too: gain is already near 0 from the
        // scheduleRestart fade-out, so this is at worst a no-op.
        ringBuffer.setOutputGain(0, rampFrames: 0)
        // Don't stop HALOutput yet — leaving it alive lets it keep pulling
        // (faded, then silent) samples through the teardown so the DAC stays
        // locked. We only stop it below if the new client format actually
        // requires it.

        // 0. Process Tap API requires the private TCC service kTCCServiceAudioCapture.
        //    Without it the tap silently delivers zero buffers. Prompt the user if
        //    not yet authorized.
        if !AudioCapturePermission.ensureAuthorized() {
            try? halOutput.stop()
            ringBuffer.reset()
            isRunning = false
            statusMessage = "Audio capture permission denied. Grant in System Settings → Privacy & Security."
            log.error("Engine start aborted: TCC audio capture not authorized")
            return
        }

        // 1. Create the process tap + aggregate device. The aggregate's nominal
        //    rate follows the tap (system audio rate). We do NOT conform the
        //    output device's rate to the tap — that's the whole point of the
        //    pinned-halSR design: the device runs at its own preferred rate,
        //    and the resampler bridges tapSR → halSR.
        let inputDeviceID: AudioDeviceID
        let tapSampleRate: Double
        do {
            let excludedBundleIDs = excludedAppsStore?.excludedBundleIDs ?? []
            let prepared = try tapInput.prepare(excludedBundleIDs: excludedBundleIDs)
            inputDeviceID = prepared.deviceID
            tapSampleRate = prepared.sampleRate
            activeSampleRate = tapSampleRate
        } catch {
            try? tapInput.stop()
            try? halOutput.stop()
            ringBuffer.reset()
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Tap setup failed: \(String(describing: error))")
            return
        }

        // Pin halSR = device's *current nominal* rate (see `preferredHalSR`).
        // This keeps the steady-state pipeline at the device rate — typically
        // 48 kHz — so the resampler runs 1:1 (or not at all) instead of
        // upsampling every buffer to the device max. If a hi-res app later
        // moves the device rate mid-run, the HAL Output AU's internal SRC
        // bridges the halSR → device-rate gap; we don't re-pin.
        guard let halSR = Self.preferredHalSR(for: output.id) else {
            try? tapInput.stop()
            try? halOutput.stop()
            ringBuffer.reset()
            isRunning = false
            statusMessage = "Error: could not read output device sample rate"
            log.error("Could not read output device rate")
            return
        }
        self.halSampleRate = halSR

        // Decide whether to bounce HALOutput. Anything that changes the AU's
        // client format (halSR) or its bound device requires a full stop/init;
        // otherwise we can leave the AU running and just rebuild the tap
        // behind it. With pinned halSR, this is true for almost every restart.
        let canKeepHAL = halWasRunning
            && outputUnchanged
            && previousHalSampleRate == halSR
        if !canKeepHAL {
            try? halOutput.stop()
        }
        ringBuffer.reset()

        // 2. Client format for the output side — at halSR, not tapSR.
        guard let clientFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: halSR,
            channels: 2,
            interleaved: false
        ) else {
            try? tapInput.stop()
            try? halOutput.stop()
            statusMessage = "Error: could not build client format"
            return
        }
        log.info("Client format: \(clientFormat)")

        // Build / re-use the resampler. A new instance is needed only when
        // halSR changes (different output device's preferred rate); otherwise
        // reconfigure the existing instance for the new tapSR.
        if resampler == nil || resampler?.outputSampleRate != halSR {
            resampler = StereoResampler(outputSampleRate: halSR)
        }
        resampler?.configure(inputSampleRate: tapSampleRate)
        resampler?.reset()
        guard let resampler else {
            try? tapInput.stop()
            try? halOutput.stop()
            statusMessage = "Error: could not build resampler"
            return
        }

        // 3. Push current preset into the EQ processor so coefficients are ready before
        //    the first input callback fires. Crossfeed and the spectrum analyzer are
        //    configured against the tap's native rate so their per-sample math (ITD
        //    delay, FFT bin → Hz mapping) is correct relative to what was captured.
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: tapSampleRate)
        }
        crossfeed.reset()
        crossfeed.configure(sampleRate: tapSampleRate)
        spectrumAnalyzer.reset()
        spectrumAnalyzer.configure(sampleRate: tapSampleRate)
        clipMeter.reset()
        clipMeter.configure(sampleRate: tapSampleRate)
        silenceGate.reset()
        silenceGate.configure(sampleRate: tapSampleRate)

        // 4. Start the tap IOProc. Its callback runs on the audio thread:
        //    crossfeed → EQ → analyzer/clip-meter → SRC → ring buffer write.
        do {
            try tapInput.start { [eqProcessor, crossfeed, spectrumAnalyzer, clipMeter, ringBuffer, resampler, silenceGate] left, right, frames in
                // Skip the heavy DSP (crossfeed + biquad cascades) once the
                // input has been silent long enough that the filter tails have
                // decayed to ~0 — at that point processing more zeros is a
                // no-op, so this is bit-exact, not lossy. The gate releases on
                // the first non-silent block, so resuming audio isn't clipped.
                if silenceGate.shouldProcess(left: left, right: right, frames: frames) {
                    crossfeed.process(left: left, right: right, frames: frames)
                    eqProcessor.process(left: left, right: right, frames: frames)
                }
                // Meters always see the (silent or processed) buffer so the UI
                // reads correctly; both are a single cheap vDSP peak scan. The
                // resampler also always runs — it's a memcpy passthrough at
                // unity rate, and keeping it fed avoids ring-buffer underruns —
                // so the DAC continues to receive clean silence while idle.
                spectrumAnalyzer.submit(left: left, right: right, frames: frames)
                // Post-loudness, pre-output: this is the last point at which we
                // can measure what the user actually hears before the ring
                // buffer hands it to the output device.
                clipMeter.submit(left: left, right: right, frames: frames)
                resampler.processIntoRingBuffer(left: left, right: right, frames: frames, ringBuffer: ringBuffer)
            }

            // 5. Start the output AU on the user's chosen device — unless it's
            //    still alive from the previous run.
            if !canKeepHAL {
                try halOutput.start(deviceID: output.id, clientFormat: clientFormat)
            }

            activeOutput = output
            isRunning = true
            log.info("Engine started: tap=\(Int(tapSampleRate)) Hz → \(output.name) @ \(Int(halSR)) Hz halBounced=\(!canKeepHAL)")

            // Hold the output muted for ~150 ms before fading in, then ramp
            // up over the standard fade-in window. On a cold engine start,
            // the system audio routing doesn't switch to our tap instantly:
            // for a brief window the same source audio is delivered to the
            // DAC twice — once via the still-active direct route, and once
            // via the tap → resampler → ring → HAL Output AU pipeline with
            // a small capture lag. That overlap is what produced the audible
            // "loops 10 ms back" artifact on startup. Holding silence past
            // the routing switch lets the direct route stop before we speak.
            scheduleStartupFadeIn(halSR: halSR)

            restartCooldownUntil = Date().addingTimeInterval(0.5)

            lastDeviceRate = (try? CoreAudioSampleRate.nominal(for: output.id)) ?? 0
            installListeners(inputDeviceID: inputDeviceID, outputDeviceID: output.id)
            startDiagnosticTimer()
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? tapInput.stop()
            try? halOutput.stop()
        }
    }

    // Fade-in is longer than fade-out because there's usually a brief gap
    // between fullStart returning and the new tap's first IOProc callback
    // landing samples in the ring buffer. The ring buffer only advances the
    // ramp on real reads, but a longer target window keeps the rise gentle
    // even on slow first-callback devices.
    private static let fadeOutSeconds: Double = 0.010
    private static let fadeInSeconds: Double = 0.030

    // Used by stop() to fade the ring buffer to silence before tearing
    // down the audio chain. Longer than the restart fade-out because we
    // want the stop transition to be deliberately gentle, not just
    // glitch-suppressing.
    private static let stopFadeOutSeconds: Double = 0.040

    // Hold the output muted for this long after `fullStart` succeeds
    // before kicking off the regular fade-in. Masks the
    // tap-activation overlap window where audio briefly comes out the
    // DAC both via the direct route and via our pipeline. Tuned
    // empirically — the audible artifact a user reported was ~10 ms,
    // and 150 ms is a comfortable margin.
    private static let startupMuteHoldSeconds: Double = 0.150

    /// Schedule the fade-in to unity after `startupMuteHoldSeconds`. The
    /// ring buffer stays at gain 0 during the hold (snapped to 0 at the
    /// top of `fullStart`), so the audio thread emits silence while the
    /// system audio routing finishes switching from the direct route to
    /// our tap. A pending fade-in is cancellable so stop / restart paths
    /// can supersede it cleanly.
    private func scheduleStartupFadeIn(halSR: Double) {
        pendingStartFadeInWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning else { return }
                let sr = self.halSampleRate ?? halSR
                self.ringBuffer.setOutputGain(1, rampFrames: Int(Self.fadeInSeconds * sr))
                self.pendingStartFadeInWork = nil
            }
        }
        pendingStartFadeInWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startupMuteHoldSeconds, execute: work)
    }

    /// Stop the engine, fading audio to silence before tearing down the
    /// audio chain so the DAC doesn't get cut mid-buffer. UI state
    /// (`isRunning`, `statusMessage`) updates eagerly; audio teardown
    /// happens after the fade completes. `completion` fires once the
    /// teardown is done — used by the app delegate to gate
    /// `applicationShouldTerminate`'s reply on the fade finishing.
    func stop(completion: (() -> Void)? = nil) {
        guard isRunning, halSampleRate != nil else {
            finishStopSynchronously()
            completion?()
            return
        }

        let sr = halSampleRate ?? 48000
        ringBuffer.setOutputGain(0, rampFrames: Int(Self.stopFadeOutSeconds * sr))

        // Tear down listeners and diagnostics eagerly so rate-change
        // notifications and any pending restart/fade-in work scheduled
        // before stop() was called can't fire fullStart() or unmute the
        // ring buffer mid-fade. The tap and HAL Output AU stay alive
        // until `finishStopSynchronously` runs after the fade.
        tearDownListeners()
        stopDiagnosticTimer()

        // Flip UI state immediately so the menu bar reflects "Stopped"
        // before the fade completes. The audio chain keeps running (now
        // ramping toward silence) until the deferred teardown.
        isRunning = false
        statusMessage = "Stopped"

        pendingStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { completion?(); return }
                self.finishStopSynchronously()
                completion?()
            }
        }
        pendingStopWork = work
        // Small safety margin past the ramp duration so the audio thread
        // has actually consumed faded samples down to ~0 before we stop
        // the AU.
        let delay = Self.stopFadeOutSeconds + 0.015
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Synchronously tear down listeners, the diagnostic timer, the tap,
    /// the HAL Output AU, and reset the ring buffer. Called either
    /// directly when the engine wasn't running, or from the deferred
    /// stop completion after the fade.
    private func finishStopSynchronously() {
        pendingStopWork?.cancel()
        pendingStopWork = nil
        tearDownListeners()
        stopDiagnosticTimer()
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
        halSampleRate = nil
        isRunning = false
        statusMessage = "Stopped"
    }

    // MARK: - Runtime change handling

    private func installListeners(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) {
        inputRateListener = AudioDevicePropertyListener(
            deviceID: inputDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in
                self?.handleTapRateNotification(deviceID: inputDeviceID)
            }
        }
        // Output-device rate listener. The HAL Output AU's internal SRC
        // already bridges device-rate changes to our pinned halSR, so we
        // never tear the chain down here — but a hi-res-source DAC moving
        // from (say) 192 kHz to 44.1 kHz on a track change produces an
        // audible pitch transient as Core Audio's SRC re-tunes its
        // polyphase state. The handler fades the ring-buffer output to
        // silence for ~150 ms across the transition to mask that
        // artifact. Behavior is gated by the `muteOnDeviceRateChange`
        // user-defaults toggle.
        outputRateListener = AudioDevicePropertyListener(
            deviceID: outputDeviceID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in
                self?.handleOutputRateNotification(deviceID: outputDeviceID)
            }
        }
    }

    /// Tap rate changed — the system default output (which the aggregate
    /// device tracks) is delivering samples at a new rate. Common path
    /// during hi-res streaming when the listening DAC *is* the system
    /// default: every track switch triggers this.
    ///
    /// With the pinned-halSR design this never restarts the audio chain —
    /// it reconfigures DSP coefficients and the resampler's input rate in
    /// place. The tap, the ring buffer, and the HAL Output AU all keep
    /// running, so the DAC stays locked and audio is continuous.
    private func handleTapRateNotification(deviceID: AudioDeviceID) {
        guard isRunning else { return }
        guard let actual = try? CoreAudioSampleRate.nominal(for: deviceID) else {
            log.info("Tap rate notification fired but rate read failed")
            return
        }
        if let active = activeSampleRate, abs(actual - active) < 0.5 {
            // Promoted to .info so it shows up under the default log
            // predicate — when investigating glitches we need to know
            // whether the listener fired at all.
            log.info("Tap rate notification fired but rate unchanged at \(Int(actual)) Hz — no reconfigure needed")
            return
        }
        softReconfigureForTapSR(actual)
    }

    /// The output device's nominal sample rate changed (or Core Audio
    /// fired a no-op notification — most often a track change in a
    /// hi-res streaming app reconfiguring the DAC). If the rate actually
    /// moved and the toggle is enabled, ride the resulting SRC-retune
    /// transient with a brief fade-mute on the ring buffer.
    private func handleOutputRateNotification(deviceID: AudioDeviceID) {
        guard isRunning else { return }
        let actual = (try? CoreAudioSampleRate.nominal(for: deviceID)) ?? -1
        let previous = lastDeviceRate
        if abs(actual - previous) < 0.5 {
            log.info("Output rate notification fired but device rate unchanged at \(Int(actual)) Hz")
            return
        }
        log.info("Output device rate moved: \(Int(previous)) Hz → \(Int(actual)) Hz (halSR pin unchanged; HAL Output AU bridging via internal SRC)")
        lastDeviceRate = actual

        let muteEnabled = UserDefaults.standard.object(forKey: Self.muteOnDeviceRateChangeKey) as? Bool ?? true
        if muteEnabled {
            scheduleDeviceRateFadeMute()
        }
    }

    // Fade-mute envelope used to mask the HAL Output AU's SRC retune
    // when the output device's nominal sample rate changes mid-stream.
    // Core Audio fires the listener *after* the device rate has already
    // changed, so by the time we mute, part of the SRC transient is
    // already in flight to the DAC. We compensate by muting fast (short
    // fade-out) and holding silence long enough that the SRC settles
    // completely before we restore.
    //
    // Total disturbance: 10 + 250 + 80 ≈ 340 ms, with 250 ms of full
    // silence in the middle. That's a noticeable pause on track changes,
    // but masks the audible pitch transient.
    private static let deviceRateFadeOutSeconds: Double = 0.010
    private static let deviceRateMuteHoldSeconds: Double = 0.250
    private static let deviceRateFadeInSeconds: Double = 0.080

    /// Quickly ramp the ring-buffer output to zero, then schedule a
    /// slower ramp back to unity after a brief hold. If another
    /// device-rate notification arrives while a fade-in is pending,
    /// cancel it and re-mute — back-to-back rate moves (e.g. 96 → 192
    /// → 44.1 across a single track change) stay continuously ducked
    /// until the device finally settles.
    private func scheduleDeviceRateFadeMute() {
        let sr = halSampleRate ?? 48000
        let totalMs = Int((Self.deviceRateFadeOutSeconds + Self.deviceRateMuteHoldSeconds + Self.deviceRateFadeInSeconds) * 1000)
        log.info("Device-rate fade-mute scheduled (~\(totalMs) ms total disturbance)")
        pendingFadeInWork?.cancel()
        ringBuffer.setOutputGain(0, rampFrames: Int(Self.deviceRateFadeOutSeconds * sr))

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning else { return }
                let srNow = self.halSampleRate ?? 48000
                self.ringBuffer.setOutputGain(1, rampFrames: Int(Self.deviceRateFadeInSeconds * srNow))
                self.pendingFadeInWork = nil
            }
        }
        pendingFadeInWork = work
        let delay = Self.deviceRateFadeOutSeconds + Self.deviceRateMuteHoldSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startDiagnosticTimer() {
        stopDiagnosticTimer()
        ringBuffer.resetUnderrunCount()
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.logDiagnosticSnapshot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        diagnosticTimer = timer
    }

    private func stopDiagnosticTimer() {
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
    }

    private func logDiagnosticSnapshot() {
        guard isRunning else { return }
        let snapshot = ringBuffer.underrunSnapshot()
        let hal = halSampleRate ?? 0
        let tap = activeSampleRate ?? 0
        let deviceRate = (activeOutput?.id).flatMap { try? CoreAudioSampleRate.nominal(for: $0) } ?? 0
        let availableMs = hal > 0 ? Double(snapshot.available) * 1000.0 / hal : 0
        if snapshot.reads > 0 {
            // Underrun → reader hit the empty edge of the ring; HAL got
            // zero-padded silence. Most likely cause of audible glitches.
            log.info("DIAG: tap=\(Int(tap)) Hz hal=\(Int(hal)) Hz device=\(Int(deviceRate)) Hz ringFill=\(snapshot.available)f (~\(String(format: "%.1f", availableMs)) ms) underruns=\(snapshot.reads) worst=\(snapshot.worstShortfall)f")
        } else {
            log.info("DIAG: tap=\(Int(tap)) Hz hal=\(Int(hal)) Hz device=\(Int(deviceRate)) Hz ringFill=\(snapshot.available)f (~\(String(format: "%.1f", availableMs)) ms)")
        }
        ringBuffer.resetUnderrunCount()
    }

    /// Apply a new tap sample rate without tearing the audio chain down.
    /// DSP modules update their coefficients while preserving filter state
    /// (one filter-length transient, inaudible); the resampler rebuilds its
    /// internal AudioConverter (briefly holds a lock the audio thread waits
    /// on — sub-millisecond in practice).
    private func softReconfigureForTapSR(_ newSR: Double) {
        log.info("Soft reconfig: tap \(self.activeSampleRate ?? 0) → \(newSR) Hz (halSR \(self.halSampleRate ?? 0) Hz)")
        activeSampleRate = newSR
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: newSR)
        }
        crossfeed.configure(sampleRate: newSR)
        spectrumAnalyzer.configure(sampleRate: newSR)
        clipMeter.configure(sampleRate: newSR)
        silenceGate.configure(sampleRate: newSR)
        resampler?.configure(inputSampleRate: newSR)
    }

    private func tearDownListeners() {
        pendingRestart?.cancel()
        pendingRestart = nil
        pendingFadeInWork?.cancel()
        pendingFadeInWork = nil
        pendingStartFadeInWork?.cancel()
        pendingStartFadeInWork = nil
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
        // Begin the fade-out *now*, not in the debounced work item. The
        // 150 ms debounce gives HALOutput plenty of callbacks to drain the
        // ramp before the actual teardown starts — by the time we reset the
        // ring buffer, the DAC has been hearing silence for a while.
        if let sr = activeSampleRate {
            ringBuffer.setOutputGain(0, rampFrames: Int(Self.fadeOutSeconds * sr))
        }
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
