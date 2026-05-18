import Foundation

/// Records that a user preset was forked from a built-in (catalog entry or
/// bundled Flat). Used to render the "Derived from …" chip, a dashed reference
/// curve in the editor, and the "Reset to original" affordance.
struct PresetParentRef: Codable, Hashable {
    enum Kind: String, Codable { case catalog, bundled }
    var kind: Kind
    var id: UUID
    /// AutoEq slug for catalog parents — kept so we can survive UUID drift
    /// across catalog refreshes. Nil for bundled parents.
    var slug: String?
    /// Parent's display name captured at fork time. Lets the chip render even
    /// when the parent isn't currently hydrated (offline, library disabled).
    var snapshotName: String
    /// Parent's source label captured at fork time (e.g. `oratory1990` or
    /// `Rtings · Bruel & Kjaer 5128`). Disambiguates two parents that share
    /// a name but differ in measurer/rig. Optional for backward compatibility
    /// with presets forked before this field existed.
    var snapshotSource: String?

    enum CodingKeys: String, CodingKey {
        case kind, id, slug, snapshotName, snapshotSource
    }

    init(kind: Kind, id: UUID, slug: String?, snapshotName: String, snapshotSource: String? = nil) {
        self.kind = kind
        self.id = id
        self.slug = slug
        self.snapshotName = snapshotName
        self.snapshotSource = snapshotSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = try c.decode(Kind.self, forKey: .kind)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
        self.snapshotName = try c.decode(String.self, forKey: .snapshotName)
        self.snapshotSource = try c.decodeIfPresent(String.self, forKey: .snapshotSource)
    }
}

struct EQPreset: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var headphone: String
    var source: String
    var preamp: Float          // dB
    var bands: [EQBand]        // expected length: 10 (Lurar's section count); shorter presets are padded with identity biquads
    var parentRef: PresetParentRef?

    enum CodingKeys: String, CodingKey {
        case id, name, headphone, source, preamp, bands, parentRef
    }

    init(id: UUID = UUID(), name: String, headphone: String, source: String, preamp: Float, bands: [EQBand], parentRef: PresetParentRef? = nil) {
        self.id = id
        self.name = name
        self.headphone = headphone
        self.source = source
        self.preamp = preamp
        self.bands = bands
        self.parentRef = parentRef
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.headphone = try c.decode(String.self, forKey: .headphone)
        self.source = try c.decode(String.self, forKey: .source)
        self.preamp = try c.decode(Float.self, forKey: .preamp)
        self.bands = try c.decode([EQBand].self, forKey: .bands)
        self.parentRef = try? c.decode(PresetParentRef.self, forKey: .parentRef)
    }
}

extension EQPreset {
    /// The neutral "no correction" preset. Always available, even offline. Its
    /// canonical UUID is mirrored in `Lurar/Resources/presets.json` so PresetStore
    /// can identify it as the bundled baseline.
    static let flatID = UUID(uuidString: "C1996F66-CC88-4D92-8511-7407391A0BE2")!

    static let flat = EQPreset(
        id: flatID,
        name: "Flat",
        headphone: "Any",
        source: "Lurar",
        preamp: 0,
        bands: [
            EQBand(type: .lowShelf,  frequency: 100,   gain: 0, q: 0.71),
            EQBand(type: .peak,      frequency: 1000,  gain: 0, q: 1.0),
            EQBand(type: .peak,      frequency: 4000,  gain: 0, q: 1.0),
            EQBand(type: .highShelf, frequency: 10000, gain: 0, q: 0.71)
        ]
    )

    /// Seed for a fully custom preset created from scratch — 10 log-spaced bands
    /// at unity gain spanning 30 Hz – 16 kHz. Low/high shelf at the edges, peaks
    /// in between. Matches the engine's 10-section count so no padding kicks in.
    static func blank(name: String = "New Preset") -> EQPreset {
        let count = 10
        let fMin = 30.0
        let fMax = 16_000.0
        let bands: [EQBand] = (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let f = fMin * pow(fMax / fMin, t)
            let type: EQBand.FilterType
            let q: Float
            if i == 0 {
                type = .lowShelf
                q = 0.71
            } else if i == count - 1 {
                type = .highShelf
                q = 0.71
            } else {
                type = .peak
                q = 1.0
            }
            return EQBand(type: type, frequency: Float(f), gain: 0, q: q)
        }
        return EQPreset(name: name, headphone: "", source: "Lurar", preamp: 0, bands: bands)
    }

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

    /// Compare just the audible content (bands + preamp). Used to gate the
    /// "Reset to original" button — a derived preset is "diverged" from its
    /// parent if these differ, regardless of name/headphone metadata.
    func sameAudibleContent(as other: EQPreset) -> Bool {
        guard preamp == other.preamp, bands.count == other.bands.count else { return false }
        for (a, b) in zip(bands, other.bands) {
            if a.type != b.type || a.frequency != b.frequency || a.gain != b.gain || a.q != b.q {
                return false
            }
        }
        return true
    }
}

/// Pair (old UUID, AutoEq slug) used to upgrade users from the in-file built-in
/// model to the network catalog without losing their selection.
struct LegacyMigrationEntry: Hashable {
    let legacyID: UUID
    let slug: String

    static let aryaStealthOratory1990 = LegacyMigrationEntry(
        legacyID: UUID(uuidString: "B2626DF3-DEDE-4EA6-A1C5-A34C0B320552")!,
        slug: "oratory1990/over-ear/HIFIMAN Arya Stealth Magnet Version"
    )

    /// All UUIDs that previous Lurar versions seeded into `presets.json` and that
    /// should now live in the network catalog instead.
    static let all: [LegacyMigrationEntry] = [aryaStealthOratory1990]
}
