import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "ABComparison")

/// One A/B comparison session. Owns the two slot picks, hydration awaits,
/// loudness-match results, the active slot, blind-mode mask, and trial log.
/// Lifecycle is tied to the comparison window — when the window closes the
/// view calls `cancel()`, which puts the engine back to single-preset mode.
@MainActor
final class ABComparisonSession: ObservableObject {
    enum Phase: Equatable {
        case setup
        case running(Mode)
        case results(Mode)
    }

    enum Mode: Equatable {
        case sighted
        /// Blind preference: labels hidden, assignment randomized once per
        /// session (see `blindMask`), votes recorded, reveal on finish.
        case blind
    }

    struct Trial: Identifiable, Equatable {
        let id = UUID()
        let votedSlot: EQProcessor.Slot
        let actualSlot: EQProcessor.Slot
        let timestamp: Date
    }

    // MARK: - Published state

    @Published var phase: Phase = .setup
    @Published var mode: Mode = .sighted

    /// Currently selected IDs in the slot pickers. Resolution to a snapshot
    /// preset happens in `resolveSelections()` whenever these change.
    @Published var selectedAID: UUID?
    @Published var selectedBID: UUID?

    /// Snapshots taken at slot-pick time. They're independent of any later
    /// edits the user might make to the underlying preset — value semantics
    /// of `EQPreset` make this automatic.
    @Published private(set) var presetA: EQPreset?
    @Published private(set) var presetB: EQPreset?

    @Published private(set) var hydratingA: Bool = false
    @Published private(set) var hydratingB: Bool = false
    @Published private(set) var hydrationErrorA: String?
    @Published private(set) var hydrationErrorB: String?

    /// Loudness-match attenuations in dB (≤ 0). Set by `start(...)`.
    @Published private(set) var matchGainA: Float = 0
    @Published private(set) var matchGainB: Float = 0

    @Published private(set) var currentSlot: EQProcessor.Slot = .a
    @Published private(set) var trials: [Trial] = []

    /// Per-session display-label permutation for blind mode. When `true`, the
    /// UI's "1" button maps to slot B and "2" maps to slot A.
    @Published private(set) var blindMask: Bool = false

    /// True while a between-trial silence is in flight (mute → re-randomize →
    /// unmute). The UI uses this to disable Vote/Toggle so a held Return key
    /// can't record duplicate trials, and so the user doesn't see a stale
    /// slot label during the swap.
    @Published private(set) var isTransitioning: Bool = false

    // MARK: - Dependencies

    private let engine: EQEngine
    private let catalog: PresetCatalog
    private let store: PresetStore
    private var cancellables: Set<AnyCancellable> = []

    init(engine: EQEngine, catalog: PresetCatalog, store: PresetStore) {
        self.engine = engine
        self.catalog = catalog
        self.store = store

        // If something else exits comparison (menu bar picker, engine stop),
        // reset back to setup so the window stays coherent.
        engine.$isInComparisonMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inComparison in
                guard let self else { return }
                if !inComparison && self.phase != .setup {
                    log.info("Comparison externally exited — returning to setup")
                    self.trials = []
                    self.phase = .setup
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Slot picking

    func pickA(id: UUID?) {
        selectedAID = id
        resolve(slot: .a)
    }

    func pickB(id: UUID?) {
        selectedBID = id
        resolve(slot: .b)
    }

    /// True when both slots have a fully-loaded snapshot and no fetch is in flight.
    var isReadyToStart: Bool {
        presetA != nil && presetB != nil && !hydratingA && !hydratingB
    }

    private func resolve(slot: EQProcessor.Slot) {
        let id: UUID?
        switch slot {
        case .a: id = selectedAID
        case .b: id = selectedBID
        }
        guard let id else {
            setSnapshot(nil, for: slot)
            return
        }
        // User-store presets resolve synchronously.
        if let local = store.presets.first(where: { $0.id == id }) {
            setSnapshot(local, for: slot)
            setHydrating(false, for: slot)
            setError(nil, for: slot)
            return
        }
        // Catalog: may already be hydrated, otherwise kick off a fetch.
        if let hydrated = catalog.hydratedPresets[id] {
            setSnapshot(hydrated, for: slot)
            setHydrating(false, for: slot)
            setError(nil, for: slot)
            return
        }
        setSnapshot(nil, for: slot)
        setHydrating(true, for: slot)
        setError(nil, for: slot)
        guard let task = catalog.ensureHydrated(id: id) else {
            setHydrating(false, for: slot)
            setError("Catalog index not loaded yet — try again in a moment.", for: slot)
            return
        }
        Task { [weak self] in
            do {
                let preset = try await task.value
                await MainActor.run {
                    guard let self else { return }
                    self.setSnapshot(preset, for: slot)
                    self.setHydrating(false, for: slot)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.setHydrating(false, for: slot)
                    self.setError(error.localizedDescription, for: slot)
                }
            }
        }
    }

    private func setSnapshot(_ preset: EQPreset?, for slot: EQProcessor.Slot) {
        switch slot {
        case .a: presetA = preset
        case .b: presetB = preset
        }
    }

    private func setHydrating(_ on: Bool, for slot: EQProcessor.Slot) {
        switch slot {
        case .a: hydratingA = on
        case .b: hydratingB = on
        }
    }

    private func setError(_ message: String?, for slot: EQProcessor.Slot) {
        switch slot {
        case .a: hydrationErrorA = message
        case .b: hydrationErrorB = message
        }
    }

    // MARK: - Session control

    func start(mode: Mode) {
        guard let a = presetA, let b = presetB else { return }
        self.mode = mode
        let (gA, gB) = LoudnessMatcher.equalAttenuationsDB(presetA: a, presetB: b)
        matchGainA = gA
        matchGainB = gB
        blindMask = (mode == .blind) ? Bool.random() : false
        trials = []
        isTransitioning = false
        currentSlot = .a
        engine.loadComparisonSlots(presetA: a, presetB: b, matchGainA: gA, matchGainB: gB)
        engine.setComparisonSlot(.a)
        phase = .running(mode)
        let summary = String(format: "Comparison started: mode=%@ matchA=%+.2f dB matchB=%+.2f dB",
                             String(describing: mode), gA, gB)
        log.info("\(summary, privacy: .public)")
    }

    /// Flip to the other slot.
    func toggle() {
        guard case .running = phase, !isTransitioning else { return }
        currentSlot = (currentSlot == .a) ? .b : .a
        engine.setComparisonSlot(currentSlot)
    }

    /// Jump to a specific slot (sighted mode buttons).
    func selectSlot(_ slot: EQProcessor.Slot) {
        guard case .running = phase, !isTransitioning else { return }
        currentSlot = slot
        engine.setComparisonSlot(slot)
    }

    /// Record a preference vote (blind mode), then begin the silent transition
    /// to the next trial: mute → re-randomize the mask (so "1" maps to a fresh
    /// random slot) → swap audio to "1" → unmute. The swap itself happens during
    /// the silence so it's inaudible, and we always land on whatever the new "1"
    /// is so the displayed label and the audible slot stay aligned.
    func vote() {
        guard case .running(.blind) = phase, !isTransitioning else { return }
        trials.append(Trial(votedSlot: currentSlot, actualSlot: currentSlot, timestamp: Date()))
        isTransitioning = true
        Task { [weak self] in
            await self?.runBlindTrialTransition()
            await MainActor.run { self?.isTransitioning = false }
        }
    }

    /// ~240 ms of total silence: 120 ms after mute (let the audio buffer drain
    /// and the user perceive a gap), do the slot swap, then 120 ms more before
    /// unmute (so the swap can't be heard at the silence edges).
    private func runBlindTrialTransition() async {
        await MainActor.run { engine.setComparisonMute(true) }
        try? await Task.sleep(nanoseconds: 120_000_000)
        await MainActor.run {
            blindMask = Bool.random()
            let labelOne: EQProcessor.Slot = blindMask ? .b : .a
            currentSlot = labelOne
            engine.setComparisonSlot(labelOne)
        }
        try? await Task.sleep(nanoseconds: 120_000_000)
        await MainActor.run { engine.setComparisonMute(false) }
    }

    func finish() {
        guard case .running(let m) = phase else { return }
        phase = .results(m)
    }

    func backToSetup() {
        phase = .setup
        trials = []
        engine.exitComparisonMode()
    }

    func cancel() {
        phase = .setup
        trials = []
        engine.exitComparisonMode()
    }

    // MARK: - Blind labels

    /// The label shown for a given slot in blind mode. With `blindMask = false`
    /// slot A is "1" and slot B is "2"; with `blindMask = true` they swap.
    func blindLabel(for slot: EQProcessor.Slot) -> String {
        let swapped = blindMask
        switch slot {
        case .a: return swapped ? "2" : "1"
        case .b: return swapped ? "1" : "2"
        }
    }

    struct BlindButton: Identifiable {
        let label: String
        let slot: EQProcessor.Slot
        var id: String { label }
    }

    /// Slots ordered by their displayed blind label so the UI always renders
    /// "1" then "2" left-to-right — only the underlying slot mapping changes
    /// with `blindMask`.
    var blindButtonOrder: [BlindButton] {
        if blindMask {
            return [BlindButton(label: "1", slot: .b), BlindButton(label: "2", slot: .a)]
        } else {
            return [BlindButton(label: "1", slot: .a), BlindButton(label: "2", slot: .b)]
        }
    }

    // MARK: - Results helpers

    /// (votes for A, votes for B). Only meaningful in blind mode.
    var voteTally: (a: Int, b: Int) {
        let a = trials.filter { $0.actualSlot == .a }.count
        let b = trials.filter { $0.actualSlot == .b }.count
        return (a, b)
    }

    /// One-line interpretation of the trial count under a null hypothesis of
    /// no preference (binomial test, two-sided p ≈ 0.05). Hand-rolled rather
    /// than pulling in a stats dep — the table is short.
    var significanceNote: String {
        let total = trials.count
        let (a, b) = voteTally
        let majority = max(a, b)
        guard total >= 3 else {
            return "Run at least 3 trials before drawing conclusions."
        }
        if total > 0, majority == total {
            return "Unanimous in \(total) trials — strong preference."
        }
        if majority >= significantMajority(forTrials: total) {
            return "\(majority)/\(total) majority — outside the 95% chance band."
        }
        return "\(majority)/\(total) — within chance; no clear preference."
    }

    /// Critical value (number of "heads") for a two-sided binomial test at
    /// α ≈ 0.05 against p = 0.5. Pre-computed for small N so we don't ship a
    /// stats library. Returns `n+1` for trial counts outside the table so
    /// the comparison always falls through to "within chance".
    private func significantMajority(forTrials n: Int) -> Int {
        switch n {
        case 5:  return 5
        case 6:  return 6
        case 7:  return 7
        case 8:  return 8
        case 9:  return 8
        case 10: return 9
        case 11: return 10
        case 12: return 10
        case 13: return 11
        case 14: return 12
        case 15: return 12
        case 16: return 13
        case 17: return 13
        case 18: return 14
        case 19: return 15
        case 20: return 15
        default: return n + 1
        }
    }
}
