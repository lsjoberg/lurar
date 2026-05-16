import SwiftUI
import OSLog

private let bootLog = Logger(subsystem: "se.linus.klang", category: "Boot")

@main
struct KlangApp: App {
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var presetStore = PresetStore()
    @StateObject private var presetCatalog = PresetCatalog()
    @StateObject private var engine = EQEngine()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                engine: engine,
                deviceManager: deviceManager,
                presetStore: presetStore,
                presetCatalog: presetCatalog
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
    }

    init() {
        bootLog.info("[klang] Booted: Process Tap + vDSP biquad EQ + HAL output (no AVAudioEngine)")
        // Migration is synchronous and one-shot: move any in-file built-ins into the
        // network catalog. The catalog kicks off its own async index refresh in its init.
        presetStore.migrateLegacyBuiltInsIfNeeded(into: presetCatalog)
    }
}
