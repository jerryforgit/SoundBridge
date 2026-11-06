import Foundation
import CoreAudio
import Cocoa
import Darwin

// ============================================================
//  SoundBridge / wakespike
//
//  目的：在不安装任何驱动、不需要 sudo 的前提下，验证
//  "HDMI 端点按 UID 重绑 + 合盖唤醒后自动恢复出声" 是否成立。
//
//  它只做三件事：
//   1. 按 UID 找到 HDMI 输出设备（不缓存 AudioObjectID）
//   2. 在设备上开一个 IOProc，播放测试音
//   3. 设备消失/重建/唤醒时，重新按 UID 解析并 StartIO
//
//  所有状态迁移都打时间戳日志，方便合盖测试后回看。
// ============================================================

let kDefaultHDMIUID = "26130027-0000-0000-2522-010380000078"
let kSystemObject = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Address helper

func propAddr(_ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

// MARK: - Logger

final class Logger {
    private let queue = DispatchQueue(label: "soundbridge.wakespike.log")
    private let formatter = DateFormatter()
    private let stdout = FileHandle.standardOutput
    private var file: FileHandle?

    init(path: String) {
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let expanded = (path as NSString).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: expanded) {
            FileManager.default.createFile(atPath: expanded, contents: nil)
        }
        file = FileHandle(forWritingAtPath: expanded)
        file?.seekToEndOfFile()
    }

    func log(_ message: String) {
        // 关键：状态机线程绝不能被 stdout/磁盘日志阻塞。
        // 时间戳在这里取，写入放到串行队列里做。
        let now = Date()
        queue.async {
            let line = "\(self.formatter.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.stdout.write(data)
            self.file?.write(data)
        }
    }

    func flush() {
        queue.sync {}
    }

    func error(_ message: String) { log("ERROR: \(message)") }
}

// MARK: - CoreAudio property helpers

func getUInt32(_ object: AudioObjectID,
               _ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = propAddr(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let err = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return err == noErr ? value : nil
}

func getFloat64(_ object: AudioObjectID,
                _ selector: AudioObjectPropertySelector,
                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Float64? {
    var address = propAddr(selector, scope)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    let err = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    return err == noErr ? value : nil
}

func getCFString(_ object: AudioObjectID,
                 _ selector: AudioObjectPropertySelector) -> String? {
    var address = propAddr(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let err = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
    }
    guard err == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func deviceUID(_ id: AudioDeviceID) -> String? {
    getCFString(id, kAudioDevicePropertyDeviceUID)
}

func deviceName(_ id: AudioDeviceID) -> String? {
    getCFString(id, kAudioDevicePropertyDeviceNameCFString)
}

func deviceAlive(_ id: AudioDeviceID) -> Bool {
    (getUInt32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
}

func deviceRunning(_ id: AudioDeviceID) -> Bool {
    (getUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0
}

func nominalSampleRate(_ id: AudioDeviceID) -> Double {
    getFloat64(id, kAudioDevicePropertyNominalSampleRate) ?? 48000
}

func allDeviceIDs() -> [AudioDeviceID] {
    var address = propAddr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSystemObject, &address, 0, nil, &size) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    guard count > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: count)
    let err = ids.withUnsafeMutableBytes { raw in
        AudioObjectGetPropertyData(kSystemObject, &address, 0, nil, &size, raw.baseAddress!)
    }
    return err == noErr ? ids : []
}

func streamIDs(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [AudioStreamID] {
    var address = propAddr(kAudioDevicePropertyStreams, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioStreamID>.size
    guard count > 0 else { return [] }
    var streams = [AudioStreamID](repeating: 0, count: count)
    let err = streams.withUnsafeMutableBytes { raw in
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw.baseAddress!)
    }
    return err == noErr ? streams : []
}

func streamVirtualFormat(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
    var address = propAddr(kAudioStreamPropertyVirtualFormat)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let err = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd)
    return err == noErr ? asbd : nil
}

func deviceOutputFormat(_ device: AudioDeviceID) -> AudioStreamBasicDescription? {
    guard let stream = streamIDs(device, scope: kAudioObjectPropertyScopeOutput).first else {
        return nil
    }
    return streamVirtualFormat(stream)
}

func deviceOutputChannels(_ device: AudioDeviceID) -> Int {
    var address = propAddr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
          size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
        return 0
    }
    let list = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func findDevice(uid: String) -> AudioDeviceID? {
    for id in allDeviceIDs() {
        if deviceUID(id) == uid { return id }
    }
    return nil
}

func physicalDisplayOutputs() -> [AudioDeviceID] {
    allDeviceIDs().filter { id in
        let transport = getUInt32(id, kAudioDevicePropertyTransportType) ?? 0
        let isDisplay = transport == kAudioDeviceTransportTypeHDMI
            || transport == kAudioDeviceTransportTypeDisplayPort
        return isDisplay && deviceAlive(id) && deviceOutputChannels(id) > 0
    }
}

func defaultOutputDevice() -> AudioDeviceID? {
    var address = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let err = AudioObjectGetPropertyData(kSystemObject, &address, 0, nil, &size, &id)
    return err == noErr ? id : nil
}

func transportName(_ id: AudioDeviceID) -> String {
    switch getUInt32(id, kAudioDevicePropertyTransportType) ?? 0 {
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
    default: return "Other(\(getUInt32(id, kAudioDevicePropertyTransportType) ?? 0))"
    }
}

func describeFormat(_ asbd: AudioStreamBasicDescription?) -> String {
    guard let asbd else { return "no-format" }
    let float = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    return "\(asbd.mSampleRate)Hz ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) " +
           "bytesPerFrame=\(asbd.mBytesPerFrame) float=\(float) nonInterleaved=\(nonInterleaved)"
}

// MARK: - Test tone generator
//
// 这个类只在 IO 线程里使用，不跨线程共享，因此不需要锁。
// 输出 float32；支持 interleaved / non-interleaved。

final class ToneGenerator {
    private let sampleRate: Double
    private let frequency: Double
    private let amplitude: Float
    private let pulse: Bool
    private var phase: Double = 0
    private var frameCount: UInt64 = 0
    private let fadeFrames: UInt64

    init(sampleRate: Double, frequency: Double, levelDB: Double, pulse: Bool) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
        self.frequency = frequency
        self.amplitude = Float(pow(10.0, levelDB / 20.0))
        self.pulse = pulse
        self.fadeFrames = UInt64(self.sampleRate * 0.02) // 20 ms fade-in
    }

    private func nextSample() -> Float {
        let raw = Float(sin(phase)) * amplitude
        phase += 2.0 * Double.pi * frequency / sampleRate
        if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }

        frameCount += 1
        var env: Float = 1.0
        if pulse {
            // 0.5 Hz 慢呼吸：2 秒一个周期，0 → 1 → 0，避免长时间单音疲劳
            let t = Double(frameCount) / sampleRate
            env = Float(0.5 * (1.0 - cos(2.0 * Double.pi * 0.5 * t)))
        }
        if frameCount < fadeFrames {
            env *= Float(frameCount) / Float(fadeFrames)
        }
        return raw * env
    }

    func render(outputData: UnsafeMutablePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(outputData)
        guard list.count > 0 else { return }

        var pointers: [UnsafeMutablePointer<Float>] = []
        var channels: [Int] = []
        var frames = 0

        for buffer in list {
            guard let data = buffer.mData else { return }
            let ch = max(1, Int(buffer.mNumberChannels))
            let f = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            if frames == 0 { frames = f }
            pointers.append(data.assumingMemoryBound(to: Float.self))
            channels.append(ch)
        }
        guard frames > 0 else { return }

        for frame in 0..<frames {
            let sample = nextSample()
            for i in 0..<pointers.count {
                if channels[i] == 1 {
                    pointers[i][frame] = sample
                } else {
                    for ch in 0..<channels[i] {
                        pointers[i][frame * channels[i] + ch] = sample
                    }
                }
            }
        }
    }
}

// MARK: - WakeSpike state machine

final class WakeSpike {
    private let uid: String
    private let frequency: Double
    private let levelDB: Double
    private let pulse: Bool
    private let duration: Double?
    private let log: Logger

    private let stateQueue = DispatchQueue(label: "soundbridge.wakespike.state")
    private var boundDevice: AudioDeviceID?
    private var ioProc: AudioDeviceIOProcID?
    private var aliveListener: AudioObjectPropertyListenerBlock?
    private var debounceWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryIndex = 0
    private var watchdog: DispatchSourceTimer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var running = false
    private var waitingLogged = false
    private var lastStatusLog = Date.distantPast

    init(uid: String, frequency: Double, levelDB: Double, pulse: Bool, duration: Double?, log: Logger) {
        self.uid = uid
        self.frequency = frequency
        self.levelDB = levelDB
        self.pulse = pulse
        self.duration = duration
        self.log = log
    }

    func start() {
        running = true
        log.log("wakespike start: uid=\(uid) freq=\(frequency)Hz level=\(levelDB)dB " +
                "pattern=\(pulse ? "pulse" : "continuous") defaultOutput=\(describeDefaultOutput())")
        installSystemListeners()
        installWakeNotifications()
        startWatchdog()
        stateQueue.async { [weak self] in
            self?.reconcile(reason: "startup")
        }
        if let duration, duration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.shutdown(reason: "duration \(duration)s reached")
            }
        }
    }

    func shutdown(reason: String) {
        var didShutdown = false
        stateQueue.sync {
            guard running else { return }
            running = false
            didShutdown = true
            debounceWork?.cancel()
            retryWork?.cancel()
            watchdog?.cancel()
            log.log("shutdown: \(reason)")
            stopIO(keepBinding: false)
        }
        guard didShutdown else { return }
        log.flush()
        let nc = NSWorkspace.shared.notificationCenter
        for observer in wakeObservers { nc.removeObserver(observer) }
        wakeObservers.removeAll()
        exit(0)
    }

    // MARK: listeners

    private func installSystemListeners() {
        var devicesAddress = propAddr(kAudioHardwarePropertyDevices)
        let devicesErr = AudioObjectAddPropertyListenerBlock(
            kSystemObject, &devicesAddress, stateQueue
        ) { [weak self] _, _ in
            guard let self else { return }
            self.log.log("event: device list changed")
            self.requestReconcile(reason: "device list", delay: 0.25)
        }
        if devicesErr != noErr {
            log.error("add device-list listener failed: \(devicesErr) \(osStatusString(devicesErr))")
        }

        var defaultAddress = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        let defaultErr = AudioObjectAddPropertyListenerBlock(
            kSystemObject, &defaultAddress, stateQueue
        ) { [weak self] _, _ in
            guard let self else { return }
            self.log.log("event: default output changed -> \(self.describeDefaultOutput())")
        }
        if defaultErr != noErr {
            log.error("add default-output listener failed: \(defaultErr) \(osStatusString(defaultErr))")
        }
    }

    private func installWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        wakeObservers.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.log.log("event: system will sleep; bound=\(self?.describeBound() ?? "nil")")
        })
        wakeObservers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.log.log("event: system did wake")
            self.requestReconcile(reason: "didWake", delay: 0.35)
        })
        wakeObservers.append(nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.log.log("event: screens did wake")
            self?.requestReconcile(reason: "screensDidWake", delay: 0.5)
        })
    }

    private func installAliveListener(_ id: AudioDeviceID) {
        removeAliveListener()
        var address = propAddr(kAudioDevicePropertyDeviceIsAlive)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.log.log("event: device \(id) alive changed (alive=\(deviceAlive(id)))")
            self.requestReconcile(reason: "alive", delay: 0.1)
        }
        aliveListener = block
        let err = AudioObjectAddPropertyListenerBlock(id, &address, stateQueue, block)
        if err != noErr {
            log.error("add alive listener on \(id) failed: \(err) \(osStatusString(err))")
        }
    }

    private func removeAliveListener() {
        guard let id = boundDevice, let block = aliveListener else {
            aliveListener = nil
            return
        }
        var address = propAddr(kAudioDevicePropertyDeviceIsAlive)
        AudioObjectRemovePropertyListenerBlock(id, &address, stateQueue, block)
        aliveListener = nil
    }

    // MARK: watchdog

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.watchdogTick()
        }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard running else { return }

        let now = Date()
        if now.timeIntervalSince(lastStatusLog) >= 10 {
            lastStatusLog = now
            log.log("status: bound=\(describeBound()) running=\(describeRunning()) " +
                    "waiting=\(boundDevice == nil)")
        }

        guard let id = boundDevice else {
            // While waiting, the retry timer / device-list listener will take care of it.
            return
        }

        if !deviceAlive(id) || !deviceRunning(id) {
            log.log("watchdog: device \(id) not healthy (alive=\(deviceAlive(id)) running=\(deviceRunning(id))); reconciling")
            reconcile(reason: "watchdog")
        }
    }

    // MARK: reconcile / retry

    private func requestReconcile(reason: String, delay: Double) {
        guard running else { return }
        retryWork?.cancel()
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reconcile(reason: reason)
        }
        debounceWork = work
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reconcile(reason: String) {
        guard running else { return }

        let found = findDevice(uid: uid)
        let foundAlive = found.map { deviceAlive($0) } ?? false
        let foundChannels = found.map { deviceOutputChannels($0) } ?? 0
        let foundRunning = found.map { deviceRunning($0) } ?? false

        log.log("reconcile [\(reason)]: uid=\(uid) found=\(found.map(String.init) ?? "nil") " +
                "alive=\(foundAlive) running=\(foundRunning) outCh=\(foundChannels) " +
                "bound=\(describeBound())")

        guard let newID = found, foundAlive, foundChannels > 0 else {
            if boundDevice != nil {
                log.log("device unavailable; entering silent standby (keeping wait loop alive)")
                stopIO(keepBinding: false)
            } else if !waitingLogged {
                waitingLogged = true
                log.log("waiting for device \(uid) ...")
            }
            scheduleRetry()
            return
        }

        // Same device and already running: nothing to do.
        if newID == boundDevice, ioProc != nil, foundRunning {
            if retryIndex != 0 {
                log.log("device is healthy again; retry counter reset")
                retryIndex = 0
            }
            waitingLogged = false
            return
        }

        // Same device but IO stopped: restart it.
        if newID == boundDevice, ioProc != nil, !foundRunning {
            log.log("same device id=\(newID) but IO is not running; restarting")
            stopIO(keepBinding: true)
            startIO(newID, reason: "restart")
            return
        }

        // Different device: tear down old binding first.
        if let oldID = boundDevice, oldID != newID {
            log.log("REBIND: old id=\(oldID) -> new id=\(newID) (uid unchanged)")
            stopIO(keepBinding: false)
        } else if boundDevice == nil {
            log.log("BIND: id=\(newID) uid=\(uid)")
        }

        startIO(newID, reason: reason)
    }

    private func scheduleRetry() {
        guard running else { return }
        retryWork?.cancel()
        let delays: [Double] = [0.2, 0.5, 0.5, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 2.0]
        let delay = delays[min(retryIndex, delays.count - 1)]
        retryIndex += 1
        if retryIndex == 1 || retryIndex % 10 == 0 {
            log.log("retry scheduled in \(delay)s (attempt \(retryIndex))")
        }
        let work = DispatchWorkItem { [weak self] in
            self?.reconcile(reason: "retry")
        }
        retryWork = work
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: IO lifecycle

    private func startIO(_ id: AudioDeviceID, reason: String) {
        guard let format = deviceOutputFormat(id) else {
            log.error("device \(id) has no output stream format; retrying")
            scheduleRetry()
            return
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              format.mBitsPerChannel == 32 else {
            log.error("device \(id) output format is not float32: \(describeFormat(format)); refusing to start")
            scheduleRetry()
            return
        }

        let rate = nominalSampleRate(id)
        let generator = ToneGenerator(
            sampleRate: rate,
            frequency: frequency,
            levelDB: levelDB,
            pulse: pulse
        )

        var proc: AudioDeviceIOProcID?
        let createErr = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) {
            _, _, _, outputData, _ in
            generator.render(outputData: outputData)
        }
        guard createErr == noErr, let proc else {
            log.error("AudioDeviceCreateIOProcIDWithBlock(\(id)) failed: \(createErr) \(osStatusString(createErr))")
            scheduleRetry()
            return
        }

        let startErr = AudioDeviceStart(id, proc)
        guard startErr == noErr else {
            log.error("AudioDeviceStart(\(id)) failed: \(startErr) \(osStatusString(startErr))")
            AudioDeviceDestroyIOProcID(id, proc)
            scheduleRetry()
            return
        }

        boundDevice = id
        ioProc = proc
        installAliveListener(id)
        retryIndex = 0
        waitingLogged = false
        log.log("IO STARTED: id=\(id) rate=\(rate)Hz format=\(describeFormat(format)) reason=\(reason)")
    }

    private func stopIO(keepBinding: Bool) {
        if let proc = ioProc, let id = boundDevice {
            let stopErr = AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
            log.log("IO STOPPED: id=\(id) stopErr=\(stopErr) \(osStatusString(stopErr))")
        }
        ioProc = nil
        removeAliveListener()
        if !keepBinding {
            boundDevice = nil
        }
    }

    // MARK: descriptions

    private func describeBound() -> String {
        guard let id = boundDevice else { return "nil" }
        return "\(id)(\(deviceName(id) ?? "?"))"
    }

    private func describeRunning() -> String {
        guard let id = boundDevice else { return "false" }
        return "\(deviceRunning(id))"
    }

    private func describeDefaultOutput() -> String {
        guard let id = defaultOutputDevice() else { return "nil" }
        return "\(id)(\(deviceName(id) ?? "?"), uid=\(deviceUID(id) ?? "?"))"
    }
}

// MARK: - OSStatus string

func osStatusString(_ status: OSStatus) -> String {
    if status == noErr { return "ok" }
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff),
    ]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
        return "'\(String(bytes: bytes, encoding: .ascii) ?? "")'"
    }
    return "\(status)"
}

// MARK: - CLI

struct Options {
    var uid: String? = nil
    var frequency = 440.0
    var levelDB = -20.0
    var pulse = true
    var duration: Double? = nil
    var logPath = "~/Library/Logs/SoundBridge/wakespike.log"
    var list = false
}

func printUsage() {
    print("""
    wakespike — HDMI UID rebind / wake test

    Usage:
      ./wakespike [options]

    Options:
      --uid <uid>        target UID (default: auto-detect HDMI/DisplayPort output)
      --freq <hz>        test tone frequency (default: 440)
      --level <db>       test tone level in dBFS (default: -20)
      --pattern <p>      pulse | continuous (default: pulse)
      --duration <sec>   stop after N seconds (default: run until Ctrl-C)
      --log <path>       log file (default: ~/Library/Logs/SoundBridge/wakespike.log)
      --list             list audio devices and exit
      -h, --help         show this help
    """)
}

func parseOptions() -> Options {
    var options = Options()
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--uid":
            index += 1
            if index < args.count { options.uid = args[index] }
        case "--freq":
            index += 1
            if index < args.count, let value = Double(args[index]) { options.frequency = value }
        case "--level":
            index += 1
            if index < args.count, let value = Double(args[index]) { options.levelDB = value }
        case "--pattern":
            index += 1
            if index < args.count { options.pulse = args[index] != "continuous" }
        case "--duration":
            index += 1
            if index < args.count, let value = Double(args[index]) { options.duration = value }
        case "--log":
            index += 1
            if index < args.count { options.logPath = args[index] }
        case "--list":
            options.list = true
        case "-h", "--help":
            printUsage()
            exit(0)
        default:
            fputs("unknown argument: \(arg)\n", stderr)
            printUsage()
            exit(2)
        }
        index += 1
    }
    return options
}

func listDevices() {
    print("default output: \(defaultOutputDevice().map(String.init) ?? "nil")")
    print("count = \(allDeviceIDs().count)\n")
    for id in allDeviceIDs() {
        let uid = deviceUID(id) ?? "?"
        let name = deviceName(id) ?? "?"
        let alive = deviceAlive(id) ? 1 : 0
        let running = deviceRunning(id) ? 1 : 0
        let channels = deviceOutputChannels(id)
        let rate = nominalSampleRate(id)
        let format = describeFormat(deviceOutputFormat(id))
        let defaultMark = (defaultOutputDevice() == id) ? " <DEFAULT-OUT>" : ""
        print("id=\(id)\(defaultMark)")
        print("  name=\(name)")
        print("  uid=\(uid)")
        print("  transport=\(transportName(id))")
        print("  alive=\(alive) running=\(running) outCh=\(channels) rate=\(rate)")
        print("  format=\(format)")
    }
}

// MARK: - main

let options = parseOptions()
if options.list {
    listDevices()
    exit(0)
}

let logger = Logger(path: options.logPath)
logger.log("==== wakespike log opened: \(options.logPath) ====")

let targetUID: String
if let explicitUID = options.uid {
    targetUID = explicitUID
} else if let detected = physicalDisplayOutputs().first,
          let detectedUID = deviceUID(detected) {
    targetUID = detectedUID
    logger.log("auto-detected physical output: id=\(detected) " +
               "name=\(deviceName(detected) ?? "?") uid=\(detectedUID) " +
               "transport=\(transportName(detected))")
} else {
    targetUID = kDefaultHDMIUID
    logger.log("no physical HDMI/DisplayPort output found; falling back to \(kDefaultHDMIUID) and waiting")
}

let spike = WakeSpike(
    uid: targetUID,
    frequency: options.frequency,
    levelDB: options.levelDB,
    pulse: options.pulse,
    duration: options.duration,
    log: logger
)

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler {
    spike.shutdown(reason: "SIGINT")
}
sigintSource.resume()
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    spike.shutdown(reason: "SIGTERM")
}
sigtermSource.resume()

spike.start()
RunLoop.main.run()
