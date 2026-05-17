import AppKit
import SwiftUI

/// Pre-prompt / recovery window for the system audio-capture TCC permission.
///
/// Two modes, picked from the live TCC state when the window first appears:
///
/// - **Initial**: TCC has never been prompted (`preflight == .unknown`). The
///   OS dialog is about to fire when we call into the request path. We show
///   our welcome copy first because raw TCC otherwise gives users no context
///   — they see "Klang would like to use audio input" with no explanation
///   of what that means in this app or that we never record or transmit.
///
/// - **Denied**: TCC previously denied (`preflight == .denied`) — either the
///   user said no in the OS dialog or revoked via System Settings. TCC won't
///   re-prompt, so the only path back through is Privacy & Security. We show
///   numbered steps and a Settings deep link.
///
/// Mode is frozen at presentation time (captured in `@State` on `onAppear`)
/// so the copy doesn't swap underneath the user mid-interaction. Continue
/// from initial mode flips to denied in-place if the OS denies the prompt,
/// rather than dismissing and stranding the user.
struct OnboardingPermissionView: View {
    enum Mode {
        case initial
        case denied
    }

    @ObservedObject var engine: EQEngine
    @ObservedObject var deviceManager: DeviceManager

    @Environment(\.dismiss) private var dismiss

    /// Captured from live preflight on first appearance. Becomes `.denied`
    /// in-place if Continue triggers an OS denial.
    @State private var mode: Mode = .initial

    /// Latches when the user clicks "Try again" and the request path still
    /// reports blocked. Surfaces a hint about ad-hoc-signed dev builds
    /// needing a full app relaunch (TCC tracks apps by code signature, and
    /// the running process can hold a stale denied verdict after a Settings
    /// flip).
    @State private var retryFailed: Bool = false

    var body: some View {
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
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(28)
        .frame(width: 480)
        .onAppear {
            // Pick the mode that matches the actual TCC state right now.
            // .authorized shouldn't reach this window (MenuBarView only
            // opens it when not authorized) but treat it like initial for
            // safety — no UI harm done.
            mode = AudioCapturePermission.preflight() == .denied ? .denied : .initial
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: mode == .denied ? "exclamationmark.shield" : "waveform.path.ecg")
                .font(.system(size: 32))
                .foregroundStyle(mode == .denied ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .denied
                     ? "Audio capture is blocked"
                     : "Welcome to Klang")
                    .font(.title2.weight(.semibold))
                Text(mode == .denied
                     ? "macOS won't re-prompt — here's how to re-enable it."
                     : "One quick permission and you're set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Initial mode

    private var initialExplanation: some View {
        Text("macOS will ask you to allow audio capture next. This lets Klang receive sound from your apps so it can apply EQ before it reaches your headphones.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var initialInstruction: some View {
        Text("When you click Continue, macOS will show a permission dialog. Choose **Allow**.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Denied mode

    private var deniedExplanation: some View {
        Text("Klang's audio-capture permission was denied. macOS only asks once — after that it has to be re-enabled manually in System Settings.")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deniedInstruction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To re-enable:")
                .font(.callout.weight(.semibold))
            stepRow("1.", "Click **Open System Settings** below.")
            stepRow("2.", "Find **Klang** under **Privacy & Security → Audio Capture**.")
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
                Text("macOS sometimes caches the previous decision. Try quitting Klang (⌘Q) and reopening — if the System Settings toggle still doesn't take, run ") + Text("`tccutil reset AudioCapture se.linus.klang`").font(.callout.monospaced()) + Text(" in Terminal and try again.")
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.top, 4)
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

    // MARK: - Shared

    private var reassurance: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.green)
            Text("Klang does not record, store, or transmit audio.")
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var buttons: some View {
        switch mode {
        case .initial:
            HStack {
                Spacer()
                Button("Not now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    continueFromInitial()
                }
                .keyboardShortcut(.defaultAction)
            }
        case .denied:
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open System Settings") {
                    openAudioCaptureSettings()
                }
                Button("Try again") {
                    retryStart()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Trigger the real OS prompt via ensureAuthorized(). If the user allows,
    /// start the engine and dismiss. If the OS denies, flip the window into
    /// denied mode in place rather than dismissing — otherwise the user is
    /// stranded with the engine still off and no on-screen guidance.
    private func continueFromInitial() {
        if AudioCapturePermission.ensureAuthorized() {
            if let output = deviceManager.selectedOutput {
                engine.start(output: output)
            } else {
                engine.reportStartFailure("Pick an output device first")
            }
            dismiss()
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
            if let output = deviceManager.selectedOutput {
                engine.start(output: output)
            } else {
                engine.reportStartFailure("Pick an output device first")
            }
            dismiss()
        } else {
            retryFailed = true
        }
    }

    /// Deep-link to System Settings → Privacy & Security → Audio Capture.
    /// The Sonoma URL scheme lands directly on the audio-capture pane; on
    /// older systems or if Apple changes the anchor, this just opens the
    /// Privacy section and the user follows the in-window steps.
    private func openAudioCaptureSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
