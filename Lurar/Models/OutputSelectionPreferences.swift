import Foundation
import Combine

/// Persisted preferences for how Lurar picks and tracks the output device:
///
/// 1. `lastOutputUID` — the UID of the device the user last had selected,
///    restored on launch so a quit/relaunch lands on the same device
///    rather than a hardcoded fallback.
/// 2. `switchPolicy` — how aggressively Lurar moves its output when the audio
///    device landscape changes mid-session. See `SwitchPolicy`.
///
/// Tiny scalar state — backed by `UserDefaults` directly so it lives across
/// launches without an extra file or schema.
@MainActor
final class OutputSelectionPreferences: ObservableObject {
    /// A single escalating policy for automatic output switching. Each step
    /// does everything the milder step does, plus more — so they read as one
    /// "how eager is Lurar to move?" choice rather than a set of overlapping
    /// switches. (Replaces the old `followMode` + `autoSwitchToNewDevices`
    /// pair, which looked contradictory side by side.)
    enum SwitchPolicy: String, CaseIterable, Identifiable {
        /// Never move automatically — the user's chosen output is sticky.
        case stay
        /// Track macOS's default output (e.g. follow when AirPods connect and
        /// macOS promotes them to default).
        case followDefault
        /// Track the default *and* jump to any newly connected device, even one
        /// macOS detects without switching to it (e.g. a USB DAC).
        case switchToNew

        var id: String { rawValue }

        /// Short label for the Settings dropdown.
        var title: String {
            switch self {
            case .stay:          return "Do nothing"
            case .followDefault: return "Follow the system default"
            case .switchToNew:   return "Switch to newly connected devices"
            }
        }

        /// One-line description shown under the dropdown for the active choice.
        var detail: String {
            switch self {
            case .stay:
                return "Lurar keeps playing to the output you pick and never changes it on its own."
            case .followDefault:
                return "When macOS changes its default output \u{2014} say AirPods connect \u{2014} Lurar follows along."
            case .switchToNew:
                return "Lurar follows the system default and also jumps to any newly connected output, like a USB DAC that macOS detects but doesn\u{2019}t switch to on its own."
            }
        }
    }

    static let lastOutputUIDKey = "lurar.lastOutputDeviceUID"
    static let switchPolicyKey = "lurar.outputSwitchPolicy"
    static let autoSwitchBlocklistKey = "lurar.autoSwitchBlocklist"
    /// Legacy key (\u{2264} 0.6.0): "autoFollow" / "ignore". Read once to seed
    /// `switchPolicy` for users upgrading from the two-state follow toggle, so
    /// someone who had turned following off doesn't silently get it back.
    static let legacyFollowModeKey = "lurar.followSystemDefaultMode"

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

    /// Defaults to `.followDefault` — matching the old default where follow
    /// mode was `autoFollow` — and migrates an existing legacy follow-mode
    /// setting on first read so upgraders keep their choice.
    var switchPolicy: SwitchPolicy {
        get {
            if let raw = defaults.string(forKey: Self.switchPolicyKey),
               let policy = SwitchPolicy(rawValue: raw) {
                return policy
            }
            // Migrate from the pre-consolidation follow-mode key.
            if let legacy = defaults.string(forKey: Self.legacyFollowModeKey) {
                return legacy == "ignore" ? .stay : .followDefault
            }
            return .followDefault
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.switchPolicyKey)
            objectWillChange.send()
        }
    }

    /// Whether Lurar should track the system default output. True for every
    /// policy except `.stay`.
    var followsSystemDefault: Bool {
        switchPolicy != .stay
    }

    /// Whether Lurar should jump to newly connected devices even if macOS
    /// doesn't promote them to default. True only for `.switchToNew`.
    var switchesToNewDevices: Bool {
        switchPolicy == .switchToNew
    }

    /// Set of device UIDs that Lurar should ignore when evaluating automatic
    /// output switches.
    var autoSwitchBlocklist: Set<String> {
        get {
            let array = defaults.stringArray(forKey: Self.autoSwitchBlocklistKey) ?? []
            return Set(array)
        }
        set {
            defaults.set(Array(newValue), forKey: Self.autoSwitchBlocklistKey)
            objectWillChange.send()
        }
    }
}
