import AppKit
import SwiftUI

struct EQEditorView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var presetCatalog: PresetCatalog

    // Working copy, edited live and pushed to the engine on every change.
    @State private var draft: EQPreset = .flat
    @State private var newPresetName: String = ""
    @State private var showSaveSheet = false
    @State private var showDeleteConfirm = false
    @State private var showLibrary = false
    /// When the user picks a different preset in the dropdown but the current
    /// draft has unsaved edits, we stash the target here and present the
    /// Save/Revert/Cancel alert. Mirrors `closeCoordinator.pendingClose` but
    /// resolves to a preset switch instead of a window close.
    @State private var pendingSwitchTargetID: UUID? = nil
    @StateObject private var closeCoordinator = EditorCloseCoordinator()
    @State private var hostWindow: NSWindow?

    private var visiblePresets: [EQPreset] {
        Klang.visiblePresets(catalog: presetCatalog, store: presetStore)
    }

    /// Both bundled Flat and any catalog-sourced preset are read-only — users must
    /// "Save As New…" to keep edits.
    private var isBuiltIn: Bool {
        presetStore.isBundledFlat(draft) || presetCatalog.isBuiltIn(draft.id)
    }

    private var savedVersion: EQPreset? {
        presetStore.presets.first(where: { $0.id == draft.id })
    }

    private var isDirty: Bool {
        guard let saved = savedVersion else { return true }
        return !draft.sameContent(as: saved)
    }

    var body: some View {
        HSplitView {
            // Left: curve + header
            VStack(alignment: .leading, spacing: 12) {
                editorTopBar
                header
                EQCurveView(bands: draft.bands, preamp: draft.preamp)
                    .frame(minHeight: 220)
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
                Button("Save") { presetStore.update(draft) }
                    .disabled(isBuiltIn || !isDirty)
                    .help(isBuiltIn ? "Built-in preset — use Save As New… to keep changes" : "")
                Button("Save As New…") { showSaveSheet = true }
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
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
            "Save changes to \u{201C}\(draft.name)\u{201D}?",
            isPresented: $closeCoordinator.pendingClose
        ) {
            Button("Save") {
                presetStore.update(draft)
                let window = hostWindow
                DispatchQueue.main.async { window?.close() }
            }
            Button("Revert", role: .destructive) {
                if let saved = savedVersion {
                    engine.apply(preset: saved)
                    draft = saved
                }
                let window = hostWindow
                DispatchQueue.main.async { window?.close() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your edits haven't been saved. Save them, revert to the on-disk version, or cancel and keep editing.")
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
        }
        .onChange(of: engine.currentPreset) { _, new in
            // Engine changed preset externally (menu bar). Mirror into the editor.
            if let new, new.id != draft.id { draft = new }
        }
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
                items: visiblePresets.map { preset in
                    .init(id: preset.id.uuidString, title: preset.menuLabel)
                }
            )
            .disabled(visiblePresets.isEmpty)

            Spacer()

            Button {
                showLibrary = true
            } label: {
                Label("Preset Library…", systemImage: "books.vertical")
            }
            .help("Pick which AutoEq headphone presets to show")
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
        VStack(alignment: .leading, spacing: 2) {
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

    private func deleteCurrent() {
        let deletedID = draft.id
        let deletedIndex = presetStore.presets.firstIndex(where: { $0.id == deletedID })
        presetStore.delete(id: deletedID)

        // Pick a neighbor: same index after removal (was the one below), else
        // the previous one, else the first remaining preset.
        let neighbor: EQPreset? = {
            if let idx = deletedIndex {
                if idx < presetStore.presets.count { return presetStore.presets[idx] }
                if idx > 0 { return presetStore.presets[idx - 1] }
            }
            return presetStore.presets.first
        }()

        if let next = neighbor {
            draft = next
            engine.apply(preset: next)
        }

        let window = hostWindow
        DispatchQueue.main.async { window?.close() }
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
            .disabled(isBuiltIn)
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
                    .disabled(isBuiltIn)
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
                    .disabled(isBuiltIn)
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
                    .disabled(isBuiltIn)
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
                    .disabled(isBuiltIn)
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

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as new preset").font(.headline)
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { showSaveSheet = false }
                Button("Save") {
                    var copy = draft
                    copy.id = UUID()
                    copy.name = newPresetName.isEmpty ? draft.name + " (new)" : newPresetName
                    presetStore.add(copy)
                    draft = copy
                    engine.apply(preset: copy)
                    showSaveSheet = false
                    newPresetName = ""
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
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
