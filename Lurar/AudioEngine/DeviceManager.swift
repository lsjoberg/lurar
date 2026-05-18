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
            // Any change to the selected output makes a pending nudge stale —
            // the user has either accepted it, ignored it, or picked something
            // else entirely.
            pendingDefaultChange = nil
        }
    }

    /// Set when the system default output changes mid-session to a device
    /// that differs from `selectedOutput`, and the user's `followMode` is
    /// `.ask`. The menu bar surfaces a banner offering to switch. Cleared
    /// when the user accepts, dismisses, or manually changes the picker.
    @Published var pendingDefaultChange: AudioDevice?

    /// Called by EQEngine to react to device topology changes (re-bind / stop / restart).
    var onTopologyChange: (() -> Void)?

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
        self.outputDevices = outs

        // Output policy: keep current selection if still around; otherwise
        // restore the last-used UID; otherwise fall back to the current system
        // default; otherwise the first device. Clear pending banner state if
        // the device list change resolved it.
        if let sel = selectedOutput, let still = outs.first(where: { $0.uid == sel.uid }) {
            selectedOutput = still
        } else {
            let remembered = preferences.lastOutputUID
                .flatMap { uid in outs.first { $0.uid == uid } }
            let systemDefault = CoreAudioDevices.defaultOutput()
                .flatMap { def in outs.first { $0.id == def.id } }
            selectedOutput = remembered ?? systemDefault ?? outs.first
        }

        if let pending = pendingDefaultChange,
           !outs.contains(where: { $0.uid == pending.uid }) {
            pendingDefaultChange = nil
        }

        // Only nudge the engine if the visible device list materially
        // changed. The tap rebuild that follows e.g. an excluded-apps
        // toggle churns aggregate devices through the system topology;
        // those changes are filtered out of the picker but the raw
        // notification still fires here, and firing `onTopologyChange`
        // would force a redundant engine restart for something the user
        // can't see.
        let newUIDs = outs.map(\.uid)
        let materialChange = newUIDs != lastVisibleUIDs
        lastVisibleUIDs = newUIDs

        log.info("Refresh — output=\(self.selectedOutput?.name ?? "nil") initial=\(initial) materialChange=\(materialChange)")

        if !initial && materialChange { onTopologyChange?() }
    }

    /// Accept the pending system-default switch (called by the menu bar's
    /// "Switch" button). Updates `selectedOutput` and clears the banner.
    func acceptPendingDefaultChange() {
        guard let pending = pendingDefaultChange else { return }
        selectedOutput = pending
        pendingDefaultChange = nil
    }

    /// Dismiss the pending system-default switch (called by the menu bar's
    /// "Keep current" button). Leaves `selectedOutput` alone.
    func dismissPendingDefaultChange() {
        pendingDefaultChange = nil
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
        if resolved.uid == selectedOutput?.uid {
            pendingDefaultChange = nil
            return
        }
        switch preferences.followMode {
        case .autoFollow:
            log.info("System default changed → \(resolved.name, privacy: .public); auto-follow on")
            selectedOutput = resolved
            pendingDefaultChange = nil
        case .ask:
            log.info("System default changed → \(resolved.name, privacy: .public); surfacing banner")
            pendingDefaultChange = resolved
        case .ignore:
            log.info("System default changed → \(resolved.name, privacy: .public); ignore mode — no action")
        }
    }
}
