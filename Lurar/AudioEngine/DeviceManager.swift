import Foundation
import Combine
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "DeviceManager")

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []

    @Published var selectedOutput: AudioDevice?

    /// Called by EQEngine to react to device topology changes (re-bind / stop / restart).
    var onTopologyChange: (() -> Void)?

    private var listener: DeviceChangeListener?

    init() {
        refresh(initial: true)
        listener = DeviceChangeListener { [weak self] in
            Task { @MainActor in self?.refresh(initial: false) }
        }
    }

    func refresh(initial: Bool) {
        let all = CoreAudioDevices.all()
        // Lurar's own private aggregate (created in ProcessTapInput) is
        // visible to its creating process even with isPrivate=true. Hide it
        // from the picker — selecting it as the output would loop the tap
        // back through itself.
        let outs = all
            .filter(\.hasOutput)
            .filter { !$0.uid.hasPrefix("app.lurar.Lurar.aggregate.") }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        self.outputDevices = outs

        // Output policy: keep current selection if still around; otherwise prefer HIFIMAN,
        // then system default, then any other device.
        if let sel = selectedOutput, let still = outs.first(where: { $0.uid == sel.uid }) {
            selectedOutput = still
        } else {
            let systemDefault = CoreAudioDevices.defaultOutput()
                .flatMap { def in outs.first { $0.id == def.id } }
            selectedOutput = outs.first(where: \.isHiFiMan)
                ?? systemDefault
                ?? outs.first
        }

        log.info("Refresh — output=\(self.selectedOutput?.name ?? "nil") initial=\(initial)")

        if !initial { onTopologyChange?() }
    }
}
