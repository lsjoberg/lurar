import AppKit
import SwiftUI

/// Welcome / TCC permission / first-run setup window.
///
/// Modes, picked from the live TCC state when the window first appears:
///
/// - **Initial**: TCC has never been prompted (`preflight == .unknown`). The
///   OS dialog is about to fire when we call into the request path. We show
///   our welcome copy first because raw TCC otherwise gives users no context
///   — they see "Lurar would like to use audio input" with no explanation
///   of what that means in this app or that we never record or transmit.
///
/// - **Denied**: TCC previously denied (`preflight == .denied`) — either the
///   user said no in the OS dialog or revoked via System Settings. TCC won't
///   re-prompt, so the only path back through is Privacy & Security. We show
///   numbered steps and a Settings deep link.
///
/// - **Setup**: Post-consent kickstart. Pick an output, optionally add a
///   matching AutoEq preset (or browse popular ones if we can't tell what
///   the user is on), and a "what's next" pointer at the menu bar icon and
///   the editor / A-B affordances. Engine starts the moment we land here
///   so the user immediately hears whatever they pick.
///
/// Mode is frozen at presentation time (captured in `@State` on `onAppear`)
/// so the copy doesn't swap underneath the user mid-interaction. Continue
/// from initial mode flips to denied in-place if the OS denies the prompt,
/// rather than dismissing and stranding the user.
struct OnboardingPermissionView: View {
    enum Mode {
        case initial
        case denied
        case setup
    }

    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var presetCatalog: PresetCatalog
    @ObservedObject var devicePresetMemory: DevicePresetMemory

    @Environment(\.dismiss) private var dismiss

    /// Captured from live preflight on first appearance. Becomes `.denied`
    /// in-place if Continue triggers an OS denial, or `.setup` if granted.
    @State private var mode: Mode = .initial

    /// Latches when the user clicks "Try again" and the request path still
    /// reports blocked. Surfaces a hint about ad-hoc-signed dev builds
    /// needing a full app relaunch (TCC tracks apps by code signature, and
    /// the running process can hold a stale denied verdict after a Settings
    /// flip).
    @State private var retryFailed: Bool = false

    /// Free-text filter for the DAC fallback's catalog search. Lower-case
    /// substring match against entry names; empty means "show popular chips".
    @State private var presetSearchQuery: String = ""

    /// UID of the output we've already evaluated for auto-apply, regardless
    /// of whether anything was applied. Prevents the auto-apply task from
    /// re-firing every render when the matched-mode preset is still loading,
    /// and prevents it from re-clobbering a user pick if they swap to an
    /// alternate after the auto-apply lands.
    @State private var autoAppliedForOutputUID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch mode {
                case .initial:
                    initialExplanation
                    reassurance
                    initialInstruction
                case .denied:
                    deniedExplanation
                    reassurance
                    deniedInstruction
                case .setup:
                    setupIntro
                    outputSection
                    presetSection
                    whatsNextSection
                }
                Spacer(minLength: 0)
                buttons
            }
            .padding(28)
        }
        .frame(
            width: mode == .setup ? 580 : 480,
            height: mode == .setup ? 860 : nil
        )
        // Bring Lurar into the dock + Cmd+Tab while the onboarding window
        // is open — without it the user can't switch back after bouncing
        // to System Settings to grant the TCC permission.
        .showsInDockWhileVisible()
        .onAppear {
            // Pick the mode that matches the actual TCC state right now.
            // .authorized falls through to setup so the user lands on
            // kickstart even if they re-open the window after granting.
            switch AudioCapturePermission.preflight() {
            case .denied:
                mode = .denied
            case .authorized:
                mode = .setup
                ensureEngineRunning()
                triggerAutoApplyIfNeeded()
            case .unknown:
                mode = .initial
            }
        }
        // Re-evaluate when the user (or auto-follow) swaps outputs — each
        // device gets its own one-shot auto-apply attempt. Also re-evaluate
        // when the catalog finally loads, since first-launch users typically
        // land in setup mode before the AutoEq index fetch finishes.
        .onChange(of: deviceManager.selectedOutput?.uid) { _, _ in
            triggerAutoApplyIfNeeded()
        }
        .onChange(of: presetCatalog.entries) { _, _ in
            triggerAutoApplyIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            headerImage
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var headerImage: some View {
        switch mode {
        case .initial:
            LurarMark()
                .frame(width: 36, height: 36)
        case .denied:
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
        case .setup:
            LurarMark()
                .frame(width: 36, height: 36)
        }
    }

    private var headerTitle: String {
        switch mode {
        case .initial: return "Welcome to Lurar"
        case .denied: return "Audio capture is blocked"
        case .setup: return "You're all set"
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .initial: return "One quick permission and you're set."
        case .denied: return "macOS won't re-prompt — here's how to re-enable it."
        case .setup: return "A couple of quick choices and Lurar's tuned for you."
        }
    }

    // MARK: - Initial mode

    private var initialExplanation: some View {
        Text("macOS will ask you to allow audio capture next. This lets Lurar receive sound from your apps so it can apply EQ before it reaches your headphones.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var initialInstruction: some View {
        Text("When you click Continue, macOS will show a permission dialog. Choose **Allow**.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Setup mode

    private var setupIntro: some View {
        Text("Permission granted. Lurar is now applying EQ to system audio — pick where you're listening and add a preset for your headphones.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Output section

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("1.", "Pick your output")
            if deviceManager.outputDevices.isEmpty {
                Text("Looking for output devices…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(deviceManager.outputDevices, id: \.uid) { device in
                        OutputRow(
                            device: device,
                            isSelected: deviceManager.selectedOutput?.uid == device.uid,
                            action: { selectOutput(device) }
                        )
                    }
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                Text("Don't see your AirPods? Connect them now— they'll appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    // MARK: Preset section

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("2.", "Add a preset for your headphones")
            // Only surface the pill once the catalog is loaded — otherwise
            // we'd nudge "pick your headphones" with nothing to pick from.
            if !presetCatalog.entries.isEmpty {
                statusPill
            }
            presetSectionBody
        }
    }

    /// Live status of what's actually EQ'ing the user's audio right now.
    /// Amber when sitting on Flat (visible nudge to pick something), green
    /// when a real preset is active (confirmation that EQ is in effect).
    /// Drives off `engine.currentPreset` directly so it always reflects
    /// reality — including the returning-user case where per-device memory
    /// already restored a preset before onboarding opened.
    private var statusPill: some View {
        let preset = engine.currentPreset
        let onFlat = preset == nil || preset?.id == EQPreset.flatID
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: onFlat ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(onFlat ? .orange : .green)
                .font(.callout)
                .padding(.top, 1)
            if onFlat {
                Text("Currently: Flat — pick your headphones below to hear the difference.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    // Including the source disambiguates the common case where
                    // the user has multiple measurements of the same headphone
                    // enabled (oratory1990 vs crinacle vs Rtings) — the name
                    // alone is identical across all three.
                    (Text("Active: ").foregroundStyle(.secondary)
                     + Text(preset?.name ?? "").fontWeight(.semibold))
                        .font(.callout)
                        .lineLimit(2)
                    if let source = preset?.source, !source.isEmpty {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((onFlat ? Color.orange : Color.green).opacity(0.12))
        )
    }

    @ViewBuilder
    private var presetSectionBody: some View {
        if presetCatalog.entries.isEmpty {
            Text("Loading AutoEq catalog…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            let device = deviceManager.selectedOutput
            let matches: [PresetSuggester.Match] = {
                guard let device else { return [] }
                return PresetSuggester.suggestions(
                    forDevice: device.name,
                    in: presetCatalog.entries,
                    limit: 3
                )
            }()
            if let device, !matches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Suggested for \(device.name):")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        ForEach(matches, id: \.entry.id) { match in
                            PresetRow(
                                name: match.entry.name,
                                subtitle: sourceLabel(for: match.entry),
                                isActive: isActivePreset(match.entry),
                                isInLibrary: presetCatalog.isEnabled(match.entry.id),
                                isLoading: presetCatalog.inFlight.contains(match.entry.id),
                                action: { applyEntry(match.entry) }
                            )
                        }
                    }
                }
            } else {
                dacFallbackBody
            }
        }
    }

    private var dacFallbackBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lurar can't tell which headphones are on your output. Search AutoEq for them, or pick one of these popular models.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search AutoEq for your headphones…", text: $presetSearchQuery)
                .textFieldStyle(.roundedBorder)

            if presetSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                let chips = Self.popularHeadphoneQueries
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)
                ], alignment: .leading, spacing: 6) {
                    ForEach(chips, id: \.self) { query in
                        Button(query) { applyPopular(query: query) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("Add the AutoEq preset for \(query)")
                    }
                }
            } else {
                let results = filteredEntries(for: presetSearchQuery)
                if results.isEmpty {
                    Text("No matches in the catalog.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 4) {
                        ForEach(results, id: \.id) { entry in
                            PresetRow(
                                name: entry.name,
                                subtitle: sourceLabel(for: entry),
                                isActive: isActivePreset(entry),
                                isInLibrary: presetCatalog.isEnabled(entry.id),
                                isLoading: presetCatalog.inFlight.contains(entry.id),
                                action: { applyEntry(entry) }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: What's next section

    private var whatsNextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("3.", "What's next")
            VStack(spacing: 8) {
                WhatsNextRow(
                    iconImage: Image(nsImage: LurarMark.statusBarImage(filled: true, pointSize: 16)),
                    title: "Lurar lives in your menu bar.",
                    body: "Find this icon up top — click it to switch outputs, change presets, or toggle the engine."
                )
                WhatsNextRow(
                    systemIcon: "rectangle.lefthalf.filled",
                    title: "Hear the difference.",
                    body: "Hold ⌥B anywhere to bypass the EQ, or open A/B Compare (⌘B) for a blind test."
                )
                WhatsNextRow(
                    systemIcon: "slider.horizontal.3",
                    title: "Tweak the curve.",
                    body: "Open Editor (⌘E) to nudge bands live — edits apply to the running engine instantly."
                )
            }
        }
    }

    // MARK: - Success / reassurance

    private var reassurance: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.green)
            Text("Lurar does not record, store, or transmit audio.")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Denied mode

    private var deniedExplanation: some View {
        Text("Lurar's audio-capture permission was denied. macOS only asks once — after that it has to be re-enabled manually in System Settings.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deniedInstruction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To re-enable:")
                .font(.callout.weight(.semibold))
            stepRow("1.", "Click **Open System Settings** below.")
            stepRow("2.", "Find **Lurar** under **Privacy & Security → Audio Capture**.")
            stepRow("3.", "Toggle it **on**.")
            stepRow("4.", "Come back here and click **Try again**.")
            if retryFailed {
                retryFailedHint
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    /// Shown once "Try again" has been clicked at least once without success.
    /// The known cause on dev builds is that ad-hoc codesigning produces a
    /// fresh CDHash on every build — the entry the user toggled in System
    /// Settings refers to a previous signature, so the running process still
    /// sees denied. A relaunch picks up the new TCC verdict for the current
    /// signature.
    private var retryFailedHint: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Still blocked.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("macOS sometimes caches the previous decision. Try quitting Lurar (⌘Q) and reopening — if the System Settings toggle still doesn't take, run ") + Text("`tccutil reset AudioCapture app.lurar.Lurar`").font(.callout.monospaced()) + Text(" in Terminal and try again.")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 4)
    }

    private func sectionLabel(_ number: String, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            Text(title)
                .font(.headline)
        }
    }

    private func stepRow(_ number: String, _ markdown: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            Text(markdown)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch mode {
        case .initial:
            HStack {
                Spacer()
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this window without granting permission (esc)")
                Button("Continue") {
                    continueFromInitial()
                }
                .keyboardShortcut(.defaultAction)
                .help("Show the macOS audio-capture permission prompt (\u{21A9})")
            }
        case .denied:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close this window (esc)")
                Button("Open System Settings") {
                    openAudioCaptureSettings()
                }
                .help("Jump to Privacy & Security \u{2192} Audio Capture in System Settings")
                Button("Try again") {
                    retryStart()
                }
                .keyboardShortcut(.defaultAction)
                .help("Re-check permission and start the engine if granted (\u{21A9})")
            }
        case .setup:
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close this window (\u{21A9})")
            }
        }
    }

    // MARK: - Actions

    /// Trigger the real OS prompt via ensureAuthorized(). If the user allows,
    /// start the engine and swap to the setup state — the user picks output
    /// + preset there before closing. If the OS denies, flip the window into
    /// denied mode in place rather than dismissing — otherwise the user is
    /// stranded with the engine still off and no on-screen guidance.
    private func continueFromInitial() {
        if AudioCapturePermission.ensureAuthorized() {
            ensureEngineRunning()
            mode = .setup
            triggerAutoApplyIfNeeded()
        } else {
            mode = .denied
        }
    }

    /// Re-check via TCCAccessRequest (the real source of truth) and start the
    /// engine if permission is now authorized. Preflight is unreliable on
    /// some macOS releases — it can keep reporting denied even after a
    /// genuine Settings grant — so we go straight to the request path,
    /// which silently returns true when the OS would actually permit the
    /// capture call. Stays on the denied screen with a hint if it doesn't.
    private func retryStart() {
        if AudioCapturePermission.ensureAuthorized() {
            ensureEngineRunning()
            mode = .setup
            triggerAutoApplyIfNeeded()
        } else {
            retryFailed = true
        }
    }

    /// Start the engine on the currently-selected output, if any. Safe to
    /// call when already running — EQEngine.start short-circuits on a
    /// same-device reentry.
    private func ensureEngineRunning() {
        guard let output = deviceManager.selectedOutput else {
            engine.reportStartFailure("Pick an output device first")
            return
        }
        engine.start(output: output)
    }

    private func selectOutput(_ device: AudioDevice) {
        guard deviceManager.selectedOutput?.uid != device.uid else { return }
        deviceManager.selectedOutput = device
        // Restart the engine on the new device so the user immediately hears
        // EQ via the chosen output. EQEngine.start handles the running-engine
        // case (rebinds rather than tearing the whole pipeline down).
        engine.start(output: device)
    }

    /// Soft auto-apply: when the user lands on (or swaps to) an output that
    /// the suggester confidently matches, apply the top match for them so
    /// they aren't quietly listening to Flat. One-shot per output to avoid
    /// re-clobbering if they pick an alternate; skipped entirely when a
    /// real preset is already active (returning user with per-device memory
    /// — respect what they already chose). DAC / unmatched outputs leave
    /// `engine.currentPreset` on Flat; the status pill picks up the slack
    /// and nudges them to pick something manually.
    private func triggerAutoApplyIfNeeded() {
        guard mode == .setup else { return }
        guard let device = deviceManager.selectedOutput else { return }
        guard autoAppliedForOutputUID != device.uid else { return }
        guard !presetCatalog.entries.isEmpty else { return }
        autoAppliedForOutputUID = device.uid

        let currentlyOnFlat = engine.currentPreset == nil
            || engine.currentPreset?.id == EQPreset.flatID
        guard currentlyOnFlat else { return }

        let matches = PresetSuggester.suggestions(
            forDevice: device.name,
            in: presetCatalog.entries,
            limit: 1
        )
        guard let top = matches.first else { return }
        applyEntry(top.entry)
    }

    /// Enable the catalog entry, wait for the network fetch to land, then
    /// select it for the current output. Mirrors MenuBarView.applySuggestion
    /// but scoped to onboarding's flow (no banner state to manage).
    private func applyEntry(_ entry: CatalogEntry) {
        let entryID = entry.id
        let pinnedDeviceUID = deviceManager.selectedOutput?.uid
        if let uid = pinnedDeviceUID {
            devicePresetMemory.setLastPresetID(entryID, for: uid)
            devicePresetMemory.dismissSuggestion(for: uid)
        }
        Task { @MainActor in
            presetCatalog.enable(entryID)
            if let task = presetCatalog.ensureHydrated(id: entryID) {
                _ = try? await task.value
            }
            guard let preset = presetCatalog.hydratedPresets[entryID] else { return }
            guard deviceManager.selectedOutput?.uid == pinnedDeviceUID else { return }
            engine.apply(preset: preset)
        }
    }

    /// Apply the first catalog entry whose name fuzzy-matches a popular
    /// chip query. Silent no-op if the catalog has nothing close — popular
    /// chips are deliberately well-known names, so this is rare.
    private func applyPopular(query: String) {
        let matches = PresetSuggester.suggestions(
            forDevice: query,
            in: presetCatalog.entries,
            limit: 1
        )
        if let first = matches.first {
            applyEntry(first.entry)
            return
        }
        // Fallback to substring match if the suggester's stricter rules
        // reject (some short queries like "HD 600" don't reach 2-token
        // overlap with multi-word catalog names).
        if let entry = filteredEntries(for: query).first {
            applyEntry(entry)
        }
    }

    private func filteredEntries(for query: String) -> [CatalogEntry] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        return presetCatalog.entries
            .filter { $0.name.lowercased().contains(needle) }
            .prefix(6)
            .map { $0 }
    }

    private func sourceLabel(for entry: CatalogEntry) -> String {
        if let rig = entry.rig { return "\(entry.measurer) · \(rig)" }
        return entry.measurer
    }

    /// True when this catalog entry is the one currently EQ'ing the audio.
    /// CatalogEntry.id and the hydrated EQPreset share the same deterministic
    /// UUID (slug-derived), so a direct id comparison is the source of truth.
    private func isActivePreset(_ entry: CatalogEntry) -> Bool {
        engine.currentPreset?.id == entry.id
    }

    /// Deep-link to System Settings → Privacy & Security → Audio Capture.
    /// The Sonoma URL scheme lands directly on the audio-capture pane; on
    /// older systems or if Apple changes the anchor, this just opens the
    /// Privacy section and the user follows the in-window steps.
    private func openAudioCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Popular chip list

    /// Well-known headphones users on a generic DAC are likely to own. Kept
    /// short on purpose — overwhelming chips would defeat the point of the
    /// fallback. Names use the canonical product spellings AutoEq uses.
    private static let popularHeadphoneQueries: [String] = [
        "HD 6XX",
        "HD 600",
        "HD 650",
        "HiFiMan Sundara",
        "DT 770",
        "DT 990",
        "AKG K371",
        "Moondrop Aria"
    ]
}

// MARK: - Subviews

private struct OutputRow: View {
    let device: AudioDevice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.callout)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .font(.callout.weight(.semibold))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSelected ? "Currently routing audio through \(device.name)" : "Route audio through \(device.name)")
    }

    /// Pick an icon from the device + manufacturer name. CoreAudio's
    /// transport-type property would be more precise but isn't currently
    /// exposed on AudioDevice — a name-based heuristic is good enough
    /// for the four buckets we show here.
    private var iconName: String {
        let n = (device.name + " " + device.manufacturer).lowercased()
        if n.contains("airpods") { return "airpods" }
        if n.contains("bluetooth") || n.contains("a2dp") || n.contains("hfp") || n.contains("beats") {
            return "antenna.radiowaves.left.and.right"
        }
        if n.contains("macbook") || n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") || n.contains("built-in") {
            return "speaker.wave.2.fill"
        }
        if n.contains("usb") || n.contains("dac") || n.contains("hifiman") || n.contains("fiio") || n.contains("schiit") || n.contains("ifi") || n.contains("topping") {
            return "cable.connector"
        }
        if n.contains("headphone") || n.contains("jack") {
            return "headphones"
        }
        return "speaker.wave.2"
    }

    private var subtitle: String {
        let n = (device.name + " " + device.manufacturer).lowercased()
        if n.contains("airpods") || n.contains("beats") || n.contains("bluetooth") {
            return "Bluetooth"
        }
        if n.contains("macbook") || n.contains("imac") || n.contains("mac mini") || n.contains("mac studio") || n.contains("built-in") {
            return "Built-in"
        }
        if n.contains("usb") || n.contains("dac") || n.contains("hifiman") || n.contains("fiio") || n.contains("schiit") || n.contains("ifi") || n.contains("topping") {
            return "USB DAC"
        }
        if n.contains("headphone") || n.contains("jack") {
            return "Headphone jack"
        }
        return device.manufacturer.isEmpty ? "Output device" : device.manufacturer
    }
}

private struct PresetRow: View {
    let name: String
    let subtitle: String
    /// Currently EQ'ing the user's audio. Strongest signal — the row gets
    /// a green tint and a fixed "Active" badge.
    let isActive: Bool
    /// In the user's library but not currently active. The row shows a
    /// "Use" button so a single tap activates without re-fetching.
    let isInLibrary: Bool
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailingControl
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.green.opacity(0.16) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.green.opacity(isActive ? 0.45 : 0), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
        } else if isActive {
            Label("Active", systemImage: "speaker.wave.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .help("Currently EQ'ing audio")
        } else if isInLibrary {
            Button("Use") { action() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Make this the active preset")
        } else {
            Button("Add") { action() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Add this preset and apply it now")
        }
    }
}

private struct WhatsNextRow: View {
    enum Icon {
        case image(Image)
        case system(String)
    }

    let icon: Icon
    let title: String
    let detail: String

    init(iconImage: Image, title: String, body: String) {
        self.icon = .image(iconImage)
        self.title = title
        self.detail = body
    }

    init(systemIcon: String, title: String, body: String) {
        self.icon = .system(systemIcon)
        self.title = title
        self.detail = body
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            iconView
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case .image(let image):
            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
        case .system(let name):
            Image(systemName: name)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}
