import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct UnifiedAppsView: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var excludedAppsStore: ExcludedAppsStore
    @ObservedObject var voipAppsStore: VoIPAppsStore

    @State private var runningApps: [AudioProcessInfo.App] = []
    @State private var processListListener: AudioProcessListChangeListener?
    @State private var filter: String = ""
    @FocusState private var filterFocused: Bool

    fileprivate struct Row: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let displayName: String
        let isRunning: Bool
    }

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
        let orphans = excludedAppsStore.excludedBundleIDs
            .union(voipAppsStore.voipBundleIDs)
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

    private func applyFilter(_ all: [Row]) -> [Row] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { row in
            row.displayName.localizedCaseInsensitiveContains(needle)
                || row.bundleID.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Call Handling Mode section
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("During Calls (FaceTime, Zoom)")
                        .font(.headline)
                    Spacer()
                    Picker("", selection: $outputPreferences.callHandlingMode) {
                        ForEach(OutputSelectionPreferences.CallHandlingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                Text(outputPreferences.callHandlingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // App Rules table
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Application Rules")
                        .font(.headline)

                    Spacer()

                    TextField("Filter apps\u{2026}", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .focused($filterFocused)
                        .frame(width: 180)

                    Button {
                        addAppViaFilePicker()
                    } label: {
                        Label("Add App\u{2026}", systemImage: "plus")
                    }
                }

                // Table Header
                HStack(spacing: 12) {
                    Text("Application")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Bypass EQ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .center)
                        .help("This app's audio completely bypasses EQ and plays directly to macOS")
                    Text("Call App")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .center)
                        .help("Monitored for microphone activity to trigger call audio handling")
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)

                // List
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(rows) { row in
                            AppRowView(
                                row: row,
                                isBypassed: excludedAppsStore.contains(row.bundleID),
                                isCallApp: voipAppsStore.contains(row.bundleID),
                                onToggleBypass: {
                                    excludedAppsStore.toggle(row.bundleID)
                                },
                                onToggleCallApp: {
                                    voipAppsStore.toggle(row.bundleID)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .padding(20)
        .task {
            refreshRunningApps()
            processListListener = AudioProcessListChangeListener { [self] in
                Task { @MainActor in self.refreshRunningApps() }
            }
        }
    }

    private func refreshRunningApps() {
        runningApps = AudioProcessInfo.runningAudioApps()
    }

    private func addAppViaFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleID.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Couldn't read bundle identifier"
            alert.informativeText = "\(url.lastPathComponent) doesn't look like a standard app bundle."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        excludedAppsStore.set(bundleID, excluded: true)
    }
}

private struct AppRowView: View {
    let row: UnifiedAppsView.Row
    let isBypassed: Bool
    let isCallApp: Bool
    let onToggleBypass: () -> Void
    let onToggleCallApp: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: AudioProcessInfo.icon(forBundleID: row.bundleID) ?? NSImage())
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .font(.body)
                        .lineLimit(1)

                    if !row.isRunning {
                        Text("not running")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(row.bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isBypassed },
                set: { _ in onToggleBypass() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 80, alignment: .center)

            Toggle("", isOn: Binding(
                get: { isCallApp },
                set: { _ in onToggleCallApp() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
