import Foundation

/// What Lurar's menu bar status item shows (issue #118). Three-way rather
/// than a Bool so users who only want the volume readout can drop the brand
/// mark entirely — clicking the item shows Lurar's identity anyway.
enum MenuBarIconStyle: String, CaseIterable, Identifiable {
    /// Just the brand mark — the original look, and the default.
    case logo
    /// Just the speaker glyph tracking the output volume. Devices without
    /// a volume control (HDMI, optical) fall back to the mark so the
    /// status item never goes blank.
    case volume
    /// The mark with the speaker glyph beside it.
    case logoAndVolume

    var id: String { rawValue }

    static let storageKey = "lurar.menuBarIconStyle"

    /// Key of the original Bool toggle this setting replaces.
    private static let legacyShowVolumeKey = "lurar.menuBarShowVolume"

    /// Carry over the original "show volume" Bool: users who had it on get
    /// `.logoAndVolume` (the look that toggle produced). Runs only while the
    /// new key is unset, so it never overrides a choice made in the picker.
    static func migrateLegacyShowVolumeSetting(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: storageKey) == nil else { return }
        if defaults.bool(forKey: legacyShowVolumeKey) {
            defaults.set(MenuBarIconStyle.logoAndVolume.rawValue, forKey: storageKey)
        }
    }

    /// Short label for the Settings dropdown.
    var title: String {
        switch self {
        case .logo:          return "Lurar mark"
        case .volume:        return "Output volume"
        case .logoAndVolume: return "Mark and volume"
        }
    }

    /// One-line description shown under the dropdown for the active choice.
    var detail: String {
        switch self {
        case .logo:
            return "The menu bar shows the Lurar mark on its own."
        case .volume:
            return "Shows a speaker glyph that tracks your output volume in place of the Lurar mark, so you can remove the system volume item from the menu bar. Outputs without a volume control (HDMI, optical) show the mark instead."
        case .logoAndVolume:
            return "Shows the Lurar mark with a speaker glyph beside it that tracks your output volume. Outputs without a volume control (HDMI, optical) show just the mark."
        }
    }
}
