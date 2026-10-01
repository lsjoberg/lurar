import Foundation
import Combine
import AppKit

@MainActor
final class VoIPAppsStore: ObservableObject {
    private static let defaultsKey = "lurar.voipBundleIDs"

    @Published private(set) var voipBundleIDs: Set<String>

    static let shared = VoIPAppsStore() // singleton for VoIPMonitor

    private init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [
            "com.apple.FaceTime",
            "us.zoom.xos",
            "com.microsoft.teams",
            "com.microsoft.teams2"
        ]
        self.voipBundleIDs = Set(raw)
    }

    func contains(_ bundleID: String) -> Bool {
        voipBundleIDs.contains(bundleID)
    }

    func set(_ bundleID: String, enabled: Bool) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let wasEnabled = voipBundleIDs.contains(trimmed)
        if enabled == wasEnabled { return }
        if enabled {
            voipBundleIDs.insert(trimmed)
        } else {
            voipBundleIDs.remove(trimmed)
        }
        persist()
    }

    func toggle(_ bundleID: String) {
        set(bundleID, enabled: !voipBundleIDs.contains(bundleID))
    }

    private func persist() {
        UserDefaults.standard.set(Array(voipBundleIDs).sorted(), forKey: Self.defaultsKey)
    }
}
