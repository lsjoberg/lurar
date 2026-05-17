import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "PresetStore")

/// Owns the user's preset library. Lives by default at
/// `~/Library/Application Support/Klang/presets.json`, and can be redirected
/// to the app's iCloud Drive container so the file syncs across Macs.
///
/// Writes go through `NSFileCoordinator` (correct for the iCloud-active case;
/// harmless for local-only). Echo suppression is by content hash: after every
/// write we stash the hash of what we just put on disk, and `load()` ignores
/// any reload event whose hash matches — so atomic writes (which look like
/// rename + write to the file watcher) don't bounce back into a reload, and
/// remote pulls from another device (different bytes, different hash) do.
@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [EQPreset] = []
    @Published private(set) var locationKind: LocationKind = .local

    enum LocationKind: String, Equatable {
        case local, iCloud
    }

    /// Container ID for the iCloud Drive ubiquity container. Must match the
    /// `com.apple.developer.icloud-container-identifiers` entitlement; with
    /// no entitlement / ad-hoc signing, `forUbiquityContainerIdentifier`
    /// returns nil and the toggle is reported as unavailable in the UI.
    static let ubiquityContainerID = "iCloud.se.linus.klang"

    private let syncSettings: PresetSyncSettings?
    private var syncCancellable: AnyCancellable?

    private(set) var fileURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?
    private var lastKnownHash: Int = 0

    init(syncSettings: PresetSyncSettings? = nil) {
        self.syncSettings = syncSettings

        let support = Self.localSupportDir
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let wantsICloud = syncSettings?.iCloudEnabled == true
        if wantsICloud, let ubiquity = Self.iCloudFileURL() {
            self.fileURL = ubiquity
            self.locationKind = .iCloud
        } else {
            self.fileURL = support.appendingPathComponent("presets.json")
            self.locationKind = .local
        }

        Self.ensureParentDirectoryExists(for: fileURL)
        seedIfNeeded()
        load()
        ensureFlatPresent()
        startWatching()

        // React to the iCloud toggle flipping at runtime. Reactions are routed
        // through `setSyncEnabled` so they get the same migration + watcher
        // restart that the explicit API path uses.
        if let syncSettings {
            syncCancellable = syncSettings.$iCloudEnabled
                .removeDuplicates()
                .dropFirst() // initial value already handled above
                .sink { [weak self] enabled in
                    guard let self else { return }
                    Task { @MainActor in
                        self.setSyncEnabled(enabled, migrate: enabled)
                    }
                }
        }
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

    // MARK: - Locations

    static let localSupportDir: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Klang", isDirectory: true)
    }()

    static let localFileURL: URL = localSupportDir.appendingPathComponent("presets.json")

    /// `nil` when no ubiquity container is available — either iCloud Drive is
    /// signed out, or the build doesn't carry the right entitlements. UI
    /// branches off this to disable the toggle.
    static func iCloudDocumentsURL() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: ubiquityContainerID)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    static func iCloudFileURL() -> URL? {
        iCloudDocumentsURL()?.appendingPathComponent("presets.json")
    }

    static func iCloudIsAvailable() -> Bool {
        iCloudDocumentsURL() != nil
    }

    private static func ensureParentDirectoryExists(for url: URL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    // MARK: - Sync mode switching

    /// Toggle between the local Application Support copy and the iCloud
    /// container copy. When migrating *into* iCloud, the current local file is
    /// copied over (unless iCloud already has its own copy). When migrating
    /// *out*, we just point back at the local file — iCloud's copy is left
    /// alone so the user can flip back without losing data.
    func setSyncEnabled(_ enabled: Bool, migrate: Bool) {
        if enabled {
            guard let target = Self.iCloudFileURL() else {
                log.error("Requested iCloud sync but no ubiquity container is available")
                return
            }
            Self.ensureParentDirectoryExists(for: target)
            if migrate, !FileManager.default.fileExists(atPath: target.path) {
                copyForMigration(from: fileURL, to: target)
            }
            // Tell iCloud to download the file if it's currently a stub on disk
            // (file present as `.presets.json.icloud` placeholder).
            try? FileManager.default.startDownloadingUbiquitousItem(at: target)
            relocate(to: target, kind: .iCloud)
        } else {
            relocate(to: Self.localFileURL, kind: .local)
        }
    }

    private func copyForMigration(from src: URL, to dst: URL) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        coordinator.coordinate(
            readingItemAt: src, options: .withoutChanges,
            writingItemAt: dst, options: .forReplacing,
            error: &coordError
        ) { readURL, writeURL in
            do {
                if FileManager.default.fileExists(atPath: writeURL.path) {
                    try FileManager.default.removeItem(at: writeURL)
                }
                try FileManager.default.copyItem(at: readURL, to: writeURL)
                log.info("Migrated presets.json: \(readURL.path) → \(writeURL.path)")
            } catch {
                log.error("Migration copy failed: \(String(describing: error))")
            }
        }
        if let coordError {
            log.error("Migration coordinator failed: \(String(describing: coordError))")
        }
    }

    private func relocate(to url: URL, kind: LocationKind) {
        guard url != fileURL || kind != locationKind else { return }
        stopWatching()
        fileURL = url
        locationKind = kind
        Self.ensureParentDirectoryExists(for: url)
        seedIfNeeded()
        load()
        ensureFlatPresent()
        startWatching()
        log.info("Switched preset store location to \(kind.rawValue): \(self.fileURL.path)")
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
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var readData: Data?
        coordinator.coordinate(
            readingItemAt: fileURL, options: .withoutChanges, error: &coordError
        ) { url in
            readData = try? Data(contentsOf: url)
        }
        if let coordError {
            log.error("Coordinator failed to read presets.json: \(String(describing: coordError))")
        }
        guard let data = readData else {
            log.error("Failed to read presets.json. Falling back to Flat.")
            presets = [EQPreset.flat]
            lastKnownHash = 0
            return
        }
        let hash = data.hashValue
        if hash == lastKnownHash, !presets.isEmpty {
            // Identical bytes to what we last wrote/read — almost certainly a
            // self-write echo from the file watcher. Skip republishing.
            return
        }
        do {
            let decoded = try JSONDecoder().decode([EQPreset].self, from: data)
            presets = decoded
            lastKnownHash = hash
            log.info("Loaded \(decoded.count) presets from \(self.locationKind.rawValue)")
        } catch {
            log.error("Failed to decode presets.json: \(String(describing: error)). Falling back to Flat.")
            presets = [EQPreset.flat]
            lastKnownHash = 0
        }
    }

    @discardableResult
    func write(_ presets: [EQPreset]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(presets)

            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordError: NSError?
            var writeError: Error?
            coordinator.coordinate(
                writingItemAt: fileURL, options: .forReplacing, error: &coordError
            ) { url in
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    writeError = error
                }
            }
            if let coordError { throw coordError }
            if let writeError { throw writeError }

            lastKnownHash = data.hashValue
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

    // MARK: - Import merge

    struct MergeResult {
        var imported: Int
        var renamed: Int
    }

    /// Append imported presets to the library, regenerating UUIDs for any whose
    /// ID collides with something already on disk. Names are passed through
    /// unchanged — only IDs are touched, so two presets called "Bass Boost"
    /// can co-exist (matching how the existing duplicate flow works).
    @discardableResult
    func merge(incoming: [EQPreset]) -> MergeResult {
        var next = presets
        var existingIDs = Set(next.map(\.id))
        var imported = 0
        var renamed = 0
        for var preset in incoming {
            // Never overwrite Flat. If a paste contains it, drop it.
            if preset.id == EQPreset.flatID { continue }
            if existingIDs.contains(preset.id) {
                preset.id = UUID()
                renamed += 1
            }
            existingIDs.insert(preset.id)
            next.append(preset)
            imported += 1
        }
        if imported > 0 {
            write(next)
        }
        return MergeResult(imported: imported, renamed: renamed)
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
            log.error("Could not open presets.json for watching at \(self.fileURL.path)")
            // For iCloud the file may not be materialized locally yet. Retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startWatching()
            }
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
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.load() }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }
}
