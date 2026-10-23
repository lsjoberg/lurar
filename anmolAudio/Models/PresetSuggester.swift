import Foundation

/// Lightweight fuzzy matcher between a Core Audio output device name and the
/// AutoEq catalog. Pure function, no state — the caller (MenuBarView) feeds in
/// the device name and the catalog entries and decides what to do with the
/// ranked matches.
enum PresetSuggester {
    struct Match: Equatable {
        let entry: CatalogEntry
        let score: Float
    }

    /// Words that appear in either side but don't carry identity.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "by", "with", "on", "for", "and", "of"
    ]

    /// Words that show up in macOS / Bluetooth device names but never in the
    /// AutoEq catalog: "AirPods Pro (Bluetooth)" should still match "Apple
    /// AirPods Pro 2".
    private static let noiseTokens: Set<String> = [
        "headphones", "headphone", "earbuds", "earphones", "headset",
        "audio", "stereo", "bluetooth", "wireless", "hands", "free",
        "hfp", "a2dp"
    ]

    /// Ranked suggestions for `deviceName` against `entries`. Returns at most
    /// `limit` entries that clear the high-confidence threshold; empty if
    /// nothing matches well enough to surface unprompted.
    static func suggestions(
        forDevice deviceName: String,
        in entries: [CatalogEntry],
        limit: Int = 3
    ) -> [Match] {
        let dTokens = tokenize(deviceName)
        guard !dTokens.isEmpty else { return [] }
        let dSet = Set(dTokens)
        let dPhrase = dTokens.joined(separator: " ")

        var matches: [Match] = []
        for entry in entries {
            let eTokens = tokenize(entry.name)
            guard !eTokens.isEmpty else { continue }
            let eSet = Set(eTokens)
            let overlap = dSet.intersection(eSet)

            // Two paths to confidence:
            // (a) Bag-of-words: most device tokens appear in the entry, ≥2
            //     overlapping tokens to keep single-word collisions out.
            // (b) Phrase: a contiguous run of ≥2 device tokens appears in
            //     the entry in the same order. Catches "Linus's AirPods Pro"
            //     → "Apple AirPods Pro 2" where bag overlap dips below 0.7.
            let runLength = longestContiguousRun(of: dTokens, in: eTokens)
            let bagRatio = dSet.isEmpty ? 0 : Float(overlap.count) / Float(dSet.count)
            let bagHit = overlap.count >= 2 && bagRatio >= 0.7
            let phraseHit = runLength >= 2
            guard bagHit || phraseHit else { continue }

            // Score: how much of the device name matched, plus an exact-phrase
            // bonus and a small bias toward tighter entries so e.g. "AirPods
            // Pro" prefers "AirPods Pro" over "AirPods Pro 2 USB-C".
            let ePhrase = eTokens.joined(separator: " ")
            let phraseBonus: Float = ePhrase.contains(dPhrase) ? 0.5 : 0
            let runBonus = Float(runLength) * 0.2
            let entryCoverage = eSet.isEmpty ? 0 : Float(overlap.count) / Float(eSet.count)
            let score = bagRatio + phraseBonus + runBonus + 0.1 * entryCoverage
            matches.append(Match(entry: entry, score: score))
        }

        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Length of the longest run of tokens from `needle` that also appears, in
    /// the same order, contiguously inside `haystack`.
    private static func longestContiguousRun(of needle: [String], in haystack: [String]) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var best = 0
        for i in needle.indices {
            for j in haystack.indices where needle[i] == haystack[j] {
                var k = 1
                while i + k < needle.count, j + k < haystack.count, needle[i + k] == haystack[j + k] {
                    k += 1
                }
                if k > best { best = k }
                if best == needle.count { return best }
            }
        }
        return best
    }

    private static func tokenize(_ s: String) -> [String] {
        var scratch = String.UnicodeScalarView()
        scratch.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scratch.append(scalar)
            } else {
                scratch.append(Unicode.Scalar(" "))
            }
        }
        return String(scratch)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { token in
                // Drop possessive "s" (e.g. "Linus's AirPods Pro" → drop "s").
                // Keep digit suffixes like "2" / "3" — they disambiguate models.
                token != "s" && !stopWords.contains(token) && !noiseTokens.contains(token)
            }
    }
}
