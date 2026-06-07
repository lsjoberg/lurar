import AppKit
import SwiftUI
import OSLog

private let bootLog = Logger(subsystem: "app.lurar.Lurar", category: "Boot")
private let launchLog = Logger(subsystem: "app.lurar.Lurar", category: "Launch")

@main
struct LurarApp: App {
    @NSApplicationDelegateAdaptor(LurarAppDelegate.self) private var appDelegate
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
    @StateObject private var burnInTracker = BurnInTracker()

    @Environment(\.openWindow) private var openWindow

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
            MenuBarLabel(
                engine: engine,
                deviceManager: deviceManager,
                presetStore: presetStore,
                presetCatalog: presetCatalog,
                devicePresetMemory: devicePresetMemory,
                burnInTracker: burnInTracker
            )
        }
        .menuBarExtraStyle(.window)
        // Global ⌘, command so Settings opens regardless of which window is
        // key — including when the menu bar popover is closed.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings\u{2026}") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            // Global \u{2318}/ \u{2014} surfaces the cheat sheet from any focused
            // window so enthusiasts can browse the full hotkey list without
            // hunting through tooltips.
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") {
                    openWindow(id: "shortcuts")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("/", modifiers: [.command])
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
            OnboardingPermissionView(
                engine: engine,
                deviceManager: deviceManager,
                presetCatalog: presetCatalog,
                devicePresetMemory: devicePresetMemory
            )
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
        .commandsRemoved()

        Window("Settings", id: "settings") {
            SettingsView(
                syncSettings: syncSettings,
                presetStore: presetStore,
                excludedAppsStore: excludedAppsStore,
                outputPreferences: outputPreferences,
                updater: updater,
                burnInTracker: burnInTracker,
                deviceManager: deviceManager
            )
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
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
        // When crossfeed is toggled off the engine runs at an effective intensity
        // of 0 while the stored slider value is preserved.
        engine.setCrossfeedIntensity(crossfeedSettings.isOn ? crossfeedSettings.intensity : 0)
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
        // run against a dead engine. The same caveat applies to wiring the
        // app delegate's engine reference — that happens from
        // `MenuBarLabel.task` (see `runLaunchCoordinator`'s call site) where
        // the persistent engine is guaranteed.
    }
}

/// Intercepts `NSApp.terminate(_:)` (Cmd+Q, "Quit Lurar" menu item, or
/// any other route) so the engine can fade audio out before the process
/// dies. Without this, the HAL Output AU gets cut mid-buffer and the
/// DAC emits a click as macOS reroutes audio back to its default
/// destination.
@MainActor
final class LurarAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MenuBarLabel.task` once the persistent engine `@StateObject`
    /// is bound. Weak because the engine is owned by the SwiftUI app, not us.
    weak var engine: EQEngine?

    nonisolated override init() {
        super.init()
        MainActor.assumeIsolated {
            launchLog.info("LurarAppDelegate: created (NSApp.delegate adaptor instantiated)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let engineWired = (engine != nil)
        let engineRunning = engine?.isRunning ?? false
        launchLog.info("applicationShouldTerminate: engineWired=\(engineWired) engineRunning=\(engineRunning)")
        guard let engine, engine.isRunning else {
            return .terminateNow
        }
        engine.stop {
            launchLog.info("Engine stop completion fired; replying terminateLater = true")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
    // Preset stores are needed to resolve the right preset at autostart —
    // without this, `MenuBarView.task` (which mounts lazily when the
    // popover first opens) was the only thing applying a preset, so
    // audio passed through flat until the user touched the menu.
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var devicePresetMemory: DevicePresetMemory
    @ObservedObject var burnInTracker: BurnInTracker

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
        Image(nsImage: LurarMark.statusBarImage(filled: engine.isRunning))
            .task {
                guard !didRunLaunchCoordinator else { return }
                didRunLaunchCoordinator = true
                // Hand the app delegate a weak ref to the engine so it can
                // fade audio out on Cmd+Q before the process exits. We wire
                // it here rather than from `LurarApp.init()` because the
                // engine `@StateObject`'s wrappedValue isn't guaranteed to
                // be the persistent instance during App init — see the note
                // in `LurarApp.init()`.
                if let delegate = NSApp.delegate as? LurarAppDelegate {
                    delegate.engine = engine
                    launchLog.info("App delegate engine reference wired")
                } else {
                    launchLog.error("Could not wire app delegate engine; NSApp.delegate is \(String(describing: NSApp.delegate))")
                }
                // Subscribe the burn-in counter to the engine's lifecycle.
                // Wired from this scope (not `LurarApp.init`) for the same
                // reason as the delegate above: app-init `@StateObject`
                // wrappedValues can be transient throwaways, and Combine
                // subscriptions bound to a transient publisher silently
                // never observe the persistent engine.
                burnInTracker.observe(engine: engine)
                runLaunchCoordinator()
            }
            .onChange(of: deviceManager.selectedOutput) { _, newOut in
                // Three cases:
                // 1. We were waiting for any device to materialize at launch
                //    (pendingAutostart) — start the engine on the first one
                //    that shows up and seed the preset.
                // 2. The engine is running and the user (or auto-follow)
                //    switched outputs — rebind to the new device so audio
                //    actually flows there. This used to live in MenuBarView
                //    only, which meant a closed-popover autoFollow swap (e.g.
                //    AirPods connecting during onboarding) updated the UI
                //    selection but kept playing through the old device.
                //    EQEngine.start handles same-device reentry cleanly,
                //    so duplicate fires from MenuBarView are no-ops.
                // 3. selectedOutput went nil — stop the engine; there's
                //    nothing to play through.
                if pendingAutostart, let out = newOut {
                    pendingAutostart = false
                    engine.start(output: out)
                    applyInitialPreset()
                } else if let out = newOut, engine.isRunning {
                    engine.start(output: out)
                } else if newOut == nil, engine.isRunning {
                    engine.stop()
                }
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
                applyInitialPreset()
            } else {
                launchLog.info("Launch: authorized + autostart on, but no output device yet — deferring")
                pendingAutostart = true
            }
        case .unknown, .denied:
            launchLog.info("Launch: permission missing, opening onboarding window")
            openWindow(id: "onboarding")
        }
    }

    /// Push the user's selected preset into the engine at autostart. Without
    /// this, `currentPreset` stays nil until `MenuBarView.task` runs — and
    /// because the popover content is mounted lazily by `MenuBarExtra`'s
    /// `.window` style, that's the first time the user opens the menu. Until
    /// then audio passed through with flat EQ. Resolution order mirrors
    /// `MenuBarView.wireUp`: the per-device "last preset" memory wins, then
    /// the first visible preset as a fallback.
    private func applyInitialPreset() {
        let visible = visiblePresets(catalog: presetCatalog, store: presetStore)
        let resolvedID: UUID? = {
            if let device = deviceManager.selectedOutput,
               let lastID = devicePresetMemory.lastPresetID(for: device.uid),
               visible.contains(where: { $0.id == lastID }) {
                return lastID
            }
            return visible.first?.id
        }()
        guard let id = resolvedID,
              let preset = visible.first(where: { $0.id == id }) else {
            launchLog.info("applyInitialPreset: no resolvable preset (visible=\(visible.count))")
            return
        }
        if engine.currentPreset?.id == preset.id { return }
        engine.apply(preset: preset)
        launchLog.info("Applied initial preset on autostart: \(preset.name, privacy: .public)")
    }
}

// MARK: - Dock-icon presence

/// Dock-icon gate driven by actual `NSWindow` lifecycle, not SwiftUI's
/// `onAppear` / `onDisappear`. Lurar runs as an `LSUIElement` (menu-bar
/// only) app by default; any window scene that the user might want to
/// Cmd+Tab back to is registered here and gets a `willCloseNotification`
/// observer attached. The dock icon shows whenever at least one tracked
/// window is open, and goes back to menu-bar-only as soon as the last
/// one closes via the red button.
///
/// We can't lean on SwiftUI's `onDisappear` because a `Window` scene on
/// macOS keeps its view tree in memory after the user closes the window
/// — `onDisappear` doesn't reliably fire, so the icon would stick around
/// forever. Watching `NSWindow.willCloseNotification` is the actual event
/// the close button raises. `didBecomeKeyNotification` covers the reopen
/// path (SwiftUI reuses the same NSWindow instance when the user reopens
/// from the menu bar) without missing windows that come up in the
/// background.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var openWindows: Set<ObjectIdentifier> = []
    private var observedWindows: Set<ObjectIdentifier> = []

    private init() {}

    /// Called by `showsInDockWhileVisible()` once SwiftUI has the underlying
    /// `NSWindow`. Idempotent: repeated calls for the same window only
    /// attach observers once.
    func register(_ window: NSWindow) {
        let id = ObjectIdentifier(window)

        if observedWindows.insert(id).inserted {
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.markClosed(id) }
            }
            // Reopening a SwiftUI Window after a close reuses the same
            // NSWindow but doesn't necessarily re-run our SwiftUI hook —
            // catch the reopen via didBecomeKey, which fires when the
            // restored window becomes key.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.markOpen(id) }
            }
        }

        if window.isVisible && !window.isMiniaturized {
            markOpen(id)
        }
    }

    private func markOpen(_ id: ObjectIdentifier) {
        guard openWindows.insert(id).inserted else { return }
        updatePolicy()
    }

    private func markClosed(_ id: ObjectIdentifier) {
        guard openWindows.remove(id) != nil else { return }
        updatePolicy()
    }

    private func updatePolicy() {
        let policy: NSApplication.ActivationPolicy = openWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

extension View {
    /// Bring Lurar into the dock (and Cmd+Tab) while the hosting `NSWindow`
    /// is open. Attach to the root of any window scene the user might want
    /// to switch back to from another app. The actual show/hide bookkeeping
    /// happens in `DockPresence` via AppKit notifications — see the note
    /// there about why we can't use SwiftUI's `onDisappear` for the close
    /// path.
    func showsInDockWhileVisible() -> some View {
        background(DockPresenceWindowReader())
    }
}

/// Hands the underlying `NSWindow` to `DockPresence` once the SwiftUI view
/// has been mounted into a window. Stays transparent and zero-sized so it
/// doesn't affect layout.
private struct DockPresenceWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // `nsView.window` is nil during makeNSView (view not yet attached)
        // and on the first updateNSView call before SwiftUI runs its
        // layout pass — defer to the next runloop tick so the lookup
        // succeeds reliably.
        DispatchQueue.main.async {
            if let window = nsView.window {
                DockPresence.shared.register(window)
            }
        }
    }
}
