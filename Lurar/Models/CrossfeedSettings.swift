import Foundation
import Combine

/// Persists crossfeed parameters across launches and broadcasts changes to the UI.
/// One global setting (not per-preset) — applies on top of whatever EQ preset is loaded.
@MainActor
final class CrossfeedSettings: ObservableObject {
    private enum Keys {
        static let intensity = "crossfeed.intensity"
        static let cutoff = "crossfeed.cutoff"
        static let isOn = "crossfeed.isOn"
    }

    /// Master on/off for crossfeed. The single source of truth for whether
    /// crossfeed is active — when off, the engine is driven with an effective
    /// intensity of 0 while `intensity` retains the user's last setting so the
    /// slider position is remembered across toggles.
    @Published var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: Keys.isOn) }
    }

    @Published var intensity: Float {
        didSet { UserDefaults.standard.set(intensity, forKey: Keys.intensity) }
    }

    @Published var cutoff: Float {
        didSet { UserDefaults.standard.set(cutoff, forKey: Keys.cutoff) }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedIntensity: Float
        if defaults.object(forKey: Keys.intensity) != nil {
            storedIntensity = defaults.float(forKey: Keys.intensity)
        } else {
            storedIntensity = 0
        }
        self.intensity = storedIntensity
        if defaults.object(forKey: Keys.cutoff) != nil {
            self.cutoff = defaults.float(forKey: Keys.cutoff)
        } else {
            self.cutoff = 700
        }
        // Migration: users from before the on/off toggle existed only had an
        // intensity. Treat any non-zero stored intensity as "on" so their
        // crossfeed doesn't silently switch off after updating.
        if defaults.object(forKey: Keys.isOn) != nil {
            self.isOn = defaults.bool(forKey: Keys.isOn)
        } else {
            self.isOn = storedIntensity > 0
        }
    }
}
