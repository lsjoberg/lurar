import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "PresetStore")

/// Owns the user's own preset library at `~/Library/Application Support/Klang/presets.json`.
/// As of Klang 0.x the network catalog (`PresetCatalog`) owns AutoEq's built-ins,
/// so this store only holds user-saved presets plus the bundled `Flat` baseline.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [EQPreset] = []

    private let fileURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?
    private var suppressNextReload = false

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Klang", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("presets.json")

        seedIfNeeded()
        load()
        ensureFlatPresent()
        startWatching()
    }

    deinit {
        fileSource?.cancel()
        fileSource = nil
    }

    /// The only built-in left in this store is Flat — used by the editor to mark
    /// the row as read-only. Catalog-sourced built-ins are detected via PresetCatalog.
    func isBundledFlat(_ preset: EQPreset) -> Bool {
        preset.id == EQPreset.flatID
    }

    // MARK: - Bundle seed

    private func seedIfNeeded() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        if let bundled = Bundle.main.url(forResource: "presets", withExtension: "json") {
            do {
                try FileManager.default.copyItem(at: bundled, to: fileURL)
                log.info("Seeded presets.json from bundle to \(self.fileURL.path)")
                return
            } catch {
                log.error("Failed to copy bundled presets: \(String(describing: error))")
            }
        }
        write([EQPreset.flat])
    }

    /// Even if a user previously wiped their file or imported a stripped copy, Flat
    /// must always be available as a fall-back. If it's missing, splice it back in
    /// at the top — but only when we'd otherwise have nothing offline-safe.
    private func ensureFlatPresent() {
        guard !presets.contains(where: { $0.id == EQPreset.flatID }) else { return }
        var next = presets
        next.insert(EQPreset.flat, at: 0)
        write(next)
    }

    // MARK: - Load / write

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([EQPreset].self, from: data)
            presets = decoded
            log.info("Loaded \(decoded.count) presets")
        } catch {
            log.error("Failed to load presets.json: \(String(describing: error)). Falling back to Flat.")
            presets = [EQPreset.flat]
        }
    }

    @discardableResult
    func write(_ presets: [EQPreset]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(presets)
            suppressNextReload = true
            try data.write(to: fileURL, options: .atomic)
            self.presets = presets
            // The atomic write will rename the file, which the watcher catches as .rename.
            // Re-arm shortly to track the new inode.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.restartWatching()
            }
            return true
        } catch {
            log.error("Failed to write presets.json: \(String(describing: error))")
            return false
        }
    }

    // MARK: - CRUD

    func add(_ preset: EQPreset) {
        var p = presets
        p.append(preset)
        write(p)
    }

    func update(_ preset: EQPreset) {
        var p = presets
        if let idx = p.firstIndex(where: { $0.id == preset.id }) {
            p[idx] = preset
        } else {
            p.append(preset)
        }
        write(p)
    }

    func duplicate(_ preset: EQPreset) -> EQPreset {
        var copy = preset
        copy.id = UUID()
        copy.name = preset.name + " (copy)"
        add(copy)
        return copy
    }

    func delete(id: UUID) {
        write(presets.filter { $0.id != id })
    }

    /// Append " 2", " 3", … as needed so a fresh preset name doesn't collide
    /// with any existing one. Shared by the editor's Tweak / New preset flow
    /// and the menu bar's New preset action so both paths disambiguate the
    /// same way.
    func uniqueName(based base: String) -> String {
        let taken = Set(presets.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Legacy migration

    private static let migrationDefaultsKey = "klang.presets.migratedBuiltIns_v1"

    /// One-time migration: prior Klang versions seeded AutoEq presets directly into
    /// the user's `presets.json` with stable UUIDs. The new model moves them into
    /// `PresetCatalog`. For each legacy entry we find, we:
    ///   1. Tell the catalog to mark its (newly deterministic) ID enabled.
    ///   2. Seed the catalog's cache with the user's existing copy so the picker
    ///      shows the right curve before the network fetch lands.
    ///   3. Remove the legacy entry from `presets.json`.
    func migrateLegacyBuiltInsIfNeeded(into catalog: PresetCatalog) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationDefaultsKey) else { return }

        var remaining = presets
        var didChange = false
        for legacy in LegacyMigrationEntry.all {
            if let idx = remaining.firstIndex(where: { $0.id == legacy.legacyID }) {
                let existing = remaining[idx]
                let catalogID = CatalogEntry.deterministicID(slug: legacy.slug)
                var seeded = existing
                seeded.id = catalogID
                catalog.seedHydrated(seeded, slug: legacy.slug)
                catalog.adoptLegacyBuiltInIDs([catalogID])
                remaining.remove(at: idx)
                didChange = true
                log.info("Migrated legacy built-in \(legacy.legacyID) → catalog \(catalogID) (\(legacy.slug))")
            }
        }
        if didChange {
            write(remaining)
        }
        defaults.set(true, forKey: Self.migrationDefaultsKey)
    }

    // MARK: - File watching

    private func startWatching() {
        guard fileSource == nil else { return }
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd != -1 else {
            log.error("Could not open presets.json for watching")
            return
        }
        fileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                // Editor wrote atomically — old inode is gone. Re-arm.
                self.restartWatching()
            }
            self.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor != -1 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }
        source.resume()
        fileSource = source
    }

    private func stopWatching() {
        fileSource?.cancel()
        fileSource = nil
    }

    private func restartWatching() {
        stopWatching()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.startWatching()
        }
    }

    private func scheduleReload() {
        if suppressNextReload {
            suppressNextReload = false
            return
        }
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.load() }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}
