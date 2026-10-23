import CoreAudio
import Foundation
import AppKit
import Combine
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "VoIPMonitor")

final class VoIPMonitor: ObservableObject {
    @Published var isInputActive: Bool = false
    private let queue = DispatchQueue(label: "app.lurar.VoIPMonitor", qos: .utility)
    
    init() {
        startPolling()
    }
    
    private func startPolling() {
        queue.async { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        checkStatus()
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.poll()
        }
    }
    
    private func checkStatus() {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        guard AudioObjectGetPropertyDataSize(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        
        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return }
        
        var currentlyActive = false
        
        for device in devices {
            var streamSize: UInt32 = 0
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) != noErr || streamSize == 0 {
                continue
            }
            
            var isRunning: UInt32 = 0
            var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
            var isRunningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device, &isRunningAddress, 0, nil, &isRunningSize, &isRunning) == noErr {
                if isRunning != 0 {
                    currentlyActive = true
                    break
                }
            }
        }
        
        // Single synchronous snapshot from the main actor.
        let voipSet: Set<String> = DispatchQueue.main.sync { VoIPAppsStore.shared.voipBundleIDs }
        
        // Check both Core Audio process objects (captures daemons like avconferenced) and GUI apps
        var isVoIPActiveInAudio = false
        if let procs = try? AudioProcessInfo.allProcessObjects() {
            for proc in procs {
                if let bid = AudioProcessInfo.bundleID(for: proc), voipSet.contains(bid) {
                    var isInputAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioProcessPropertyIsRunningInput,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )
                    var isRunningInput: UInt32 = 0
                    var s = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(proc, &isInputAddr, 0, nil, &s, &isRunningInput) == noErr, isRunningInput != 0 {
                        isVoIPActiveInAudio = true
                        break
                    }
                }
            }
        }

        let isVoIPAppRunning = isVoIPActiveInAudio || NSWorkspace.shared.runningApplications.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return voipSet.contains(bundleID)
        }
        
        let shouldBypass = (currentlyActive && isVoIPAppRunning) || isVoIPActiveInAudio
        
        // Read and update the @Published property exclusively on the main queue.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if shouldBypass && !self.isInputActive {
                log.info("VoIP Monitor: Input active and VoIP app running. Suspending.")
                self.isInputActive = true
            } else if !shouldBypass && self.isInputActive {
                log.info("VoIP Monitor: Input inactive or VoIP app closed. Resuming.")
                self.isInputActive = false
            }
        }
    }
}
