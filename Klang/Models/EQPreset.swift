import Foundation

struct EQPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var headphone: String
    var source: String
    var preamp: Float          // dB
    var bands: [EQBand]        // expected length: 4

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
    static let aryaStealthOratory1990 = EQPreset(
        name: "HiFiMan Arya Stealth · Oratory1990",
        headphone: "HiFiMan Arya Stealth",
        source: "Oratory1990",
        preamp: -6.0,
        bands: [
            EQBand(type: .lowShelf,  frequency: 105,   gain:  5.5, q: 0.71),
            EQBand(type: .peak,      frequency: 2800,  gain: -2.5, q: 3.0),
            EQBand(type: .peak,      frequency: 5800,  gain: -3.0, q: 4.0),
            EQBand(type: .highShelf, frequency: 10000, gain: -2.0, q: 0.71)
        ]
    )

    static let flat = EQPreset(
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
}
