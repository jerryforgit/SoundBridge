import Foundation
import CoreAudio
import Cocoa
import Darwin

// ============================================================
//  SoundBridge engine v0
//
//  SoundBridge (input stream) -> ring -> LECOO (output stream)
//
//  关键点：
//   - 输入/输出设备都按 UID 解析，不缓存 AudioObjectID
//   - 输入和输出各一个 IOProc，中间是无锁环形缓冲
//   - 输出侧用分数读指针 + 微调速率做时钟漂移补偿
//   - 输出启动/停止/重绑都有淡入淡出
//   - 设备增删、alive、didWake、1s watchdog 都会触发 reconcile
//
//  P3 先跑通声音和音量；P4 再做 10 连唤醒加固。
// ============================================================

let kDefaultInputUID = "com.jerry.soundbridge.device"
let kDefaultOutputUID = "30A30132-0000-0000-0120-0104B5472878" // LECOO M3221PL
let kSystemObject = AudioObjectID(kAudioObjectSystemObject)

// MARK: - Logger

final class Logger {
    private let queue = DispatchQueue(label: "soundbridge.engine.log")
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
        let now = Date()
        queue.async {
            let line = "\(self.formatter.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.stdout.write(data)
            self.file?.write(data)
        }
    }

    func flush() { queue.sync {} }
}

// MARK: - CoreAudio helpers

func propAddr(_ selector: AudioObjectPropertySelector,
              _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
              _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getUInt32(_ object: AudioObjectID,
               _ selector: AudioObjectPropertySelector,
               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var address = propAddr(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func getFloat64(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
    var address = propAddr(selector)
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func getCFString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propAddr(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let err = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
    }
    guard err == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func deviceUID(_ id: AudioDeviceID) -> String? { getCFString(id, kAudioDevicePropertyDeviceUID) }
func deviceName(_ id: AudioDeviceID) -> String? { getCFString(id, kAudioDevicePropertyDeviceNameCFString) }
func deviceAlive(_ id: AudioDeviceID) -> Bool { (getUInt32(id, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0 }
func deviceRunning(_ id: AudioDeviceID) -> Bool { (getUInt32(id, kAudioDevicePropertyDeviceIsRunning) ?? 0) != 0 }
func nominalSampleRate(_ id: AudioDeviceID) -> Double { getFloat64(id, kAudioDevicePropertyNominalSampleRate) ?? 48000 }

func allDeviceIDs() -> [AudioDeviceID] {
    var address = propAddr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(kSystemObject, &address, 0, nil, &size) == noErr else { return [] }
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
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return [] }
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
    return AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr ? asbd : nil
}

func deviceFormat(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
    guard let stream = streamIDs(device, scope: scope).first else { return nil }
    return streamVirtualFormat(stream)
}

func deviceChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var address = propAddr(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func findDevice(uid: String) -> AudioDeviceID? {
    for id in allDeviceIDs() where deviceUID(id) == uid { return id }
    return nil
}

func physicalDisplayOutputs() -> [AudioDeviceID] {
    allDeviceIDs().filter { id in
        let transport = getUInt32(id, kAudioDevicePropertyTransportType) ?? 0
        let isDisplay = transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
        return isDisplay && deviceAlive(id) && deviceChannels(id, scope: kAudioObjectPropertyScopeOutput) > 0
    }
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
    default: return "Other"
    }
}

func formatDescription(_ asbd: AudioStreamBasicDescription?) -> String {
    guard let asbd else { return "no-format" }
    let float = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
    let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    return "\(asbd.mSampleRate)Hz ch=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) " +
        "bytesPerFrame=\(asbd.mBytesPerFrame) float=\(float) nonInterleaved=\(nonInterleaved)"
}

func isFloat32Stereo(_ asbd: AudioStreamBasicDescription?) -> Bool {
    guard let asbd else { return false }
    return asbd.mFormatID == kAudioFormatLinearPCM &&
        (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
        asbd.mBitsPerChannel == 32 &&
        asbd.mChannelsPerFrame == 2 &&
        (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
}

// MARK: - Lock-free loopback ring

final class AudioRing {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex: UnsafeMutablePointer<Int64>
    private let readIndex: UnsafeMutablePointer<Int64>

    init(capacity: Int) {
        self.capacity = capacity
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
        storage.initialize(repeating: 0, count: capacity * 2)
        writeIndex = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        readIndex = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
        writeIndex.initialize(to: 0)
        readIndex.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        writeIndex.deallocate()
        readIndex.deallocate()
    }

    var writePosition: Int64 { writeIndex.pointee }
    var readPosition: Int64 { readIndex.pointee }
    var fill: Int64 { writeIndex.pointee - readIndex.pointee }

    func write(_ source: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let w = writeIndex.pointee
        let r = readIndex.pointee
        let available = capacity - Int(w - r)
        let n = min(frames, max(0, available))
        guard n > 0 else { return }

        let offset = Int(w % Int64(capacity))
        let first = min(n, capacity - offset)
        memcpy(storage + offset * 2, source, first * 2 * MemoryLayout<Float>.size)
        if n > first {
            memcpy(storage, source + first * 2, (n - first) * 2 * MemoryLayout<Float>.size)
        }
        OSAtomicAdd64Barrier(Int64(n), writeIndex)
    }

    // 丢弃到指定位置；只在输出 IO 停止时调用。
    func discard(to position: Int64) {
        let target = min(max(0, position), writeIndex.pointee)
        let current = readIndex.pointee
        if target > current {
            OSAtomicAdd64Barrier(target - current, readIndex)
        }
    }

    // 精确设置读位置（可前可后）；只在消费者停止时调用。
    func setReadPosition(_ position: Int64) {
        let target = min(max(0, position), writeIndex.pointee)
        let current = readIndex.pointee
        if target != current {
            OSAtomicAdd64Barrier(target - current, readIndex)
        }
    }

    // 分数读指针 + 线性插值。返回实际产生的帧数；不足部分补零。
    func read(into destination: UnsafeMutablePointer<Float>,
              frames: Int,
              readPos: inout Double,
              rate: Double,
              fadeGain: inout Float,
              fadeTarget: Float) -> Int {
        guard frames > 0 else { return 0 }
        let write = writeIndex.pointee
        var produced = 0

        for frame in 0..<frames {
            let base = Int64(floor(readPos))
            guard base + 1 < write else { break }
            let frac = Float(readPos - Double(base))
            let i0 = Int(base % Int64(capacity))
            let i1 = Int((base + 1) % Int64(capacity))

            let l0 = storage[i0 * 2 + 0]
            let l1 = storage[i1 * 2 + 0]
            let r0 = storage[i0 * 2 + 1]
            let r1 = storage[i1 * 2 + 1]

            let fadeStep: Float = 0.002
            if fadeGain < fadeTarget {
                fadeGain = min(fadeTarget, fadeGain + fadeStep)
            } else if fadeGain > fadeTarget {
                fadeGain = max(fadeTarget, fadeGain - fadeStep)
            }

            destination[frame * 2 + 0] = (l0 + (l1 - l0) * frac) * fadeGain
            destination[frame * 2 + 1] = (r0 + (r1 - r0) * frac) * fadeGain
            readPos += rate
            produced += 1
        }

        if produced < frames {
            memset(destination + produced * 2, 0,
                (frames - produced) * 2 * MemoryLayout<Float>.size)
        }

        let target = Int64(readPos)
        let current = readIndex.pointee
        if target > current {
            OSAtomicAdd64Barrier(target - current, readIndex)
        }
        return produced
    }
}

// MARK: - Engine

final class Engine {
    private let inputUID: String
    private(set) var outputUID: String
    private let ring = AudioRing(capacity: 16384)
    let dsp = SpatialDSP()
    private let log: Logger
    private let stateQueue = DispatchQueue(label: "soundbridge.engine.state")

    private var shared: SharedRing?
    private let sharedScratch = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
    private var sharedWaitingLogged = false

    private let targetFill: Int64 = 1024
    private var inputDevice: AudioDeviceID?
    private var inputProc: AudioDeviceIOProcID?
    private var outputDevice: AudioDeviceID?
    private var outputProc: AudioDeviceIOProcID?

    private var outputReadPos: Double = 0
    private var fadeGain: Float = 0
    private var fadeTarget: Float = 0
    private var outputNeedsPrefill = true
    private var driftCorrection: Double = 0

    private var inputAliveListener: AudioObjectPropertyListenerBlock?
    private var outputAliveListener: AudioObjectPropertyListenerBlock?
    private var debounceWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryIndex = 0
    private var watchdog: DispatchSourceTimer?
    private var wakeObservers: [NSObjectProtocol] = []
    private var running = false
    private var sleeping = false
    private var inputWaitingLogged = false
    private var outputWaitingLogged = false
    private var lastStatusLog = Date.distantPast
    private var lastInputWritePosition: Int64 = 0
    private var lastOutputCallbackCount: Int64 = 0
    private var inputStartedAt = Date.distantPast
    private var outputStartedAt = Date.distantPast
    private let outputCallbackCounter = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    init(inputUID: String, outputUID: String, log: Logger) {
        self.inputUID = inputUID
        self.outputUID = outputUID
        self.log = log
        outputCallbackCounter.initialize(to: 0)
        sharedScratch.initialize(repeating: 0, count: 4096 * 2)
        shared = SharedRing()
    }

    deinit {
        outputCallbackCounter.deallocate()
        sharedScratch.deallocate()
    }

    func start() {
        running = true
        log.log("engine start: input=\(inputUID) output=\(outputUID)")
        log.log("shared memory: \(shared != nil ? "available" : "not available")")
        log.log("spatial: AUMatrixReverb available=\(dsp.auAvailable)")
        installSystemListeners()
        installWakeNotifications()
        startWatchdog()
        stateQueue.async { [weak self] in
            self?.reconcile(reason: "startup")
        }
    }

    func stop(reason: String) {
        var didShutdown = false
        stateQueue.sync {
            guard running else { return }
            running = false
            didShutdown = true
            debounceWork?.cancel()
            retryWork?.cancel()
            watchdog?.cancel()
            log.log("shutdown: \(reason)")
            stopOutput(fade: true)
            stopInput()
        }
        guard didShutdown else { return }
        log.flush()
        let nc = NSWorkspace.shared.notificationCenter
        for observer in wakeObservers { nc.removeObserver(observer) }
        wakeObservers.removeAll()
    }

    func setOutputUID(_ uid: String) {
        stateQueue.async {
            guard self.running else { return }
            guard uid != self.outputUID else { return }
            self.log.log("output UID changed: \(self.outputUID) -> \(uid)")
            self.outputUID = uid
            self.stopOutput(fade: true)
            self.retryIndex = 0
            self.reconcile(reason: "output UID change")
        }
    }

    var selectedOutputUID: String {
        stateQueue.sync { outputUID }
    }

    func statusText() -> String {
        stateQueue.sync {
            "input=\(describeInput()) output=\(describeOutput()) ring=\(ring.fill)"
        }
    }

    var isRunningBoth: Bool {
        stateQueue.sync {
            guard let output = outputDevice, deviceRunning(output) else { return false }
            if shared != nil { return true }
            guard let input = inputDevice else { return false }
            return deviceRunning(input)
        }
    }

    // MARK: listeners

    private func installSystemListeners() {
        var devicesAddress = propAddr(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(kSystemObject, &devicesAddress, stateQueue) { [weak self] _, _ in
            guard let self else { return }
            self.log.log("event: device list changed")
            self.requestReconcile(reason: "device list", delay: 0.25)
        }

        var defaultAddress = propAddr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(kSystemObject, &defaultAddress, stateQueue) { [weak self] _, _ in
            guard let self else { return }
            self.log.log("event: default output changed")
        }
    }

    private func installWakeNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        wakeObservers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.sleeping = true
                self.log.log("event: system will sleep")
            }
        })

        wakeObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.sleeping = false
                self.log.log("event: system did wake")
                if self.outputDevice != nil, self.outputProc != nil {
                    self.outputNeedsPrefill = true
                }
                self.requestReconcile(reason: "didWake", delay: 0.35)
            }
        })

        wakeObservers.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.stateQueue.async {
                self.sleeping = false
                self.log.log("event: screens did wake")
                if self.outputDevice != nil, self.outputProc != nil {
                    self.outputNeedsPrefill = true
                }
                self.requestReconcile(reason: "screensDidWake", delay: 0.5)
            }
        })
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func watchdogTick() {
        guard running, !sleeping else { return }

        if shared == nil {
            shared = SharedRing()
            if shared != nil {
                log.log("shared memory ready")
            }
        }

        let now = Date()
        if now.timeIntervalSince(lastStatusLog) >= 10 {
            lastStatusLog = now
            log.log("status: input=\(shared != nil ? "shared" : describeInput()) output=\(describeOutput()) ring=\(ring.fill)")
        }

        var unhealthy = false

        if shared == nil, let id = inputDevice {
            if !deviceAlive(id) || !deviceRunning(id) {
                log.log("watchdog: input \(id) not healthy (alive=\(deviceAlive(id)) running=\(deviceRunning(id)))")
                unhealthy = true
            } else {
                let position = ring.writePosition
                if Date().timeIntervalSince(inputStartedAt) > 2.0,
                   position == lastInputWritePosition {
                    log.log("watchdog: input \(id) running but no frames for >1s; restarting input+output")
                    stopInput()
                    stopOutput(fade: false)
                    unhealthy = true
                }
                lastInputWritePosition = position
            }
        }

        if let id = outputDevice {
            if !deviceAlive(id) || !deviceRunning(id) {
                log.log("watchdog: output \(id) not healthy (alive=\(deviceAlive(id)) running=\(deviceRunning(id)))")
                unhealthy = true
            } else {
                let count = outputCallbackCounter.pointee
                if Date().timeIntervalSince(outputStartedAt) > 2.0,
                   count == lastOutputCallbackCount {
                    log.log("watchdog: output \(id) running but no callbacks for >1s; restarting output")
                    stopOutput(fade: false)
                    unhealthy = true
                }
                lastOutputCallbackCount = count
            }
        }

        if (shared == nil && inputDevice == nil) || outputDevice == nil {
            unhealthy = true
        }
        if unhealthy { reconcile(reason: "watchdog") }
    }

    // MARK: reconcile

    private func requestReconcile(reason: String, delay: Double) {
        guard running, !sleeping else { return }
        retryWork?.cancel()
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile(reason: reason) }
        debounceWork = work
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reconcile(reason: String) {
        guard running, !sleeping else { return }
        if shared == nil {
            shared = SharedRing()
            if shared == nil && !sharedWaitingLogged {
                sharedWaitingLogged = true
                log.log("waiting for shared memory \(SharedRing.path) ...")
            }
        }
        if shared != nil {
            sharedWaitingLogged = false
        }
        log.log("reconcile [\(reason)]: input=\(shared != nil ? "shared" : describeInput()) output=\(describeOutput()) ring=\(ring.fill)")
        reconcileOutput(reason: reason)
    }

    private func reconcileInput(reason: String) {
        let found = findDevice(uid: inputUID)
        let foundAlive = found.map { deviceAlive($0) } ?? false
        let channels = found.map { deviceChannels($0, scope: kAudioObjectPropertyScopeInput) } ?? 0

        guard let id = found, foundAlive, channels > 0 else {
            if inputDevice != nil {
                log.log("input unavailable; stopping input IO (waiting for \(inputUID))")
                stopInput()
            } else if !inputWaitingLogged {
                inputWaitingLogged = true
                log.log("waiting for input device \(inputUID) ...")
            }
            scheduleRetry()
            return
        }

        if id == inputDevice, inputProc != nil, deviceRunning(id) {
            inputWaitingLogged = false
            return
        }

        if let old = inputDevice, old != id {
            log.log("input REBIND: old id=\(old) -> new id=\(id) (uid unchanged)")
            stopInput()
        }
        if inputDevice == id, inputProc != nil {
            stopInput()
        }
        startInput(id, reason: reason)
    }

    private func reconcileOutput(reason: String) {
        let found = findDevice(uid: outputUID)
        let foundAlive = found.map { deviceAlive($0) } ?? false
        let channels = found.map { deviceChannels($0, scope: kAudioObjectPropertyScopeOutput) } ?? 0

        guard let id = found, foundAlive, channels > 0 else {
            if outputDevice != nil {
                log.log("output unavailable; entering silent standby (waiting for \(outputUID))")
                stopOutput(fade: true)
            } else if !outputWaitingLogged {
                outputWaitingLogged = true
                log.log("waiting for output device \(outputUID) ...")
            }
            scheduleRetry()
            return
        }

        if id == outputDevice, outputProc != nil, deviceRunning(id) {
            outputWaitingLogged = false
            return
        }

        if let old = outputDevice, old != id {
            log.log("output REBIND: old id=\(old) -> new id=\(id) (uid unchanged)")
            stopOutput(fade: true)
        } else if outputDevice == id, outputProc != nil {
            stopOutput(fade: true)
        }

        startOutput(id, reason: reason)
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
        let work = DispatchWorkItem { [weak self] in self?.reconcile(reason: "retry") }
        retryWork = work
        stateQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: input IO

    private func startInput(_ id: AudioDeviceID, reason: String) {
        guard let format = deviceFormat(id, scope: kAudioObjectPropertyScopeInput) else {
            log.log("input \(id) has no format; retrying")
            scheduleRetry()
            return
        }
        guard isFloat32Stereo(format) else {
            log.log("input \(id) format is not float32 stereo interleaved: \(formatDescription(format)); refusing")
            scheduleRetry()
            return
        }

        ring.discard(to: ring.writePosition)

        var proc: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.count == 1, let data = list[0].mData else { return }
            let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * 2)
            guard frames > 0 else { return }
            self.ring.write(data.assumingMemoryBound(to: Float.self), frames: frames)
        }
        guard err == noErr, let proc else {
            log.log("input AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
            scheduleRetry()
            return
        }
        let startErr = AudioDeviceStart(id, proc)
        guard startErr == noErr else {
            log.log("input AudioDeviceStart failed: \(startErr)")
            AudioDeviceDestroyIOProcID(id, proc)
            scheduleRetry()
            return
        }

        inputDevice = id
        inputProc = proc
        installAliveListener(id, isInput: true)
        inputWaitingLogged = false
        inputStartedAt = Date()
        log.log("INPUT STARTED: id=\(id) format=\(formatDescription(format)) reason=\(reason)")
    }

    private func stopInput() {
        if let proc = inputProc, let id = inputDevice {
            AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
            log.log("INPUT STOPPED: id=\(id)")
        }
        inputProc = nil
        removeAliveListener(isInput: true)
        inputDevice = nil
    }

    // MARK: output IO

    private func startOutput(_ id: AudioDeviceID, reason: String) {
        guard let format = deviceFormat(id, scope: kAudioObjectPropertyScopeOutput) else {
            log.log("output \(id) has no format; retrying")
            scheduleRetry()
            return
        }
        guard isFloat32Stereo(format) else {
            log.log("output \(id) format is not float32 stereo interleaved: \(formatDescription(format)); refusing")
            scheduleRetry()
            return
        }

        let start = max(0, ring.writePosition - targetFill)
        ring.setReadPosition(start)
        outputReadPos = Double(start)
        outputNeedsPrefill = true
        driftCorrection = 0
        fadeGain = 0
        fadeTarget = 1

        var proc: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { [weak self] _, _, _, outputData, _ in
            guard let self else { return }
            let list = UnsafeMutableAudioBufferListPointer(outputData)
            guard list.count == 1, let data = list[0].mData else { return }
            let frames = Int(list[0].mDataByteSize) / (MemoryLayout<Float>.size * 2)
            guard frames > 0 else { return }

            OSAtomicIncrement64Barrier(self.outputCallbackCounter)

            if let shared = self.shared {
                let deficit = max(0, Int(self.targetFill - self.ring.fill))
                let wanted = min(frames + deficit, 4096)
                let count = shared.read(into: self.sharedScratch, frames: wanted)
                if count > 0 {
                    self.ring.write(self.sharedScratch, frames: count)
                }
            }

            if self.outputNeedsPrefill {
                let prefill = max(0, self.ring.writePosition - self.targetFill)
                self.ring.setReadPosition(prefill)
                self.outputReadPos = Double(prefill)
                self.fadeGain = 0
                self.outputNeedsPrefill = false
            }

            // 唤醒后如果积压太多，直接丢掉旧数据并淡入，避免 100–300 ms 的延迟。
            if self.ring.fill > 8192 {
                let reset = max(0, self.ring.writePosition - self.targetFill)
                self.ring.setReadPosition(reset)
                self.outputReadPos = Double(reset)
                self.fadeGain = 0
            }

            let fill = Double(self.ring.fill)
            let target = Double(self.targetFill)
            let error = (fill - target) / max(1.0, target)
            let dt = Double(frames) / 48000.0

            // PI 控制器：比例项快速拉回，积分项抵消 SoundBridge 与 LECOO
            // 之间的固定时钟差，避免 ring 长期停在 3–4k 帧。
            self.driftCorrection += error * 0.0003 * dt
            self.driftCorrection = max(-0.01, min(0.01, self.driftCorrection))
            let rate = max(0.98, min(1.02,
                1.0 + error * 0.002 + self.driftCorrection))

            _ = self.ring.read(
                into: data.assumingMemoryBound(to: Float.self),
                frames: frames,
                readPos: &self.outputReadPos,
                rate: rate,
                fadeGain: &self.fadeGain,
                fadeTarget: self.fadeTarget
            )
            self.dsp.process(data.assumingMemoryBound(to: Float.self), frames: frames)
        }
        guard err == noErr, let proc else {
            log.log("output AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
            scheduleRetry()
            return
        }
        let startErr = AudioDeviceStart(id, proc)
        guard startErr == noErr else {
            log.log("output AudioDeviceStart failed: \(startErr)")
            AudioDeviceDestroyIOProcID(id, proc)
            scheduleRetry()
            return
        }

        outputDevice = id
        outputProc = proc
        installAliveListener(id, isInput: false)
        outputWaitingLogged = false
        retryIndex = 0
        outputStartedAt = Date()
        log.log("OUTPUT STARTED: id=\(id) format=\(formatDescription(format)) ring=\(ring.fill) reason=\(reason)")
    }

    private func stopOutput(fade: Bool) {
        if fade {
            fadeTarget = 0
            usleep(30_000)
        }
        if let proc = outputProc, let id = outputDevice {
            let stopErr = AudioDeviceStop(id, proc)
            AudioDeviceDestroyIOProcID(id, proc)
            log.log("OUTPUT STOPPED: id=\(id) stopErr=\(stopErr)")
        }
        outputProc = nil
        removeAliveListener(isInput: false)
        outputDevice = nil
        ring.discard(to: ring.writePosition)
    }

    // MARK: alive listeners

    private func installAliveListener(_ id: AudioDeviceID, isInput: Bool) {
        removeAliveListener(isInput: isInput)
        var address = propAddr(kAudioDevicePropertyDeviceIsAlive)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.log.log("event: \(isInput ? "input" : "output") device \(id) alive changed (alive=\(deviceAlive(id)))")
            self.requestReconcile(reason: isInput ? "input alive" : "output alive", delay: 0.1)
        }
        if isInput {
            inputAliveListener = block
        } else {
            outputAliveListener = block
        }
        AudioObjectAddPropertyListenerBlock(id, &address, stateQueue, block)
    }

    private func removeAliveListener(isInput: Bool) {
        if isInput {
            if let id = inputDevice, let block = inputAliveListener {
                var address = propAddr(kAudioDevicePropertyDeviceIsAlive)
                AudioObjectRemovePropertyListenerBlock(id, &address, stateQueue, block)
            }
            inputAliveListener = nil
        } else {
            if let id = outputDevice, let block = outputAliveListener {
                var address = propAddr(kAudioDevicePropertyDeviceIsAlive)
                AudioObjectRemovePropertyListenerBlock(id, &address, stateQueue, block)
            }
            outputAliveListener = nil
        }
    }

    // MARK: descriptions

    private func describeInput() -> String {
        guard let id = inputDevice else { return "nil" }
        return "\(id)(\(deviceName(id) ?? "?"), running=\(deviceRunning(id)))"
    }

    private func describeOutput() -> String {
        guard let id = outputDevice else { return "nil" }
        return "\(id)(\(deviceName(id) ?? "?"), running=\(deviceRunning(id)))"
    }
}

