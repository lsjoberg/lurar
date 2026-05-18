import Foundation
import Combine

/// Persisted preferences for how Lurar picks and tracks the output device:
///
/// 1. `lastOutputUID` — the UID of the device the user last had selected,
///    restored on launch so a quit/relaunch lands on the same device
///    rather than a hardcoded fallback.
/// 2. `followMode` — how Lurar reacts when the macOS system default output
///    changes mid-session (e.g. AirPods connect). See `FollowMode`.
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
}
