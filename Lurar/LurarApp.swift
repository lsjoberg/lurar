import SwiftUI
import OSLog

private let bootLog = Logger(subsystem: "app.lurar.Lurar", category: "Boot")
private let launchLog = Logger(subsystem: "app.lurar.Lurar", category: "Launch")

@main
struct LurarApp: App {
    @StateObject private var outputPreferences: OutputSelectionPreferences
    @StateObject private var deviceManager: DeviceManager
    @StateObject private var syncSettings: PresetSyncSettings
    @StateObject private var presetStore: PresetStore
    @StateObject private var presetCatalog = PresetCatalog()
    @StateObject private var engine = EQEngine()
    @StateObject private var crossfeedSettings = CrossfeedSettings()
    @StateObject private var excludedAppsStore = ExcludedAppsStore()
    @StateObject private var devicePresetMemory = DevicePresetMemory()
    @StateObject private var updater = UpdaterController()

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                engine: engine,
                deviceManager: deviceManager,
                presetStore: presetStore,
                presetCatalog: presetCatalog,
                crossfeedSettings: crossfeedSettings,
                devicePresetMemory: devicePresetMemory
            )
        } label: {
            MenuBarLabel(engine: engine, deviceManager: deviceManager)
        }
        .menuBarExtraStyle(.window)
        // Global ⌘, command so Settings opens regardless of which window is
        // key — including when the menu bar popover is closed.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        Window("Lurar EQ Editor", id: "editor") {
            EQEditorView(
                engine: engine,
                presetStore: presetStore,
                presetCatalog: presetCatalog
            )
            .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Preset Library", id: "library") {
            PresetLibraryView(catalog: presetCatalog)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Compare Presets", id: "ab") {
            ABComparisonView(
                engine: engine,
                presetStore: presetStore,
                presetCatalog: presetCatalog
            )
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Welcome to Lurar", id: "onboarding") {
            OnboardingPermissionView(engine: engine, deviceManager: deviceManager)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            SettingsView(
                syncSettings: syncSettings,
                presetStore: presetStore,
                excludedAppsStore: excludedAppsStore,
                outputPreferences: outputPreferences,
                updater: updater
            )
        }
    }

    init() {
        bootLog.info("[lurar] Booted: Process Tap + vDSP biquad EQ + HAL output (no AVAudioEngine)")
        // DeviceManager needs the user's output preferences (last-used UID,
        // follow mode) at init time so its first refresh restores the right
        // device. Construct prefs eagerly and share the same instance with
        // the @StateObject wrapper.
        let prefs = OutputSelectionPreferences()
        _outputPreferences = StateObject(wrappedValue: prefs)
        _deviceManager = StateObject(wrappedValue: DeviceManager(preferences: prefs))
        // PresetStore needs the sync settings at init time so it can pick the
        // right backing location (local vs iCloud) before its first read. We
        // construct both eagerly here and share the same instance.
        let settings = PresetSyncSettings()
        let store = PresetStore(syncSettings: settings)
        _syncSettings = StateObject(wrappedValue: settings)
        _presetStore = StateObject(wrappedValue: store)
        // Migration is synchronous and one-shot: move any in-file built-ins into the
        // network catalog. The catalog kicks off its own async index refresh in its init.
        store.migrateLegacyBuiltInsIfNeeded(into: _presetCatalog.wrappedValue)
        // Seed the engine with the persisted crossfeed settings so the first audio
        // callback (whenever the engine is started) already has the user's params.
        engine.setCrossfeedIntensity(crossfeedSettings.intensity)
        engine.setCrossfeedCutoff(crossfeedSettings.cutoff)
        // Hand the engine a weak handle to the per-app exclusion list and have it
        // rebuild the tap whenever the user toggles a row. Without the onChange
        // wire-up, toggles would only take effect on the next manual engine start.
        engine.excludedAppsStore = excludedAppsStore
        excludedAppsStore.onChange = { [weak engine] in
            engine?.reEnumerateTapTargets()
        }
        // Note: the global ⌥B hotkey is wired up by `EQEngine.init()` itself,
        // not here. App-level `@StateObject` wrappedValue accesses during init
        // can hit a transient instance that SwiftUI discards before binding the
        // persistent storage, so anything we'd schedule from this scope would
        // run against a dead engine.
    }
}

/// Always-rendered menu bar status icon. Doubles as the launch coordinator:
/// the `.task` modifier fires once when the status item materializes at app
/// launch (well before the user opens the popover), which is the earliest
/// safe point to touch the persistent `@StateObject` storage — see the note
/// in `LurarApp.init()` about transient wrappedValue accesses during init.
private struct MenuBarLabel: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager

    @Environment(\.openWindow) private var openWindow

    /// `true` by default — the new flow assumes Lurar "just runs" once it has
    /// permission. Settings exposes a toggle for users who'd rather start it
    /// manually from the menu bar.
    @AppStorage("startEngineOnLaunch") private var startEngineOnLaunch: Bool = true

    /// Set when the launch coordinator wanted to autostart but no output
    /// device was selected yet (rare — DeviceManager.init picks one
    /// synchronously, but the "no audio devices at all" case is real). Cleared
    /// when a device shows up and we successfully start the engine.
    @State private var pendingAutostart: Bool = false

    /// One-shot gate for the launch coordinator. The label can rebuild when
    /// `engine.isRunning` flips, so without this we'd rerun the coordinator
    /// every toggle.
    @State private var didRunLaunchCoordinator: Bool = false

    var body: some View {
        Image(systemName: engine.isRunning ? "waveform.circle.fill" : "waveform.circle")
            .task {
                guard !didRunLaunchCoordinator else { return }
                didRunLaunchCoordinator = true
                runLaunchCoordinator()
            }
            .onChange(of: deviceManager.selectedOutput) { _, newOut in
                guard pendingAutostart, let out = newOut else { return }
                pendingAutostart = false
                engine.start(output: out)
            }
    }

    private func runLaunchCoordinator() {
        switch AudioCapturePermission.preflight() {
        case .authorized:
            guard startEngineOnLaunch else {
                launchLog.info("Launch: authorized, but startEngineOnLaunch=false — staying idle")
                return
            }
            if let out = deviceManager.selectedOutput {
                launchLog.info("Launch: authorized + autostart on, starting engine on \(out.name, privacy: .public)")
                engine.start(output: out)
            } else {
                launchLog.info("Launch: authorized + autostart on, but no output device yet — deferring")
                pendingAutostart = true
            }
        case .unknown, .denied:
            launchLog.info("Launch: permission missing, opening onboarding window")
            openWindow(id: "onboarding")
        }
    }
}
