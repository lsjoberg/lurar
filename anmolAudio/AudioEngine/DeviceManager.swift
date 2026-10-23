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
            guard let newOutput = selectedOutput else { return }
            guard newOutput.uid != oldValue?.uid else { return }
            preferences.lastOutputUID = newOutput.uid
            syncSystemDefaultIfNeeded(to: newOutput)
        }
    }

    /// Called by EQEngine to react to device topology changes (re-bind / stop / restart).
    var onTopologyChange: (() -> Void)?

    private let preferences: OutputSelectionPreferences
    private var topologyListener: DeviceChangeListener?
    private var defaultOutputListener: DefaultOutputDeviceListener?
    private var pendingSyncDeviceID: AudioObjectID?
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
        for device in all where device.hasOutput {
            preferences.recordSeen(device: device)
        }
        // anmolAudio's own private aggregate (created in ProcessTapInput) is
        // visible to its creating process even with isPrivate=true. Hide it
        // from the picker — selecting it as the output would loop the tap
        // back through itself. Also filter out ignored devices (like displays).
        let outs = all
            .filter(\.hasOutput)
            .filter { !$0.uid.hasPrefix("app.anmol.anmolAudio.aggregate.") && !$0.uid.hasPrefix("app.lurar.Lurar.aggregate.") }
            .filter { device in
                let policy = preferences.effectivePolicy(for: device)
                return policy != .ignored || device.uid == selectedOutput?.uid
            }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        // Snapshot the previous visible set before overwriting it — used both
        // for the material-change gate and to spot devices that just appeared.
        let previousUIDs = lastVisibleUIDs
        let newUIDs = outs.map(\.uid)
        let addedUIDs = Set(newUIDs).subtracting(previousUIDs)

        self.outputDevices = outs

        // Opt-in auto-switch: when a brand-new output device connects — e.g. a
        // USB DAC that macOS detects but doesn't promote to system default —
        // move anmolAudio's output to it if the device policy allows auto-switching.
        let newlyConnected = (!initial && preferences.switchesToNewDevices)
            ? outs.first(where: { addedUIDs.contains($0.uid) && preferences.effectivePolicy(for: $0) == .auto })
            : nil

        // Output policy: jump to a just-connected device if auto-switch claimed
        // one; otherwise keep the current selection if it's still around;
        // otherwise restore the last-used UID; otherwise fall back to the
        // current system default (if allowed); otherwise the first valid device.
        if let newlyConnected {
            selectedOutput = newlyConnected
        } else if let sel = selectedOutput, let still = outs.first(where: { $0.uid == sel.uid }) {
            selectedOutput = still
        } else {
            let remembered = preferences.lastOutputUID
                .flatMap { uid in outs.first { $0.uid == uid && preferences.effectivePolicy(for: $0) != .ignored } }
            let systemDefault = CoreAudioDevices.defaultOutput()
                .flatMap { def in outs.first { $0.id == def.id && preferences.effectivePolicy(for: $0) == .auto } }
            let firstValid = outs.first(where: { preferences.effectivePolicy(for: $0) != .ignored })
            selectedOutput = remembered ?? systemDefault ?? firstValid ?? outs.first
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

    private func syncSystemDefaultIfNeeded(to output: AudioDevice) {
        guard let currentDefault = CoreAudioDevices.defaultOutput(), currentDefault.id != output.id else { return }
        pendingSyncDeviceID = output.id
        do {
            try CoreAudioDevices.setDefaultOutput(id: output.id)
            log.info("Synced macOS default output to \(output.name, privacy: .public)")
        } catch {
            pendingSyncDeviceID = nil
            log.error("Failed to sync macOS default output to \(output.name, privacy: .public): \(String(describing: error))")
        }
    }

    private func handleSystemDefaultChanged() {
        guard let newDefault = CoreAudioDevices.defaultOutput() else {
            log.info("System default changed — no default device available")
            return
        }
        if let pending = pendingSyncDeviceID {
            if pending == newDefault.id {
                pendingSyncDeviceID = nil
                log.info("Ignoring echo of our own default output sync to \(newDefault.name, privacy: .public)")
                return
            }
            pendingSyncDeviceID = nil
        }
        // CoreAudio fires the default-change and device-list notifications
        // independently — if a brand-new device (AirPods) just became default
        // and the topology listener hasn't run yet, outputDevices is stale.
        // Refresh inline so the new device is in the picker before we set it.
        if !outputDevices.contains(where: { $0.id == newDefault.id || $0.uid == newDefault.uid }) {
            refresh(initial: false)
        }
        guard let resolved = outputDevices.first(where: { $0.uid == newDefault.uid })
            ?? outputDevices.first(where: { $0.id == newDefault.id }) else {
            log.info("System default changed to \(newDefault.name, privacy: .public) but it isn't in the visible output list")
            return
        }
        if resolved.uid == selectedOutput?.uid { return }

        // Guard against auto-switching to blocked or manual-only devices (such as docks or monitors)
        let effectivePolicy = preferences.effectivePolicy(for: resolved)
        guard effectivePolicy == .auto else {
            log.info("System default changed to \(resolved.name, privacy: .public), but device policy is \(effectivePolicy.rawValue) — staying on current output")
            return
        }

        if preferences.followsSystemDefault {
            log.info("System default changed → \(resolved.name, privacy: .public); following")
            selectedOutput = resolved
        } else {
            log.info("System default changed → \(resolved.name, privacy: .public); policy is stay — no action")
        }
    }
}
