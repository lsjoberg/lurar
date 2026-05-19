import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "BurnInTracker")

/// Per-output-device runtime counter. Subscribes to the engine's
/// `isRunning` / `activeOutput` pair and accumulates wall-clock seconds
/// into a UserDefaults-backed `[deviceUID: { name, seconds }]` map. The
/// stored value reflects everything flushed up to `current.lastFlushedAt`;
/// while a run is active, `entries()` adds the live tail from
/// `lastFlushedAt → now` so the UI sees a moving total without us having
/// to write to disk every tick. A 60 s timer flushes incremental progress
/// so an unexpected exit only loses up to a minute.
@MainActor
final class BurnInTracker: ObservableObject {
    static let defaultsKey = "lurar.burnInByDevice"

    struct Entry: Equatable {
        let uid: String
        let name: String
        let seconds: Double
    }

    private let defaults: UserDefaults
    private var cancellables: Set<AnyCancellable> = []
    private var current: ActiveRun?
    private var flushTimer: Timer?

    private struct ActiveRun {
        let uid: String
        let name: String
        var lastFlushedAt: Date
    }

    private struct StoredEntry: Codable {
        var name: String
        var seconds: Double
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Subscribe to the engine's lifecycle. Idempotent — calling twice
    /// replaces the prior subscriptions and keeps a single live counter.
    func observe(engine: EQEngine) {
        cancellables.removeAll()
        Publishers.CombineLatest(engine.$isRunning, engine.$activeOutput)
            .sink { [weak self] running, output in
                Task { @MainActor in
                    self?.update(running: running, device: output)
                }
            }
            .store(in: &cancellables)
    }

    /// UID of the device currently being counted, or nil when idle.
    var activeDeviceUID: String? { current?.uid }

    /// All recorded per-device totals, sorted by accumulated seconds desc.
    /// While a run is in flight, the active device's value includes the
    /// unflushed tail since `lastFlushedAt`.
    func entries() -> [Entry] {
        var totals = stored()
        if let run = current {
            let tail = max(0, Date().timeIntervalSince(run.lastFlushedAt))
            let prior = totals[run.uid]?.seconds ?? 0
            totals[run.uid] = StoredEntry(name: run.name, seconds: prior + tail)
        }
        return totals
            .map { Entry(uid: $0.key, name: $0.value.name, seconds: $0.value.seconds) }
            .sorted { $0.seconds > $1.seconds }
    }

    // MARK: - Internal

    private func update(running: Bool, device: AudioDevice?) {
        let shouldEnd: Bool = {
            guard let run = current else { return false }
            return !running || device?.uid != run.uid
        }()
        if shouldEnd {
            flush()
            current = nil
            stopFlushTimer()
        }
        if running, let device, current == nil {
            current = ActiveRun(uid: device.uid, name: device.name, lastFlushedAt: Date())
            startFlushTimer()
            log.info("Burn-in: counting started for \(device.name, privacy: .public) (\(device.uid, privacy: .public))")
        }
        objectWillChange.send()
    }

    private func flush() {
        guard var run = current else { return }
        let now = Date()
        let elapsed = max(0, now.timeIntervalSince(run.lastFlushedAt))
        guard elapsed > 0 else { return }
        var totals = stored()
        let prior = totals[run.uid]?.seconds ?? 0
        totals[run.uid] = StoredEntry(name: run.name, seconds: prior + elapsed)
        persist(totals)
        run.lastFlushedAt = now
        current = run
    }

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = Timer(timeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.flush()
                self.objectWillChange.send()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
    }

    private func stopFlushTimer() {
        flushTimer?.invalidate()
        flushTimer = nil
    }

    private func stored() -> [String: StoredEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredEntry].self, from: data)) ?? [:]
    }

    private func persist(_ totals: [String: StoredEntry]) {
        guard let data = try? JSONEncoder().encode(totals) else {
            log.error("Burn-in: failed to encode totals")
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
