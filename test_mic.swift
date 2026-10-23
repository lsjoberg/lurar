import CoreAudio
import Foundation

var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

AudioObjectGetPropertyData(UInt32(kAudioObjectSystemObject), &address, 0, nil, &size, &inputDeviceID)

var isRunning: UInt32 = 0
var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
var isRunningAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunning,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)

AudioObjectGetPropertyData(inputDeviceID, &isRunningAddress, 0, nil, &isRunningSize, &isRunning)

print("Mic running: \(isRunning)")
