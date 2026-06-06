import Foundation
import CoreAudio
import AudioToolbox
import Combine
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "EQEngine")

@MainActor
final class EQEngine: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    /// True while audio is actually flowing — the tap is delivering buffers and
    /// the output peak is above the silence floor. Distinct from `isRunning`,
    /// which only means the chain is built and driving the DAC (it stays true
    /// through a paused track, when the engine is pushing silence). Observers
    /// that care about real playback rather than engine uptime — e.g.
    /// `BurnInTracker` — gate on this. Re-derived on the engine's periodic
    /// diagnostic tick; see `pollPlayback`.
    @Published private(set) var isPlayingAudio: Bool = false
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

    // Signal flow (single real-time thread):
    //   ProcessTapIO aggregate IOProc, clocked by the output device:
    //     inInputData (system audio mixdown, tap, at deviceSR)
    //       → crossfeed + EQProcessor (DSP in place)
    //       → analyzer + clip meter
    //       → output gain ramp
    //     → copied into outOutputData → DAC
    //
    // The output device is the aggregate's main sub-device, so the tap and the
    // output share one clock and one sample rate. There is no resampler, no ring
    // buffer, and no separate HAL Output AU — the EQ'd audio is written straight
    // into the device's output buffers in the same callback that captured it.
    //
    // If the output device's nominal rate changes (e.g. the user picks a new rate
    // in Audio MIDI Setup, or a hi-res app moves it), the aggregate rate follows
    // and the rate listener reconfigures the DSP coefficients in place — the tap,
    // the IOProc, and the device keep running, so the change is seamless.
    //
    // Process Taps (macOS 14.2+) capture system output at the HAL layer without going
    // through an input device, so the orange microphone privacy indicator stays off.
    private let tapIO = ProcessTapIO()
    private let eqProcessor = EQProcessor()
    private let crossfeed = Crossfeed()
    let spectrumAnalyzer = SpectrumAnalyzer()
    let clipMeter = ClipMeter()
    /// Output fade/mute envelope applied as the last DSP stage in the IOProc.
    /// Replaces the ring buffer's gain ramp in the old two-thread pipeline.
    private let gainRamp = OutputGainRamp()

    /// Owned here so it's retained for the engine's (i.e. the app's) lifetime
    /// without relying on SwiftUI @State binding semantics. Created lazily
    /// via `wireUpBypassHotkey()` after the App's StateObject machinery has
    /// finished setting up.
    private var bypassHotkey: BypassHotkey?

    /// The aggregate's (== output device's) current nominal rate. Updates on
    /// every soft reconfigure. nil when the engine is stopped.
    private var activeSampleRate: Double?
    /// Output device the engine is currently driving, or nil when idle.
    /// Published so observers (e.g. `BurnInTracker`) can react to rebinds
    /// without polling.
    @Published private(set) var activeOutput: AudioDevice?

    /// User's per-app exclusion list. Read at tap-creation time in `fullStart`
    /// and after every change via `reEnumerateTapTargets`. Weak because the
    /// store is owned by the App (same lifetime as the engine, so this is just
    /// to avoid a retain cycle, not to handle real teardown).
    weak var excludedAppsStore: ExcludedAppsStore?

    // Aggregate sample-rate listener. The output device is the aggregate's main
    // sub-device, so this fires whenever the output device's nominal rate moves
    // (a manual change in Audio MIDI Setup, or a hi-res app driving the device).
    // The handler reconfigures DSP coefficients in place and optionally rides the
    // transition with a brief fade-mute — it never tears the chain down.
    private var rateListener: AudioDevicePropertyListener?
    private var pendingRestart: DispatchWorkItem?
    private var restartCooldownUntil: Date = .distantPast
    /// Periodic tick while running (see `diagnosticInterval`). Drives playback
    /// detection (`pollPlayback`) and logs a small rate/throughput snapshot off
    /// the same wakeup, so detection adds no idle-CPU timer of its own.
    private var diagnosticTimer: Timer?
    /// Clip-meter frame count at the previous diagnostic tick. Compared
    /// against the next tick to tell whether the tap is still delivering
    /// buffers at all (playback detection — see `pollPlayback`).
    private var lastPlaybackFrames: UInt64 = 0
    /// Wall-clock time the output signal last crossed the silence floor while
    /// the tap was live. `isPlayingAudio` stays true for `playbackHangover`
    /// seconds past this so brief gaps between tracks don't stop the tally.
    private var lastSignalAt: Date = .distantPast

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
    /// fade masks an audible artifact while the aggregate re-tunes to the
    /// device's new nominal rate.
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

        // Already running on this exact device — nothing to rebuild. (Topology
        // refreshes and redundant selections can re-call start with the current
        // output; rebuilding the aggregate for that would cause a needless gap.)
        if isRunning, tapIO.deviceID != 0, activeOutput?.id == output.id {
            return
        }

        // Switching the output device on a live engine. The output device is the
        // aggregate's main sub-device, so changing it means rebuilding the tap +
        // aggregate — there's no cheap output-only rebind anymore (that was a
        // property of the old separate HAL Output AU). Route through the debounced
        // restart so the audio fades out before the teardown and back in after,
        // instead of clicking. User-initiated, so it bypasses the restart cooldown.
        if isRunning, tapIO.deviceID != 0 {
            scheduleRestart(reason: "output device changed", output: output, force: true)
            return
        }

        fullStart(output: output)
    }

    private func fullStart(output: AudioDevice) {
        // If a fade-then-stop was in flight, finalize it synchronously so the
        // pending teardown work won't fire later and tear down our brand-new
        // chain. (A start arriving during the fade window should rebuild
        // cleanly, not race against the scheduled stop.)
        if pendingStopWork != nil {
            finishStopSynchronously()
        }

        tearDownListeners()
        // Clear playback state across the rebuild; the diagnostic-timer poll
        // re-derives it once samples flow again, so a failed start leaves
        // `isPlayingAudio` false rather than stuck at its pre-teardown value.
        isPlayingAudio = false
        lastSignalAt = .distantPast
        try? tapIO.stop()
        // Snap the output gain to silence before the IOProc starts producing
        // samples. The fade-in below ramps 0 → 1; without this pre-mute a cold
        // start (currentGain == 1) makes the ramp a no-op and the first samples
        // land at full amplitude — audible on quiet content. Safe on the restart
        // path too: gain is already near 0 from the scheduleRestart fade-out.
        gainRamp.setTarget(0, rampFrames: 0)

        // 0. Process Tap API requires the private TCC service kTCCServiceAudioCapture.
        //    Without it the tap silently delivers zero buffers. Prompt the user if
        //    not yet authorized.
        if !AudioCapturePermission.ensureAuthorized() {
            isRunning = false
            statusMessage = "Audio capture permission denied. Grant in System Settings → Privacy & Security."
            log.error("Engine start aborted: TCC audio capture not authorized")
            return
        }

        // 1. Create the process tap + aggregate. The output device is the
        //    aggregate's main sub-device: it provides the clock and the output
        //    streams we write into. The aggregate's nominal rate follows the
        //    output device, and the tap rides the same clock — so the DSP runs
        //    at the device rate with no conversion.
        let aggregateID: AudioDeviceID
        let sampleRate: Double
        do {
            let excludedBundleIDs = excludedAppsStore?.excludedBundleIDs ?? []
            let prepared = try tapIO.prepare(
                outputDeviceUID: output.uid,
                excludedBundleIDs: excludedBundleIDs
            )
            aggregateID = prepared.deviceID
            sampleRate = prepared.sampleRate
            activeSampleRate = sampleRate
        } catch {
            try? tapIO.stop()
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Tap setup failed: \(String(describing: error))")
            return
        }

        // 2. Push current preset into the EQ processor so coefficients are ready
        //    before the first callback. Crossfeed and the spectrum analyzer are
        //    configured against the device rate so their per-sample math (ITD
        //    delay, FFT bin → Hz mapping) is correct relative to what was captured.
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: sampleRate)
        }
        crossfeed.reset()
        crossfeed.configure(sampleRate: sampleRate)
        spectrumAnalyzer.reset()
        spectrumAnalyzer.configure(sampleRate: sampleRate)
        clipMeter.reset()
        clipMeter.configure(sampleRate: sampleRate)

        // 3. Start the in-place IOProc. Its handler runs on the audio thread and
        //    mutates the captured L/R in place; ProcessTapIO copies the result to
        //    the output device.
        do {
            try tapIO.start { [eqProcessor, crossfeed, spectrumAnalyzer, clipMeter, gainRamp] left, right, frames in
                crossfeed.process(left: left, right: right, frames: frames)
                eqProcessor.process(left: left, right: right, frames: frames)
                spectrumAnalyzer.submit(left: left, right: right, frames: frames)
                // Post-loudness, pre-gain: this is the last point at which we can
                // measure what the user actually hears before the fade envelope.
                clipMeter.submit(left: left, right: right, frames: frames)
                // Output fade/mute envelope (startup fade-in, stop fade-out, A/B
                // mute, device-rate duck). Last stage before the copy to output.
                gainRamp.apply(left: left, right: right, frames: frames)
            }

            activeOutput = output
            isRunning = true
            log.info("Engine started: in-place tap → \(output.name) @ \(Int(sampleRate)) Hz")

            // Hold the output muted for ~150 ms before fading in, then ramp up
            // over the standard fade-in window. On a cold engine start the system
            // audio routing doesn't switch to our tap instantly: for a brief
            // window the same source audio is delivered to the DAC twice — once
            // via the still-active direct route, and once via our pipeline with a
            // small capture lag. That overlap is the audible "loops 10 ms back"
            // artifact on startup. Holding silence past the routing switch lets
            // the direct route stop before we speak.
            scheduleStartupFadeIn(sampleRate: sampleRate)

            restartCooldownUntil = Date().addingTimeInterval(0.5)
            installRateListener(aggregateID: aggregateID)
            startDiagnosticTimer()
        } catch {
            isRunning = false
            statusMessage = "Error: \(String(describing: error))"
            log.error("Engine start failed: \(String(describing: error))")
            try? tapIO.stop()
        }
    }

    // Fade-in is longer than fade-out because there's usually a brief gap
    // between fullStart returning and the new tap's first IOProc callback
    // landing samples. The gain ramp advances on real processed frames, so a
    // longer target window keeps the rise gentle even on slow first-callback
    // devices.
    private static let fadeOutSeconds: Double = 0.010
    private static let fadeInSeconds: Double = 0.030

    // Used by stop() to fade to silence before tearing down the audio chain.
    // Longer than the restart fade-out because we want the stop transition to be
    // deliberately gentle, not just glitch-suppressing.
    private static let stopFadeOutSeconds: Double = 0.040

    // Hold the output muted for this long after `fullStart` succeeds before
    // kicking off the regular fade-in. Masks the tap-activation overlap window
    // where audio briefly comes out the DAC both via the direct route and via
    // our pipeline. Tuned empirically — the audible artifact a user reported was
    // ~10 ms, and 150 ms is a comfortable margin.
    private static let startupMuteHoldSeconds: Double = 0.150

    /// Schedule the fade-in to unity after `startupMuteHoldSeconds`. The output
    /// stays at gain 0 during the hold (snapped to 0 at the top of `fullStart`),
    /// so the IOProc emits silence while the system audio routing finishes
    /// switching from the direct route to our tap. A pending fade-in is
    /// cancellable so stop / restart paths can supersede it cleanly.
    private func scheduleStartupFadeIn(sampleRate: Double) {
        pendingStartFadeInWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning else { return }
                let sr = self.activeSampleRate ?? sampleRate
                self.gainRamp.setTarget(1, rampFrames: Int(Self.fadeInSeconds * sr))
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
        guard isRunning, let sr = activeSampleRate else {
            finishStopSynchronously()
            completion?()
            return
        }

        gainRamp.setTarget(0, rampFrames: Int(Self.stopFadeOutSeconds * sr))

        // Tear down listeners and diagnostics eagerly so rate-change
        // notifications and any pending restart/fade-in work scheduled
        // before stop() was called can't fire fullStart() or unmute the
        // output mid-fade. The tap stays alive until `finishStopSynchronously`
        // runs after the fade.
        tearDownListeners()
        stopDiagnosticTimer()

        // Flip UI state immediately so the menu bar reflects "Stopped"
        // before the fade completes. The audio chain keeps running (now
        // ramping toward silence) until the deferred teardown.
        isRunning = false
        isPlayingAudio = false
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
        // the aggregate.
        let delay = Self.stopFadeOutSeconds + 0.015
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Synchronously tear down the rate listener, the diagnostic timer, and the
    /// tap + aggregate. Called either directly when the engine wasn't running,
    /// or from the deferred stop completion after the fade.
    private func finishStopSynchronously() {
        pendingStopWork?.cancel()
        pendingStopWork = nil
        tearDownListeners()
        stopDiagnosticTimer()
        try? tapIO.stop()
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
        isPlayingAudio = false
        statusMessage = "Stopped"
    }

    // MARK: - Runtime change handling

    private func installRateListener(aggregateID: AudioDeviceID) {
        // The output device is the aggregate's main sub-device, so the aggregate's
        // nominal sample rate tracks it. One listener covers both a manual rate
        // change on the device and a hi-res app moving it.
        rateListener = AudioDevicePropertyListener(
            deviceID: aggregateID,
            selector: kAudioDevicePropertyNominalSampleRate
        ) { [weak self] in
            Task { @MainActor in
                self?.handleRateNotification(deviceID: aggregateID)
            }
        }
    }

    /// The aggregate's (== output device's) nominal rate changed. Reconfigure DSP
    /// coefficients in place without tearing the chain down. The IOProc keeps
    /// running and simply starts delivering buffers at the new rate; the only
    /// visible effect is one filter-length transient (inaudible), optionally
    /// masked by a brief fade-mute.
    private func handleRateNotification(deviceID: AudioDeviceID) {
        guard isRunning else { return }
        guard let actual = try? CoreAudioSampleRate.nominal(for: deviceID) else {
            log.info("Rate notification fired but rate read failed")
            return
        }
        if let active = activeSampleRate, abs(actual - active) < 0.5 {
            log.info("Rate notification fired but rate unchanged at \(Int(actual)) Hz — no reconfigure needed")
            return
        }
        log.info("Output/aggregate rate moved: \(Int(self.activeSampleRate ?? 0)) Hz → \(Int(actual)) Hz; reconfiguring DSP in place")

        let muteEnabled = UserDefaults.standard.object(forKey: Self.muteOnDeviceRateChangeKey) as? Bool ?? true
        if muteEnabled {
            scheduleDeviceRateFadeMute()
        }
        softReconfigureForSR(actual)
    }

    // Fade-mute envelope used to mask the transient while the aggregate re-tunes
    // to the device's new nominal rate. Core Audio fires the listener *after* the
    // rate has already changed, so we mute fast (short fade-out) and hold silence
    // long enough that the change settles before we restore.
    //
    // Total disturbance: 10 + 250 + 80 ≈ 340 ms, with 250 ms of full silence in
    // the middle.
    private static let deviceRateFadeOutSeconds: Double = 0.010
    private static let deviceRateMuteHoldSeconds: Double = 0.250
    private static let deviceRateFadeInSeconds: Double = 0.080

    /// Quickly ramp the output to zero, then schedule a slower ramp back to unity
    /// after a brief hold. If another rate notification arrives while a fade-in is
    /// pending, cancel it and re-mute — back-to-back rate moves stay continuously
    /// ducked until the device finally settles.
    private func scheduleDeviceRateFadeMute() {
        let sr = activeSampleRate ?? 48000
        let totalMs = Int((Self.deviceRateFadeOutSeconds + Self.deviceRateMuteHoldSeconds + Self.deviceRateFadeInSeconds) * 1000)
        log.info("Device-rate fade-mute scheduled (~\(totalMs) ms total disturbance)")
        pendingFadeInWork?.cancel()
        gainRamp.setTarget(0, rampFrames: Int(Self.deviceRateFadeOutSeconds * sr))

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning else { return }
                let srNow = self.activeSampleRate ?? 48000
                self.gainRamp.setTarget(1, rampFrames: Int(Self.deviceRateFadeInSeconds * srNow))
                self.pendingFadeInWork = nil
            }
        }
        pendingFadeInWork = work
        let delay = Self.deviceRateFadeOutSeconds + Self.deviceRateMuteHoldSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Cadence of the combined diagnostic + playback-detection tick. Kept
    /// coarse (and paired with a wide tolerance below) because nothing it
    /// drives is time-critical: the burn-in tally is hours-scale and the
    /// `playbackHangover` is far longer than one tick.
    private static let diagnosticInterval: TimeInterval = 10.0

    private func startDiagnosticTimer() {
        stopDiagnosticTimer()
        // Prime playback detection so the first tick measures advancement from
        // a clean baseline — the clip meter was just reset in `fullStart`.
        lastPlaybackFrames = clipMeter.snapshot().framesProcessed
        lastSignalAt = .distantPast
        let timer = Timer(timeInterval: Self.diagnosticInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pollPlayback()
                self.logDiagnosticSnapshot()
            }
        }
        // Neither job is time-critical (debug logging + a coarse playback
        // poll), so give the timer generous slack. macOS coalesces the wakeup
        // with other timers instead of scheduling it tightly, which is what
        // keeps a long-lived "just running" engine from nudging idle CPU.
        timer.tolerance = Self.diagnosticInterval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        diagnosticTimer = timer
    }

    private func stopDiagnosticTimer() {
        diagnosticTimer?.invalidate()
        diagnosticTimer = nil
    }

    // MARK: - Playback detection

    /// Output peak below which we treat the signal as silence. Paused apps
    /// deliver digital zeros, which read at the meter's ~−120 dBFS floor, so
    /// the bar sits well below any real playback. We measure post-loudness /
    /// post-preamp (what the user actually hears), so heavy loudness
    /// compensation can attenuate quiet music by tens of dB — −70 keeps that
    /// margin and still never mistakes true silence for playback.
    private static let silenceFloorDB: Float = -70
    /// Keep `isPlayingAudio` true for this long after the signal last crossed
    /// the floor, so gaps between tracks and brief quiet passages don't churn
    /// the flag (or the burn-in tally) off and back on. Must stay comfortably
    /// longer than `diagnosticInterval` (plus its tolerance) so a single tick
    /// reading a momentary dip can't drop the flag mid-playback.
    private static let playbackHangover: TimeInterval = 30

    /// Derive `isPlayingAudio` from the clip meter. Runs on the diagnostic
    /// timer's tick — no dedicated timer, so detection adds no idle-CPU
    /// wakeups. Signal counts as present only when the tap actually advanced
    /// its frame counter since the last tick *and* the output peak is above
    /// the silence floor — the frame check catches setups that stop the IOProc
    /// on pause (which would otherwise freeze the peak at its last, possibly
    /// loud, value). A hangover bridges brief dips so we don't flap.
    private func pollPlayback() {
        guard isRunning else {
            if isPlayingAudio { isPlayingAudio = false }
            return
        }
        let snap = clipMeter.snapshot()
        let tapAdvanced = snap.framesProcessed != lastPlaybackFrames
        lastPlaybackFrames = snap.framesProcessed
        if tapAdvanced && max(snap.peakDBL, snap.peakDBR) > Self.silenceFloorDB {
            lastSignalAt = Date()
        }
        let playing = Date().timeIntervalSince(lastSignalAt) <= Self.playbackHangover
        if playing != isPlayingAudio { isPlayingAudio = playing }
    }

    private func logDiagnosticSnapshot() {
        guard isRunning else { return }
        let rate = activeSampleRate ?? 0
        let deviceRate = (activeOutput?.id).flatMap { try? CoreAudioSampleRate.nominal(for: $0) } ?? 0
        let frames = clipMeter.snapshot().framesProcessed
        log.info("DIAG: rate=\(Int(rate)) Hz device=\(Int(deviceRate)) Hz framesProcessed=\(frames) playing=\(self.isPlayingAudio)")
    }

    /// Apply a new sample rate without tearing the audio chain down. DSP modules
    /// update their coefficients while preserving filter state (one filter-length
    /// transient, inaudible). With the in-place pipeline there's no resampler to
    /// rebuild — the IOProc just starts delivering at the new rate.
    private func softReconfigureForSR(_ newSR: Double) {
        log.info("Soft reconfig: \(self.activeSampleRate ?? 0) → \(newSR) Hz")
        activeSampleRate = newSR
        if let preset = currentPreset {
            eqProcessor.configure(preset: preset, sampleRate: newSR)
        }
        crossfeed.configure(sampleRate: newSR)
        spectrumAnalyzer.configure(sampleRate: newSR)
        clipMeter.configure(sampleRate: newSR)
    }

    private func tearDownListeners() {
        pendingRestart?.cancel()
        pendingRestart = nil
        pendingFadeInWork?.cancel()
        pendingFadeInWork = nil
        pendingStartFadeInWork?.cancel()
        pendingStartFadeInWork = nil
        rateListener = nil
    }

    /// Fade out, then (after a short debounce) rebuild the chain. `output`
    /// defaults to the current `activeOutput` — pass a different device to
    /// switch outputs across the rebuild.
    private func scheduleRestart(reason: String, output: AudioDevice? = nil, force: Bool = false) {
        guard isRunning, let target = output ?? activeOutput else { return }
        if !force, Date() < restartCooldownUntil {
            log.info("Ignoring \(reason) during cooldown")
            return
        }
        log.info("Scheduling engine restart: \(reason) → \(target.name)")
        // Begin the fade-out *now*, not in the debounced work item. The 150 ms
        // debounce gives the IOProc plenty of callbacks to drain the ramp before
        // the actual teardown starts — by the time we rebuild, the DAC has been
        // hearing silence for a while.
        if let sr = activeSampleRate {
            gainRamp.setTarget(0, rampFrames: Int(Self.fadeOutSeconds * sr))
        }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.isRunning else { return }
                self.fullStart(output: target)
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
