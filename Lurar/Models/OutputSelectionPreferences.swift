import Foundation
import Combine

/// Persisted preferences for how Lurar picks and tracks the output device:
///
/// 1. `lastOutputUID` — the UID of the device the user last had selected,
///    restored on launch so a quit/relaunch lands on the same device
///    rather than a hardcoded fallback.
/// 2. `followMode` — how Lurar reacts when the macOS system default output
///    changes mid-session (e.g. AirPods connect). See `FollowMode`.
/// 3. `autoSwitchToNewDevices` — whether to move Lurar's output to a device
///    the moment it connects, even if macOS keeps its own default unchanged
///    (e.g. plugging in a USB DAC). Off by default — it's an intrusive
///    behavior change, so it's opt-in.
///
/// Tiny scalar state — backed by `UserDefaults` directly so it lives across
/// launches without an extra file or schema.
@MainActor
final class OutputSelectionPreferences: ObservableObject {
    enum FollowMode: String, CaseIterable {
        /// Switch Lurar's output silently to match the new system default. Default.
        case autoFollow
        /// Don't react at all.
        case ignore
    }

    static let lastOutputUIDKey = "lurar.lastOutputDeviceUID"
    static let followModeKey = "lurar.followSystemDefaultMode"
    static let autoSwitchToNewDevicesKey = "lurar.autoSwitchToNewlyConnectedDevices"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastOutputUID: String? {
        get {
            let raw = defaults.string(forKey: Self.lastOutputUIDKey) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            defaults.set(newValue ?? "", forKey: Self.lastOutputUIDKey)
            objectWillChange.send()
        }
    }

    var followMode: FollowMode {
        get {
            guard let raw = defaults.string(forKey: Self.followModeKey),
                  let mode = FollowMode(rawValue: raw) else { return .autoFollow }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.followModeKey)
            objectWillChange.send()
        }
    }

    /// Defaults to `false` (the `UserDefaults.bool` default for an unset key),
    /// which is what we want — auto-switching is opt-in.
    var autoSwitchToNewDevices: Bool {
        get { defaults.bool(forKey: Self.autoSwitchToNewDevicesKey) }
        set {
            defaults.set(newValue, forKey: Self.autoSwitchToNewDevicesKey)
            objectWillChange.send()
        }
    }
}
