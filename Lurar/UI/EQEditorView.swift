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
    @State private var toast: ToastBanner.Content?
    @State private var toastDismissWorkItem: DispatchWorkItem?
    /// While a slider is being dragged, the curve view is fed these snapshots
    /// instead of the live `draft.bands` / `draft.preamp`. The audio engine
    /// still updates live on every slider tick (`updateBand` is cheap), but
    /// the curve — which has to re-evaluate ~128 biquad magnitude points per
    /// redraw — is held until the mouse comes back up. Cleared in
    /// `sliderEditingChanged(false)`.
    @State private var frozenBands: [EQBand]? = nil
    @State private var frozenPreamp: Float? = nil
    /// Tracks an in-flight curve-badge drag. `index` is the band's storage
    /// position; `dragStartOffset` is the px distance between the badge centre
    /// and the cursor at touch-down, preserved across the drag so the badge
    /// follows the cursor without snapping to it.
    @State private var draggingBand: (index: Int, dragStartOffset: CGFloat)? = nil
    /// Spectrum overlay is opt-in: the 30 Hz redraw is fine on modern Macs but can
    /// feel laggy on slower hardware or when many other apps are pulling on the
    /// main runloop. Persists across launches.
    @AppStorage("spectrum.enabled") private var spectrumEnabled: Bool = false
    /// Tracks whether the editor window is actually on-screen. Drives the
    /// spectrum/clip visualisers' redraw loops so they pause when the window is
    /// closed, minimised, or fully occluded. Starts true; the occlusion-state
    /// observer corrects it as soon as the window reports its state.
    @State private var isWindowVisible: Bool = true
    /// Drives the preset-name field's focus chrome — the border brightens to
    /// the accent colour while editing, and the trailing pencil hint hides so
    /// it doesn't crowd the cursor (#118).
    @FocusState private var nameFieldFocused: Bool
    /// Natural height of the editor content (the padded VStack), measured by
    /// the GeometryReader background in `body`. The sections all have fixed
    /// minimum heights, so when the window's content area is shorter than
    /// this the stack can't compress — it overflows and clips at the top and
    /// bottom edges. `enforceWindowFloor` watches for that and adopts the
    /// measurement as the window's real height floor.
    @State private var measuredContentHeight: CGFloat = 0
    /// Largest `measuredContentHeight` observed while the content was
    /// actually overflowing its window — i.e. the learned true minimum
    /// height. Sticky so the floor survives once the window has grown past
    /// it (at which point the content stretches and the measurement stops
    /// being a minimum).
    @State private var learnedMinContentHeight: CGFloat?

    /// Preamp slider/label bounds. The engine itself doesn't clamp preamp
    /// (`EQEngine.setPreamp` just converts dB→linear), so this range is purely
    /// the editor's floor. Extended below the old −12 dB so presets with large
    /// positive band gains — or users stacking loudness on top — have room to
    /// pull the master down further before the cascade clips. The 0 dB ceiling
    /// stays: preamp only ever attenuates.
    static let preampRange: ClosedRange<Float> = -24...0

    private var visiblePresets: [EQPreset] {
        Lurar.visiblePresets(catalog: presetCatalog, store: presetStore)
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

    /// Band/preamp sliders are disabled when comparison or bypass mode is
    /// active — the engine is playing a pre-loaded slot, not the editor
    /// draft, so live edits would silently desync from what's audible.
    private var editsLocked: Bool {
        isBuiltIn || engine.isInComparisonMode || engine.isBypassed
    }

    private var savedVersion: EQPreset? {
        presetStore.presets.first(where: { $0.id == draft.id })
    }

    /// Map slot index (0..9) → band storage index, or nil for empty slots.
    ///
    /// Bands are placed left-to-right in ascending-frequency order; each
    /// prefers its `SlotMath.zoneIndex` slot but is bumped right if a
    /// lower-frequency band already claimed that slot. If the rightmost
    /// band would overflow past slot 9 the whole row shifts left by the
    /// overflow amount, which guarantees frequency ordering is preserved
    /// even when many bands cluster in the same zone (the old greedy
    /// algorithm wrapped overflow back to slot 0, putting the highest band
    /// at the far left).
    private var slotAssignment: [Int?] {
        let sortedIndices = draft.bands.indices.sorted {
            draft.bands[$0].frequency < draft.bands[$1].frequency
        }
        guard !sortedIndices.isEmpty else {
            return Array(repeating: nil, count: SlotMath.count)
        }

        // Pass 1: each band wants its preferred zone, but slots must strictly
        // increase to keep frequency ordering left-to-right.
        var placements: [Int] = []
        placements.reserveCapacity(sortedIndices.count)
        for bandIdx in sortedIndices {
            let preferred = SlotMath.zoneIndex(for: draft.bands[bandIdx].frequency)
            let minSlot = (placements.last ?? -1) + 1
            placements.append(max(preferred, minSlot))
        }

        // Pass 2: if the rightmost placement overshot the last slot, shift
        // everything left by that overflow. Re-enforce strict increase in
        // case the shift collapses earlier placements onto each other.
        if let last = placements.last, last >= SlotMath.count {
            let overflow = last - (SlotMath.count - 1)
            for i in placements.indices {
                placements[i] = max(0, placements[i] - overflow)
            }
            for i in 1..<placements.count where placements[i] <= placements[i - 1] {
                placements[i] = placements[i - 1] + 1
            }
        }

        var slots: [Int?] = Array(repeating: nil, count: SlotMath.count)
        for (rank, slot) in placements.enumerated() where slot < SlotMath.count {
            slots[slot] = sortedIndices[rank]
        }
        return slots
    }

    /// `bandLabels[storageIdx]` is the 1-based position of that band in
    /// frequency-sorted order — the number drawn on the curve badge and on
    /// the strip's number chip so the two stay in sync.
    private var bandLabels: [Int] {
        var labels = Array(repeating: 0, count: draft.bands.count)
        let sorted = draft.bands.indices.sorted {
            draft.bands[$0].frequency < draft.bands[$1].frequency
        }
        for (pos, bandIdx) in sorted.enumerated() where labels.indices.contains(bandIdx) {
            labels[bandIdx] = pos + 1
        }
        return labels
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
        VStack(alignment: .leading, spacing: 12) {
            editorTopBar
            header
            if engine.isInComparisonMode {
                comparisonBanner
            }
            curvePane
            stripRail
            preampRow
        }
        .padding(16)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { measuredContentHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, newHeight in
                        measuredContentHeight = newHeight
                    }
            }
        )
        .frame(minWidth: 980)
        .background(hiddenEditorShortcuts)
        .toolbar {
            ToolbarItemGroup(placement: .destructiveAction) {
                if !isBuiltIn && savedVersion != nil {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .lurarShortcut(LurarShortcuts.deletePreset)
                }
            }
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button("Export Current Preset…") {
                        PresetImportExport.exportSingle(draft)
                    }
                    .disabled(presetStore.isBundledFlat(draft))
                    .lurarShortcut(LurarShortcuts.exportPreset)
                    Button("Export Whole Library…") {
                        PresetImportExport.exportLibrary(presetStore.presets)
                    }
                    .lurarShortcut(LurarShortcuts.exportLibrary)
                    Divider()
                    Button("Import…") { runImport() }
                        .lurarShortcut(LurarShortcuts.importPresets)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Export or import .lurarpreset / .lurarpresets files")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if isBuiltIn {
                    Button {
                        tweakCurrent()
                    } label: {
                        Label("Tweak\u{2026}", systemImage: "slider.horizontal.3")
                    }
                    .labelStyle(.titleAndIcon)
                    .lurarShortcutHelp(LurarShortcuts.tweak,
                                       label: "Make an editable copy of this built-in in your library. The original stays available as a dashed reference curve, and you can reset back to it any time.")
                    .keyboardShortcut(LurarShortcuts.tweak.key, modifiers: LurarShortcuts.tweak.modifiers)
                } else {
                    Button("Discard Changes") { discardChanges() }
                        .disabled(!isDirty)
                        .lurarShortcutHelp(LurarShortcuts.discard,
                                           label: "Throw away unsaved edits and return to the last saved version")
                        .keyboardShortcut(LurarShortcuts.discard.key, modifiers: LurarShortcuts.discard.modifiers)
                    Button("Save") { presetStore.update(draft) }
                        .disabled(!isDirty)
                        .lurarShortcut(LurarShortcuts.save)
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                ToastBanner(content: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast?.id)
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
            guard let win else { return }
            win.delegate = closeCoordinator
            enforceWindowFloor(win)
        }
        .onChange(of: measuredContentHeight) { _, _ in
            if let win = hostWindow { enforceWindowFloor(win) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { notification in
            // A live resize can shrink the window below the content floor
            // before the floor has been learned — re-check once the drag ends.
            guard let win = notification.object as? NSWindow, win == hostWindow else { return }
            enforceWindowFloor(win)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            // Only react to our own editor window — the notification fires for
            // every window in the app.
            guard let win = notification.object as? NSWindow, win == hostWindow else { return }
            isWindowVisible = win.occlusionState.contains(.visible)
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
        // Editor is the window users keep open while flipping to a browser
        // or measurement app — bring Lurar into the dock + Cmd+Tab so they
        // can get back without having to click the menu-bar icon again.
        .showsInDockWhileVisible()
    }

    // MARK: - Window sizing

    /// Editor needs room for 10 strip columns (≈88 px each) under the curve,
    /// plus the full column of sections above the preamp/output meters.
    /// `.frame(minWidth:)` on the SwiftUI content isn't always honoured at
    /// first open if the window restored a smaller frame from a previous
    /// session — set the floor on the NSWindow directly and grow if we're
    /// below it.
    ///
    /// The height floor is partly learned at runtime: the static constant
    /// below is a safe lower bound, and whenever the measured content height
    /// exceeds the area the window actually gives the content (i.e. the
    /// layout is clipping the top dropdown / bottom output meters), the
    /// measurement becomes the new floor. That keeps the floor correct
    /// across font-metric differences and future layout changes without
    /// hand-tuning a constant that silently goes stale.
    private func enforceWindowFloor(_ win: NSWindow) {
        var minContent = NSSize(width: 1000, height: 760)
        if measuredContentHeight > win.contentLayoutRect.height + 0.5 {
            learnedMinContentHeight = max(learnedMinContentHeight ?? 0, measuredContentHeight)
        }
        if let learned = learnedMinContentHeight {
            minContent.height = max(minContent.height, learned)
        }

        // `contentMinSize` is in content-rect coordinates (frame minus title
        // bar), but the SwiftUI content is laid out in `contentLayoutRect`,
        // which also excludes the toolbar — add the toolbar band so AppKit's
        // own resize clamping protects the actual layout area.
        let toolbarHeight = win.contentRect(forFrameRect: win.frame).height - win.contentLayoutRect.height
        win.contentMinSize = NSSize(width: minContent.width, height: minContent.height + toolbarHeight)

        // Don't fight the user's drag mid-gesture; the contentMinSize set
        // above clamps further shrinking, and the didEndLiveResize hook
        // re-runs this to snap back if they got below the floor first.
        guard !win.inLiveResize else { return }
        var frame = win.frame
        let chrome = frame.height - win.contentLayoutRect.height
        let neededHeight = minContent.height + chrome
        var changed = false
        if frame.width < minContent.width {
            frame.size.width = minContent.width
            changed = true
        }
        if frame.height < neededHeight {
            frame.size.height = neededHeight
            changed = true
        }
        if changed {
            win.setFrame(frame, display: true, animate: false)
        }
    }

    // MARK: - Shortcuts

    /// Hotkeys for the preset-picker menu actions (New preset, Add more presets)
    /// that live inside a custom `NSPopUpButton` bridge whose menu items can't
    /// accept SwiftUI `.keyboardShortcut(...)`. Same pattern as `MenuBarView`'s
    /// `hiddenShortcuts`.
    private var hiddenEditorShortcuts: some View {
        VStack(spacing: 0) {
            Button { createNewPreset() } label: { EmptyView() }
                .lurarShortcut(LurarShortcuts.editorNewPreset)

            Button { showLibrary = true } label: { EmptyView() }
                .lurarShortcut(LurarShortcuts.editorLibrary)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
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
                items: Lurar.sortedPresetItems(
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
        VStack(alignment: .leading, spacing: 8) {
            detailsCard
            // Lineage + Reset describe the *curve's* provenance, not the
            // editable text metadata, so they sit below the field group now
            // instead of wedging between the name and the headphone/source
            // fields the way they used to (#118).
            if !isBuiltIn, let ref = draft.parentRef {
                HStack(spacing: 8) {
                    parentChip(ref: ref)
                    if parentPreset != nil {
                        resetToOriginalButton(snapshotName: ref.snapshotName)
                    }
                    Spacer()
                }
            }
        }
    }

    /// The three editable metadata fields — name, headphone, source — grouped
    /// into one bordered card so they read as a related set of inputs rather
    /// than three loose elements, and so the heading-styled name clearly sits
    /// inside an editable container (#118).
    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            nameField
            HStack(alignment: .top, spacing: 12) {
                labeledTextField(
                    caption: "Headphone",
                    placeholder: "e.g. Sennheiser HD 600",
                    text: $draft.headphone
                )
                labeledTextField(
                    caption: "Source",
                    placeholder: "e.g. oratory1990",
                    text: $draft.source
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    /// Preset-name input. Keeps the large title type for prominence, but for
    /// editable presets wraps it in a focusable, bordered field so it no
    /// longer reads as a static heading: the caption above, the border, and
    /// the trailing pencil all signal it's editable, and the border lights up
    /// in the accent colour while focused. Built-in presets, whose name is
    /// read-only, drop the input chrome and show the "Built-in" pill (#118).
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 3) {
            fieldCaption("Preset name")
            HStack(spacing: 8) {
                TextField("Untitled preset", text: $draft.name)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($nameFieldFocused)
                    .disabled(isBuiltIn)
                if isBuiltIn {
                    builtInBadge
                } else {
                    if isDirty { unsavedBadge }
                    if !nameFieldFocused {
                        Image(systemName: "pencil")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .help("Click to rename this preset")
                    }
                }
            }
            .padding(.horizontal, isBuiltIn ? 0 : 8)
            .padding(.vertical, isBuiltIn ? 0 : 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isBuiltIn ? Color.clear : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(nameFieldBorder, lineWidth: nameFieldFocused ? 1.5 : 1)
            )
            .animation(.easeInOut(duration: 0.12), value: nameFieldFocused)
        }
    }

    /// Accent border while the name field is focused, a faint resting border
    /// otherwise, and no border at all for read-only built-ins.
    private var nameFieldBorder: Color {
        if isBuiltIn { return .clear }
        return nameFieldFocused ? .accentColor : .secondary.opacity(0.25)
    }

    private var builtInBadge: some View {
        Text("Built-in")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private var unsavedBadge: some View {
        Text("Unsaved")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
    }

    /// Small gray caption that labels a header field. Clarifies what each of
    /// the three editable fields is for — and, above the title, signals that
    /// the heading-styled name is itself editable (#118).
    private func fieldCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    /// Captioned, bordered text field used for the Headphone/Source metadata.
    /// The caption stays visible after the field is filled, where the
    /// placeholder would have disappeared.
    private func labeledTextField(
        caption: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            fieldCaption(caption)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .disabled(isBuiltIn)
        }
    }

    @ViewBuilder
    private func parentChip(ref: PresetParentRef) -> some View {
        // Prefer the snapshot taken at fork time; fall back to the live parent
        // when older presets (forked before snapshotSource existed) are still
        // around and the catalog has hydrated them.
        let source = ref.snapshotSource ?? parentPreset?.source
        let label = source.map { "Derived from \(ref.snapshotName) · \($0)" }
                       ?? "Derived from \(ref.snapshotName)"
        HStack(spacing: 6) {
            Image(systemName: "link")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(label)
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
        .lurarShortcutHelp(LurarShortcuts.resetParent,
                           label: canResetToOriginal
                              ? "Overwrite this preset's bands and preamp with the original \u{201C}\(snapshotName)\u{201D} curve. Replaces your saved version — your name, headphone, and source are kept"
                              : "Bands and preamp already match the original")
        .keyboardShortcut(LurarShortcuts.resetParent.key, modifiers: LurarShortcuts.resetParent.modifiers)
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
        .lurarShortcutHelp(LurarShortcuts.toggleSpectrum,
                           label: spectrumEnabled
                              ? "Hide the live FFT overlay"
                              : "Show a live FFT of the post-EQ signal")
        .keyboardShortcut(LurarShortcuts.toggleSpectrum.key, modifiers: LurarShortcuts.toggleSpectrum.modifiers)
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
            snapshotName: draft.name,
            snapshotSource: draft.source
        )
        var copy = draft
        copy.id = UUID()
        copy.name = presetStore.uniqueName(based: draft.name + " (custom)")
        // Reset source so the menu label doesn't claim oratory1990 authorship of
        // the user's tweaked copy — lineage is preserved via parentRef.
        copy.source = "Lurar"
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

    /// Wired into every band/preamp `Slider` via `onEditingChanged:` and into
    /// the curve-badge drag. Snapshots the current bands at drag start and
    /// releases on drag end so the curve re-renders exactly twice per
    /// interaction (once frozen at drag-start state, once when the freeze
    /// lifts) instead of once per drag tick.
    ///
    /// Also brackets the engine's live-edit mode for the same window: while
    /// the drag is in flight, `updateBand`/`setPreamp` update the DSP but
    /// defer the `@Published currentPreset` mirror, so this view (which
    /// observes the engine) isn't invalidated a second time per drag tick.
    private func sliderEditingChanged(_ editing: Bool) {
        if editing {
            frozenBands = draft.bands
            frozenPreamp = draft.preamp
            engine.beginLiveEdit()
        } else {
            engine.endLiveEdit()
            frozenBands = nil
            frozenPreamp = nil
        }
    }

    // MARK: - Band add / remove

    /// Append a band seeded with sensible defaults for the slot the user
    /// clicked. Shelves at the spectrum edges, peak elsewhere. Engine has to
    /// rebuild the cascade since the band count changed — `apply(preset:)`
    /// does that atomically.
    private func addBand(at frequency: Float) {
        guard !editsLocked, draft.bands.count < SlotMath.count else { return }
        let type: EQBand.FilterType
        if frequency <= 60 {
            type = .lowShelf
        } else if frequency >= 8_000 {
            type = .highShelf
        } else {
            type = .peak
        }
        let q: Float = type == .peak ? 1.0 : 0.71
        draft.bands.append(EQBand(type: type, frequency: frequency, gain: 0, q: q))
        engine.apply(preset: draft)
    }

    /// Remove the band at the given storage index. Slot indices in the
    /// engine's cascade shift, so we have to rebuild via `apply(preset:)`.
    private func removeBand(at storageIndex: Int) {
        guard !editsLocked, draft.bands.indices.contains(storageIndex) else { return }
        draft.bands.remove(at: storageIndex)
        engine.apply(preset: draft)
    }

    // MARK: - Curve + badge drag

    /// Curve plot stacked over a dedicated badge track. Each badge represents
    /// one active band and tracks the band's frequency along the same log-x
    /// axis as the curve above. The curve view is frozen during drags so we
    /// don't redraw 128 biquad samples per gesture tick — the badge moves
    /// via SwiftUI `.position`, which is cheap. Kept as a separate track
    /// (not painted on the curve) so badges and the curve's own frequency
    /// labels don't fight for the same pixels at the bottom edge.
    private var curvePane: some View {
        VStack(spacing: 2) {
            EQCurveView(
                bands: frozenBands ?? draft.bands,
                preamp: frozenPreamp ?? draft.preamp,
                referenceBands: parentPreset?.bands,
                referencePreamp: parentPreset?.preamp
            )
            .equatable()
            .frame(minHeight: 220)
            .overlay {
                if spectrumEnabled {
                    SpectrumOverlayView(analyzer: engine.spectrumAnalyzer, isVisible: isWindowVisible)
                }
            }
            .overlay(alignment: .topTrailing) {
                spectrumToggleButton.padding(8)
            }

            badgeTrack
        }
    }

    /// 28 pt rail under the curve where draggable band-number capsules live.
    /// Shares the curve's width via VStack stretching, so the badges' log-x
    /// positions line up with the curve plot above them.
    private var badgeTrack: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.3))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)

                ForEach(Array(draft.bands.enumerated()), id: \.element.id) { (bandIdx, band) in
                    let bandID = band.id
                    BandBadge(label: bandLabels.indices.contains(bandIdx) ? bandLabels[bandIdx] : bandIdx + 1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .position(
                            x: EQCurveGeometry.xPos(forFreq: Double(band.frequency), in: geo.size),
                            y: geo.size.height / 2
                        )
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("badgeTrack"))
                                .onChanged { value in
                                    // Look up by UUID at drag time so a remove
                                    // elsewhere in the rail can't shift our
                                    // target band out from under us.
                                    if let i = draft.bands.firstIndex(where: { $0.id == bandID }) {
                                        handleBadgeDragChanged(bandIndex: i, value: value, curveSize: geo.size)
                                    }
                                }
                                .onEnded { _ in handleBadgeDragEnded() }
                        )
                        .allowsHitTesting(!editsLocked)
                }
            }
            .coordinateSpace(name: "badgeTrack")
        }
        .frame(height: 28)
    }

    private func handleBadgeDragChanged(bandIndex: Int, value: DragGesture.Value, curveSize: CGSize) {
        guard draft.bands.indices.contains(bandIndex), !editsLocked else { return }
        if draggingBand?.index != bandIndex {
            // First event of this drag — remember the click offset so the
            // badge tracks the cursor instead of snapping to it, and freeze
            // the curve until the drag ends.
            let badgeX = EQCurveGeometry.xPos(
                forFreq: Double(draft.bands[bandIndex].frequency),
                in: curveSize
            )
            draggingBand = (bandIndex, value.startLocation.x - badgeX)
            sliderEditingChanged(true)
        }
        let offset = draggingBand?.dragStartOffset ?? 0
        let targetX = max(0, min(curveSize.width, value.location.x - offset))
        let t = curveSize.width > 0 ? Double(targetX / curveSize.width) : 0
        let logMin = log10(EQCurveGeometry.minFreq)
        let logMax = log10(EQCurveGeometry.maxFreq)
        let newFreq = Float(pow(10, logMin + t * (logMax - logMin)))
        draft.bands[bandIndex].frequency = newFreq
        engine.updateBand(index: bandIndex, band: draft.bands[bandIndex])
    }

    private func handleBadgeDragEnded() {
        draggingBand = nil
        sliderEditingChanged(false)
    }

    // MARK: - Strip rail

    /// Horizontal row of 10 strip columns under the curve. Slots are bound
    /// to log-frequency zones (see `SlotMath`), so a strip's x-position
    /// roughly matches the position of its band on the curve above. Empty
    /// slots show a dashed "+" with the zone's default frequency.
    private var stripRail: some View {
        HStack(spacing: 4) {
            let slots = slotAssignment
            ForEach(0..<SlotMath.count, id: \.self) { slotIdx in
                if let bandIdx = slots[slotIdx], draft.bands.indices.contains(bandIdx) {
                    bandStrip(
                        bandIndex: bandIdx,
                        displayPosition: bandLabels.indices.contains(bandIdx) ? bandLabels[bandIdx] : bandIdx + 1
                    )
                } else {
                    emptySlotStrip(slotIndex: slotIdx)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var preampRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Preamp").bold()
                Spacer()
                EditableValueLabel(
                    value: $draft.preamp,
                    range: Self.preampRange,
                    format: { String(format: "%+.1f dB", $0) },
                    parse: Self.parseDecibels,
                    step: { _ in 0.1 },
                    disabled: editsLocked,
                    onCommit: { engine.setPreamp($0) }
                )
            }
            Slider(
                value: Binding(
                    get: { Double(draft.preamp) },
                    set: { newValue in
                        draft.preamp = Float(newValue)
                        engine.setPreamp(Float(newValue))
                    }
                ),
                in: Double(Self.preampRange.lowerBound)...Double(Self.preampRange.upperBound),
                onEditingChanged: sliderEditingChanged
            )
            .disabled(editsLocked)
            .help("Preamp \u{2014} master attenuation in dB (\u{2212}\(Int(-Self.preampRange.lowerBound)) to 0). Click the value to type it.")
            ClipMeterView(clipMeter: engine.clipMeter, isVisible: isWindowVisible)
                .padding(.top, 2)
        }
    }

    /// Bridge `slotAssignment` + the supporting callbacks into a `BandStrip`
    /// instance. The struct is `Equatable` so SwiftUI can skip re-rendering
    /// the 9 non-dragged strips on every slider tick (the difference between
    /// a smooth and a laggy drag).
    ///
    /// Closures look up the band by its UUID at execution time instead of
    /// closing over the storage index — when `BandStrip`'s Equatable says
    /// "no change", SwiftUI keeps the previous closures, which would mutate
    /// the wrong band after a remove had shifted indices underneath us.
    @ViewBuilder
    private func bandStrip(bandIndex index: Int, displayPosition: Int) -> some View {
        let band = draft.bands[index]
        let bandID = band.id
        BandStrip(
            band: band,
            displayPosition: displayPosition,
            editsLocked: editsLocked,
            onBandChange: { updated in
                if let i = draft.bands.firstIndex(where: { $0.id == bandID }) {
                    draft.bands[i] = updated
                    engine.updateBand(index: i, band: updated)
                }
            },
            onRemove: {
                if let i = draft.bands.firstIndex(where: { $0.id == bandID }) {
                    removeBand(at: i)
                }
            },
            onSliderEditingChanged: sliderEditingChanged
        )
        .equatable()
    }

    /// Dashed-outline slot showing only a "+" and the default frequency we'd
    /// seed if the user clicks. The whole strip is the button.
    @ViewBuilder
    private func emptySlotStrip(slotIndex: Int) -> some View {
        let defaultFreq = SlotMath.zoneCenter(slotIndex)
        Button {
            addBand(at: defaultFreq)
        } label: {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Add band")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Self.formatFrequency(defaultFreq))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        .separator,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(editsLocked || draft.bands.count >= SlotMath.count)
        .help("Add a band centered near \(Self.formatFrequency(defaultFreq))")
    }

    // MARK: - Numeric field parsing

    /// Pretty-print a frequency in Hz, switching to "kHz" with one decimal at
    /// 1 kHz and above so band labels stay short. The accompanying parser
    /// accepts either form on input so the round-trip is lossless for users.
    static func formatFrequency(_ hz: Float) -> String {
        hz >= 1000
            ? String(format: "%.1f kHz", hz / 1000)
            : String(format: "%.0f Hz", hz)
    }

    /// Arrow-key step size matched to `formatFrequency`'s least significant
    /// visible digit: 1 Hz under 1 kHz (display reads in Hz), 100 Hz at and
    /// above 1 kHz (display reads in kHz with one decimal = 0.1 kHz = 100 Hz).
    static func frequencyStep(_ hz: Float) -> Float {
        hz >= 1000 ? 100 : 1
    }

    /// Permissive frequency parser: accepts "8900", "8900 Hz", "8.9k",
    /// "8.9 kHz", with any casing and trimmed whitespace. Returns nil only
    /// when the numeric portion can't be parsed at all.
    static func parseFrequency(_ raw: String) -> Float? {
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: "hz", with: "")
        s = s.replacingOccurrences(of: ",", with: ".")
        s = s.replacingOccurrences(of: " ", with: "")
        let isKHz = s.hasSuffix("k")
        if isKHz { s.removeLast() }
        guard let value = Float(s) else { return nil }
        return isKHz ? value * 1000 : value
    }

    /// Accepts signed decibels with or without the unit and either sign
    /// character: "+2.6", "+2.6 dB", "-4", "2".
    static func parseDecibels(_ raw: String) -> Float? {
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: "db", with: "")
        s = s.replacingOccurrences(of: ",", with: ".")
        s = s.trimmingCharacters(in: .whitespaces)
        // Strip a leading "+" — Float can't parse it.
        if s.hasPrefix("+") { s.removeFirst() }
        return Float(s)
    }

    /// Plain (unitless) number with comma/period tolerance — used for Q.
    static func parsePlainNumber(_ raw: String) -> Float? {
        let s = raw.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Float(s)
    }

    // MARK: - Helpers

    private func runImport() {
        guard let summary = PresetImportExport.importIntoStore(presetStore) else { return }
        presentToast(.init(message: summary.message, kind: summary.imported > 0 ? .info : .warning))
    }

    private func presentToast(_ content: ToastBanner.Content) {
        toast = content
        toastDismissWorkItem?.cancel()
        let item = DispatchWorkItem { toast = nil }
        toastDismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: item)
    }
}

// MARK: - Toast

struct ToastBanner: View {
    struct Content: Equatable {
        let id = UUID()
        let message: String
        let kind: Kind
        enum Kind { case info, warning }
    }

    let content: Content

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: content.kind == .info ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(content.kind == .info ? Color.accentColor : .orange)
            Text(content.message)
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.secondary.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
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

// MARK: - Editable numeric label

/// Click-to-edit numeric value displayed in band rows and the preamp header.
/// Behaves like a label until focused, then accepts free-form text and commits
/// on Enter or blur. Up/Down arrows step the value by one unit of the least
/// significant displayed digit; Escape discards the in-progress edit. An
/// internal text buffer keeps live slider updates from clobbering in-progress
/// typing — the displayed text only refreshes from the bound value while the
/// field is unfocused.
///
/// Backed by an `NSTextField` wrapper (`NumericTextField`) rather than
/// SwiftUI's own `TextField` so we can catch Up/Down/Enter/Escape in the
/// `doCommandBy:` delegate hook — that fires *before* the field editor moves
/// the cursor, which is the only way to keep the first arrow press from being
/// eaten by NSTextField's "move cursor to edge of single line" behavior.
private struct EditableValueLabel: View {
    @Binding var value: Float
    var range: ClosedRange<Float>
    var width: CGFloat = 80
    var format: (Float) -> String
    var parse: (String) -> Float?
    /// Step delta for arrow-key nudges, sized to the value's current decade
    /// (e.g. 1 Hz under 1 kHz, 100 Hz above; 0.1 dB; 0.01 Q). The closure is
    /// passed the latest value so frequency stepping can scale with magnitude.
    var step: (Float) -> Float = { _ in 1 }
    var disabled: Bool = false
    var onCommit: (Float) -> Void = { _ in }

    @State private var text: String = ""
    @State private var focused: Bool = false

    var body: some View {
        NumericTextField(
            text: $text,
            isEnabled: !disabled,
            onCommit: commit,
            onCancel: { syncFromValue() },
            onStep: { direction in stepBy(Float(direction)) },
            onFocusChange: { focused = $0 }
        )
        .frame(width: width, height: 18)
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(focused ? Color.secondary.opacity(0.18) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.secondary.opacity(focused ? 0.35 : 0), lineWidth: 1)
        )
        .help("Click to type a value. \u{2191}/\u{2193} nudge \u{2022} \u{21A9} commit \u{2022} esc cancel.")
        .onAppear { syncFromValue() }
        .onChange(of: value) { _, _ in
            // Live updates from sliders should refresh the displayed text
            // — but only when the user isn't mid-edit, otherwise their
            // in-progress digits would get overwritten.
            if !focused { syncFromValue() }
        }
    }

    private func syncFromValue() {
        text = format(value)
    }

    private func commit() {
        if let parsed = parse(text) {
            let clamped = clamp(parsed)
            if clamped != value {
                value = clamped
                onCommit(clamped)
            }
        }
        syncFromValue()
    }

    /// Step the value by `direction × step(currentBase)`. If the user has
    /// typed unsaved digits, parse and use those as the base so stepping
    /// continues from what's visible rather than the last committed value.
    private func stepBy(_ direction: Float) {
        let base = parse(text).map(clamp) ?? value
        let delta = step(base) * direction
        let next = clamp(base + delta)
        if next != value {
            value = next
            onCommit(next)
        }
        syncFromValue()
    }

    private func clamp(_ x: Float) -> Float {
        max(range.lowerBound, min(range.upperBound, x))
    }
}

// MARK: - Arrow-key-aware numeric field

/// `NSTextField` wrapper that exposes Up/Down/Enter/Escape as callbacks via
/// the `doCommandBy:` delegate hook. SwiftUI's `TextField` + `onKeyPress`
/// can't do this — by the time `onKeyPress` runs, the underlying field
/// editor has already swallowed the arrow keys to move the insertion point
/// to the edge of the line, which means the first press of a stepper-style
/// shortcut never reaches the handler.
private struct NumericTextField: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only push text back into the NSTextField when it's actually out of
        // sync. Skipping no-op writes keeps the insertion point stable while
        // the user is typing.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumericTextField

        init(parent: NumericTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocusChange(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange(false)
            // Treat any normal focus loss (Tab, click elsewhere) as a
            // commit. The Enter/Escape command handlers run *before* this
            // and resign first responder themselves, so they'll trigger
            // an additional onCommit here — which is harmless because
            // commit is idempotent once the text matches the value.
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.onStep(+1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onStep(-1)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Band strip

/// One column in the editor's strip rail: number chip + type picker, gain
/// row (value + center-zero slider), Q row, then an editable frequency
/// value at the bottom (no slider — drag the curve badge to retune).
///
/// `Equatable` so SwiftUI can skip re-rendering the 9 non-dragged strips on
/// every slider tick. Closures are intentionally excluded from `==` — they
/// change identity on every parent re-render but their effects don't matter
/// for the visible state, so treating them as equal is the right choice.
private struct BandStrip: View, Equatable {
    let band: EQBand
    let displayPosition: Int
    let editsLocked: Bool
    let onBandChange: (EQBand) -> Void
    let onRemove: () -> Void
    let onSliderEditingChanged: (Bool) -> Void

    static func == (lhs: BandStrip, rhs: BandStrip) -> Bool {
        lhs.band == rhs.band
            && lhs.displayPosition == rhs.displayPosition
            && lhs.editsLocked == rhs.editsLocked
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                BandNumberChip(number: displayPosition)
                Spacer(minLength: 0)
                typeMenu
            }

            VStack(spacing: 2) {
                EditableValueLabel(
                    value: gainBinding,
                    range: -12...12,
                    width: 60,
                    format: { String(format: "%+.1f dB", $0) },
                    parse: EQEditorView.parseDecibels,
                    step: { _ in 0.1 },
                    disabled: editsLocked
                )
                Slider(
                    value: doubleBinding(\.gain),
                    in: -12...12,
                    onEditingChanged: onSliderEditingChanged
                )
                .controlSize(.mini)
                .disabled(editsLocked)
                .help("Gain in dB. Click the value above to type it; \u{2191}/\u{2193} nudge by 0.1.")
            }

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Text("Q")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    EditableValueLabel(
                        value: qBinding,
                        range: 0.1...10,
                        width: 44,
                        format: { String(format: "%.2f", $0) },
                        parse: EQEditorView.parsePlainNumber,
                        step: { _ in 0.01 },
                        disabled: editsLocked
                    )
                }
                Slider(
                    value: doubleBinding(\.q),
                    in: 0.1...10,
                    onEditingChanged: onSliderEditingChanged
                )
                .controlSize(.mini)
                .disabled(editsLocked)
                .help("Bandwidth / resonance. Higher Q = narrower band.")
            }

            Divider()

            EditableValueLabel(
                value: frequencyBinding,
                range: 20...20_000,
                width: 64,
                format: EQEditorView.formatFrequency,
                parse: EQEditorView.parseFrequency,
                step: EQEditorView.frequencyStep,
                disabled: editsLocked
            )
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    /// `Low shelf` / `Peak` / `High shelf` with a checkmark on the current
    /// selection plus a destructive `Remove band` after a separator.
    private var typeMenu: some View {
        Menu {
            ForEach(EQBand.FilterType.allCases) { t in
                Button {
                    var updated = band
                    updated.type = t
                    onBandChange(updated)
                } label: {
                    if t == band.type {
                        Label(t.displayName, systemImage: "checkmark")
                    } else {
                        Text(t.displayName)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove band", systemImage: "trash")
            }
        } label: {
            HStack(spacing: 3) {
                FilterTypeIcon(type: band.type)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.18))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(editsLocked)
        .help(band.type.displayName)
    }

    // MARK: - Bindings

    /// Build an ad-hoc `Binding<Float>` that mutates the band field and
    /// fires `onBandChange` so the parent persists + pushes to the engine.
    private func floatBinding(_ keyPath: WritableKeyPath<EQBand, Float>) -> Binding<Float> {
        Binding(
            get: { band[keyPath: keyPath] },
            set: { newValue in
                var updated = band
                updated[keyPath: keyPath] = newValue
                onBandChange(updated)
            }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<EQBand, Float>) -> Binding<Double> {
        Binding(
            get: { Double(band[keyPath: keyPath]) },
            set: { newValue in
                var updated = band
                updated[keyPath: keyPath] = Float(newValue)
                onBandChange(updated)
            }
        )
    }

    private var gainBinding: Binding<Float> { floatBinding(\.gain) }
    private var qBinding: Binding<Float> { floatBinding(\.q) }
    private var frequencyBinding: Binding<Float> { floatBinding(\.frequency) }
}

// MARK: - Filter type icon

/// Tiny glyph for each `EQBand.FilterType`, drawn as a stroked path inside a
/// 14×10 box: a step that's high on the left for low shelf, a quadratic
/// hump for peak, the mirror for high shelf. Reused on the strip's type
/// pill and inside the menu items so the collapsed control and the open
/// menu look the same.
private struct FilterTypeIcon: View {
    let type: EQBand.FilterType

    var body: some View {
        FilterTypeShape(type: type)
            .stroke(
                Color.primary,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            .frame(width: 14, height: 10)
    }
}

private struct FilterTypeShape: Shape {
    let type: EQBand.FilterType

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        let x0 = rect.minX
        let y0 = rect.minY
        switch type {
        case .lowShelf:
            // Step that's high on the left (boosts lows), flat on the right.
            p.move(to: CGPoint(x: x0 + 0.07 * w, y: y0 + 0.20 * h))
            p.addLine(to: CGPoint(x: x0 + 0.36 * w, y: y0 + 0.20 * h))
            p.addLine(to: CGPoint(x: x0 + 0.64 * w, y: y0 + 0.80 * h))
            p.addLine(to: CGPoint(x: x0 + 0.93 * w, y: y0 + 0.80 * h))
        case .peak:
            p.move(to: CGPoint(x: x0 + 0.07 * w, y: y0 + 0.80 * h))
            p.addQuadCurve(
                to: CGPoint(x: x0 + 0.93 * w, y: y0 + 0.80 * h),
                control: CGPoint(x: x0 + 0.50 * w, y: y0 - 0.10 * h)
            )
        case .highShelf:
            // Mirror of low shelf: flat on the left, high on the right.
            p.move(to: CGPoint(x: x0 + 0.07 * w, y: y0 + 0.80 * h))
            p.addLine(to: CGPoint(x: x0 + 0.36 * w, y: y0 + 0.80 * h))
            p.addLine(to: CGPoint(x: x0 + 0.64 * w, y: y0 + 0.20 * h))
            p.addLine(to: CGPoint(x: x0 + 0.93 * w, y: y0 + 0.20 * h))
        }
        return p
    }
}

// MARK: - Band number chips

/// Pill-shaped 1-based number badge shown in the strip header. Mirrors the
/// `BandBadge` used on the curve so the two stay visually linked.
private struct BandNumberChip: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
    }
}

/// Draggable badge that sits on the curve at its band's frequency. Capsule
/// shape + faint track underneath read as "slides along this axis"; the
/// actual drag handling lives in the editor's `handleBadgeDragChanged`.
private struct BandBadge: View {
    let label: Int

    var body: some View {
        Text("\(label)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
    }
}

// MARK: - Slot math

/// Log-spaced zones that map a band's frequency to one of 10 strip columns.
/// Each zone spans the same multiplicative range (20 Hz × 10^(i/10)), so the
/// strip layout below the curve roughly tracks the curve's log-x axis.
enum SlotMath {
    static let count = 10
    static let minFreq: Double = 20
    static let maxFreq: Double = 20_000

    /// Slot index (0..count−1) for a given frequency.
    static func zoneIndex(for hz: Float) -> Int {
        let clamped = max(Double(hz), minFreq)
        let span = log10(maxFreq) - log10(minFreq)
        let t = (log10(clamped) - log10(minFreq)) / span
        let i = Int(t * Double(count))
        return max(0, min(count - 1, i))
    }

    /// Geometric centre of a zone — the default frequency we seed when the
    /// user clicks the "+" on an empty slot.
    static func zoneCenter(_ index: Int) -> Float {
        let lo = minFreq * pow(maxFreq / minFreq, Double(index) / Double(count))
        let hi = minFreq * pow(maxFreq / minFreq, Double(index + 1) / Double(count))
        return Float(sqrt(lo * hi))
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
