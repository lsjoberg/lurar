import Foundation
import Combine
import CoreAudio
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "DeviceManager")

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var inputDevices: [AudioDevice] = []
    @Published private(set) var outputDevices: [AudioDevice] = []

    @Published var selectedInput: AudioDevice?
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
        let ins = all.filter(\.hasInput).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        let outs = all.filter(\.hasOutput).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        self.inputDevices = ins
        self.outputDevices = outs

        // Input policy: always prefer BlackHole when it's present, regardless of prior selection,
        // unless the user has explicitly picked something else this session.
        let blackHole = ins.first(where: \.isBlackHole)
        if let bh = blackHole {
            if selectedInput?.uid != bh.uid && !userPickedInput {
                selectedInput = bh
            } else if let sel = selectedInput {
                selectedInput = ins.first { $0.uid == sel.uid } ?? bh
            } else {
                selectedInput = bh
            }
        } else if let sel = selectedInput, !ins.contains(where: { $0.uid == sel.uid }) {
            selectedInput = ins.first
        } else if selectedInput == nil {
            selectedInput = ins.first
        }

        // Output policy: keep current selection if still around; otherwise prefer HIFIMAN, then
        // system default *only if it isn't BlackHole* (BlackHole-as-output would create a feedback
        // loop), then any non-BlackHole device.
        if let sel = selectedOutput, let still = outs.first(where: { $0.uid == sel.uid }) {
            selectedOutput = still
        } else {
            let realOutputs = outs.filter { !$0.isBlackHole }
            let systemDefault = CoreAudioDevices.defaultOutput()
                .flatMap { def in realOutputs.first { $0.id == def.id } }
            selectedOutput = realOutputs.first(where: \.isHiFiMan)
                ?? systemDefault
                ?? realOutputs.first
                ?? outs.first  // last resort if BlackHole is the only output
        }

        log.info("Refresh — input=\(self.selectedInput?.name ?? "nil") output=\(self.selectedOutput?.name ?? "nil") initial=\(initial)")

        if !initial { onTopologyChange?() }
    }

    /// Mark the input as user-chosen so refresh() stops auto-promoting to BlackHole.
    func userSelectInput(_ device: AudioDevice?) {
        userPickedInput = device != nil && device?.isBlackHole == false
        selectedInput = device
    }

    private var userPickedInput = false
}
