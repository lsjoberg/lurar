import SwiftUI

struct EQEditorView: View {
    @ObservedObject var engine: EQEngine
    @ObservedObject var presetStore: PresetStore

    // Working copy, edited live and pushed to the engine on every change.
    @State private var draft: EQPreset = .flat
    @State private var newPresetName: String = ""
    @State private var showSaveSheet = false

    var body: some View {
        HSplitView {
            // Left: curve + header
            VStack(alignment: .leading, spacing: 12) {
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Save As New…") { showSaveSheet = true }
                Button("Overwrite Current") { presetStore.update(draft) }
                    .disabled(!presetStore.presets.contains(where: { $0.id == draft.id }))
                Button("Duplicate") {
                    let copy = presetStore.duplicate(draft)
                    draft = copy
                }
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            saveSheet
        }
        .task {
            if let current = engine.currentPreset { draft = current }
            else if let first = presetStore.presets.first { draft = first }
        }
        .onChange(of: engine.currentPreset) { _, new in
            // Engine changed preset externally (menu bar). Mirror into the editor.
            if let new, new.id != draft.id { draft = new }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Preset name", text: $draft.name)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
            HStack(spacing: 8) {
                TextField("Headphone", text: $draft.headphone)
                    .textFieldStyle(.roundedBorder)
                TextField("Source", text: $draft.source)
                    .textFieldStyle(.roundedBorder)
            }
            .font(.callout)
        }
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
