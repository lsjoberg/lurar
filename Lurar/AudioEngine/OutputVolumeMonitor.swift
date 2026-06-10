import Foundation
import CoreAudio
import Combine
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "OutputVolumeMonitor")

/// Mirrors the active output device's hardware volume so the menu bar icon can
/// show it live (issue #118). Display-only: it never writes volume — the OS
/// volume keys remain the control surface.
///
/// Owns Core Audio property listeners (volume + mute) on the current device and
/// rebinds them whenever the selected output changes; the listeners are keyed
/// by `AudioDeviceID`, which differs per device. Mirrors `DeviceManager`'s
/// listener-ownership style: hold the listener objects, drop them to deregister
/// (their `deinit` removes the block).
@MainActor
final class OutputVolumeMonitor: ObservableObject {
    /// Current output volume as 0...1, or `nil` when the device has no software
    /// volume control (HDMI, optical, fixed line-outs). The menu bar falls back
    /// to the plain brand mark in that case.
    @Published private(set) var volume: Float?
    @Published private(set) var isMuted: Bool = false

    private var boundDeviceID: AudioDeviceID?
    private var volumeListener: AudioDevicePropertyListener?
    private var muteListener: AudioDevicePropertyListener?

    /// Point the monitor at a new output device (or `nil` to tear down). Re-reads
    /// synchronously so the published values aren't stale for a notification
    /// cycle, then installs fresh listeners. No-op if already bound to `deviceID`.
    func rebind(to deviceID: AudioDeviceID?) {
        guard deviceID != boundDeviceID else { return }
        boundDeviceID = deviceID

        guard let deviceID else {
            volumeListener = nil
            muteListener = nil
            volume = nil
            isMuted = false
            return
        }

        readNow(deviceID)

        // The listener fires on the main queue, but its handler type isn't
        // main-actor-isolated; hop explicitly like DeviceManager does.
        // Wildcard element so we still hear changes on devices that publish
        // volume per channel (elements 1/2) rather than on the main element.
        volumeListener = AudioDevicePropertyListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioObjectPropertyScopeOutput,
            element: kAudioObjectPropertyElementWildcard
        ) { [weak self] in
            Task { @MainActor in self?.readNow(deviceID) }
        }
        muteListener = AudioDevicePropertyListener(
            deviceID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        ) { [weak self] in
            Task { @MainActor in self?.readNow(deviceID) }
        }
        log.debug("Bound output volume monitor to device \(deviceID)")
    }

    private func readNow(_ deviceID: AudioDeviceID) {
        // Ignore late callbacks from a device we've since rebound away from.
        guard deviceID == boundDeviceID else { return }
        let newVolume = CoreAudioVolume.scalar(for: deviceID)
        let newMuted = CoreAudioVolume.isMuted(for: deviceID)
        if newVolume != volume { volume = newVolume }
        if newMuted != isMuted { isMuted = newMuted }
    }
}
