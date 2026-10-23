import Foundation
import Combine

/// Persisted preferences for how anmolAudio picks and tracks output devices,
/// filters out unwanted destinations (like displays or docks), and handles
/// VoIP call audio.
@MainActor
final class OutputSelectionPreferences: ObservableObject {
    /// A single escalating policy for automatic output switching.
    enum SwitchPolicy: String, CaseIterable, Identifiable {
        case stay
        case followDefault
        case switchToNew

        var id: String { rawValue }

        var title: String {
            switch self {
            case .stay:          return "Do nothing"
            case .followDefault: return "Follow the system default"
            case .switchToNew:   return "Switch to newly connected devices"
            }
        }

        var detail: String {
            switch self {
            case .stay:
                return "anmolAudio keeps playing to the output you pick and never changes it on its own."
            case .followDefault:
                return "When macOS changes its default output \u{2014} say AirPods connect \u{2014} anmolAudio follows along."
            case .switchToNew:
                return "anmolAudio follows the system default and also jumps to any newly connected output, like a USB DAC that macOS detects but doesn\u{2019}t switch to on its own."
            }
        }
    }

    /// Per-device policy for automatic output switching and visibility.
    enum DevicePolicy: String, Codable, CaseIterable, Identifiable {
        case auto = "auto"
        case manualOnly = "manualOnly"
        case ignored = "ignored"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: return "Auto-switch"
            case .manualOnly: return "Manual only"
            case .ignored: return "Blocked"
            }
        }

        var detail: String {
            switch self {
            case .auto: return "Normal automatic switching when connected or default."
            case .manualOnly: return "Can be selected manually, but anmolAudio will never auto-switch to it."
            case .ignored: return "Completely hidden and blocked from output selection."
            }
        }
    }

    /// Policy for how anmolAudio handles audio during active calls (FaceTime, Zoom).
    enum CallHandlingMode: String, Codable, CaseIterable, Identifiable {
        case bypassCallAudio = "bypassCallAudio"
        case flattenEQKeepPreamp = "flattenEQKeepPreamp"
        case pauseDuringCalls = "pauseDuringCalls"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bypassCallAudio: return "Bypass call audio (Recommended)"
            case .flattenEQKeepPreamp: return "Flatten EQ & keep Preamp"
            case .pauseDuringCalls: return "Pause during calls"
            }
        }

        var detail: String {
            switch self {
            case .bypassCallAudio:
                return "Call audio (FaceTime, Zoom) bypasses anmolAudio directly to hardware with full native volume and echo cancellation. Background music retains full EQ."
            case .flattenEQKeepPreamp:
                return "Call audio passes through anmolAudio with flat EQ filters to protect echo cancellation, while preserving the active preset's preamp level."
            case .pauseDuringCalls:
                return "Suspends anmolAudio entirely during active calls and resumes when you hang up."
            }
        }
    }

    /// Persistent record of every audio device anmolAudio has ever encountered.
    struct KnownDeviceRecord: Codable, Identifiable {
        var id: String { uid }
        let uid: String
        var name: String
        var transportType: AudioDeviceTransportType
        var lastSeen: Date
        var policy: DevicePolicy
    }

    static let lastOutputUIDKey = "anmolAudio.lastOutputDeviceUID"
    static let switchPolicyKey = "anmolAudio.outputSwitchPolicy"
    static let ignoreDisplayAudioKey = "anmolAudio.ignoreDisplayAudio"
    static let callHandlingModeKey = "anmolAudio.callHandlingMode"
    static let knownDevicesKey = "anmolAudio.knownDevices"

    // Legacy migration keys
    static let legacyLastOutputUIDKey = "lurar.lastOutputDeviceUID"
    static let legacySwitchPolicyKey = "lurar.outputSwitchPolicy"
    static let legacyFollowModeKey = "lurar.followSystemDefaultMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastOutputUID: String? {
        get {
            let val = defaults.string(forKey: Self.lastOutputUIDKey)
                ?? defaults.string(forKey: Self.legacyLastOutputUIDKey) ?? ""
            return val.isEmpty ? nil : val
        }
        set {
            defaults.set(newValue ?? "", forKey: Self.lastOutputUIDKey)
            objectWillChange.send()
        }
    }

    var switchPolicy: SwitchPolicy {
        get {
            if let raw = defaults.string(forKey: Self.switchPolicyKey)
                ?? defaults.string(forKey: Self.legacySwitchPolicyKey),
               let policy = SwitchPolicy(rawValue: raw) {
                return policy
            }
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

    var followsSystemDefault: Bool { switchPolicy != .stay }
    var switchesToNewDevices: Bool { switchPolicy == .switchToNew }

    /// When true, DisplayPort and HDMI audio devices (monitors/TVs) are automatically
    /// blocked from output selection and autoswitching. Defaults to true.
    var ignoreDisplayAudio: Bool {
        get {
            if defaults.object(forKey: Self.ignoreDisplayAudioKey) == nil {
                return true
            }
            return defaults.bool(forKey: Self.ignoreDisplayAudioKey)
        }
        set {
            defaults.set(newValue, forKey: Self.ignoreDisplayAudioKey)
            objectWillChange.send()
        }
    }

    /// Strategy for handling audio during VoIP calls. Defaults to .bypassCallAudio.
    var callHandlingMode: CallHandlingMode {
        get {
            guard let raw = defaults.string(forKey: Self.callHandlingModeKey),
                  let mode = CallHandlingMode(rawValue: raw) else {
                return .bypassCallAudio
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.callHandlingModeKey)
            objectWillChange.send()
        }
    }

    // MARK: - Known Devices & Policy Management

    var knownDevices: [KnownDeviceRecord] {
        get {
            guard let data = defaults.data(forKey: Self.knownDevicesKey),
                  let decoded = try? JSONDecoder().decode([KnownDeviceRecord].self, from: data) else {
                return []
            }
            return decoded.sorted { $0.lastSeen > $1.lastSeen }
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                defaults.set(encoded, forKey: Self.knownDevicesKey)
                objectWillChange.send()
            }
        }
    }

    func recordSeen(device: AudioDevice) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == device.uid }) {
            list[idx].name = device.name
            list[idx].transportType = device.transportType
            list[idx].lastSeen = Date()
        } else {
            // Smart defaults: Docks default to .manualOnly; Displays default to .ignored
            let initialPolicy: DevicePolicy
            if device.isDisplay {
                initialPolicy = .ignored
            } else if device.isDock {
                initialPolicy = .manualOnly
            } else {
                initialPolicy = .auto
            }
            list.append(KnownDeviceRecord(
                uid: device.uid,
                name: device.name,
                transportType: device.transportType,
                lastSeen: Date(),
                policy: initialPolicy
            ))
        }
        self.knownDevices = list
    }

    func policy(for uid: String) -> DevicePolicy? {
        knownDevices.first(where: { $0.uid == uid })?.policy
    }

    func setPolicy(_ policy: DevicePolicy, for uid: String) {
        var list = knownDevices
        if let idx = list.firstIndex(where: { $0.uid == uid }) {
            list[idx].policy = policy
            self.knownDevices = list
        }
    }

    /// Evaluates the effective policy for an audio device, accounting for the global
    /// `ignoreDisplayAudio` setting and per-device overrides.
    func effectivePolicy(for device: AudioDevice) -> DevicePolicy {
        if ignoreDisplayAudio && device.isDisplay {
            return .ignored
        }
        if let explicit = policy(for: device.uid) {
            return explicit
        }
        if device.isDock {
            return .manualOnly
        }
        return .auto
    }
}
