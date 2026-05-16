import Foundation
import Combine

/// Persists crossfeed parameters across launches and broadcasts changes to the UI.
/// One global setting (not per-preset) — applies on top of whatever EQ preset is loaded.
@MainActor
final class CrossfeedSettings: ObservableObject {
    private enum Keys {
        static let intensity = "crossfeed.intensity"
        static let cutoff = "crossfeed.cutoff"
    }

    @Published var intensity: Float {
        didSet { UserDefaults.standard.set(intensity, forKey: Keys.intensity) }
    }

    @Published var cutoff: Float {
        didSet { UserDefaults.standard.set(cutoff, forKey: Keys.cutoff) }
    }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.intensity) != nil {
            self.intensity = defaults.float(forKey: Keys.intensity)
        } else {
            self.intensity = 0
        }
        if defaults.object(forKey: Keys.cutoff) != nil {
            self.cutoff = defaults.float(forKey: Keys.cutoff)
        } else {
            self.cutoff = 700
        }
    }
}
