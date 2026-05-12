import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "CoreAudio")

// MARK: - Errors

enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)
    case noDefaultDevice
    case deviceNotFound(String)
    case audioUnitMissing
    case sampleRateUnsupported(Double)

    var description: String {
        switch self {
        case .osStatus(let code, let context):
            return "OSStatus \(code) (\(fourCharCode(code))) — \(context)"
        case .noDefaultDevice: return "No default audio device"
        case .deviceNotFound(let id): return "Device not found: \(id)"
        case .audioUnitMissing: return "AVAudioNode has no underlying AudioUnit"
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

    var isBlackHole: Bool {
        name.localizedCaseInsensitiveContains("BlackHole")
    }

    var isHiFiMan: Bool {
        name.localizedCaseInsensitiveContains("HIFIMAN")
            || manufacturer.localizedCaseInsensitiveContains("HIFIMAN")
    }
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

    static func defaultInput() -> AudioDevice? {
        guard let id = try? defaultDeviceID(scope: kAudioHardwarePropertyDefaultInputDevice) else { return nil }
        return try? device(for: id)
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
        log.warning("Sample rate mismatch — input \(inRate) Hz, output \(outRate) Hz")
        for candidate in [96000.0, 48000.0, 44100.0] {
            if supports(candidate, for: input) && supports(candidate, for: output) {
                return candidate
            }
        }
        throw CoreAudioError.sampleRateUnsupported(96000)
    }
}

// MARK: - AUHAL binding (binds AVAudioEngine input/output nodes to specific devices)

enum AUHAL {
    /// Log the AU's component description so we know what kind of unit AVAudioEngine actually
    /// gave us. DefaultOutput vs HALOutput is the critical distinction.
    static func logComponentDescription(_ au: AudioUnit, label: String) {
        var desc = AudioComponentDescription()
        let comp = AudioComponentInstanceGetComponent(au)
        AudioComponentGetDescription(comp, &desc)
        log.info("\(label) AU component: type=\(fourCharCode(OSStatus(bitPattern: desc.componentType))) subType=\(fourCharCode(OSStatus(bitPattern: desc.componentSubType))) manufacturer=\(fourCharCode(OSStatus(bitPattern: desc.componentManufacturer)))")
    }

    /// Bind the engine's output node to the given device and configure its client stream format.
    /// The format passed in is what AVAudioEngine will feed into the output AU's Input scope on
    /// element 0; the AU then converts it to the device's native format on its Output scope.
    static func bindOutput(_ deviceID: AudioDeviceID, to node: AVAudioOutputNode, clientFormat: AVAudioFormat) throws {
        guard let au = node.audioUnit else { throw CoreAudioError.audioUnitMissing }
        logComponentDescription(au, label: "output")

        let uninitStatus = AudioUnitUninitialize(au)
        log.info("output AU uninit status: \(uninitStatus)")

        var id = deviceID
        try check(
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "set output AU CurrentDevice (id=\(deviceID))"
        )

        var asbd = clientFormat.streamDescription.pointee
        try check(
            AudioUnitSetProperty(
                au,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0, // element 0 = the bus we feed
                &asbd,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "set output AU client StreamFormat"
        )

        let initStatus = AudioUnitInitialize(au)
        log.info("output AU init status: \(initStatus)")
        if initStatus != noErr {
            throw CoreAudioError.osStatus(initStatus, "initialize output AU after bind")
        }
    }

    /// Bind the engine's input node to the given device. Also enables IO on bus 1 (input) and
    /// disables IO on bus 0 (output) of the underlying AUHAL, which is required when the input
    /// node is being used as a non-default input source.
    /// Bind the input AU to the given device, then force its client stream format on the OUTPUT
    /// scope of element 1. The AU's internal converter reconciles the hardware format (whatever
    /// the device actually delivers) with the client format we want. Returns the actual format
    /// passed in, for chaining.
    @discardableResult
    static func bindInput(_ deviceID: AudioDeviceID, to node: AVAudioInputNode, clientFormat: AVAudioFormat) throws -> AVAudioFormat {
        guard let au = node.audioUnit else { throw CoreAudioError.audioUnitMissing }

        let uninitStatus = AudioUnitUninitialize(au)
        log.info("input AU uninit status: \(uninitStatus)")

        var enable: UInt32 = 1
        try check(
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input,
                1,
                &enable,
                UInt32(MemoryLayout<UInt32>.size)
            ),
            "enable input AU bus 1"
        )

        var disable: UInt32 = 0
        let dStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disable,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if dStatus != noErr {
            log.info("Disabling bus 0 on input AU returned \(dStatus); continuing.")
        }

        var id = deviceID
        try check(
            AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            ),
            "set input AU CurrentDevice (id=\(deviceID))"
        )

        // Log the hardware format for diagnostics; we don't actually need it because the AU's
        // built-in converter handles hw→client conversion.
        var hwFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hwFormat, &size) == noErr {
            log.info("input AU hw format: \(hwFormat.mChannelsPerFrame) ch, \(hwFormat.mSampleRate) Hz")
        }

        var clientASBD = clientFormat.streamDescription.pointee
        try check(
            AudioUnitSetProperty(
                au,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &clientASBD,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ),
            "set input AU client StreamFormat (\(clientFormat))"
        )

        let initStatus = AudioUnitInitialize(au)
        log.info("input AU init status: \(initStatus)")
        if initStatus != noErr {
            throw CoreAudioError.osStatus(initStatus, "initialize input AU after bind")
        }

        return clientFormat
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
