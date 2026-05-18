import SwiftUI
import ServiceManagement
import OSLog

private let settingsLog = Logger(subsystem: "app.lurar.Lurar", category: "Settings")

struct SettingsView: View {
    @ObservedObject var syncSettings: PresetSyncSettings
    @ObservedObject var presetStore: PresetStore
    @ObservedObject var excludedAppsStore: ExcludedAppsStore
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var updater: UpdaterController

    var body: some View {
        TabView {
            GeneralSettingsTab(outputPreferences: outputPreferences, updater: updater)
                .tabItem { Label("General", systemImage: "gearshape") }
                .padding(20)
                .frame(width: 460)

            ExcludedAppsView(store: excludedAppsStore, embedded: true)
                .tabItem { Label("Excluded Apps", systemImage: "square.slash") }
                .frame(width: 520, height: 460)

            SyncSettingsTab(syncSettings: syncSettings, presetStore: presetStore)
                .tabItem { Label("Sync", systemImage: "icloud") }
                .padding(20)
                .frame(width: 460)
        }
        .frame(width: 520)
        .showsInDockWhileVisible()
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var outputPreferences: OutputSelectionPreferences
    @ObservedObject var updater: UpdaterController

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    @AppStorage("startEngineOnLaunch") private var startEngineOnLaunch: Bool = true
    @AppStorage(EQEngine.muteOnDeviceRateChangeKey) private var muteOnDeviceRateChange: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .help("Register Lurar with Login Items so it launches when you sign in")
                    .onChange(of: launchAtLogin, initial: false) { _, newValue in
                        toggleLaunchAtLogin(newValue)
                    }
                Text("Lurar launches automatically when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start engine when Lurar launches", isOn: $startEngineOnLaunch)
                    .toggleStyle(.switch)
                    .help("Begin processing audio as soon as Lurar boots, instead of waiting for a manual start")
                Text("When Lurar has audio-capture permission, the engine starts automatically on launch. Turn this off if you'd rather start it manually from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Follow the system default output", isOn: Binding(
                    get: { outputPreferences.followMode == .autoFollow },
                    set: { outputPreferences.followMode = $0 ? .autoFollow : .ignore }
                ))
                .toggleStyle(.switch)
                .help("Switch Lurar's output when macOS changes its default output device")
                Text("When AirPods or another device connects, macOS may change its default output. With this on, Lurar follows along.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Mute briefly on output rate change", isOn: $muteOnDeviceRateChange)
                    .toggleStyle(.switch)
                    .help("Fade audio out for ~150 ms when the output device's sample rate changes, to mask the resampler transient")
                Text("Apple Music and other hi-res sources can change your DAC's sample rate between tracks. Fading briefly hides the audible pitch glitch as Core Audio's internal sample-rate converter re-tunes. Turn this off if you'd rather hear the unmasked transition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Updates").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Check for Updates\u{2026}") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                        .help("Manually check for a newer Lurar release")
                }
                Text("Lurar checks for new releases automatically. You can also check manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .onAppear {
            // Re-sync in case the user toggled the login item from System Settings.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func toggleLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settingsLog.error("Launch-at-login toggle failed: \(String(describing: error))")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Sync

private struct SyncSettingsTab: View {
    @ObservedObject var syncSettings: PresetSyncSettings
    @ObservedObject var presetStore: PresetStore

    @State private var iCloudAvailable: Bool = PresetStore.iCloudIsAvailable()
    @State private var showMigratePrompt: Bool = false
    @State private var pendingToggleValue: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Preset sync").font(.title3.weight(.semibold))

            Toggle("Sync presets via iCloud", isOn: Binding(
                get: { syncSettings.iCloudEnabled },
                set: { handleToggle(newValue: $0) }
            ))
            .toggleStyle(.switch)
            .disabled(!iCloudAvailable)

            statusBlurb

            Divider().padding(.vertical, 4)

            Text("Current file")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: presetStore.locationKind == .iCloud ? "icloud" : "internaldrive")
                    .foregroundStyle(.secondary)
                Text(presetStore.fileURL.path)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .alert(
            "Move existing presets to iCloud?",
            isPresented: $showMigratePrompt
        ) {
            Button("Move") {
                pendingToggleValue = true
                syncSettings.iCloudEnabled = true
            }
            Button("Cancel", role: .cancel) {
                pendingToggleValue = false
            }
        } message: {
            Text("Your current presets.json will be copied to your iCloud Drive container so it syncs to your other Macs. Lurar on other devices will pick up changes automatically.")
        }
        .onAppear {
            // Refresh in case the user signed into iCloud since launch.
            iCloudAvailable = PresetStore.iCloudIsAvailable()
        }
    }

    @ViewBuilder
    private var statusBlurb: some View {
        if !iCloudAvailable {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Drive isn\u{2019}t available")
                        .font(.callout.weight(.semibold))
                    Text("Sign in to iCloud and enable iCloud Drive in System Settings. The build must also be signed with a developer team that has the iCloud capability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
            }
        } else if syncSettings.iCloudEnabled {
            Label {
                Text("Presets are synced via iCloud Drive. Changes from other Macs appear automatically.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
            }
        } else {
            Text("Presets are stored locally in Application Support. Turn on iCloud to keep them in sync across your Macs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func handleToggle(newValue: Bool) {
        if newValue {
            // Only prompt if there's a local file to migrate — first launches
            // with iCloud directly are fine without the confirmation.
            let hasLocal = FileManager.default.fileExists(atPath: PresetStore.localFileURL.path)
            if hasLocal && presetStore.locationKind == .local {
                showMigratePrompt = true
            } else {
                syncSettings.iCloudEnabled = true
            }
        } else {
            syncSettings.iCloudEnabled = false
        }
    }
}
