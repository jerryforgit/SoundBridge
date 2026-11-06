import Foundation
import CoreAudio

let kSoundBridgeDeviceUID = "com.jerry.soundbridge.device"

func getFloat32Scoped(_ object: AudioObjectID,
                      _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Float32? {
    var address = propAddr(selector, scope, element)
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func setFloat32Scoped(_ object: AudioObjectID,
                      _ selector: AudioObjectPropertySelector,
                      value: Float32,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                      element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> OSStatus {
    var address = propAddr(selector, scope, element)
    var value = value
    let size = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectSetPropertyData(object, &address, 0, nil, size, &value)
}

func setUInt32Scoped(_ object: AudioObjectID,
                     _ selector: AudioObjectPropertySelector,
                     value: UInt32,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> OSStatus {
    var address = propAddr(selector, scope, element)
    var value = value
    let size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectSetPropertyData(object, &address, 0, nil, size, &value)
}

func soundBridgeDeviceID() -> AudioDeviceID? {
    findDevice(uid: kSoundBridgeDeviceUID)
}

func getSoundBridgeVolume() -> Float32? {
    guard let id = soundBridgeDeviceID() else { return nil }
    return getVolume(for: id)
}

func getVolume(for id: AudioDeviceID) -> Float32? {
    if let value = getFloat32Scoped(id, kAudioDevicePropertyVolumeScalar,
                                    scope: kAudioObjectPropertyScopeOutput) {
        return value
    }
    // 回退：从 ControlList 里找主音量控件
    for control in objectIDsForApp(id, kAudioObjectPropertyControlList) {
        let cls = getUInt32(control, kAudioObjectPropertyClass) ?? 0
        if cls == kAudioVolumeControlClassID {
            return getFloat32Scoped(control, kAudioLevelControlPropertyScalarValue,
                                    scope: kAudioObjectPropertyScopeOutput)
        }
    }
    return nil
}

func setSoundBridgeVolume(_ value: Float32) -> OSStatus {
    guard let id = soundBridgeDeviceID() else { return kAudioHardwareBadObjectError }
    return setFloat32Scoped(id, kAudioDevicePropertyVolumeScalar, value: value,
                            scope: kAudioObjectPropertyScopeOutput)
}

func getSoundBridgeMute() -> Bool {
    guard let id = soundBridgeDeviceID() else { return false }
    return getMute(for: id)
}

func getMute(for id: AudioDeviceID) -> Bool {
    (getUInt32(id, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) ?? 0) != 0
}

func setSoundBridgeMute(_ muted: Bool) -> OSStatus {
    guard let id = soundBridgeDeviceID() else { return kAudioHardwareBadObjectError }
    return setUInt32Scoped(id, kAudioDevicePropertyMute, value: muted ? 1 : 0,
                           scope: kAudioObjectPropertyScopeOutput)
}

func currentDefaultOutputID() -> AudioDeviceID? {
    var address = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectGetPropertyData(kSystemObject, &address, 0, nil, &size, &id) == noErr ? id : nil
}

func setDefaultOutput(_ id: AudioDeviceID) {
    var address = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var value = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectSetPropertyData(kSystemObject, &address, 0, nil, size, &value)

    address = propAddr(kAudioHardwarePropertyDefaultSystemOutputDevice)
    _ = AudioObjectSetPropertyData(kSystemObject, &address, 0, nil, size, &value)
}

struct OutputDeviceChoice {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

func outputDeviceChoices() -> [OutputDeviceChoice] {
    allDeviceIDs().compactMap { id in
        guard deviceAlive(id), deviceChannels(id, scope: kAudioObjectPropertyScopeOutput) > 0 else {
            return nil
        }
        guard let uid = deviceUID(id), uid != kSoundBridgeDeviceUID else { return nil }
        let transport = getUInt32(id, kAudioDevicePropertyTransportType) ?? 0
        let allowed = transport == kAudioDeviceTransportTypeHDMI
            || transport == kAudioDeviceTransportTypeDisplayPort
            || transport == kAudioDeviceTransportTypeUSB
            || transport == kAudioDeviceTransportTypeBuiltIn
        guard allowed else { return nil }
        return OutputDeviceChoice(id: id, name: deviceName(id) ?? "?", uid: uid)
    }
}

func objectIDsForApp(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var address = propAddr(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    guard count > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: count)
    let err = ids.withUnsafeMutableBytes { raw in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw.baseAddress!)
    }
    return err == noErr ? ids : []
}
