import SwiftUI

/// Window scene for A/B preset comparison. Owns the session, drives the
/// two-curve overlay, and exposes slot pickers + toggle / vote / finish.
struct ABComparisonView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog

    @StateObject private var session: ABComparisonSession
    @Environment(\.dismiss) private var dismiss

    init(engine: EQEngine, presetStore: PresetStore, presetCatalog: PresetCatalog) {
        self.engine = engine
        self.presetStore = presetStore
        self.presetCatalog = presetCatalog
        _session = StateObject(wrappedValue: ABComparisonSession(
            engine: engine,
            catalog: presetCatalog,
            store: presetStore
        ))
    }

    private var visiblePresets: [EQPreset] {
        Lurar.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            slotPickers
            if isBlindRunning {
                blindNowPlayingPanel
            } else {
                curveOverlay
            }
            controls
        }
        .padding(20)
        // minHeight has to accommodate the tallest phase (results, which adds
        // the preference tiles + significance note + "New session" row to the
        // setup layout). windowResizability(.contentSize) sizes the window at
        // creation, so this needs to be big enough for the results phase up front.
        .frame(minWidth: 640, minHeight: 640)
        .showsInDockWhileVisible()
        .onAppear { seedDefaultSlotsIfNeeded() }
        .onDisappear { session.cancel() }
    }

    /// NSPopUpButton visually defaults to its first menu item even when the
    /// bound selection is empty, which makes the slot pickers look pre-filled
    /// before the session has snapshots. Seed real defaults on first appearance
    /// so the dropdown and the rest of the UI agree.
    private func seedDefaultSlotsIfNeeded() {
        let presets = visiblePresets
        guard !presets.isEmpty else { return }
        if session.selectedAID == nil {
            session.pickA(id: presets[0].id)
        }
        if session.selectedBID == nil {
            // Prefer a different preset for slot B so the user sees two distinct
            // curves immediately; fall back to the same preset if only one exists.
            let candidate = presets.first(where: { $0.id != session.selectedAID }) ?? presets[0]
            session.pickB(id: candidate.id)
        }
    }

    /// Curve overlay is hidden in blind mode: the curve shapes are pattern-matchable
    /// to known presets, which would defeat the point. We show a neutral
    /// "Now playing" indicator instead.
    private var blindNowPlayingPanel: some View {
        VStack(spacing: 12) {
            if session.isTransitioning {
                Text("Next trial…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("—")
                    .font(.system(size: 96, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Text("Audio briefly muted while the next pair is shuffled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Now playing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(session.blindLabel(for: session.currentSlot))
                    .font(.system(size: 96, weight: .light, design: .rounded))
                    .monospacedDigit()
                Text("Listen, then toggle and vote for the one you prefer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var isBlindRunning: Bool {
        if case .running(.blind) = session.phase { return true }
        return false
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Compare presets")
                .font(.title2.weight(.semibold))
            Text(headerSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var headerSubtitle: String {
        switch session.phase {
        case .setup:
            return engine.isRunning
                ? "Pick two presets, then start a sighted or blind A/B."
                : "Start the engine from the menu bar to compare."
        case .running(.sighted):
            return "Sighted A/B — Space toggles, Esc cancels."
        case .running(.blind):
            return "Blind A/B — Space toggles, Return votes for the current one."
        case .results:
            return "Results"
        }
    }

    // MARK: - Slot pickers

    private var slotPickers: some View {
        HStack(alignment: .top, spacing: 12) {
            slotColumn(
                title: "Slot A",
                selection: Binding(
                    get: { session.selectedAID?.uuidString ?? "" },
                    set: { id in session.pickA(id: UUID(uuidString: id)) }
                ),
                preset: session.presetA,
                hydrating: session.hydratingA,
                error: session.hydrationErrorA,
                matchGain: session.matchGainA
            )
            slotColumn(
                title: "Slot B",
                selection: Binding(
                    get: { session.selectedBID?.uuidString ?? "" },
                    set: { id in session.pickB(id: UUID(uuidString: id)) }
                ),
                preset: session.presetB,
                hydrating: session.hydratingB,
                error: session.hydrationErrorB,
                matchGain: session.matchGainB
            )
        }
        .disabled(isRunningOrResults)
    }

    @ViewBuilder
    private func slotColumn(
        title: String,
        selection: Binding<String>,
        preset: EQPreset?,
        hydrating: Bool,
        error: String?,
        matchGain: Float
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if hydrating {
                    ProgressView().controlSize(.small)
                }
            }
            FixedWidthPopUp(
                width: 280,
                selection: selection,
                items: visiblePresets.map { .init(id: $0.id.uuidString, title: $0.menuLabel) }
            )
            if let preset {
                Text(preset.headphone.isEmpty ? preset.source : "\(preset.headphone) · \(preset.source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if !hydrating {
                Text("No preset selected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if case .running = session.phase, matchGain != 0 {
                Text(String(format: "Loudness match: %+.1f dB", matchGain))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Curve overlay

    private var curveOverlay: some View {
        TwoCurveView(
            curveA: session.presetA.map { (bands: $0.bands, preamp: $0.preamp) },
            curveB: session.presetB.map { (bands: $0.bands, preamp: $0.preamp) },
            highlight: isRunningSighted ? session.currentSlot : nil
        )
        .frame(minHeight: 240)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        switch session.phase {
        case .setup:
            setupControls
        case .running(.sighted):
            sightedRunningControls
        case .running(.blind):
            blindRunningControls
        case .results(let mode):
            resultsControls(mode: mode)
        }
    }

    private var setupControls: some View {
        HStack(spacing: 12) {
            Button("Start sighted A/B") {
                session.start(mode: .sighted)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!session.isReadyToStart || !engine.isRunning)
            .lurarShortcutHelp(LurarShortcuts.abStart, label: "Start a sighted comparison")

            Button("Start blind A/B") {
                session.start(mode: .blind)
            }
            .disabled(!session.isReadyToStart || !engine.isRunning)
            .help("Start a blind A/B \u{2014} slot labels shuffle between trials")

            Spacer()

            if !engine.isRunning {
                Label("Engine off", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var sightedRunningControls: some View {
        HStack(spacing: 12) {
            slotButton(slot: .a, label: "A", shortcut: LurarShortcuts.abSlotA)
            slotButton(slot: .b, label: "B", shortcut: LurarShortcuts.abSlotB)
            Button("Toggle") { session.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .lurarShortcutHelp(LurarShortcuts.abToggle)
            Spacer()
            Button("Done") { session.backToSetup() }
                .keyboardShortcut(.cancelAction)
                .lurarShortcutHelp(LurarShortcuts.abCancel, label: "End the session")
        }
    }

    private var blindRunningControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Group {
                    // In blind mode the slot identities shuffle between trials,
                    // so bind "1" to the leftmost button and "2" to the rightmost
                    // \u{2014} the user picks by VISUAL position, not slot identity.
                    ForEach(Array(session.blindButtonOrder.enumerated()), id: \.element.id) { index, entry in
                        slotButton(
                            slot: entry.slot,
                            label: entry.label,
                            shortcut: index == 0 ? LurarShortcuts.abSlotA : LurarShortcuts.abSlotB
                        )
                    }
                    Button("Toggle") { session.toggle() }
                        .keyboardShortcut(.space, modifiers: [])
                        .lurarShortcutHelp(LurarShortcuts.abToggle)
                    Button("I prefer this one") { session.vote() }
                        .keyboardShortcut(.defaultAction)
                        .lurarShortcutHelp(LurarShortcuts.abVote, label: "Vote for the currently-audible slot (\u{21A9})")
                        .background(
                            // Sibling invisible Button carries the "v" binding so we keep
                            // the visible button's `.defaultAction` (Return) binding intact
                            // \u{2014} two `.keyboardShortcut(...)` modifiers on the same view
                            // replace rather than stack.
                            Button { session.vote() } label: { EmptyView() }
                                .lurarShortcut(LurarShortcuts.abVote)
                                .frame(width: 0, height: 0)
                                .opacity(0)
                                .accessibilityHidden(true)
                        )
                }
                .disabled(session.isTransitioning)
                Spacer()
                Text("Trials: \(session.trials.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Finish") { session.finish() }
                    .disabled(session.trials.isEmpty || session.isTransitioning)
                    .lurarShortcut(LurarShortcuts.abFinish)
                Button("Cancel") { session.backToSetup() }
                    .keyboardShortcut(.cancelAction)
                    .lurarShortcutHelp(LurarShortcuts.abCancel, label: "End the session")
            }
            if session.isTransitioning {
                Text("Shuffling next trial…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Currently audible: \(session.blindLabel(for: session.currentSlot))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func slotButton(slot: EQProcessor.Slot, label: String, shortcut: LurarShortcut? = nil) -> some View {
        Button(label) { session.selectSlot(slot) }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(session.currentSlot == slot ? Color.accentColor : nil)
            .modifier(OptionalShortcut(shortcut: shortcut))
    }

    private func resultsControls(mode: ABComparisonSession.Mode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .blind {
                resultsBlindBody
            } else {
                Text("Sighted session ended.")
                    .font(.callout)
            }
            HStack(spacing: 8) {
                if let a = session.presetA {
                    useButton(preset: a, isWinner: winningSlot(mode: mode) == .a)
                }
                if let b = session.presetB {
                    useButton(preset: b, isWinner: winningSlot(mode: mode) == .b)
                }
                Spacer()
                Button("Close") { applyAndClose(preset: nil) }
                    .help("Close without changing the active preset")
                Button("New session") { session.backToSetup() }
                    .help("Reset and start over")
            }
        }
    }

    /// "Use [preset]" — applies that preset to the engine and closes the window.
    /// The prominent button is the winner in blind mode (when there's one).
    /// Label includes the author/rig suffix (matching the slot dropdown) and is
    /// width-capped so a long catalog label doesn't push the trailing
    /// Close / New session buttons off-screen.
    @ViewBuilder
    private func useButton(preset: EQPreset, isWinner: Bool) -> some View {
        let label = Text("Use \(preset.menuLabel)")
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 260)
        if isWinner {
            Button(action: { applyAndClose(preset: preset) }) { label }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Apply \u{201C}\(preset.menuLabel)\u{201D} and close (\u{21A9})")
        } else {
            Button(action: { applyAndClose(preset: preset) }) { label }
                .buttonStyle(.bordered)
                .help("Apply \u{201C}\(preset.menuLabel)\u{201D} and close")
        }
    }

    /// Apply the chosen preset (or just revert to the pre-comparison preset if
    /// `nil`) and close the window. `engine.apply(...)` exits slot mode and
    /// publishes the new preset; `dismiss()` triggers `onDisappear → cancel()`
    /// which is a no-op after the apply since the engine is already out of
    /// comparison mode.
    private func applyAndClose(preset: EQPreset?) {
        if let preset {
            engine.apply(preset: preset)
        }
        dismiss()
    }

    /// The slot the user actually preferred. Only meaningful in blind mode and
    /// only when one slot got strictly more votes than the other.
    private func winningSlot(mode: ABComparisonSession.Mode) -> EQProcessor.Slot? {
        guard mode == .blind else { return nil }
        let (a, b) = session.voteTally
        if a > b { return .a }
        if b > a { return .b }
        return nil
    }

    @ViewBuilder
    private var resultsBlindBody: some View {
        let (a, b) = session.voteTally
        VStack(alignment: .leading, spacing: 6) {
            Text("You preferred:")
                .font(.headline)
            HStack(spacing: 20) {
                preferenceTile(
                    title: session.presetA?.menuLabel ?? "Slot A",
                    votes: a,
                    total: a + b,
                    label: "shown as \(session.blindLabel(for: .a))"
                )
                preferenceTile(
                    title: session.presetB?.menuLabel ?? "Slot B",
                    votes: b,
                    total: a + b,
                    label: "shown as \(session.blindLabel(for: .b))"
                )
            }
            Text(session.significanceNote)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func preferenceTile(title: String, votes: Int, total: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(votes) of \(total) trials")
                .font(.title3.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Phase helpers

    private var isRunningOrResults: Bool {
        switch session.phase {
        case .setup: return false
        case .running, .results: return true
        }
    }

    private var isRunningSighted: Bool {
        if case .running(.sighted) = session.phase { return true }
        return false
    }
}

/// Applies a `LurarShortcut` only when one is provided; no-op when nil.
/// Keeps `slotButton(...)` callers that don't need a keyboard binding
/// (rare \u{2014} currently the results screen doesn't use this helper) clean.
private struct OptionalShortcut: ViewModifier {
    let shortcut: LurarShortcut?
    func body(content: Content) -> some View {
        if let s = shortcut {
            content.lurarShortcut(s)
        } else {
            content
        }
    }
}

// MARK: - Two-curve overlay

/// Draws two response curves on the same axes. The "highlighted" curve (when
/// non-nil) is the brighter one; the other is rendered with reduced opacity.
private struct TwoCurveView: View {
    let curveA: (bands: [EQBand], preamp: Float)?
    let curveB: (bands: [EQBand], preamp: Float)?
    let highlight: EQProcessor.Slot?

    private let minDB: Double = -15
    private let maxDB: Double = 15
    private let samples = 256

    var body: some View {
        Canvas { ctx, size in
            drawGrid(ctx: &ctx, size: size)
            if let curveA {
                drawCurve(ctx: &ctx, size: size, bands: curveA.bands, preamp: curveA.preamp,
                          color: color(forSlot: .a))
            }
            if let curveB {
                drawCurve(ctx: &ctx, size: size, bands: curveB.bands, preamp: curveB.preamp,
                          color: color(forSlot: .b))
            }
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .overlay(legend, alignment: .topLeading)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendChip(slot: .a)
            legendChip(slot: .b)
        }
        .padding(8)
    }

    private func legendChip(slot: EQProcessor.Slot) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color(forSlot: slot)).frame(width: 8, height: 8)
            Text(slot == .a ? "A" : "B")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.background.tertiary, in: Capsule())
    }

    private func color(forSlot slot: EQProcessor.Slot) -> Color {
        let base: Color = slot == .a ? Color.accentColor : Color.orange
        if let highlight {
            return slot == highlight ? base : base.opacity(0.35)
        }
        return base
    }

    private func drawGrid(ctx: inout GraphicsContext, size: CGSize) {
        let gridColor = Color.secondary.opacity(0.18)
        let yZero = EQCurveGeometry.yPos(forDB: 0, minDB: minDB, maxDB: maxDB, in: size)
        var midPath = Path()
        midPath.move(to: CGPoint(x: 0, y: yZero))
        midPath.addLine(to: CGPoint(x: size.width, y: yZero))
        ctx.stroke(midPath, with: .color(.secondary.opacity(0.4)), lineWidth: 1)

        for db in stride(from: -12.0, through: 12.0, by: 3.0) where db != 0 {
            let y = EQCurveGeometry.yPos(forDB: db, minDB: minDB, maxDB: maxDB, in: size)
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
        }

        let decadeFreqs: [Double] = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000]
        for f in decadeFreqs {
            let x = EQCurveGeometry.xPos(forFreq: f, in: size)
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 1)
        }
    }

    private func drawCurve(
        ctx: inout GraphicsContext,
        size: CGSize,
        bands: [EQBand],
        preamp: Float,
        color: Color
    ) {
        var path = Path()
        var started = false
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let f = EQCurveGeometry.minFreq * pow(EQCurveGeometry.maxFreq / EQCurveGeometry.minFreq, t)
            let dB = EQCurveGeometry.totalDB(at: f, bands: bands, preamp: preamp)
            let x = EQCurveGeometry.xPos(forFreq: f, in: size)
            let y = EQCurveGeometry.yPos(forDB: dB, minDB: minDB, maxDB: maxDB, in: size)
            if !started {
                path.move(to: CGPoint(x: x, y: y))
                started = true
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        ctx.stroke(path, with: .color(color), lineWidth: 2)
    }
}
