import Foundation

/// Quality ranking for AutoEq's `measurer` strings. When several measurements
/// of the same headphone exist (e.g. "HIFIMAN Arya" appears under oratory1990,
/// crinacle, and a handful of community squigs), surfacing the well-established
/// sources first helps newcomers pick without needing to know the landscape.
///
/// This is intentionally opinionated and conservative: only sources with
/// public methodology, modern rigs, and broad peer cross-reference make it
/// to `.recommended`. The rest are not "bad" — just unranked by us.
enum MeasurerTier: Int, Comparable {
    case recommended = 0
    case trusted = 1
    case other = 2

    static func < (lhs: MeasurerTier, rhs: MeasurerTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Match the part of AutoEq's INDEX.md byline that precedes " on <rig>".
    /// `AutoEqClient.parseIndexLine` already strips the rig, so we get clean
    /// strings like "oratory1990" or "Rtings" here.
    static func tier(for measurer: String) -> MeasurerTier {
        let key = measurer.lowercased()
        if recommendedKeys.contains(key) { return .recommended }
        if trustedKeys.contains(key) { return .trusted }
        return .other
    }

    private static let recommendedKeys: Set<String> = [
        "oratory1990",
        "crinacle"
    ]

    private static let trustedKeys: Set<String> = [
        "rtings",
        "super review",
        "innerfidelity",
        "headphone.com legacy"
    ]

    /// Pick the strongest tier represented in `items`: prefer `.recommended`
    /// matches, fall back to `.trusted`, then to the full input. `selectedTier`
    /// tells the caller which bucket was returned so it can adjust copy (e.g.
    /// "showing community sources"). Preserves input ordering inside each
    /// bucket.
    ///
    /// Generic over the element type so it works for both `[CatalogEntry]`
    /// (substring catalog search) and `[PresetSuggester.Match]` (device-name
    /// matcher), and avoids each call site re-implementing the same cascade.
    static func preferRecommended<T>(
        _ items: [T],
        measurer: (T) -> String
    ) -> (items: [T], selectedTier: MeasurerTier) {
        let recommended = items.filter { tier(for: measurer($0)) == .recommended }
        if !recommended.isEmpty { return (recommended, .recommended) }
        let trusted = items.filter { tier(for: measurer($0)) == .trusted }
        if !trusted.isEmpty { return (trusted, .trusted) }
        return (items, .other)
    }
}
