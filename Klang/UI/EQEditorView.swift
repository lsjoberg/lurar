import AppKit
import SwiftUI

struct EQEditorView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog

    // Working copy, edited live and pushed to the engine on every change.
    @State private var draft: EQPreset = .flat
    @State private var showDeleteConfirm = false
    @State private var showResetConfirm = false
    @State private var showLibrary = false
    /// When the user picks a different preset in the dropdown but the current
    /// draft has unsaved edits, we stash the target here and present the
    /// Save/Discard/Cancel alert. Mirrors `closeCoordinator.pendingClose` but
    /// resolves to a preset switch instead of a window close.
    @State private var pendingSwitchTargetID: UUID? = nil
    @StateObject private var closeCoordinator = EditorCloseCoordinator()
    @State private var hostWindow: NSWindow?
    /// Spectrum overlay is opt-in: the 30 Hz redraw is fine on modern Macs but can
    /// feel laggy on slower hardware or when many other apps are pulling on the
    /// main runloop. Persists across launches.
    @AppStorage("spectrum.enabled") private var spectrumEnabled: Bool = false

    private var visiblePresets: [EQPreset] {
        Klang.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    /// Dropdown source. Always includes the current draft, even if the store's
    /// @Published update from a just-completed Tweak/New preset hasn't reached
    /// this view yet — otherwise the popup briefly has no matching item for the
    /// selection and renders blank.
    private var dropdownPresets: [EQPreset] {
        var list = visiblePresets
        if !list.contains(where: { $0.id == draft.id }) {
            list.append(draft)
        }
        return list
    }

    /// Both bundled Flat and any catalog-sourced preset are read-only — users must
    /// Tweak the preset to keep edits.
    private var isBuiltIn: Bool {
        presetStore.isBundledFlat(draft) || presetCatalog.isBuiltIn(draft.id)
    }

    /// Band/preamp sliders are disabled when comparison mode is active too —
    /// the engine is playing one of two pre-loaded slots, not the editor draft,
    /// so live edits would silently desync from what's audible.
    private var editsLocked: Bool {
        isBuiltIn || engine.isInComparisonMode
    }

    private var savedVersion: EQPreset? {
        presetStore.presets.first(where: { $0.id == draft.id })
    }

    private var isDirty: Bool {
        guard let saved = savedVersion else { return true }
        return !draft.sameContent(as: saved)
    }

    /// Live lookup of the draft's parent preset. Returns nil if the draft has no
    /// parentRef, or if the parent is a catalog entry that isn't currently hydrated.
    private var parentPreset: EQPreset? {
        guard let ref = draft.parentRef else { return nil }
        switch ref.kind {
        case .bundled:
            return ref.id == EQPreset.flatID ? EQPreset.flat : nil
        case .catalog:
            return presetCatalog.hydratedPresets[ref.id]
        }
    }

    private var canResetToOriginal: Bool {
        guard let parent = parentPreset else { return false }
        return !draft.sameAudibleContent(as: parent)
    }

    var body: some View {
        HSplitView {
            // Left: curve + header
            VStack(alignment: .leading, spacing: 12) {
                editorTopBar
                header
                if engine.isInComparisonMode {
                    comparisonBanner
                }
                EQCurveView(
                    bands: draft.bands,
                    preamp: draft.preamp,
                    referenceBands: parentPreset?.bands,
                    referencePreamp: parentPreset?.preamp
                )
                .frame(minHeight: 220)
                .overlay {
                    // Stacked separately so the spectrum's 30 Hz redraw doesn't
                    // invalidate the EQ curve (which has expensive per-band trig
                    // math). Kept present whenever the toggle is on regardless of
                    // engine state — an empty audio ring just renders as no fill.
                    if spectrumEnabled {
                        SpectrumOverlayView(analyzer: engine.spectrumAnalyzer)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    spectrumToggleButton
                        .padding(8)
                }
                preampRow
            }
            .padding(16)
            .frame(minWidth: 360)

            // Right: per-band controls
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(Array(draft.bands.enumerated()), id: \.offset) { idx, _ in
                        bandEditor(index: idx)
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 320)
        }
        .toolbar {
            ToolbarItemGroup(placement: .destructiveAction) {
                if !isBuiltIn && savedVersion != nil {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isBuiltIn {
                    Button {
                        tweakCurrent()
                    } label: {
                        Label("Tweak\u{2026}", systemImage: "slider.horizontal.3")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Make an editable copy of this built-in in your library. The original stays available as a dashed reference curve, and you can reset back to it any time.")
                } else {
                    Button("Discard Changes") { discardChanges() }
                        .disabled(!isDirty)
                        .help("Throw away unsaved edits and return to the last saved version.")
                    Button("Save") { presetStore.update(draft) }
                        .disabled(!isDirty)
                }
            }
        }
        .sheet(isPresented: $showLibrary) {
            PresetLibraryView(catalog: presetCatalog)
        }
        .alert("Delete \u{201C}\(draft.name)\u{201D}?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This preset will be permanently removed.")
        }
        .alert(
            "Reset \u{201C}\(draft.name)\u{201D} to original?",
            isPresented: $showResetConfirm
        ) {
            Button("Reset", role: .destructive) { resetToOriginal() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Bands and preamp will be overwritten with the original \u{201C}\(draft.parentRef?.snapshotName ?? "")\u{201D} curve. Your preset name, headphone, and source are preserved. This replaces the saved version.")
        }
        .alert(
            "Save changes to \u{201C}\(draft.name)\u{201D}?",
            isPresented: $closeCoordinator.pendingClose
        ) {
            Button("Save") {
                presetStore.update(draft)
                let window = hostWindow
                DispatchQueue.main.async { window?.close() }
            }
            Button("Discard", role: .destructive) {
                if let saved = savedVersion {
                    engine.apply(preset: saved)
                    draft = saved
                }
                let window = hostWindow
                DispatchQueue.main.async { window?.close() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your edits haven't been saved. Save them, discard them, or cancel and keep editing.")
        }
        .alert(
            "Save changes to \u{201C}\(draft.name)\u{201D}?",
            isPresented: Binding(
                get: { pendingSwitchTargetID != nil },
                set: { if !$0 { pendingSwitchTargetID = nil } }
            )
        ) {
            Button("Save") {
                presetStore.update(draft)
                commitPendingSwitch()
            }
            Button("Discard", role: .destructive) {
                commitPendingSwitch()
            }
            Button("Cancel", role: .cancel) {
                pendingSwitchTargetID = nil
            }
        } message: {
            Text("Your edits haven't been saved. Save them, discard them, or cancel to keep editing this preset.")
        }
        .background(WindowAccessor(window: $hostWindow))
        .task {
            if let current = engine.currentPreset { draft = current }
            else if let first = presetStore.presets.first { draft = first }
            hydrateParentIfNeeded()
        }
        .onChange(of: engine.currentPreset) { _, new in
            // Engine changed preset externally (menu bar). Mirror into the editor.
            if let new, new.id != draft.id { draft = new }
        }
        .onChange(of: draft.parentRef) { _, _ in hydrateParentIfNeeded() }
        .onChange(of: hostWindow) { _, win in
            win?.delegate = closeCoordinator
        }
        .onAppear {
            closeCoordinator.isDirty = isDirty
            closeCoordinator.isBuiltIn = isBuiltIn
        }
        .onChange(of: isDirty) { _, new in
            closeCoordinator.isDirty = new
        }
        .onChange(of: isBuiltIn) { _, new in
            closeCoordinator.isBuiltIn = new
        }
    }

    // MARK: - Sections

    private var editorTopBar: some View {
        HStack(spacing: 8) {
            Text("Preset")
                .foregroundStyle(.secondary)
            FixedWidthPopUp(
                width: 280,
                selection: Binding(
                    get: { draft.id.uuidString },
                    set: { newID in attemptSwitch(to: UUID(uuidString: newID)) }
                ),
                items: Klang.sortedPresetItems(
                    presets: dropdownPresets,
                    catalog: presetCatalog,
                    store: presetStore
                ),
                actions: [
                    .init(id: "new", title: "New preset…"),
                    .init(id: "library", title: "Add more presets…")
                ],
                onAction: { actionID in
                    switch actionID {
                    case "new": createNewPreset()
                    case "library": showLibrary = true
                    default: break
                    }
                }
            )
            .disabled(dropdownPresets.isEmpty)

            Spacer()
        }
    }

    private func attemptSwitch(to id: UUID?) {
        guard let id, id != draft.id,
              visiblePresets.contains(where: { $0.id == id }) else { return }
        if !isDirty || isBuiltIn {
            commitSwitch(to: id)
        } else {
            pendingSwitchTargetID = id
        }
    }

    private func commitPendingSwitch() {
        guard let id = pendingSwitchTargetID else { return }
        commitSwitch(to: id)
    }

    private func commitSwitch(to id: UUID) {
        guard let target = visiblePresets.first(where: { $0.id == id }) else {
            pendingSwitchTargetID = nil
            return
        }
        draft = target
        engine.apply(preset: target)
        pendingSwitchTargetID = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Preset name", text: $draft.name)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .disabled(isBuiltIn)
                if isBuiltIn {
                    Text("Built-in")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                } else if isDirty {
                    Text("Unsaved")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            if !isBuiltIn, let ref = draft.parentRef {
                HStack(spacing: 8) {
                    parentChip(ref: ref)
                    if parentPreset != nil {
                        resetToOriginalButton(snapshotName: ref.snapshotName)
                    }
                    Spacer()
                }
            }
            HStack(spacing: 8) {
                TextField("Headphone", text: $draft.headphone)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBuiltIn)
                TextField("Source", text: $draft.source)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isBuiltIn)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func parentChip(ref: PresetParentRef) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "link")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text("Derived from \(ref.snapshotName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if parentPreset == nil {
                Text("· original unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    @ViewBuilder
    private func resetToOriginalButton(snapshotName: String) -> some View {
        Button {
            showResetConfirm = true
        } label: {
            Label("Reset to Original", systemImage: "arrow.uturn.backward")
        }
        .controlSize(.small)
        .disabled(!canResetToOriginal)
        .help(canResetToOriginal
              ? "Overwrite this preset's bands and preamp with the original \u{201C}\(snapshotName)\u{201D} curve. Replaces your saved version — your name, headphone, and source are kept."
              : "Bands and preamp already match the original.")
    }

    private func deleteCurrent() {
        let deletedID = draft.id
        let deletedIndex = presetStore.presets.firstIndex(where: { $0.id == deletedID })
        let parentRef = draft.parentRef
        presetStore.delete(id: deletedID)

        // Prefer the parent the deleted preset was forked from — the user just
        // threw away their tweak, so the original it came from is the most
        // useful place to land. Falls back to the neighbor heuristic when there
        // is no parent, or the parent isn't currently visible (e.g., a catalog
        // entry the user disabled in the library after forking).
        let parent: EQPreset? = parentRef.flatMap { ref in
            visiblePresets.first(where: { $0.id == ref.id })
        }

        // Neighbor fallback: same index after removal (was the one below), else
        // the previous one, else the first remaining user preset, else the
        // first visible preset (built-in Flat is always present).
        let neighbor: EQPreset? = {
            if let idx = deletedIndex {
                if idx < presetStore.presets.count { return presetStore.presets[idx] }
                if idx > 0 { return presetStore.presets[idx - 1] }
            }
            return presetStore.presets.first ?? visiblePresets.first
        }()

        if let next = parent ?? neighbor {
            draft = next
            engine.apply(preset: next)
        }
    }

    private var comparisonBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("A/B comparison in progress")
                    .font(.callout.weight(.semibold))
                Text("Band edits paused. Pick a preset above to exit, or close the Compare window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Toggle for the live FFT overlay. Sits in the top-right corner of the EQ curve
    /// because that's the thing it controls — a toolbar slot was both too far away
    /// and visually adjacent to destructive actions.
    private var spectrumToggleButton: some View {
        Button {
            spectrumEnabled.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: spectrumEnabled ? "waveform" : "waveform.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text("Spectrum")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(spectrumEnabled ? Color.accentColor : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(.regularMaterial)
            )
            .overlay(
                Capsule()
                    .strokeBorder(spectrumEnabled ? Color.accentColor.opacity(0.6) : .secondary.opacity(0.5),
                                  lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(spectrumEnabled
              ? "Hide the live FFT overlay"
              : "Show a live FFT of the post-EQ signal")
    }

    /// Throw away unsaved edits and snap the draft + engine back to the saved
    /// on-disk version. No-op if the preset has no saved version yet (shouldn't
    /// happen — Tweak/New both save on creation).
    private func discardChanges() {
        guard let saved = savedVersion else { return }
        draft = saved
        engine.apply(preset: saved)
    }

    /// Fork the current built-in into the user library, stamping a parentRef so
    /// the editor can later show "Derived from …" and offer Reset to original.
    /// Writes to disk immediately so Discard Changes has a stable on-disk target.
    private func tweakCurrent() {
        guard isBuiltIn else { return }
        let kind: PresetParentRef.Kind
        let slug: String?
        if presetStore.isBundledFlat(draft) {
            kind = .bundled
            slug = nil
        } else {
            kind = .catalog
            slug = presetCatalog.entries.first(where: { $0.id == draft.id })?.slug
        }
        let ref = PresetParentRef(
            kind: kind,
            id: draft.id,
            slug: slug,
            snapshotName: draft.name
        )
        var copy = draft
        copy.id = UUID()
        copy.name = presetStore.uniqueName(based: draft.name + " (custom)")
        // Reset source so the menu label doesn't claim oratory1990 authorship of
        // the user's tweaked copy — lineage is preserved via parentRef.
        copy.source = "Klang"
        copy.parentRef = ref
        presetStore.add(copy)
        draft = copy
        engine.apply(preset: copy)
    }

    /// Seed a fully custom preset from scratch — 10 log-spaced bands at 0 dB,
    /// no parent reference. Writes to disk immediately.
    private func createNewPreset() {
        let preset = EQPreset.blank(name: presetStore.uniqueName(based: "New Preset"))
        presetStore.add(preset)
        draft = preset
        engine.apply(preset: preset)
    }

    /// Overwrite the draft's bands + preamp with the live parent curve and
    /// persist. Keeps id/name/headphone/source/parentRef untouched.
    private func resetToOriginal() {
        guard let parent = parentPreset else { return }
        var next = draft
        next.bands = parent.bands
        next.preamp = parent.preamp
        draft = next
        presetStore.update(next)
        engine.apply(preset: next)
    }

    /// Catalog parents can be disabled in the library — in that case we still
    /// want the overlay/reset to work, so trigger an on-demand fetch.
    private func hydrateParentIfNeeded() {
        guard let ref = draft.parentRef,
              ref.kind == .catalog,
              presetCatalog.hydratedPresets[ref.id] == nil
        else { return }
        _ = presetCatalog.ensureHydrated(id: ref.id)
    }

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preamp").bold()
                Spacer()
                Text(String(format: "%+.1f dB", draft.preamp)).monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(draft.preamp) },
                    set: { newValue in
                        draft.preamp = Float(newValue)
                        engine.setPreamp(Float(newValue))
                    }
                ),
                in: -12...0
            )
            .disabled(editsLocked)
        }
    }

    @ViewBuilder
    private func bandEditor(index: Int) -> some View {
        let band = draft.bands[index]
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Band \(index + 1)").bold()
                    Spacer()
                    Picker("", selection: Binding(
                        get: { band.type },
                        set: { newType in
                            draft.bands[index].type = newType
                            engine.updateBand(index: index, band: draft.bands[index])
                        }
                    )) {
                        ForEach(EQBand.FilterType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .disabled(editsLocked)
                }

                // Frequency (log scale)
                row(label: "Frequency",
                    value: String(format: band.frequency >= 1000 ? "%.1f kHz" : "%.0f Hz",
                                  band.frequency >= 1000 ? band.frequency / 1000 : band.frequency)) {
                    Slider(
                        value: Binding(
                            get: { logFreq(Double(band.frequency)) },
                            set: { logVal in
                                let hz = Float(expFreq(logVal))
                                draft.bands[index].frequency = hz
                                engine.updateBand(index: index, band: draft.bands[index])
                            }
                        ),
                        in: logFreq(20)...logFreq(20_000)
                    )
                    .disabled(editsLocked)
                }

                // Gain
                row(label: "Gain",
                    value: String(format: "%+.1f dB", band.gain)) {
                    Slider(
                        value: Binding(
                            get: { Double(band.gain) },
                            set: { v in
                                draft.bands[index].gain = Float(v)
                                engine.updateBand(index: index, band: draft.bands[index])
                            }
                        ),
                        in: -12...12
                    )
                    .disabled(editsLocked)
                }

                // Q
                row(label: "Q",
                    value: String(format: "%.2f", band.q)) {
                    Slider(
                        value: Binding(
                            get: { Double(band.q) },
                            set: { v in
                                draft.bands[index].q = Float(v)
                                engine.updateBand(index: index, band: draft.bands[index])
                            }
                        ),
                        in: 0.1...10
                    )
                    .disabled(editsLocked)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func row<Content: View>(label: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit().font(.callout)
            }
            content()
        }
    }

    // MARK: - Helpers

    private func logFreq(_ hz: Double) -> Double { log10(max(hz, 1)) }
    private func expFreq(_ log: Double) -> Double { pow(10, log) }
}

// MARK: - Window close interception

private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if window !== view.window { window = view.window }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== nsView.window { window = nsView.window }
        }
    }
}

final class EditorCloseCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published var pendingClose: Bool = false
    var isDirty: Bool = false
    var isBuiltIn: Bool = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !isDirty || isBuiltIn { return true }
        pendingClose = true
        return false
    }
}
