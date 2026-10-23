import Foundation
import Combine

/// Per-output-device persistent state for two features:
/// 1. Last-used preset: when the user picks a preset while a particular output
///    device is selected, we remember it and auto-recall on next switch.
/// 2. Suggestion dismissal: when the user says "Not now" to the auto-detect
///    banner, we don't ask again for that device UID.
///
/// Both are tiny dictionaries persisted to UserDefaults — no schema, no file
/// watching. ObservableObject so the menu-bar view re-evaluates the banner
/// when the dismissed set or last-used map changes mid-session.
@MainActor
final class DevicePresetMemory: ObservableObject {
    static let lastPresetKey = "lurar.lastPresetByDevice"
    static let dismissedSuggestionsKey = "lurar.suggestionsDismissedDevices"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Last-used preset

    func lastPresetID(for deviceUID: String) -> UUID? {
        guard let raw = lastPresetMap[deviceUID] else { return nil }
        return UUID(uuidString: raw)
    }

    func setLastPresetID(_ id: UUID, for deviceUID: String) {
        var map = lastPresetMap
        if map[deviceUID] == id.uuidString { return }
        map[deviceUID] = id.uuidString
        defaults.set(map, forKey: Self.lastPresetKey)
        objectWillChange.send()
    }

    private var lastPresetMap: [String: String] {
        defaults.dictionary(forKey: Self.lastPresetKey) as? [String: String] ?? [:]
    }

    // MARK: - Dismissed suggestions

    func isSuggestionDismissed(for deviceUID: String) -> Bool {
        dismissedSet.contains(deviceUID)
    }

    func dismissSuggestion(for deviceUID: String) {
        var set = dismissedSet
        if !set.insert(deviceUID).inserted { return }
        defaults.set(Array(set), forKey: Self.dismissedSuggestionsKey)
        objectWillChange.send()
    }

    /// Un-dismiss the device so the suggestion banner can fire again. Used by
    /// the menu-bar "Suggest preset for this device…" action when the user
    /// wants to re-check after having previously dismissed.
    func clearDismissedSuggestion(for deviceUID: String) {
        var set = dismissedSet
        guard set.remove(deviceUID) != nil else { return }
        defaults.set(Array(set), forKey: Self.dismissedSuggestionsKey)
        objectWillChange.send()
    }

    private var dismissedSet: Set<String> {
        Set(defaults.stringArray(forKey: Self.dismissedSuggestionsKey) ?? [])
    }
}
