import Foundation

struct EQPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var headphone: String
    var source: String
    var preamp: Float          // dB
    var bands: [EQBand]        // expected length: 10 (Klang's section count); shorter presets are padded with identity biquads

    enum CodingKeys: String, CodingKey {
        case id, name, headphone, source, preamp, bands
    }

    init(id: UUID = UUID(), name: String, headphone: String, source: String, preamp: Float, bands: [EQBand]) {
        self.id = id
        self.name = name
        self.headphone = headphone
        self.source = source
        self.preamp = preamp
        self.bands = bands
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.headphone = try c.decode(String.self, forKey: .headphone)
        self.source = try c.decode(String.self, forKey: .source)
        self.preamp = try c.decode(Float.self, forKey: .preamp)
        self.bands = try c.decode([EQBand].self, forKey: .bands)
    }
}

extension EQPreset {
    // Stable IDs — mirror Klang/Resources/presets.json so PresetStore can
    // recognize these as built-in even when seeded from the in-code fallback.
    static let aryaStealthOratory1990ID = UUID(uuidString: "B2626DF3-DEDE-4EA6-A1C5-A34C0B320552")!
    static let flatID = UUID(uuidString: "C1996F66-CC88-4D92-8511-7407391A0BE2")!

    static let aryaStealthOratory1990 = EQPreset(
        id: aryaStealthOratory1990ID,
        name: "HiFiMan Arya Stealth · Oratory1990",
        headphone: "HiFiMan Arya Stealth",
        source: "Oratory1990",
        preamp: -5.2,
        bands: [
            EQBand(type: .lowShelf,  frequency: 105,   gain:  5.9, q: 0.70),
            EQBand(type: .peak,      frequency: 99,    gain: -2.5, q: 0.31),
            EQBand(type: .peak,      frequency: 1825,  gain:  5.1, q: 1.78),
            EQBand(type: .peak,      frequency: 3009,  gain: -2.8, q: 3.29),
            EQBand(type: .peak,      frequency: 4828,  gain: -3.9, q: 4.18),
            EQBand(type: .peak,      frequency: 150,   gain:  0.2, q: 1.75),
            EQBand(type: .peak,      frequency: 652,   gain:  0.8, q: 4.18),
            EQBand(type: .peak,      frequency: 969,   gain: -1.3, q: 3.17),
            EQBand(type: .peak,      frequency: 1373,  gain:  0.9, q: 4.21),
            EQBand(type: .highShelf, frequency: 10000, gain: -3.1, q: 0.70)
        ]
    )

    static let flat = EQPreset(
        id: flatID,
        name: "Flat",
        headphone: "Any",
        source: "Klang",
        preamp: 0,
        bands: [
            EQBand(type: .lowShelf,  frequency: 100,   gain: 0, q: 0.71),
            EQBand(type: .peak,      frequency: 1000,  gain: 0, q: 1.0),
            EQBand(type: .peak,      frequency: 4000,  gain: 0, q: 1.0),
            EQBand(type: .highShelf, frequency: 10000, gain: 0, q: 0.71)
        ]
    )

    func sameContent(as other: EQPreset) -> Bool {
        guard name == other.name,
              headphone == other.headphone,
              source == other.source,
              preamp == other.preamp,
              bands.count == other.bands.count
        else { return false }
        for (a, b) in zip(bands, other.bands) {
            if a.type != b.type || a.frequency != b.frequency || a.gain != b.gain || a.q != b.q {
                return false
            }
        }
        return true
    }
}
