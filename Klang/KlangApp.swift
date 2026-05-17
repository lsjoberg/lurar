import SwiftUI
import OSLog

private let bootLog = Logger(subsystem: "se.linus.klang", category: "Boot")

@main
struct KlangApp: App {
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var syncSettings: PresetSyncSettings
    @StateObject private var presetStore: PresetStore
    @StateObject private var presetCatalog = PresetCatalog()
    @StateObject private var engine = EQEngine()
    @StateObject private var crossfeedSettings = CrossfeedSettings()
    @StateObject private var excludedAppsStore = ExcludedAppsStore()
    @StateObject private var devicePresetMemory = DevicePresetMemory()
    @StateObject private var updater = UpdaterController()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                engine: engine,
                deviceManager: deviceManager,
                presetStore: presetStore,
                presetCatalog: presetCatalog,
                crossfeedSettings: crossfeedSettings,
                excludedAppsStore: excludedAppsStore,
                devicePresetMemory: devicePresetMemory,
                updater: updater
            )
        } label: {
            Image(systemName: engine.isRunning ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Klang EQ Editor", id: "editor") {
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

        Window("Excluded Apps", id: "excluded-apps") {
            ExcludedAppsView(store: excludedAppsStore)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Welcome to Klang", id: "onboarding") {
            OnboardingPermissionView(engine: engine, deviceManager: deviceManager)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Settings {
            SettingsView(syncSettings: syncSettings, presetStore: presetStore)
        }
    }

    init() {
        bootLog.info("[klang] Booted: Process Tap + vDSP biquad EQ + HAL output (no AVAudioEngine)")
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
