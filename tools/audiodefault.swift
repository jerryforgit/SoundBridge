import Foundation
import CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ selector: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func propAddr(_ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = addr(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func getFloat64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
    var address = addr(selector)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func getUInt32Scoped(_ object: AudioObjectID,
                     _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> UInt32? {
    var address = propAddr(selector, scope, element)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func getASBD(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioStreamBasicDescription? {
    var address = propAddr(selector)
    var value = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func getCFString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = addr(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let err = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
    }
    guard err == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func getFloat32(_ object: AudioObjectID,
                _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Float32? {
    var address = propAddr(selector, scope, element)
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    let err = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return err == noErr ? value : nil
}

func getValueRange(_ object: AudioObjectID,
                   _ selector: AudioObjectPropertySelector,
                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                   element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioValueRange? {
    var address = propAddr(selector, scope, element)
    var value = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    let err = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return err == noErr ? value : nil
}

func hasProperty(_ object: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
    var address = propAddr(selector, scope, element)
    return AudioObjectHasProperty(object, &address)
}

func isSettable(_ object: AudioObjectID,
                _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> Bool {
    var address = propAddr(selector, scope, element)
    var settable: DarwinBoolean = false
    guard AudioObjectIsPropertySettable(object, &address, &settable) == noErr else { return false }
    return settable.boolValue
}

func fourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(value, radix: 16))"
}

func scopeName(_ scope: UInt32) -> String {
    switch scope {
    case kAudioObjectPropertyScopeGlobal: return "global"
    case kAudioObjectPropertyScopeInput: return "input"
    case kAudioObjectPropertyScopeOutput: return "output"
    case kAudioObjectPropertyScopePlayThrough: return "playthrough"
    default: return "0x\(String(scope, radix: 16))"
    }
}

func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
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

func deviceIDs() -> [AudioDeviceID] {
    var address = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: count)
    let err = ids.withUnsafeMutableBytes { raw in
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, raw.baseAddress!)
    }
    return err == noErr ? ids : []
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var address = addr(selector)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr ? id : nil
}

func setDefaultDevice(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) -> OSStatus {
    var address = addr(selector)
    var value = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectSetPropertyData(systemObject, &address, 0, nil, size, &value)
}

func findDevice(uid: String) -> AudioDeviceID? {
    for id in deviceIDs() where getCFString(id, kAudioDevicePropertyDeviceUID) == uid {
        return id
    }
    return nil
}

func describe(_ id: AudioDeviceID?) -> String {
    guard let id else { return "nil" }
    let name = getCFString(id, kAudioDevicePropertyDeviceNameCFString) ?? "?"
    let uid = getCFString(id, kAudioDevicePropertyDeviceUID) ?? "?"
    return "\(id) \(name) (\(uid))"
}

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "get"

switch command {
case "get":
    print("default output:        \(describe(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)))")
    print("default system output: \(describe(defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)))")

case "list":
    let out = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let sys = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    for id in deviceIDs() {
        let name = getCFString(id, kAudioDevicePropertyDeviceNameCFString) ?? "?"
        let uid = getCFString(id, kAudioDevicePropertyDeviceUID) ?? "?"
        let running = (getUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0
        var markers: [String] = []
        if id == out { markers.append("DEFAULT-OUT") }
        if id == sys { markers.append("DEFAULT-SYS") }
        print("\(id) \(name) uid=\(uid) running=\(running ? 1 : 0) \(markers.joined(separator: ","))")
    }

case "set":
    guard args.count > 2 else {
        fputs("usage: audiodefault set <uid>\n", stderr)
        exit(2)
    }
    let uid = args[2]
    guard let id = findDevice(uid: uid) else {
        fputs("device not found: \(uid)\n", stderr)
        exit(1)
    }
    let oldOut = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let oldSys = defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    let errOut = setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, id)
    let errSys = setDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, id)
    print("old output:        \(describe(oldOut))")
    print("old system output: \(describe(oldSys))")
    print("new output:        \(describe(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))) (err=\(errOut))")
    print("new system output: \(describe(defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice))) (err=\(errSys))")

case "inspect":
    guard args.count > 2 else {
        fputs("usage: audiodefault inspect <uid>\n", stderr)
        exit(2)
    }
    guard let id = findDevice(uid: args[2]) else {
        fputs("device not found: \(args[2])\n", stderr)
        exit(1)
    }
    let name = getCFString(id, kAudioDevicePropertyDeviceNameCFString) ?? "?"
    let uid = getCFString(id, kAudioDevicePropertyDeviceUID) ?? "?"
    print("device id=\(id) name=\(name) uid=\(uid)")
    print("  transport=\(fourCC(getUInt32(id, kAudioDevicePropertyTransportType) ?? 0))")
    print("  alive=\(getUInt32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) " +
          "running=\(getUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0) " +
          "rate=\(getFloat64(id, kAudioDevicePropertyNominalSampleRate) ?? 0)")
    print("  bufferFrames=\(getUInt32(id, kAudioDevicePropertyBufferFrameSize) ?? 0)")

    for (label, scope) in [("output", kAudioObjectPropertyScopeOutput),
                           ("input", kAudioObjectPropertyScopeInput)] {
        let streams = objectIDs(id, kAudioDevicePropertyStreams, scope: scope)
        for stream in streams {
            let direction = getUInt32(stream, kAudioStreamPropertyDirection) ?? 0
            var formatText = "no-format"
            if let fmt = getASBD(stream, kAudioStreamPropertyVirtualFormat) {
                formatText = "\(fmt.mSampleRate)Hz ch=\(fmt.mChannelsPerFrame) bits=\(fmt.mBitsPerChannel) " +
                    "float=\((fmt.mFormatFlags & kAudioFormatFlagIsFloat) != 0) " +
                    "nonInterleaved=\((fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)"
            }
            print("  stream[\(label)] id=\(stream) direction=\(direction) format=\(formatText)")
        }
    }

    let controls = objectIDs(id, kAudioObjectPropertyControlList)
    print("  controls=\(controls.count)")
    for control in controls {
        let cls = getUInt32(control, kAudioObjectPropertyClass) ?? 0
        let scope = getUInt32(control, kAudioControlPropertyScope) ?? 0
        let element = getUInt32(control, kAudioControlPropertyElement) ?? 0
        var text = "  control id=\(control) class=\(fourCC(cls)) scope=\(scopeName(scope)) element=\(element)"
        if let scalar = getFloat32(control, kAudioLevelControlPropertyScalarValue, scope: scope, element: element) {
            text += " scalar=\(String(format: "%.4f", scalar))"
        }
        if let db = getFloat32(control, kAudioLevelControlPropertyDecibelValue, scope: scope, element: element) {
            text += " db=\(String(format: "%.2f", db))"
        }
        if let mute = getUInt32(control, kAudioBooleanControlPropertyValue) {
            text += " mute=\(mute)"
        }
        print(text)
    }

    for (label, selector) in [("volumeScalar", kAudioDevicePropertyVolumeScalar),
                              ("mute", kAudioDevicePropertyMute)] {
        let present = hasProperty(id, selector, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain)
        var text = "  device.\(label): present=\(present)"
        if present {
            text += " settable=\(isSettable(id, selector, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain))"
            if let scalar = getFloat32(id, selector, scope: kAudioObjectPropertyScopeOutput, element: kAudioObjectPropertyElementMain) {
                text += " value=\(String(format: "%.4f", scalar))"
            }
            if let mute = getUInt32Scoped(id, selector, scope: kAudioObjectPropertyScopeOutput) {
                text += " value=\(mute)"
            }
        }
        print(text)
    }
    if let range = getValueRange(id, kAudioDevicePropertyVolumeRangeDecibels,
                                 scope: kAudioObjectPropertyScopeOutput,
                                 element: kAudioObjectPropertyElementMain) {
        print("  device.volumeRangeDB: \(range.mMinimum) .. \(range.mMaximum)")
    }

default:
    fputs("usage: audiodefault [get|list|set <uid>]\n", stderr)
    exit(2)
}
