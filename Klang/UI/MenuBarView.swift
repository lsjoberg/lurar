import SwiftUI
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "MenuBarView")

struct MenuBarView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var crossfeedSettings: CrossfeedSettings
    @ObservedObject var devicePresetMemory: DevicePresetMemory

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var selectedPresetID: UUID?
    @State private var showCrossfeedHelp: Bool = false
    @State private var showLoudnessHelp: Bool = false
    /// Top-ranked suggestion for the current output, or nil if none matches
    /// confidently / the user has dismissed it / it's already enabled.
    @State private var suggestion: PresetSuggester.Match?
    /// All ranked suggestions for the current output. Used by the "Choose
    /// another" popover; never includes entries the user already has enabled.
    @State private var suggestionAlternatives: [PresetSuggester.Match] = []
    @State private var showingAlternatives: Bool = false
    /// Set transiently when the "Suggest preset for this device…" action is
    /// invoked but the matcher returned nothing for the current device. The
    /// banner area shows a one-line "No close matches for X" notice and the
    /// notice auto-clears after a few seconds so the menu bar doesn't hold
    /// stale state.
    @State private var noMatchesNotice: String?

    private var visiblePresets: [EQPreset] {
        Klang.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if suggestion != nil {
                suggestionBanner
            } else if let deviceName = noMatchesNotice {
                noMatchesBanner(deviceName: deviceName)
            }

            presetPicker
            outputPicker
            statusRow

            Divider()

            crossfeedRow
            loudnessRow

            Divider()

            HStack {
                Button("Open Editor…") {
                    dismissMenuBarWindow()
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("e", modifiers: [.command])

                Button("Compare A/B…") {
                    dismissMenuBarWindow()
                    openWindow(id: "ab")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .help("Sighted or blind A/B comparison of two presets")

                bypassButton

                Spacer()
            }

            HStack {
                Button {
                    dismissMenuBarWindow()
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.medium)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(",", modifiers: [.command])
                .help("Settings (⌘,)")

                Spacer()

                Button("Quit Klang") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: [.command])
            }
        }
        .padding(14)
        .frame(width: 340)
        .task {
            wireUp()
            applySelectedPreset()
            reevaluateSuggestion()
        }
        .onChange(of: selectedPresetID) { oldValue, newValue in
            applySelectedPreset()
            // Per-device memory: only persist a preset choice when the user
            // changes the picker (oldValue != nil). Skip the nil → first-value
            // transition in `wireUp()` so the suggestion banner can still tell
            // a "first time we've seen this device" from "user picked Flat".
            if oldValue != nil,
               let id = newValue,
               let device = deviceManager.selectedOutput {
                devicePresetMemory.setLastPresetID(id, for: device.uid)
            }
        }
        .onChange(of: engine.currentPreset) { _, new in
            // Engine changed preset externally (e.g. editor deleted the current
            // preset and moved to a neighbor). Keep the dropdown in sync.
            if let id = new?.id, id != selectedPresetID {
                selectedPresetID = id
            }
        }
        .onChange(of: deviceManager.selectedOutput) { oldDevice, newDevice in
            // Implicit memory for the OUTGOING device: if we never wrote one
            // (because the user hadn't explicitly picked a preset while on it
            // — wireUp's nil→Flat init deliberately skips the write), claim
            // the currently active preset as its default. Without this, a
            // user who launches on A, switches to B and picks something
            // there, then comes back to A, would see B's preset stuck on A
            // because A's slot was never populated.
            if let old = oldDevice,
               let id = selectedPresetID,
               devicePresetMemory.lastPresetID(for: old.uid) == nil {
                devicePresetMemory.setLastPresetID(id, for: old.uid)
            }
            restartIfRunning()
            autoRecallPreset(for: newDevice)
            // Clear any stale "no close matches" notice — it was for the
            // previous device and would be misleading after the switch.
            noMatchesNotice = nil
            reevaluateSuggestion()
        }
        .onReceive(presetCatalog.$entries) { _ in reevaluateSuggestion() }
        .onReceive(presetCatalog.$enabledIDs) { _ in reevaluateSuggestion() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Klang").font(.headline)
                Text("Parametric EQ for headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Suggestion banner

    private var suggestionBanner: some View {
        Group {
            if let match = suggestion {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Detected \(deviceManager.selectedOutput?.name ?? "device")")
                        .font(.callout.bold())
                        .lineLimit(1)
                    Text("Apply the \(match.entry.measurer) measurement?")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Button("Apply") { applySuggestion(match) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Choose another") {
                            showingAlternatives = true
                        }
                        .controlSize(.small)
                        .popover(isPresented: $showingAlternatives, arrowEdge: .bottom) {
                            alternativesPopover
                        }
                        Spacer(minLength: 0)
                        Button("Not now") { dismissSuggestion() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
        }
    }

    private var alternativesPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Matches for \(deviceManager.selectedOutput?.name ?? "this device")")
                .font(.callout.bold())
            if suggestionAlternatives.isEmpty {
                Text("No other close matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(suggestionAlternatives, id: \.entry.id) { match in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(match.entry.name)
                                .font(.callout)
                                .lineLimit(1)
                            Text(sourceLabel(for: match.entry))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button("Apply") {
                            showingAlternatives = false
                            applySuggestion(match)
                        }
                        .controlSize(.small)
                    }
                }
            }
            Divider()
            Button("Browse all presets…") {
                showingAlternatives = false
                dismissMenuBarWindow()
                openWindow(id: "library")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.link)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func sourceLabel(for entry: CatalogEntry) -> String {
        if let rig = entry.rig { return "\(entry.measurer) · \(rig)" }
        return entry.measurer
    }

    /// Single-line "no matches" feedback shown when the user manually invokes
    /// "Suggest preset for this device…" but the matcher finds nothing.
    /// Without this the action would be silently no-op.
    private func noMatchesBanner(deviceName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("No close matches for \(deviceName)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Press-and-hold "Bypass" / "Bypassing…" button. Wraps a real
    /// `NSButton` via `NSViewRepresentable` so the bezel matches the
    /// surrounding default-style SwiftUI `Button`s exactly. Press/release
    /// edges come from overriding `mouseDown(with:)` on the NSButton
    /// subclass — NSButton's internal tracking loop blocks until the user
    /// releases the mouse, so `super.mouseDown` returning is the mouse-up
    /// signal.
    private var bypassButton: some View {
        let canBypass = engine.isRunning && !engine.isInComparisonMode
        return BypassNativeButton(
            title: engine.isBypassed ? "Bypassing\u{2026}" : "Bypass",
            isActive: engine.isBypassed,
            isEnabled: canBypass,
            onPressChange: { pressed in
                if pressed {
                    if canBypass { engine.setBypassed(true) }
                } else {
                    // Always release on press-up so the button can't get
                    // wedged on if state changed (e.g. comparison started)
                    // mid-press.
                    engine.setBypassed(false)
                }
            }
        )
        .fixedSize()
        .help("Hold to swap to Flat. Global shortcut: \u{2325}B (hold).")
    }

    /// Label column width shared by Preset/Output/Status rows so the right-hand
    /// controls line up cleanly. Picked to fit "Preset" / "Output" / "Status" at
    /// the body font without truncation.
    private let labelColumnWidth: CGFloat = 56

    /// Width of the dropdown chrome. `Picker` (NSPopUpButton) ignores `.frame`,
    /// so we use `Menu` instead and constrain its label — Menu *does* honor it.
    private let pickerWidth: CGFloat = 232

    private var presetPicker: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .frame(width: labelColumnWidth, alignment: .leading)
            FixedWidthPopUp(
                width: pickerWidth,
                selection: Binding(
                    get: { selectedPresetID?.uuidString ?? "" },
                    set: { uuidString in
                        // Route through userPickedPreset so an explicit
                        // dropdown selection is recorded as a real
                        // interaction — that's what marks the suggestion
                        // banner as handled for this device.
                        if let id = UUID(uuidString: uuidString) {
                            userPickedPreset(id)
                        }
                    }
                ),
                items: Klang.sortedPresetItems(
                    presets: visiblePresets,
                    catalog: presetCatalog,
                    store: presetStore
                ),
                actions: presetPickerActions(),
                onAction: { actionID in
                    switch actionID {
                    case "new":
                        createNewPresetAndOpenEditor()
                    case "library":
                        dismissMenuBarWindow()
                        openWindow(id: "library")
                        NSApp.activate(ignoringOtherApps: true)
                    case "suggest":
                        triggerManualSuggestion()
                    default:
                        break
                    }
                }
            )
        }
    }

    /// Dropdown action list. "Suggest preset for this device…" is only
    /// offered when a device is selected — the matcher needs a device name
    /// to run against.
    private func presetPickerActions() -> [FixedWidthPopUp.Action] {
        var result: [FixedWidthPopUp.Action] = [
            .init(id: "new", title: "New preset…")
        ]
        if deviceManager.selectedOutput != nil {
            result.append(.init(id: "suggest", title: "Suggest preset for this device…"))
        }
        result.append(.init(id: "library", title: "Add more presets…"))
        return result
    }

    /// Create a fully custom preset, select it, and open the editor on it.
    /// Mirrors the editor's New preset… so both entry points produce the same
    /// shape (10 log-spaced bands at 0 dB, no parent).
    private func createNewPresetAndOpenEditor() {
        let preset = EQPreset.blank(name: presetStore.uniqueName(based: "New Preset"))
        presetStore.add(preset)
        selectedPresetID = preset.id
        engine.apply(preset: preset)
        dismissMenuBarWindow()
        openWindow(id: "editor")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var outputPicker: some View {
        HStack(spacing: 8) {
            Text("Output")
                .frame(width: labelColumnWidth, alignment: .leading)
            FixedWidthPopUp(
                width: pickerWidth,
                selection: Binding(
                    get: { deviceManager.selectedOutput?.uid ?? "" },
                    set: { uid in
                        deviceManager.selectedOutput = deviceManager.outputDevices.first { $0.uid == uid }
                    }
                ),
                items: deviceManager.outputDevices.map { .init(id: $0.uid, title: $0.name) }
            )
            .disabled(deviceManager.outputDevices.isEmpty)
        }
    }

    /// Global ISO 226-based loudness compensation. Sits next to crossfeed in
    /// the menu bar because both are global processing that apply on top of
    /// every preset, not part of one. Same row layout as the crossfeed
    /// control so the two read as a pair.
    private var loudnessRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Loudness").bold()
                Button {
                    showLoudnessHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What is loudness compensation?")
                .popover(isPresented: $showLoudnessHelp, arrowEdge: .top) {
                    loudnessHelp
                }
                Spacer()
                Text(loudnessValueLabel)
                    .monospacedDigit()
                    .font(.callout)
            }
            Slider(
                value: Binding(
                    get: { Double(engine.loudnessOffsetDB) },
                    set: { engine.setLoudnessOffset(Float($0)) }
                ),
                in: Double(EQEngine.loudnessOffsetRange.lowerBound)...Double(EQEngine.loudnessOffsetRange.upperBound)
            )
        }
    }

    /// |value| < 0.5 reads as "Off" — the slider snaps to a numerically tiny
    /// but non-zero value as the user drags through; we don't want the
    /// readout flickering or showing "-0 dB".
    private var loudnessValueLabel: String {
        if abs(engine.loudnessOffsetDB) < 0.5 { return "Off" }
        return String(format: "%.0f dB", engine.loudnessOffsetDB)
    }

    private var loudnessHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loudness").font(.headline)
            Text("Boosts low and high frequencies when listening below typical mastering level, compensating for the way your ears perceive less bass and treble when audio is quieter (the Fletcher\u{2013}Munson effect). Pull down when listening softly; leave at 0 for normal listening levels.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Typical settings").font(.subheadline.bold())
            VStack(alignment: .leading, spacing: 4) {
                helpRow("0 dB", "Off. Normal or loud listening \u{2014} the music already sounds the way the mix engineer intended.")
                helpRow("\u{2212}10 dB", "Comfortable evening listening below mix level. Mild bass and treble lift.")
                helpRow("\u{2212}20 dB", "Quiet listening (late night, low background). The bread-and-butter setting.")
                helpRow("\u{2212}40 dB", "Very low background. The cascade attenuates preamp heavily to make room for the bass lift, so absolute output gets quieter \u{2014} turn your amp up.")
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320)
    }

    private var statusRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Status")
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(engine.statusMessage)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
            Button {
                if engine.isRunning { engine.stop() } else { startEngine() }
            } label: {
                Image(systemName: engine.isRunning ? "power.circle.fill" : "power.circle")
                    .foregroundStyle(engine.isRunning ? Color.green : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(engine.isRunning ? "Turn engine off" : "Turn engine on")
        }
        .font(.callout)
    }

    /// Global crossfeed amount. Sits in the menu bar rather than the EQ editor
    /// because it applies on top of every preset, not as part of one.
    private var crossfeedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Crossfeed").bold()
                Button {
                    showCrossfeedHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("What is crossfeed?")
                .popover(isPresented: $showCrossfeedHelp, arrowEdge: .top) {
                    crossfeedHelp
                }
                Spacer()
                Text(crossfeedSettings.intensity <= 0
                     ? "Off"
                     : String(format: "%.0f%%", crossfeedSettings.intensity * 100))
                    .monospacedDigit()
                    .font(.callout)
            }
            Slider(
                value: Binding(
                    get: { Double(crossfeedSettings.intensity) },
                    set: { newValue in
                        let v = Float(newValue)
                        crossfeedSettings.intensity = v
                        engine.setCrossfeedIntensity(v)
                    }
                ),
                in: 0...1
            )
        }
    }

    private var crossfeedHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crossfeed").font(.headline)
            Text("Mixes a delayed, lowpassed copy of each channel into the opposite ear, simulating the acoustic path that exists on speakers but is missing on headphones. Pulls hard-panned stereo content out of \u{201C}inside your head\u{201D} toward a more in-front soundstage.")
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Typical settings").font(.subheadline.bold())
            VStack(alignment: .leading, spacing: 4) {
                helpRow("0%", "Off. Modern music mixed for headphones (most pop, electronic, orchestral) doesn\u{2019}t need it.")
                helpRow("20–30%", "Safe always-on default. Barely noticeable on most material; subtly opens the image.")
                helpRow("40–60%", "For old hard-panned stereo: early Beatles, \u{2019}50s/\u{2019}60s jazz, early stereo orchestral. The point of crossfeed.")
                helpRow("70%+", "Audibly boxy and air-deficient. Diminishing returns.")
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320)
    }

    private func helpRow(_ amount: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(amount)
                .monospacedDigit()
                .bold()
                .frame(width: 56, alignment: .leading)
            Text(description)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func wireUp() {
        if selectedPresetID == nil {
            // Prefer the preset the user last used with this output device, if
            // we have one and it's currently visible. Otherwise fall back to
            // whatever's first in the picker.
            if let device = deviceManager.selectedOutput,
               let lastID = devicePresetMemory.lastPresetID(for: device.uid),
               visiblePresets.contains(where: { $0.id == lastID }) {
                selectedPresetID = lastID
            } else {
                selectedPresetID = visiblePresets.first?.id
            }
        }
        deviceManager.onTopologyChange = {
            // If currently running, try to restart with the current selection.
            // If selection went nil (device removed and no fallback), stop.
            restartIfRunning()
        }
    }

    /// Switch to the preset the user previously selected with `device`, if any
    /// and it's currently visible. No-op when we'd just be re-asserting the
    /// current selection.
    private func autoRecallPreset(for device: AudioDevice?) {
        guard let device,
              let lastID = devicePresetMemory.lastPresetID(for: device.uid),
              visiblePresets.contains(where: { $0.id == lastID }),
              selectedPresetID != lastID
        else { return }
        selectedPresetID = lastID
    }

    /// Recompute the suggestion banner for the current output. Suppressed when
    /// the user has explicitly dismissed it for this device (Not now / Apply /
    /// picked a preset from the dropdown), or when a confident match is
    /// already enabled in their library. NOTE: we deliberately do NOT gate on
    /// `lastPresetID != nil` — the implicit memory claim on output toggle
    /// would otherwise dismiss the banner after a single A→B→A round-trip.
    /// "Has memory" is for recall; "has dismissed" is for the banner.
    private func reevaluateSuggestion() {
        guard let device = deviceManager.selectedOutput else {
            suggestion = nil
            suggestionAlternatives = []
            return
        }
        if devicePresetMemory.isSuggestionDismissed(for: device.uid) {
            suggestion = nil
            suggestionAlternatives = []
            return
        }
        let matches = PresetSuggester.suggestions(
            forDevice: device.name,
            in: presetCatalog.entries
        )
        let enabled = presetCatalog.enabledIDs
        // If ANY confident match is already enabled, treat this as a device the
        // user has already curated and stay quiet — don't second-guess them.
        if matches.contains(where: { enabled.contains($0.entry.id) }) {
            suggestion = nil
            suggestionAlternatives = []
            return
        }
        suggestion = matches.first
        suggestionAlternatives = Array(matches.dropFirst())
    }

    /// Called from the preset dropdown's Binding.set when the USER explicitly
    /// picks a preset. Distinct from the .onChange observer because that
    /// observer also fires for auto-recall and engine-driven syncs, and we
    /// only want to mark the suggestion banner as "handled" on real user
    /// intent. The .onChange path still writes per-device memory.
    private func userPickedPreset(_ id: UUID) {
        selectedPresetID = id
        if let device = deviceManager.selectedOutput {
            devicePresetMemory.dismissSuggestion(for: device.uid)
        }
    }

    /// Magic button: clears the dismissed flag for the current device and
    /// re-runs the matcher. If matches exist, the banner reappears via the
    /// normal `reevaluateSuggestion` path. If not, we surface a brief
    /// "No close matches" notice so the click isn't silent — auto-clears
    /// after a few seconds.
    private func triggerManualSuggestion() {
        guard let device = deviceManager.selectedOutput else { return }
        devicePresetMemory.clearDismissedSuggestion(for: device.uid)
        noMatchesNotice = nil
        reevaluateSuggestion()
        if suggestion == nil {
            let name = device.name
            noMatchesNotice = name
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if noMatchesNotice == name {
                    noMatchesNotice = nil
                }
            }
        }
    }

    /// Enable the catalog entry, wait for the network fetch to land, then
    /// select it. Pinning the device UID up-front guards against the user
    /// switching outputs while the fetch is in flight — in that case we leave
    /// the preset enabled in the library but don't activate it.
    ///
    /// Memory is written EAGERLY (before enable) so the reevaluation triggered
    /// by enable()'s @Published change sees a populated slot and doesn't
    /// resurface the banner. The catalog persists enabledIDs and retries on
    /// next launch, so a stale memory pointer (fetch failed, never hydrated)
    /// is fine — autoRecallPreset's `visiblePresets.contains` guard prevents
    /// us from acting on it.
    private func applySuggestion(_ match: PresetSuggester.Match) {
        let entryID = match.entry.id
        let pinnedDeviceUID = deviceManager.selectedOutput?.uid
        if let uid = pinnedDeviceUID {
            devicePresetMemory.setLastPresetID(entryID, for: uid)
            // Apply counts as "handled" alongside Not now and explicit picks
            // so the banner doesn't bounce back on next open.
            devicePresetMemory.dismissSuggestion(for: uid)
        }
        suggestion = nil
        suggestionAlternatives = []
        Task { @MainActor in
            presetCatalog.enable(entryID)
            if let task = presetCatalog.ensureHydrated(id: entryID) {
                _ = try? await task.value
            }
            guard presetCatalog.hydratedPresets[entryID] != nil else { return }
            guard deviceManager.selectedOutput?.uid == pinnedDeviceUID else { return }
            selectedPresetID = entryID
        }
    }

    private func dismissSuggestion() {
        guard let device = deviceManager.selectedOutput else {
            suggestion = nil
            return
        }
        devicePresetMemory.dismissSuggestion(for: device.uid)
        suggestion = nil
        suggestionAlternatives = []
    }

    private func applySelectedPreset() {
        guard let id = selectedPresetID,
              let preset = visiblePresets.first(where: { $0.id == id }) else { return }
        if engine.currentPreset?.id == preset.id { return }
        engine.apply(preset: preset)
    }

    private func startEngine() {
        guard let output = deviceManager.selectedOutput else {
            engine.reportStartFailure("Pick an output device first")
            return
        }
        // Permission decision tree, driven by the live TCC state — not a
        // "have we ever shown the explainer" flag, because that misses the
        // case where TCC was reset externally (tccutil, system update) and
        // a fresh OS prompt is about to fire. We want our pre-prompt copy
        // in front of the user every time the OS dialog is coming, even if
        // they've seen it before.
        switch AudioCapturePermission.preflight() {
        case .authorized:
            engine.start(output: output)
        case .unknown:
            // OS is about to prompt — show the welcome copy first so the
            // user understands what "audio input" means in our context.
            presentOnboarding()
        case .denied:
            // preflight says denied, but it can be stale. Ask the real
            // source of truth before deciding which dialog (or none) to
            // show — ensureAuthorized() returns true silently if the OS
            // would actually permit the capture.
            if AudioCapturePermission.ensureAuthorized() {
                engine.start(output: output)
            } else {
                presentOnboarding()
            }
        }
    }

    private func presentOnboarding() {
        dismissMenuBarWindow()
        openWindow(id: "onboarding")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func restartIfRunning() {
        guard engine.isRunning else { return }
        guard let output = deviceManager.selectedOutput else {
            engine.stop()
            return
        }
        engine.start(output: output)
    }

    /// MenuBarExtra(.window) has no programmatic dismiss API. The popover is the
    /// key window at the moment the user clicks an item inside it, so capture it
    /// synchronously and hide it on the next runloop tick.
    ///
    /// IMPORTANT: call this BEFORE `openWindow(id:)`. SwiftUI sometimes makes the
    /// newly opened window key synchronously (especially on subsequent opens, after
    /// the window has been materialized once), which would cause this function to
    /// capture and order out the new window instead of the popover — manifesting
    /// as a "flash open then close" on the second open of any window.
    private func dismissMenuBarWindow() {
        let menuBarWindow = NSApp.keyWindow
        DispatchQueue.main.async {
            menuBarWindow?.orderOut(nil)
        }
    }

}

/// SwiftUI bridge around an `NSButton` subclass that emits press-down and
/// press-up callbacks. Using a real NSButton (rather than a SwiftUI
/// `Button` + custom `ButtonStyle`) guarantees the bezel matches the
/// surrounding default `Button`s exactly. Press tracking comes from
/// overriding `mouseDown(with:)` — NSButton's internal tracking loop
/// blocks until the mouse is released, so emitting `pressed=true` before
/// the super call and `pressed=false` after gives reliable down/up edges
/// without fighting SwiftUI's gesture priority.
private struct BypassNativeButton: NSViewRepresentable {
    let title: String
    let isActive: Bool
    let isEnabled: Bool
    let onPressChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoldNSButton {
        let button = HoldNSButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.title = title
        // Empty target/action: mouseDown/Up overrides do the work.
        button.target = nil
        button.action = nil
        return button
    }

    func updateNSView(_ button: HoldNSButton, context: Context) {
        if button.title != title { button.title = title }
        if button.isEnabled != isEnabled { button.isEnabled = isEnabled }
        button.onPressChange = onPressChange
        // `bezelColor` tints a `.rounded` NSButton bezel; combined with a
        // white content tint this gives a clearly "engaged" look while
        // staying within native NSButton chrome.
        button.bezelColor = isActive ? NSColor.systemBlue : nil
        button.contentTintColor = isActive ? NSColor.white : nil
    }
}

private final class HoldNSButton: NSButton {
    var onPressChange: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onPressChange?(true)
        super.mouseDown(with: event)
        // super.mouseDown blocks inside NSButton's internal tracking loop
        // until the user releases; by the time control returns here, the
        // mouse is up.
        onPressChange?(false)
    }
}

