import SwiftUI
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "MenuBarView")

struct MenuBarView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var crossfeedSettings: CrossfeedSettings
    @ObservedObject var excludedAppsStore: ExcludedAppsStore

    @Environment(\.openWindow) private var openWindow

    @State private var selectedPresetID: UUID?
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var showCrossfeedHelp: Bool = false
    @State private var showLoudnessHelp: Bool = false

    private var visiblePresets: [EQPreset] {
        Klang.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            engineRow
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

                Spacer()
            }

            HStack {
                Button(excludedAppsButtonLabel) {
                    dismissMenuBarWindow()
                    openWindow(id: "excluded-apps")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .help("Pick apps whose audio should bypass Klang entirely")

                Spacer()
            }

            HStack {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin, initial: false) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
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
        }
        .onChange(of: selectedPresetID) { _, _ in applySelectedPreset() }
        .onChange(of: engine.currentPreset) { _, new in
            // Engine changed preset externally (e.g. editor deleted the current
            // preset and moved to a neighbor). Keep the dropdown in sync.
            if let id = new?.id, id != selectedPresetID {
                selectedPresetID = id
            }
        }
        .onChange(of: deviceManager.selectedOutput) { _, _ in restartIfRunning() }
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

    private var engineRow: some View {
        Toggle(isOn: Binding(
            get: { engine.isRunning },
            set: { newValue in
                if newValue { startEngine() } else { engine.stop() }
            }
        )) {
            Text("Engine")
        }
        .toggleStyle(.switch)
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
                        selectedPresetID = UUID(uuidString: uuidString)
                    }
                ),
                items: Klang.sortedPresetItems(
                    presets: visiblePresets,
                    catalog: presetCatalog,
                    store: presetStore
                ),
                actions: [
                    .init(id: "new", title: "New preset…"),
                    .init(id: "library", title: "Add more presets…")
                ],
                onAction: { actionID in
                    switch actionID {
                    case "new":
                        createNewPresetAndOpenEditor()
                    case "library":
                        dismissMenuBarWindow()
                        openWindow(id: "library")
                        NSApp.activate(ignoringOtherApps: true)
                    default:
                        break
                    }
                }
            )
        }
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
        HStack(alignment: .top) {
            Text("Status")
                .foregroundStyle(.secondary)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(engine.statusMessage)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
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

    private var excludedAppsButtonLabel: String {
        let n = excludedAppsStore.excludedBundleIDs.count
        if n == 0 { return "Excluded Apps\u{2026}" }
        return "Excluded Apps (\(n))\u{2026}"
    }

    // MARK: - Actions

    private func wireUp() {
        if selectedPresetID == nil {
            selectedPresetID = visiblePresets.first?.id
        }
        deviceManager.onTopologyChange = {
            // If currently running, try to restart with the current selection.
            // If selection went nil (device removed and no fallback), stop.
            restartIfRunning()
        }
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

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Launch-at-login toggle failed: \(String(describing: error))")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

