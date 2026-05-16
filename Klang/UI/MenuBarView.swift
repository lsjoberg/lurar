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

    @Environment(\.openWindow) private var openWindow

    @State private var selectedPresetID: UUID?
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var showCrossfeedHelp: Bool = false

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
                items: visiblePresets.map { preset in
                    .init(id: preset.id.uuidString, title: preset.menuLabel)
                },
                actions: [
                    .init(id: "library", title: "Add more presets…")
                ],
                onAction: { actionID in
                    if actionID == "library" {
                        dismissMenuBarWindow()
                        openWindow(id: "library")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            )
        }
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
        engine.start(output: output)
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

