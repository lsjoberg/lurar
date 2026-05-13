import Foundation

struct EQBand: Codable, Hashable, Identifiable {
    enum FilterType: String, Codable, CaseIterable, Identifiable {
        case lowShelf
        case peak
        case highShelf

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .lowShelf:  return "Low shelf"
            case .peak:      return "Peak"
            case .highShelf: return "High shelf"
            }
        }
    }

    var id = UUID()
    var type: FilterType
    var frequency: Float      // Hz
    var gain: Float           // dB
    var q: Float              // quality factor

    enum CodingKeys: String, CodingKey {
        case type, frequency, gain, q
    }

    init(type: FilterType, frequency: Float, gain: Float, q: Float) {
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(FilterType.self, forKey: .type)
        self.frequency = try c.decode(Float.self, forKey: .frequency)
        self.gain = try c.decode(Float.self, forKey: .gain)
        self.q = try c.decode(Float.self, forKey: .q)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(frequency, forKey: .frequency)
        try c.encode(gain, forKey: .gain)
        try c.encode(q, forKey: .q)
    }
}

