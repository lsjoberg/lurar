import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation
import OSLog

private let log = Logger(subsystem: "se.linus.klang", category: "HALInput")

/// Owns a HAL Output Audio Unit configured for input-only on bus 1, bound to a specific
/// Core Audio device (e.g. BlackHole). On every input device tick, the AU invokes our
/// input callback; we `AudioUnitRender` into a pre-allocated scratch buffer and forward
/// the samples to the `frameHandler` closure on the audio thread.
final class HALInput {
    typealias FrameHandler = (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Void

    private(set) var deviceID: AudioDeviceID = 0

    private var au: AudioUnit?
    private var frameHandler: FrameHandler?

    /// Pre-allocated AudioBufferList header (mNumberBuffers=2) sized for `maxFrames` frames.
    /// The mData pointers point into `leftScratch` / `rightScratch`. We reuse this on
    /// every callback — no allocation in the audio path.
    private var scratchABL: UnsafeMutablePointer<AudioBufferList>?
    private var leftScratch: UnsafeMutablePointer<Float>?
    private var rightScratch: UnsafeMutablePointer<Float>?
    private var scratchCapacityFrames: Int = 0

    private let maxFrames: UInt32 = 4096

    deinit { try? stop() }

    func start(deviceID: AudioDeviceID, clientFormat: AVAudioFormat, frameHandler: @escaping FrameHandler) throws {
        try stop()

        self.frameHandler = frameHandler

        // 1. Instantiate a HALOutput AU (yes, the input AU is also subtype HALOutput; the
        //    distinction is which bus is enabled and which device is bound).
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CoreAudioError.osStatus(-1, "find HALOutput component (for input)")
        }
        var instance: AudioUnit?
        let createStatus = AudioComponentInstanceNew(component, &instance)
        if createStatus != noErr {
            throw CoreAudioError.osStatus(createStatus, "instantiate input AU")
        }
        guard let au = instance else {
            throw CoreAudioError.osStatus(-1, "input AU instance nil")
        }
        self.au = au

        // 2. Enable input on bus 1, disable output on bus 0.
        var enable: UInt32 = 1
        let enableStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enable,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if enableStatus != noErr {
            throw CoreAudioError.osStatus(enableStatus, "enable input bus 1")
        }
        var disable: UInt32 = 0
        let disableStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disable,
            UInt32(MemoryLayout<UInt32>.size)
        )
        if disableStatus != noErr {
            log.info("disable output bus 0 returned \(disableStatus); continuing")
        }

        // 3. Bind to the chosen device.
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
            throw CoreAudioError.osStatus(devStatus, "set input AU CurrentDevice (id=\(deviceID))")
        }

        // 4. Set client stream format on element 1 OUTPUT scope (what the AU produces
        //    after its internal converter reconciles with the hardware format). Log the
        //    hardware format too, for diagnostics.
        var hwFormat = AudioStreamBasicDescription()
        var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hwFormat, &hwSize) == noErr {
            log.info("input AU hw format: \(hwFormat.mChannelsPerFrame) ch, \(hwFormat.mSampleRate) Hz")
        }

        var asbd = clientFormat.streamDescription.pointee
        let fmtStatus = AudioUnitSetProperty(
            au,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        if fmtStatus != noErr {
            throw CoreAudioError.osStatus(fmtStatus, "set input AU client StreamFormat")
        }

        // 5. Raise MaximumFramesPerSlice; default 512 can be tripped by ~1100-frame bursts
        //    during sample-rate transitions.
        AUHAL.setMaxFramesPerSlice(maxFrames, on: au)

        // 6. Pre-allocate the scratch AudioBufferList + L/R float buffers.
        allocateScratch(maxFrames: Int(maxFrames))

        // 7. Install input callback (note: SetInputCallback, NOT SetRenderCallback).
        var callback = AURenderCallbackStruct(
            inputProc: HALInput.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let cbStatus = AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if cbStatus != noErr {
            throw CoreAudioError.osStatus(cbStatus, "set input callback")
        }

        let initStatus = AudioUnitInitialize(au)
        if initStatus != noErr {
            throw CoreAudioError.osStatus(initStatus, "initialize input AU")
        }

        let startStatus = AudioOutputUnitStart(au)
        if startStatus != noErr {
            throw CoreAudioError.osStatus(startStatus, "start input AU")
        }

        self.deviceID = deviceID
        log.info("HALInput started on device \(deviceID) with client \(clientFormat)")
    }

    func stop() throws {
        if let au = au {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        au = nil
        frameHandler = nil
        deviceID = 0
        freeScratch()
    }

    // MARK: - Scratch buffer management

    private func allocateScratch(maxFrames: Int) {
        freeScratch()
        leftScratch = .allocate(capacity: maxFrames)
        rightScratch = .allocate(capacity: maxFrames)
        leftScratch!.initialize(repeating: 0, count: maxFrames)
        rightScratch!.initialize(repeating: 0, count: maxFrames)

        // AudioBufferList with 2 buffers — allocate raw bytes sized for the flexible array.
        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size  // header has 1 inline, +1 more
        let raw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = 2
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        buffers[0] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(leftScratch!)
        )
        buffers[1] = AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: UInt32(maxFrames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(rightScratch!)
        )
        scratchABL = abl
        scratchCapacityFrames = maxFrames
    }

    private func freeScratch() {
        if let abl = scratchABL {
            UnsafeMutableRawPointer(abl).deallocate()
            scratchABL = nil
        }
        if let p = leftScratch { p.deallocate(); leftScratch = nil }
        if let p = rightScratch { p.deallocate(); rightScratch = nil }
        scratchCapacityFrames = 0
    }

    // MARK: - Audio thread

    private static let inputCallback: AURenderCallback = { refCon, ioActionFlags, timestamp, busNumber, numFrames, _ in
        let me = Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue()
        return me.handleInput(flags: ioActionFlags, timestamp: timestamp, bus: busNumber, frames: numFrames)
    }

    private func handleInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let au = au, let abl = scratchABL else { return noErr }
        guard Int(frames) <= scratchCapacityFrames else {
            // Burst bigger than our scratch — drop, the next callback will catch up.
            return noErr
        }

        // Re-set per-buffer byte size to match the requested frame count. The AU writes into
        // our mData pointers verbatim; mDataByteSize is the contract for how many bytes are valid.
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let bytes = UInt32(Int(frames) * MemoryLayout<Float>.size)
        buffers[0].mDataByteSize = bytes
        buffers[1].mDataByteSize = bytes

        let status = AudioUnitRender(au, flags, timestamp, bus, frames, abl)
        if status != noErr {
            return status
        }

        if let handler = frameHandler, let l = leftScratch, let r = rightScratch {
            handler(l, r, Int(frames))
        }
        return noErr
    }
}
