import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "PresetCatalog")

/// Manages AutoEq's network-fetched catalog: index metadata, lazily hydrated
/// presets, the set of catalog IDs the user has chosen to surface in the picker,
/// and a small on-disk cache so the library still works offline.
@MainActor
final class PresetCatalog: ObservableObject {
    enum IndexState: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    @Published private(set) var entries: [CatalogEntry] = []
    @Published private(set) var enabledIDs: Set<UUID> = []
    @Published private(set) var hydratedPresets: [UUID: EQPreset] = [:]
    @Published private(set) var indexState: IndexState = .idle
    /// Catalog IDs whose ParametricEQ fetch is currently running.
    @Published private(set) var inFlight: Set<UUID> = []
    /// Catalog IDs whose last fetch attempt failed. Cleared on success or
    /// when the user toggles the entry off and back on.
    @Published private(set) var fetchErrors: [UUID: String] = [:]

    /// Refresh the index automatically if the cached copy is older than this.
    private let indexTTL: TimeInterval = 7 * 24 * 60 * 60

    private let client: AutoEqClient
    private let supportDirectory: URL
    private let indexCacheURL: URL
    private let presetsCacheDirectory: URL
    private let enabledIDsURL: URL

    private var inFlightFetches: [UUID: Task<EQPreset, Error>] = [:]

    init(client: AutoEqClient = AutoEqClient()) {
        self.client = client
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Lurar", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let cacheRoot = support.appendingPathComponent("Catalog", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let presetCache = cacheRoot.appendingPathComponent("presets", isDirectory: true)
        try? FileManager.default.createDirectory(at: presetCache, withIntermediateDirectories: true)

        self.supportDirectory = support
        self.indexCacheURL = cacheRoot.appendingPathComponent("index.json")
        self.presetsCacheDirectory = presetCache
        self.enabledIDsURL = support.appendingPathComponent("enabledBuiltIns.json")

        loadCachedIndex()
        loadEnabledIDs()
        hydrateEnabledFromDisk()
        fetchMissingEnabled()

        // Background refresh on launch. No-op if the cached index is fresh.
        Task { [weak self] in
            await self?.refreshIndex()
        }
    }

    /// Kick off network fetches for any enabled entries that aren't yet hydrated
    /// (e.g. enabled in a previous session but never successfully fetched, or
    /// migrated from a legacy build whose cache file is missing).
    private func fetchMissingEnabled() {
        for id in enabledIDs where hydratedPresets[id] == nil {
            scheduleFetch(id: id)
        }
    }

    // MARK: - Public access

    /// Presets currently visible to the rest of the app: enabled, hydrated entries
    /// in the order they appear in the catalog.
    var enabledPresets: [EQPreset] {
        entries.compactMap { entry in
            guard enabledIDs.contains(entry.id) else { return nil }
            return hydratedPresets[entry.id]
        }
    }

    func isEnabled(_ id: UUID) -> Bool { enabledIDs.contains(id) }

    /// Catalog presets are always read-only; user copies happen via the editor's
    /// Tweak… flow, which forks a copy into the user's presets and stamps a
    /// `parentRef` so the original can still be shown as a dashed reference.
    func isBuiltIn(_ id: UUID) -> Bool {
        entries.contains(where: { $0.id == id })
    }

    /// Add `id` to enabled IDs and synchronously persist; kicks off a fetch if the
    /// preset isn't already hydrated. Returns true if a fetch was scheduled.
    @discardableResult
    func enable(_ id: UUID) -> Bool {
        guard !enabledIDs.contains(id) else { return false }
        enabledIDs.insert(id)
        persistEnabledIDs()
        if hydratedPresets[id] == nil {
            fetchErrors.removeValue(forKey: id)
            scheduleFetch(id: id)
            return true
        }
        return false
    }

    func disable(_ id: UUID) {
        guard enabledIDs.remove(id) != nil else { return }
        persistEnabledIDs()
        fetchErrors.removeValue(forKey: id)
    }

    func setEnabled(_ id: UUID, _ on: Bool) {
        if on { enable(id) } else { disable(id) }
    }

    /// Retry a failed fetch for an already-enabled entry. No-op if the entry
    /// is already hydrated or currently in flight.
    func retry(_ id: UUID) {
        guard hydratedPresets[id] == nil, inFlightFetches[id] == nil else { return }
        fetchErrors.removeValue(forKey: id)
        scheduleFetch(id: id)
    }

    /// Force a fresh fetch of an individual entry. Useful for the preview pane in
    /// the library sheet.
    @discardableResult
    func ensureHydrated(id: UUID) -> Task<EQPreset, Error>? {
        if hydratedPresets[id] != nil { return nil }
        return scheduleFetch(id: id)
    }

    // MARK: - Index refresh

    /// Fetch the AutoEq index. No-op if the cached copy is within the TTL, unless
    /// `force` is true (used by the manual Refresh button).
    func refreshIndex(force: Bool = false) async {
        if case .loaded(let when) = indexState, !force,
           Date().timeIntervalSince(when) < indexTTL {
            return
        }
        indexState = .loading
        do {
            let fetched = try await client.fetchIndex()
            entries = fetched
            indexState = .loaded(Date())
            writeIndexCache(fetched)
            fetchMissingEnabled()
        } catch {
            log.error("Index refresh failed: \(String(describing: error))")
            indexState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Internal: fetch / cache

    @discardableResult
    private func scheduleFetch(id: UUID) -> Task<EQPreset, Error>? {
        if let existing = inFlightFetches[id] { return existing }
        guard let entry = entries.first(where: { $0.id == id }) else {
            log.notice("scheduleFetch: no entry for id \(id.uuidString) — index not loaded yet?")
            return nil
        }
        inFlight.insert(id)
        let task = Task<EQPreset, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let preset = try await self.client.fetchPreset(for: entry)
                self.fetchSucceeded(id: id, preset: preset, slug: entry.slug)
                return preset
            } catch {
                self.fetchFailed(id: id, error: error, slug: entry.slug)
                throw error
            }
        }
        inFlightFetches[id] = task
        return task
    }

    private func fetchSucceeded(id: UUID, preset: EQPreset, slug: String) {
        log.notice("Fetched preset for \(slug, privacy: .public)")
        hydratedPresets[id] = preset
        writePresetCache(preset, slug: slug)
        fetchErrors.removeValue(forKey: id)
        inFlight.remove(id)
        inFlightFetches[id] = nil
    }

    private func fetchFailed(id: UUID, error: Error, slug: String) {
        let message = error.localizedDescription
        log.error("Fetch failed for \(slug, privacy: .public): \(message, privacy: .public)")
        fetchErrors[id] = message
        inFlight.remove(id)
        inFlightFetches[id] = nil
    }

    private func hydrateEnabledFromDisk() {
        var hits = 0
        for entry in entries where enabledIDs.contains(entry.id) {
            if let cached = readPresetCache(slug: entry.slug) {
                hydratedPresets[entry.id] = cached
                hits += 1
            }
        }
        if !enabledIDs.isEmpty {
            log.notice("hydrateEnabledFromDisk: \(hits)/\(self.enabledIDs.count) enabled entries found in disk cache")
        }
    }

    private func writePresetCache(_ preset: EQPreset, slug: String) {
        let url = presetCacheURL(slug: slug)
        do {
            let data = try JSONEncoder().encode(preset)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Failed to cache preset \(slug): \(String(describing: error))")
        }
    }

    private func readPresetCache(slug: String) -> EQPreset? {
        let url = presetCacheURL(slug: slug)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EQPreset.self, from: data)
    }

    private func presetCacheURL(slug: String) -> URL {
        let safe = slug
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: ":", with: "_")
        return presetsCacheDirectory.appendingPathComponent("\(safe).json")
    }

    // MARK: - Index cache

    private struct IndexCache: Codable {
        var entries: [CatalogEntry]
        var fetchedAt: Date
    }

    private func writeIndexCache(_ entries: [CatalogEntry]) {
        let cache = IndexCache(entries: entries, fetchedAt: Date())
        do {
            let data = try JSONEncoder().encode(cache)
            try data.write(to: indexCacheURL, options: .atomic)
        } catch {
            log.error("Failed to write index cache: \(String(describing: error))")
        }
    }

    private func loadCachedIndex() {
        guard let data = try? Data(contentsOf: indexCacheURL),
              let cache = try? JSONDecoder().decode(IndexCache.self, from: data)
        else { return }
        entries = cache.entries
        indexState = .loaded(cache.fetchedAt)
        log.notice("Loaded \(cache.entries.count) catalog entries from cache (fetched \(cache.fetchedAt))")
    }

    // MARK: - Enabled IDs persistence

    private struct EnabledIDsFile: Codable {
        var ids: [UUID]
    }

    private func loadEnabledIDs() {
        guard let data = try? Data(contentsOf: enabledIDsURL),
              let decoded = try? JSONDecoder().decode(EnabledIDsFile.self, from: data)
        else { return }
        enabledIDs = Set(decoded.ids)
    }

    private func persistEnabledIDs() {
        let file = EnabledIDsFile(ids: Array(enabledIDs))
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: enabledIDsURL, options: .atomic)
        } catch {
            log.error("Failed to persist enabled IDs: \(String(describing: error))")
        }
    }

    /// One-time migration entry point used by PresetStore: take a set of "built-in"
    /// UUIDs that used to live in `presets.json` and mark them enabled here, without
    /// requiring the index to be loaded yet.
    func adoptLegacyBuiltInIDs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let added = ids.subtracting(enabledIDs)
        guard !added.isEmpty else { return }
        enabledIDs.formUnion(added)
        persistEnabledIDs()
    }

    /// Used by PresetStore migration: stash a known good copy of a legacy built-in
    /// (e.g. the canonical Arya preset already on disk) so the library shows the
    /// correct curve before the network fetch completes.
    func seedHydrated(_ preset: EQPreset, slug: String) {
        hydratedPresets[preset.id] = preset
        writePresetCache(preset, slug: slug)
    }
}
