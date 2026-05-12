import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "PresetStore")

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
        startWatching()
    }

    deinit {
        fileSource?.cancel()
        fileSource = nil
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
        // Fall back to writing the in-code defaults.
        let defaults = [EQPreset.aryaStealthOratory1990, EQPreset.flat]
        write(defaults)
    }

    // MARK: - Load / write

    func load() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([EQPreset].self, from: data)
            presets = decoded
            log.info("Loaded \(decoded.count) presets")
        } catch {
            log.error("Failed to load presets.json: \(String(describing: error)). Falling back to defaults.")
            presets = [EQPreset.aryaStealthOratory1990, EQPreset.flat]
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
        // Give the new file a moment to land.
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
