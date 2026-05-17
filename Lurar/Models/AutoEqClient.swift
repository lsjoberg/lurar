import Foundation
import CryptoKit
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "AutoEqClient")

/// Where AutoEq's published results live. We pin to `master` because the project
/// publishes there continuously; the `Refresh` button re-fetches on demand.
enum AutoEqEndpoint {
    static let resultsBase = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
    static var indexURL: URL { resultsBase.appendingPathComponent("INDEX.md") }

    /// Build the URL for a headphone's ParametricEQ.txt from a decoded slug like
    /// `oratory1990/over-ear/HIFIMAN Arya Stealth Magnet Version`. The file inside
    /// the directory is always `<last-component> ParametricEQ.txt`.
    ///
    /// We resolve via `URL(string:relativeTo:)` rather than `appendingPathComponent`
    /// because the latter percent-encodes the input again, turning `%20` into
    /// `%2520` and 404-ing the fetch.
    static func parametricURL(slug: String) -> URL? {
        let components = slug.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return nil }
        let path = (components + ["\(leaf) ParametricEQ.txt"]).joined(separator: "/")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: encoded, relativeTo: resultsBase)?.absoluteURL
    }
}

/// Metadata for one entry in AutoEq's catalog. Bands are fetched on demand.
struct CatalogEntry: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier derived from the slug. Cached as a stored property so that
    /// `ForEach`/diffing over thousands of rows doesn't pay a SHA-256 hit per access.
    let id: UUID
    /// Decoded path under `results/`, e.g. `oratory1990/over-ear/HIFIMAN Arya Stealth Magnet Version`.
    let slug: String
    /// Display label from INDEX.md (the link text).
    let name: String
    /// Measurer / source, e.g. `oratory1990`, `crinacle`, `Rtings`.
    let measurer: String
    /// Optional rig label, e.g. `GRAS 43AG-7`, `711`, `Bruel & Kjaer 5128`.
    let rig: String?

    init(slug: String, name: String, measurer: String, rig: String?) {
        self.id = CatalogEntry.deterministicID(slug: slug)
        self.slug = slug
        self.name = name
        self.measurer = measurer
        self.rig = rig
    }

    /// Codable init: ignore any persisted `id` value and recompute from slug so
    /// caches stay correct if the hashing scheme ever changes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let slug = try c.decode(String.self, forKey: .slug)
        self.slug = slug
        self.id = CatalogEntry.deterministicID(slug: slug)
        self.name = try c.decode(String.self, forKey: .name)
        self.measurer = try c.decode(String.self, forKey: .measurer)
        self.rig = try c.decodeIfPresent(String.self, forKey: .rig)
    }

    /// Truncate a SHA-256 of the slug to 16 bytes and stamp RFC-4122 v5 bits. Not a
    /// real namespace UUIDv5 — we just need stable, well-distributed UUIDs.
    static func deterministicID(slug: String) -> UUID {
        let digest = SHA256.hash(data: Data(slug.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50      // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80      // variant RFC-4122
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

/// Network + parser for AutoEq's catalog. Stateless — caching lives in PresetCatalog.
struct AutoEqClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchIndex() async throws -> [CatalogEntry] {
        let (data, response) = try await session.data(from: AutoEqEndpoint.indexURL)
        try Self.validate(response: response, url: AutoEqEndpoint.indexURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEqError.decoding("INDEX.md is not UTF-8")
        }
        let entries = Self.parseIndex(text)
        log.notice("Fetched AutoEq index: \(entries.count) entries")
        return entries
    }

    func fetchPreset(for entry: CatalogEntry) async throws -> EQPreset {
        guard let url = AutoEqEndpoint.parametricURL(slug: entry.slug) else {
            throw AutoEqError.invalidSlug(entry.slug)
        }
        let (data, response) = try await session.data(from: url)
        try Self.validate(response: response, url: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEqError.decoding("ParametricEQ for \(entry.slug) is not UTF-8")
        }
        let parsed = try Self.parseParametricEQ(text)
        return EQPreset(
            id: entry.id,
            name: entry.name,
            headphone: entry.name,
            source: Self.sourceLabel(for: entry),
            preamp: parsed.preamp,
            bands: parsed.bands
        )
    }

    private static func sourceLabel(for entry: CatalogEntry) -> String {
        if let rig = entry.rig { return "\(entry.measurer) · \(rig)" }
        return entry.measurer
    }

    // MARK: - Parsing

    /// One entry per matching markdown line in INDEX.md. Lines look like:
    /// `- [Name](./path/with%20encoding) by Measurer[ on Rig]`
    static func parseIndex(_ text: String) -> [CatalogEntry] {
        var out: [CatalogEntry] = []
        out.reserveCapacity(9_000)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- [") else { continue }
            guard let entry = parseIndexLine(line) else { continue }
            out.append(entry)
        }
        return out
    }

    static func parseIndexLine(_ line: String) -> CatalogEntry? {
        // - [NAME](./PATH) by TRAIL
        // PATH commonly contains literal `)` for headphones like "1MORE Aero (ANC On)",
        // so we anchor on ") by " (which can't legally appear inside a path) instead
        // of the first `)`.
        guard let nameOpen = line.firstIndex(of: "["),
              let nameClose = line[nameOpen...].firstIndex(of: "]") else { return nil }
        let name = String(line[line.index(after: nameOpen)..<nameClose])
        let afterName = line.index(after: nameClose)
        guard afterName < line.endIndex, line[afterName] == "(" else { return nil }
        let pathOpen = line.index(after: afterName)
        guard let separator = line.range(of: ") by ", range: pathOpen..<line.endIndex) else {
            return nil
        }
        var rawPath = String(line[pathOpen..<separator.lowerBound])
        if rawPath.hasPrefix("./") { rawPath.removeFirst(2) }
        guard let slug = rawPath.removingPercentEncoding, !slug.isEmpty else { return nil }
        let bySuffix = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        let measurer: String
        let rig: String?
        if let onRange = bySuffix.range(of: " on ") {
            measurer = String(bySuffix[..<onRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            rig = String(bySuffix[onRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            measurer = bySuffix
            rig = nil
        }
        guard !measurer.isEmpty else { return nil }
        return CatalogEntry(slug: slug, name: name, measurer: measurer, rig: rig)
    }

    struct ParsedParametric {
        let preamp: Float
        let bands: [EQBand]
    }

    /// AutoEq's `*ParametricEQ.txt` format:
    /// ```
    /// Preamp: -5.2 dB
    /// Filter 1: ON LSC Fc 105 Hz Gain 5.9 dB Q 0.70
    /// Filter 2: ON PK  Fc 1825 Hz Gain 5.1 dB Q 1.78
    /// ...
    /// ```
    static func parseParametricEQ(_ text: String) throws -> ParsedParametric {
        var preamp: Float = 0
        var bands: [EQBand] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let p = parsePreampLine(line) {
                preamp = p
            } else if let band = parseFilterLine(line) {
                bands.append(band)
            }
        }
        guard !bands.isEmpty else {
            throw AutoEqError.decoding("No filter lines found")
        }
        // The engine has 10 sections; the AutoEq files emit at most 10 filters today,
        // but defensively trim in case of upstream changes.
        if bands.count > 10 { bands = Array(bands.prefix(10)) }
        return ParsedParametric(preamp: preamp, bands: bands)
    }

    private static func parsePreampLine(_ line: String) -> Float? {
        guard line.hasPrefix("Preamp:") else { return nil }
        let value = line.dropFirst("Preamp:".count)
            .replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Float(value)
    }

    private static func parseFilterLine(_ line: String) -> EQBand? {
        guard line.hasPrefix("Filter ") else { return nil }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Layout: ["Filter", "N:", "ON", "TYPE", "Fc", "<hz>", "Hz", "Gain", "<db>", "dB", "Q", "<q>"]
        guard tokens.count >= 12,
              tokens[2] == "ON",
              tokens[4] == "Fc",
              tokens[7] == "Gain",
              tokens[10] == "Q",
              let freq = Float(tokens[5]),
              let gain = Float(tokens[8]),
              let q = Float(tokens[11])
        else { return nil }
        guard let type = filterType(from: tokens[3]) else { return nil }
        return EQBand(type: type, frequency: freq, gain: gain, q: q)
    }

    private static func filterType(from token: String) -> EQBand.FilterType? {
        switch token {
        case "PK": return .peak
        case "LSC", "LS": return .lowShelf
        case "HSC", "HS": return .highShelf
        default: return nil
        }
    }

    private static func validate(response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AutoEqError.http(status: http.statusCode, url: url)
        }
    }
}

enum AutoEqError: LocalizedError {
    case http(status: Int, url: URL)
    case decoding(String)
    case invalidSlug(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let url):
            return "HTTP \(status) fetching \(url.lastPathComponent)"
        case .decoding(let detail):
            return "Couldn't parse AutoEq response: \(detail)"
        case .invalidSlug(let slug):
            return "Invalid AutoEq slug: \(slug)"
        }
    }
}
