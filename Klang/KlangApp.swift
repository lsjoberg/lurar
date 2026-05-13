import SwiftUI
import OSLog

private let bootLog = Logger(subsystem: "se.linus.klang", category: "Boot")

@main
struct KlangApp: App {
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var presetStore = PresetStore()
    @StateObject private var engine = EQEngine()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                engine: engine,
                deviceManager: deviceManager,
                presetStore: presetStore
            )
        } label: {
            Image(systemName: engine.isRunning ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)

        Window("Klang EQ Editor", id: "editor") {
            EQEditorView(
                engine: engine,
                presetStore: presetStore
            )
            .frame(minWidth: 720, minHeight: 460)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }

    init() {
        bootLog.info("[klang] Booted: HAL input + vDSP biquad EQ + HAL output (no AVAudioEngine)")
    }
}
