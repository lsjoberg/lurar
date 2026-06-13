import Foundation
import Combine
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "DeviceManager")

@MainActor
final class DeviceManager: ObservableObject {
    @Published private(set) var outputDevices: [AudioDevice] = []

    @Published var selectedOutput: AudioDevice? {
        didSet {
            guard let uid = selectedOutput?.uid, uid != oldValue?.uid else { return }
            preferences.lastOutputUID = uid
        }
    }

    /// Called by EQEngine to react to device topology changes (re-bind / stop / restart).
    var onTopologyChange: (() -> Void)?

    /// Closure to query whether audio is currently actively playing.
    var isPlayingAudio: () -> Bool = { false }

    private let preferences: OutputSelectionPreferences
    private var topologyListener: DeviceChangeListener?
    private var defaultOutputListener: DefaultOutputDeviceListener?
    /// UID snapshot of the last visible device list — used to decide
    /// whether a topology notification actually changed anything the user
    /// cares about, or whether it was just our private tap aggregate
    /// churning during an engine restart.
    private var lastVisibleUIDs: [String] = []

    init(preferences: OutputSelectionPreferences) {
        self.preferences = preferences
        refresh(initial: true)
        topologyListener = DeviceChangeListener { [weak self] in
            Task { @MainActor in self?.refresh(initial: false) }
        }
        defaultOutputListener = DefaultOutputDeviceListener { [weak self] in
            Task { @MainActor in self?.handleSystemDefaultChanged() }
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

        // Snapshot the previous visible set before overwriting it — used both
        // for the material-change gate and to spot devices that just appeared.
        let previousUIDs = lastVisibleUIDs
        let newUIDs = outs.map(\.uid)
        let addedUIDs = Set(newUIDs).subtracting(previousUIDs)

        self.outputDevices = outs

        // Opt-in auto-switch: when a brand-new output device connects — e.g. a
        // USB DAC that macOS detects but doesn't promote to system default —
        // move Lurar's output to it. Only on real topology changes (never the
        // initial population) and only when the user enabled the toggle. The
        // aggregate filter above keeps our own tap churn out of `addedUIDs`, so
        // this fires on genuine, user-visible plug-ins. When it doesn't apply
        // we fall through to the normal keep/restore policy below.
        // Also abort if audio is actively playing and the user prefers not to switch.
        let isPlaying = isPlayingAudio()
        let newlyConnected = (!initial && preferences.switchesToNewDevices && (!preferences.preventAutoSwitchWhilePlaying || !isPlaying))
            ? outs.first(where: { addedUIDs.contains($0.uid) })
            : nil

        // Output policy: jump to a just-connected device if auto-switch claimed
        // one; otherwise keep the current selection if it's still around;
        // otherwise restore the last-used UID; otherwise fall back to the
        // current system default; otherwise the first device.
        if let newlyConnected {
            selectedOutput = newlyConnected
        } else if let sel = selectedOutput, let still = outs.first(where: { $0.uid == sel.uid }) {
            selectedOutput = still
        } else {
            let remembered = preferences.lastOutputUID
                .flatMap { uid in outs.first { $0.uid == uid } }
            let systemDefault = CoreAudioDevices.defaultOutput()
                .flatMap { def in outs.first { $0.id == def.id } }
            selectedOutput = remembered ?? systemDefault ?? outs.first
        }

        // Only nudge the engine if the visible device list materially
        // changed. The tap rebuild that follows e.g. an excluded-apps
        // toggle churns aggregate devices through the system topology;
        // those changes are filtered out of the picker but the raw
        // notification still fires here, and firing `onTopologyChange`
        // would force a redundant engine restart for something the user
        // can't see.
        let materialChange = newUIDs != previousUIDs
        lastVisibleUIDs = newUIDs

        log.info("Refresh — output=\(self.selectedOutput?.name ?? "nil") initial=\(initial) materialChange=\(materialChange) autoSwitched=\(newlyConnected != nil)")

        if !initial && materialChange { onTopologyChange?() }
    }

    private func handleSystemDefaultChanged() {
        guard let newDefault = CoreAudioDevices.defaultOutput() else {
            log.info("System default changed — no default device available")
            return
        }
        // CoreAudio fires the default-change and device-list notifications
        // independently — if a brand-new device (AirPods) just became default
        // and the topology listener hasn't run yet, outputDevices is stale.
        // Refresh inline so the new device is in the picker before we set it.
        if !outputDevices.contains(where: { $0.id == newDefault.id || $0.uid == newDefault.uid }) {
            refresh(initial: false)
        }
        guard let resolved = outputDevices.first(where: { $0.id == newDefault.id })
            ?? outputDevices.first(where: { $0.uid == newDefault.uid }) else {
            log.info("System default changed to \(newDefault.name, privacy: .public) but it isn't in the visible output list")
            return
        }
        if resolved.uid == selectedOutput?.uid { return }
        if preferences.followsSystemDefault {
            if preferences.preventAutoSwitchWhilePlaying && isPlayingAudio() {
                log.info("System default changed → \(resolved.name, privacy: .public); but audio is playing — no action")
                return
            }
            log.info("System default changed → \(resolved.name, privacy: .public); following")
            selectedOutput = resolved
        } else {
            log.info("System default changed → \(resolved.name, privacy: .public); policy is stay — no action")
        }
    }
}
