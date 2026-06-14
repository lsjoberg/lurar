import Foundation
import CoreAudio
import AudioToolbox
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "CoreAudio")

// MARK: - Errors

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case noDefaultDevice
    case deviceNotFound(String)
    case sampleRateUnsupported(Double)

    var description: String {
        switch self {
        case .osStatus(let code, let context):
            return "OSStatus \(code) (\(fourCharCode(code))) — \(context)"
        case .noDefaultDevice: return "No default audio device"
        case .deviceNotFound(let id): return "Device not found: \(id)"
        case .sampleRateUnsupported(let sr): return "Sample rate \(sr) Hz not supported on device"
        }
    }
}

private func fourCharCode(_ code: OSStatus) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff)
    ]
    if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) {
        return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
    }
    return "\(code)"
}

@discardableResult
private func check(_ status: OSStatus, _ context: @autoclosure () -> String) throws -> OSStatus {
    if status != noErr { throw CoreAudioError.osStatus(status, context()) }
    return status
}

// MARK: - Device representation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
    let hasInput: Bool
    let hasOutput: Bool
}

// MARK: - Device enumeration

enum CoreAudioDevices {
    static func all() -> [AudioDevice] {
        do {
            let ids = try systemDeviceIDs()
            return ids.compactMap { try? device(for: $0) }
        } catch {
            log.error("Failed to enumerate devices: \(String(describing: error))")
            return []
        }
    }

    static func defaultOutput() -> AudioDevice? {
        guard let id = try? defaultDeviceID(scope: kAudioHardwarePropertyDefaultOutputDevice) else { return nil }
        return try? device(for: id)
    }

    static func setDefaultOutput(id: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        try check(
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID),
            "set default output device"
        )
    }

    private static func systemDeviceIDs() throws -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size),
            "kAudioHardwarePropertyDevices size"
        )
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids),
            "kAudioHardwarePropertyDevices data"
        )
        return ids
    }

    private static func defaultDeviceID(scope selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id),
            "default device"
        )
        guard id != 0 else { throw CoreAudioError.noDefaultDevice }
        return id
    }

    private static func device(for id: AudioDeviceID) throws -> AudioDevice {
        let name = (try? stringProperty(id: id, selector: kAudioObjectPropertyName)) ?? "Unknown"
        let uid = (try? stringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)) ?? ""
        let manufacturer = (try? stringProperty(id: id, selector: kAudioObjectPropertyManufacturer)) ?? ""
        let inputChans = streamChannelCount(id: id, scope: kAudioObjectPropertyScopeInput)
        let outputChans = streamChannelCount(id: id, scope: kAudioObjectPropertyScopeOutput)
        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            manufacturer: manufacturer,
            hasInput: inputChans > 0,
            hasOutput: outputChans > 0
        )
    }

    private static func stringProperty(id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfRef),
            "string property \(fourCharCode(OSStatus(bitPattern: selector)))"
        )
        // Core Audio returns +1 retained CFString for these properties — take ownership.
        guard let cf = cfRef?.takeRetainedValue() else { return "" }
        return cf as String
    }

    private static func streamChannelCount(id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufferList) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - Sample rate

enum CoreAudioSampleRate {
    static func nominal(for id: AudioDeviceID) throws -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sr: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        try check(
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &sr),
            "nominal sample rate get"
        )
        return sr
    }

    static func setNominal(_ rate: Double, for id: AudioDeviceID) throws {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sr = rate
        try check(
            AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &sr),
            "nominal sample rate set to \(rate)"
        )
    }

    static func available(for id: AudioDeviceID) -> [ClosedRange<Double>] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map { $0.mMinimum...$0.mMaximum }
    }

    static func supports(_ rate: Double, for id: AudioDeviceID) -> Bool {
        available(for: id).contains { $0.contains(rate) }
    }

    /// Returns a sample rate both devices support. Prefers existing match, then 96k, then 48k, then 44.1k.
    static func reconcile(input: AudioDeviceID, output: AudioDeviceID) throws -> Double {
        let inRate = try nominal(for: input)
        let outRate = try nominal(for: output)
        if abs(inRate - outRate) < 0.5 { return inRate }
        log.info("Sample rate differs — input \(inRate) Hz, output \(outRate) Hz; picking a common rate")
        for candidate in [96000.0, 48000.0, 44100.0] {
            if supports(candidate, for: input) && supports(candidate, for: output) {
                return candidate
            }
        }
        throw CoreAudioError.sampleRateUnsupported(96000)
    }
}

// MARK: - Output volume

/// Reads the output device's own hardware volume so the menu bar can mirror
/// the system volume indicator. There's no DSP here — this is the device's
/// `kAudioDevicePropertyVolumeScalar`, the same value the macOS volume keys
/// and Control Center drive. Display-only: no setter (see issue #118).
enum CoreAudioVolume {
    /// Current output volume as 0...1, or `nil` when the device exposes no
    /// software volume control (HDMI, optical, many pro interfaces and fixed
    /// line-outs). Tries the main element first, then averages the per-channel
    /// scalars — some devices only publish volume per channel, not on main.
    static func scalar(for id: AudioDeviceID) -> Float? {
        if let main = channelScalar(for: id, element: kAudioObjectPropertyElementMain) {
            return main
        }
        // Fall back to per-channel (typically elements 1 and 2 for stereo).
        var values: [Float] = []
        for element in UInt32(1)...UInt32(2) {
            if let v = channelScalar(for: id, element: element) { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    /// Whether the output device is muted. Absent mute property ⇒ not muted.
    static func isMuted(for id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }

    private static func channelScalar(for id: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return Float(value)
    }
}

// MARK: - HAL AU helpers

enum AUHAL {
    /// Log the AU's component description for diagnostics.
    static func logComponentDescription(_ au: AudioUnit, label: String) {
        var desc = AudioComponentDescription()
        let comp = AudioComponentInstanceGetComponent(au)
        AudioComponentGetDescription(comp, &desc)
        log.info("\(label) AU component: type=\(fourCharCode(OSStatus(bitPattern: desc.componentType))) subType=\(fourCharCode(OSStatus(bitPattern: desc.componentSubType))) manufacturer=\(fourCharCode(OSStatus(bitPattern: desc.componentManufacturer)))")
    }

    /// Raise an AU's `MaximumFramesPerSlice` so it can absorb bursty large render calls. The
    /// 512-frame default trips `-10874 kAudioUnitErr_TooManyFramesToProcess` on the ~1100-frame
    /// bursts that HAL inputs emit during sample-rate transitions.
    static func setMaxFramesPerSlice(_ frames: UInt32, on au: AudioUnit?) {
        guard let au else { return }
        var f = frames
        let status = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &f,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if status != noErr {
            log.warning("setMaxFramesPerSlice(\(frames)) returned \(status); continuing.")
        }
    }
}

// MARK: - Device-list change listener

final class DeviceChangeListener {
    typealias Handler = () -> Void

    private let handler: Handler
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var block: AudioObjectPropertyListenerBlock?

    init(handler: @escaping Handler) {
        self.handler = handler
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handler()
        }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            log.error("Failed to register device change listener: \(status)")
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }
}

// MARK: - Default output device listener

/// Listens for changes to the system's default output device
/// (`kAudioHardwarePropertyDefaultOutputDevice`). Parallels
/// `DeviceChangeListener`, which only fires on topology changes.
/// Needed so Lurar can react when macOS auto-switches output (e.g. AirPods
/// connecting) without the device list itself changing.
final class DefaultOutputDeviceListener {
    typealias Handler = () -> Void

    private let handler: Handler
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var block: AudioObjectPropertyListenerBlock?

    init(handler: @escaping Handler) {
        self.handler = handler
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handler()
        }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            log.error("Failed to register default-output device listener: \(status)")
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }
}

// MARK: - Per-device property listener

/// Listens for a single property change on a specific Core Audio device and calls the handler
/// on the main queue. Used to detect runtime sample-rate / format changes on the active input
/// or output so the engine can re-reconcile.
final class AudioDevicePropertyListener {
    typealias Handler = () -> Void

    private let deviceID: AudioDeviceID
    private let handler: Handler
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        handler: @escaping Handler
    ) {
        self.deviceID = deviceID
        self.handler = handler
        self.address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handler()
        }
        self.block = block
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            log.error("Failed to register device property listener (device=\(deviceID), selector=\(fourCharCode(OSStatus(bitPattern: selector)))): \(status)")
        }
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            block
        )
    }
}
