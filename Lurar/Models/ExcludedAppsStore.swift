import Foundation
import Combine

/// Persists the user's per-app exclusion list — bundle identifiers whose audio
/// should bypass Lurar and play directly through the system mixer.
///
/// The list is consulted at tap-creation time (see `EQEngine.fullStart` →
/// `ProcessTapIO.prepare`). Mutations fire `onChange`, which the engine
/// wires to a tap re-enumeration so toggles take effect without a manual
/// restart.
@MainActor
final class ExcludedAppsStore: ObservableObject {
    private static let defaultsKey = "lurar.excludedBundleIDs"

    @Published private(set) var excludedBundleIDs: Set<String>

    /// Fired after every mutation. The engine subscribes to rebuild its tap
    /// target list — without that, toggles wouldn't take effect until the
    /// next engine start.
    var onChange: (() -> Void)?

    init() {
        let raw = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        self.excludedBundleIDs = Set(raw)
    }

    func contains(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    func set(_ bundleID: String, excluded: Bool) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let wasExcluded = excludedBundleIDs.contains(trimmed)
        if excluded == wasExcluded { return }
        if excluded {
            excludedBundleIDs.insert(trimmed)
        } else {
            excludedBundleIDs.remove(trimmed)
        }
        persist()
        onChange?()
    }

    func toggle(_ bundleID: String) {
        set(bundleID, excluded: !excludedBundleIDs.contains(bundleID))
    }

    private func persist() {
        UserDefaults.standard.set(Array(excludedBundleIDs).sorted(), forKey: Self.defaultsKey)
    }
}
