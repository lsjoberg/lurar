import Foundation

/// Unit the EQ editor renders band frequencies in — and, just as importantly,
/// the unit it reads a typed value back in.
///
/// `automatic` is the original behaviour: Hz below 1 kHz, kHz at and above it.
/// That switch happens under the user's fingers, and a bare number typed into
/// a field labelled "kHz" was still parsed as Hz, so there was no way to get
/// 1.5 kHz by typing `1.5` — you had to know to type `1500` or `1.5k` (#144).
/// Pinning the unit to `hertz` or `kilohertz` makes both the display and the
/// parse unambiguous.
enum FrequencyUnit: String, CaseIterable, Identifiable {
    /// Hz below 1 kHz, kHz at and above it.
    case automatic
    case hertz
    case kilohertz

    var id: String { rawValue }

    static let storageKey = "lurar.editorFrequencyUnit"

    /// Label for the editor's segmented picker.
    var title: String {
        switch self {
        case .automatic:  return "Auto"
        case .hertz:      return "Hz"
        case .kilohertz:  return "kHz"
        }
    }

    /// Boundary at which `automatic` flips over to kHz.
    static let automaticThreshold: Float = 1000

    /// The concrete unit `hz` is rendered in — never `.automatic`.
    func resolved(for hz: Float) -> FrequencyUnit {
        switch self {
        case .hertz:      return .hertz
        case .kilohertz:  return .kilohertz
        case .automatic:  return hz >= Self.automaticThreshold ? .kilohertz : .hertz
        }
    }
}
