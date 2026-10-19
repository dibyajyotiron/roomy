import Foundation
import CoreAudio
import CoreMediaIO
import IOKit.pwr_mgt

/// Whether any app is using a camera or microphone right now. Read from the devices' own "running somewhere" flags,
/// which needs no camera or microphone permission and never opens a device.
enum Presence {
    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var ids = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        for id in ids {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0, got: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == 0, running != 0 { return true }
        }
        return false
    }

    static func microphoneInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            // Only devices with input channels are microphones.
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { continue }
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0, s = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &s, &running) == noErr, running != 0 { return true }
        }
        return false
    }
}

/// Keeps the Mac (and optionally the display) awake while Roomy is open, with macOS's own power assertions.
/// They end when you switch them off or Roomy quits; nothing is changed in Energy settings.
@MainActor @Observable
final class KeepAwake {
    static let shared = KeepAwake()
    var system = false { didSet { set(&systemID, on: system, type: kIOPMAssertionTypePreventUserIdleSystemSleep, why: "Roomy: Keep awake") } }
    var display = false { didSet { set(&displayID, on: display, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, why: "Roomy: Keep the screen on") } }
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0

    private func set(_ id: inout IOPMAssertionID, on: Bool, type: String, why: String) {
        if on, id == 0 {
            var new: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), why as CFString, &new) == kIOReturnSuccess { id = new }
        } else if !on, id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
}
