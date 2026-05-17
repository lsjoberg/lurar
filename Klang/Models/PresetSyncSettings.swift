import Foundation
import Combine

/// Persists the user's "Sync presets via iCloud" preference. Owned by the app
/// at startup and handed to `PresetStore`; PresetStore reacts to changes by
/// switching its backing file location.
@MainActor
final class PresetSyncSettings: ObservableObject {
    static let defaultsKey = "klang.presets.iCloudSyncEnabled"

    @Published var iCloudEnabled: Bool {
        didSet {
            guard iCloudEnabled != oldValue else { return }
            UserDefaults.standard.set(iCloudEnabled, forKey: Self.defaultsKey)
        }
    }

    init() {
        self.iCloudEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }
}
