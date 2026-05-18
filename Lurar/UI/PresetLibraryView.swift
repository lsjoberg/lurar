import SwiftUI

/// Browse AutoEq's catalog and pick which entries should show up in Lurar's
/// preset picker. Selection is purely a visibility flag — entries stay
/// read-only and live in the catalog, not the user's `presets.json`.
struct PresetLibraryView: View {
    @ObservedObject var catalog: PresetCatalog
    @Environment(\.dismiss) private var dismiss

    @State private var search: String = ""
    @State private var measurerFilter: String = "All"
    @FocusState private var searchFocused: Bool

    private var measurers: [String] {
        let set = Set(catalog.entries.map(\.measurer))
        return ["All"] + set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [CatalogEntry] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return catalog.entries.filter { entry in
            if measurerFilter != "All" && entry.measurer != measurerFilter { return false }
            guard !needle.isEmpty else { return true }
            if entry.name.lowercased().contains(needle) { return true }
            if entry.measurer.lowercased().contains(needle) { return true }
            if let rig = entry.rig?.lowercased(), rig.contains(needle) { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 480, idealHeight: 600)
        .showsInDockWhileVisible()
        .background(hiddenShortcuts)
    }

    /// Zero-sized hidden Buttons that carry the library's keyboard bindings
    /// for actions whose primary control either lives inside a TextField
    /// (\u{2318}F focus search) or as a regular button that we want surfaced
    /// in the cheat sheet too (\u{2318}R refresh \u{2014} bound here so the binding
    /// works whether the footer Refresh button is offscreen or not).
    private var hiddenShortcuts: some View {
        VStack(spacing: 0) {
            Button { searchFocused = true } label: { EmptyView() }
                .lurarShortcut(LurarShortcuts.focusSearch)
            Button {
                Task { await catalog.refreshIndex(force: true) }
            } label: { EmptyView() }
                .lurarShortcut(LurarShortcuts.refreshCatalog)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preset Library").font(.title2.weight(.semibold))
                Spacer()
                statusLabel
            }
            Text("Toggle headphones on to show their AutoEq preset in Lurar's menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Search headphone, measurer, rig…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .help("Filter the catalog (\u{2318}F to focus)")
                Picker("", selection: $measurerFilter) {
                    ForEach(measurers, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                .help("Filter by measurement source")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch catalog.indexState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
        case .loaded(let when):
            Text("Updated \(relativeDate(when))")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
        }
    }

    @ViewBuilder
    private var content: some View {
        if catalog.entries.isEmpty {
            emptyState
        } else if filtered.isEmpty {
            VStack(spacing: 6) {
                Text("No matches").font(.headline)
                Text("Try a different search or measurer.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(filtered) { entry in
                    row(for: entry)
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No catalog available yet").font(.headline)
            switch catalog.indexState {
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .loading:
                Text("Fetching from AutoEq…").foregroundStyle(.secondary)
            default:
                Text("Waiting for first fetch.").foregroundStyle(.secondary)
            }
            Button("Refresh") {
                Task { await catalog.refreshIndex(force: true) }
            }
            .lurarShortcutHelp(LurarShortcuts.refreshCatalog, label: "Reload the catalog from AutoEq")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for entry: CatalogEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                HStack(spacing: 6) {
                    Text(entry.measurer)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                    if let rig = entry.rig {
                        Text(rig).font(.caption).foregroundStyle(.secondary)
                    }
                    rowStatus(for: entry)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { catalog.isEnabled(entry.id) },
                set: { on in catalog.setEnabled(entry.id, on) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func rowStatus(for entry: CatalogEntry) -> some View {
        if catalog.inFlight.contains(entry.id) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Fetching…").font(.caption).foregroundStyle(.secondary)
            }
        } else if let error = catalog.fetchErrors[entry.id] {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Failed").font(.caption).foregroundStyle(.orange)
                Button("Retry") { catalog.retry(entry.id) }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("Retry fetching this preset")
            }
            .help(error)
        } else if catalog.isEnabled(entry.id) && catalog.hydratedPresets[entry.id] != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green.opacity(0.7))
                .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(filtered.count) of \(catalog.entries.count) shown · \(catalog.enabledIDs.count) enabled")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Refresh") {
                Task { await catalog.refreshIndex(force: true) }
            }
            .lurarShortcutHelp(LurarShortcuts.refreshCatalog, label: "Reload the catalog from AutoEq")
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .lurarShortcutHelp(LurarShortcuts.libraryDone, label: "Close")
        }
        .padding(12)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
