import SwiftUI
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "MenuBarView")

struct MenuBarView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog

    @Environment(\.openWindow) private var openWindow

    @State private var selectedPresetID: UUID?
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

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

            HStack {
                Button("Open Editor…") {
                    openWindow(id: "editor")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("e", modifiers: [.command])

                Spacer()

                Toggle("Start at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: launchAtLogin, initial: false) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
            }

            HStack {
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

