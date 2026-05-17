import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Per-app exclusion list. Toggling a row updates the store, which fires
/// `onChange` → `EQEngine.reEnumerateTapTargets` so the tap rebuilds with
/// the new set. Excluded apps' audio bypasses Klang and plays through the
/// system mixer's normal output path.
struct ExcludedAppsView: View {
    @ObservedObject var store: ExcludedAppsStore

    /// Currently-running, audio-registered apps (deduplicated by bundle ID).
    /// Refreshed live via `AudioProcessListChangeListener` while the window
    /// is open, so newly launched apps appear without a manual reload.
    @State private var runningApps: [AudioProcessInfo.App] = []
    @State private var processListListener: AudioProcessListChangeListener?
    @State private var filter: String = ""

    /// Union of running apps and apps that are excluded but not currently
    /// running — the latter still need to be visible so the user can remove
    /// them. Excluded-but-not-running rows are tagged so we can label them.
    private var rows: [Row] {
        var seen = Set<String>()
        var result: [Row] = []
        for app in runningApps {
            seen.insert(app.bundleID)
            result.append(Row(
                bundleID: app.bundleID,
                displayName: app.displayName,
                isRunning: true
            ))
        }
        let orphans = store.excludedBundleIDs
            .subtracting(seen)
            .map { bundleID in
                Row(
                    bundleID: bundleID,
                    displayName: AudioProcessInfo.displayName(forBundleID: bundleID),
                    isRunning: false
                )
            }
            .sorted { $0.displayName.localizedCompare($1.displayName) == .orderedAscending }
        result.append(contentsOf: orphans)
        return applyFilter(result)
    }

    /// Free-text filter over both display name and bundle ID — so `chrome`
    /// matches Google Chrome and `com.spotify` matches Spotify.
    private func applyFilter(_ all: [Row]) -> [Row] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { row in
            row.displayName.localizedCaseInsensitiveContains(needle)
                || row.bundleID.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Set to true when embedded as a Settings tab — suppresses the standalone
    /// window's min/ideal frame so the TabView gets to size us.
    var embedded: Bool = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .onAppear {
            refreshRunningApps()
            processListListener = AudioProcessListChangeListener {
                refreshRunningApps()
            }
        }
        .onDisappear {
            processListListener = nil
        }

        if embedded {
            content
        } else {
            content
                .frame(minWidth: 460, idealWidth: 520, minHeight: 380, idealHeight: 500)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Excluded Apps").font(.title2.weight(.semibold))
            Text("Audio from these apps bypasses Klang and plays directly through your output device. Useful for voice/video calls and apps that ship their own audio processing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            searchField
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter by app name or bundle ID", text: $filter)
                .textFieldStyle(.roundedBorder)
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let visibleRows = rows
                if visibleRows.isEmpty {
                    Text(emptyStateMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.bundleID) { index, row in
                        AppRow(
                            row: row,
                            isExcluded: store.contains(row.bundleID),
                            onToggle: { store.toggle(row.bundleID) }
                        )
                        if index < visibleRows.count - 1 {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private var emptyStateMessage: String {
        if !filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No apps match \u{201C}\(filter)\u{201D}."
        }
        return "No audio-producing apps detected. Start playback in an app, or use \u{201C}Add app\u{2026}\u{201D} below."
    }

    private var footer: some View {
        HStack {
            Button("Add app\u{2026}") { addAppViaFilePicker() }
            Spacer()
            Text(footerSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var footerSummary: String {
        let count = store.excludedBundleIDs.count
        switch count {
        case 0: return "Nothing excluded \u{2014} all apps go through Klang."
        case 1: return "1 app excluded"
        default: return "\(count) apps excluded"
        }
    }

    // MARK: - Actions

    private func refreshRunningApps() {
        runningApps = AudioProcessInfo.runningAudioApps()
    }

    /// NSOpenPanel filtered to .app bundles. We pull the bundle ID out of the
    /// selected bundle (not its path or name) — that's what the audio-side
    /// filter matches against.
    private func addAppViaFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Add App to Excluded List"
        panel.prompt = "Exclude"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
            // Not strictly an .app bundle, or missing CFBundleIdentifier — surface
            // a small alert rather than failing silently.
            let alert = NSAlert()
            alert.messageText = "Couldn\u{2019}t read bundle identifier"
            alert.informativeText = "\(url.lastPathComponent) doesn\u{2019}t look like a standard app bundle."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        store.set(bundleID, excluded: true)
    }

    // MARK: - Row model

    fileprivate struct Row: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        /// False for apps in the exclusion list that aren't currently audio-
        /// registered. We still list them so the user can remove them.
        let isRunning: Bool
    }
}

/// One app row: icon + name (+ bundle ID hint) + on/off toggle.
private struct AppRow: View {
    let row: ExcludedAppsView.Row
    let isExcluded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if !row.isRunning {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                    }
                }
                Text(row.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isExcluded },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .help(isExcluded ? "Excluded \u{2014} audio bypasses Klang" : "Routed through Klang")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        if let nsImage = AudioProcessInfo.icon(forBundleID: row.bundleID) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }
}
