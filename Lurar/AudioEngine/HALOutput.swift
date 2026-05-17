import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import OSLog

private let log = Logger(subsystem: "app.lurar.Lurar", category: "HALOutput")

/// Owns a HAL Output Audio Unit bound to a specific Core Audio device, pulling samples from a
/// stereo ring buffer in its render callback. We use this instead of AVAudioEngine.outputNode
/// because AVAudioEngine on macOS aggressively rebinds its output AU's CurrentDevice to the
/// system default, defeating any attempt to route to a different output device.
final class HALOutput {
    private var au: AudioUnit?
    let ringBuffer: StereoFloatRingBuffer
    private(set) var deviceID: AudioDeviceID = 0

    init(ringBuffer: StereoFloatRingBuffer) {
        self.ringBuffer = ringBuffer
    }

    deinit { try? stop() }

    func start(deviceID: AudioDeviceID, clientFormat: AVAudioFormat) throws {
        try stop()
        ringBuffer.reset()

        // Find and instantiate the HAL Output AU.
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CoreAudioError.osStatus(-1, "find HAL Output component")
        }
        var instance: AudioUnit?
        let createStatus = AudioComponentInstanceNew(component, &instance)
        if createStatus != noErr {
            throw CoreAudioError.osStatus(createStatus, "instantiate HAL Output")
        }
        guard let au = instance else { throw CoreAudioError.osStatus(-1, "HAL Output instance nil") }
        self.au = au

        // Bind device — fresh AU is uninitialized so this just works.
        var id = deviceID
        let devStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if devStatus != noErr {
            throw CoreAudioError.osStatus(devStatus, "HALOutput set CurrentDevice (id=\(deviceID))")
        }

        // Client stream format on input scope of element 0 (the bus we feed via render callback).
        var asbd = clientFormat.streamDescription.pointee
        let fmtStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if fmtStatus != noErr {
            throw CoreAudioError.osStatus(fmtStatus, "HALOutput set StreamFormat")
        }

        // Render callback.
        var callback = AURenderCallbackStruct(
            inputProc: HALOutput.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let cbStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if cbStatus != noErr {
            throw CoreAudioError.osStatus(cbStatus, "HALOutput set render callback")
        }

        let initStatus = AudioUnitInitialize(au)
        if initStatus != noErr {
            throw CoreAudioError.osStatus(initStatus, "HALOutput initialize")
        }

        let startStatus = AudioOutputUnitStart(au)
        if startStatus != noErr {
            throw CoreAudioError.osStatus(startStatus, "HALOutput start")
        }

        self.deviceID = deviceID
        log.info("HALOutput started on device \(deviceID) with format \(clientFormat)")
    }

    func stop() throws {
        guard let au = au else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        self.au = nil
        deviceID = 0
    }

    // MARK: - Render callback (audio thread)

    private static let renderCallback: AURenderCallback = { refCon, _, _, _, numFrames, ioData in
        let me = Unmanaged<HALOutput>.fromOpaque(refCon).takeUnretainedValue()
        return me.render(ioData: ioData, numFrames: numFrames)
    }

    private func render(ioData: UnsafeMutablePointer<AudioBufferList>?, numFrames: UInt32) -> OSStatus {
        guard let ioData = ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)

        // Non-interleaved stereo: expect 2 buffers, one per channel.
        if abl.count >= 2,
           let leftRaw = abl[0].mData,
           let rightRaw = abl[1].mData {
            let left = leftRaw.assumingMemoryBound(to: Float.self)
            let right = rightRaw.assumingMemoryBound(to: Float.self)
            ringBuffer.read(left: left, right: right, frames: Int(numFrames))
            return noErr
        }

        // Interleaved fallback — shouldn't happen with our explicit format, but handle defensively.
        if abl.count == 1,
           let raw = abl[0].mData {
            let interleaved = raw.assumingMemoryBound(to: Float.self)
            // Read into a temporary stereo pair, then interleave.
            let n = Int(numFrames)
            let tmpL = UnsafeMutablePointer<Float>.allocate(capacity: n)
            let tmpR = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { tmpL.deallocate(); tmpR.deallocate() }
            ringBuffer.read(left: tmpL, right: tmpR, frames: n)
            for i in 0..<n {
                interleaved[i * 2] = tmpL[i]
                interleaved[i * 2 + 1] = tmpR[i]
            }
            return noErr
        }

        // Fill silence if buffer shape is unexpected.
        for i in 0..<abl.count {
            if let raw = abl[i].mData {
                memset(raw, 0, Int(abl[i].mDataByteSize))
            }
        }
        return noErr
    }
}
