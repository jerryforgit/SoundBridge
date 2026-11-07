import Foundation
import Darwin

// ============================================================
//  Spatial DSP（P7）
//
//  width:  M/S 展宽，0 → 0 dB，100 → +6 dB
//  depth:  crossfeed（0.2 ms, -9 dB）
//          + 3 个早期反射（5/11/17 ms L，7/13/19 ms R）
//          低通 ~3 kHz，衰减 -12/-15/-18 dB
//  旁路:   dry/wet 20 ms 交叉淡化
//  限幅:   2 ms look-ahead，立体声联动，默认 -1 dBFS
//
//  所有状态在 init 里预分配；process() 里不分配、不加锁、不打日志。
// ============================================================

final class AtomicFloat {
    private let storage: UnsafeMutablePointer<Int32>

    init(_ value: Float) {
        storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        storage.initialize(to: Int32(bitPattern: value.bitPattern))
    }

    deinit {
        storage.deallocate()
    }

    var value: Float {
        get {
            Float(bitPattern: UInt32(bitPattern: storage.pointee))
        }
        set {
            let newValue = Int32(bitPattern: newValue.bitPattern)
            while true {
                let oldValue = storage.pointee
                if oldValue == newValue { break }
                if OSAtomicCompareAndSwap32Barrier(oldValue, newValue, storage) { break }
            }
        }
    }
}

final class AtomicBool {
    private let storage: UnsafeMutablePointer<Int32>

    init(_ value: Bool) {
        storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        storage.initialize(to: value ? 1 : 0)
    }

    deinit {
        storage.deallocate()
    }

    var value: Bool {
        get { storage.pointee != 0 }
        set {
            let newValue: Int32 = newValue ? 1 : 0
            while true {
                let oldValue = storage.pointee
                if oldValue == newValue { break }
                if OSAtomicCompareAndSwap32Barrier(oldValue, newValue, storage) { break }
            }
        }
    }
}

final class SpatialDSP {
    // 0...1
    let width = AtomicFloat(0)
    let depth = AtomicFloat(0)
    let reverb = AtomicFloat(0)
    let reverbMode = AtomicFloat(0) // 0 = Schroeder, 1 = AU Medium Hall, 2 = AU Large Hall
    let bypass = AtomicBool(true)
    let limiterEnabled = AtomicBool(true)
    let thresholdDB = AtomicFloat(-1.0)
    // 前置增益，dB。应用在 EQ 之前；正增益由 limiter 保护。
    let gainDB = AtomicFloat(0.0)

    private let maxFrames = 4096
    private let channelCount = 2

    private let dry: UnsafeMutablePointer<Float>
    let eq = EQDSP()
    private let spatialL: UnsafeMutablePointer<Float>
    private let spatialR: UnsafeMutablePointer<Float>
    private let auL: UnsafeMutablePointer<Float>
    private let auR: UnsafeMutablePointer<Float>
    private let auMedium: MatrixReverbAU?
    private let auLarge: MatrixReverbAU?

    private let xfSize = 16
    private let xfDelay = 10
    private let xfL: UnsafeMutablePointer<Float>
    private let xfR: UnsafeMutablePointer<Float>
    private var xfIndex = 0

    private let reflSize = 1024
    private let reflL: UnsafeMutablePointer<Float>
    private let reflR: UnsafeMutablePointer<Float>
    private var reflIndex = 0

    private let lpL: UnsafeMutablePointer<Float>
    private let lpR: UnsafeMutablePointer<Float>
    private let lpAlpha: Float = 0.324

    private let limSize = 256
    private let lookahead = 96
    private let limL: UnsafeMutablePointer<Float>
    private let limR: UnsafeMutablePointer<Float>
    private var limIndex = 0
    private var limGain: Float = 1.0
    private var limEnv: Float = 0.0

    // Hall reverb：4 个并联 comb + 2 个串联 all-pass（每声道）
    private let combSize = 4096
    private let combCount = 4
    private let combDelaysL = [1426, 1781, 1973, 2098] // 29.7 / 37.1 / 41.1 / 43.7 ms
    private let combDelaysR = [1447, 1802, 1994, 2119]
    private let combL: [UnsafeMutablePointer<Float>]
    private let combR: [UnsafeMutablePointer<Float>]
    private let combDampL: UnsafeMutablePointer<Float>
    private let combDampR: UnsafeMutablePointer<Float>
    private var combIndexL = [Int](repeating: 0, count: 4)
    private var combIndexR = [Int](repeating: 0, count: 4)

    private let apSize = 512
    private let apCount = 2
    private let apDelaysL = [240, 82]
    private let apDelaysR = [261, 103]
    private let apL: [UnsafeMutablePointer<Float>]
    private let apR: [UnsafeMutablePointer<Float>]
    private var apIndexL = [Int](repeating: 0, count: 2)
    private var apIndexR = [Int](repeating: 0, count: 2)

    private var mix: Float = 0.0
    private var gainCurrent: Float = 1.0

    init() {
        dry = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channelCount)
        dry.initialize(repeating: 0, count: maxFrames * channelCount)
        spatialL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        spatialR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        auL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        auR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        spatialL.initialize(repeating: 0, count: maxFrames)
        spatialR.initialize(repeating: 0, count: maxFrames)
        auL.initialize(repeating: 0, count: maxFrames)
        auR.initialize(repeating: 0, count: maxFrames)
        auMedium = MatrixReverbAU(preset: 3)
        auLarge = MatrixReverbAU(preset: 4)

        xfL = UnsafeMutablePointer<Float>.allocate(capacity: xfSize)
        xfR = UnsafeMutablePointer<Float>.allocate(capacity: xfSize)
        xfL.initialize(repeating: 0, count: xfSize)
        xfR.initialize(repeating: 0, count: xfSize)

        reflL = UnsafeMutablePointer<Float>.allocate(capacity: reflSize)
        reflR = UnsafeMutablePointer<Float>.allocate(capacity: reflSize)
        reflL.initialize(repeating: 0, count: reflSize)
        reflR.initialize(repeating: 0, count: reflSize)

        lpL = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        lpR = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        lpL.initialize(repeating: 0, count: 3)
        lpR.initialize(repeating: 0, count: 3)

        limL = UnsafeMutablePointer<Float>.allocate(capacity: limSize)
        limR = UnsafeMutablePointer<Float>.allocate(capacity: limSize)
        limL.initialize(repeating: 0, count: limSize)
        limR.initialize(repeating: 0, count: limSize)

        var combsL: [UnsafeMutablePointer<Float>] = []
        var combsR: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<combCount {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: combSize)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: combSize)
            l.initialize(repeating: 0, count: combSize)
            r.initialize(repeating: 0, count: combSize)
            combsL.append(l)
            combsR.append(r)
        }
        combL = combsL
        combR = combsR

        combDampL = UnsafeMutablePointer<Float>.allocate(capacity: combCount)
        combDampR = UnsafeMutablePointer<Float>.allocate(capacity: combCount)
        combDampL.initialize(repeating: 0, count: combCount)
        combDampR.initialize(repeating: 0, count: combCount)

        var apsL: [UnsafeMutablePointer<Float>] = []
        var apsR: [UnsafeMutablePointer<Float>] = []
        for _ in 0..<apCount {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: apSize)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: apSize)
            l.initialize(repeating: 0, count: apSize)
            r.initialize(repeating: 0, count: apSize)
            apsL.append(l)
            apsR.append(r)
        }
        apL = apsL
        apR = apsR
    }

    deinit {
        dry.deallocate()
        spatialL.deallocate()
        spatialR.deallocate()
        auL.deallocate()
        auR.deallocate()
        xfL.deallocate()
        xfR.deallocate()
        reflL.deallocate()
        reflR.deallocate()
        lpL.deallocate()
        lpR.deallocate()
        limL.deallocate()
        limR.deallocate()
        for pointer in combL { pointer.deallocate() }
        for pointer in combR { pointer.deallocate() }
        combDampL.deallocate()
        combDampR.deallocate()
        for pointer in apL { pointer.deallocate() }
        for pointer in apR { pointer.deallocate() }
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var offset = 0
        while offset < frames {
            let count = min(frames - offset, maxFrames)
            processChunk(buffer + offset * channelCount, frames: count)
            offset += count
        }
    }

    var auAvailable: Bool {
        auMedium != nil && auLarge != nil
    }

    private func processChunk(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        // Pre-amp gain: ramp within the chunk to avoid clicks while dragging.
        let targetGain = powf(10.0, gainDB.value / 20.0)
        if abs(targetGain - 1.0) > 0.000001 || abs(gainCurrent - 1.0) > 0.000001 {
            let step = (targetGain - gainCurrent) / Float(frames)
            var current = gainCurrent
            for frame in 0..<frames {
                current += step
                buffer[frame * 2 + 0] *= current
                buffer[frame * 2 + 1] *= current
            }
            gainCurrent = targetGain
        }

        eq.process(buffer, frames: frames)
        memcpy(dry, buffer, frames * channelCount * MemoryLayout<Float>.size)

        let widthValue = width.value
        let depthValue = depth.value
        let rawReverbAmount = reverb.value
        let mode = Int(reverbMode.value.rounded())
        // AU 模式做 0.5 校准：UI 50 ≈ SpeakerAmp 的 50% wet
        let reverbAmount = (mode == 1 || mode == 2) ? rawReverbAmount * 0.5 : rawReverbAmount
        let isBypassed = bypass.value

        let sideGain = powf(10.0, (widthValue * 6.0) / 20.0)
        let crossfeedGain = depthValue * powf(10.0, -9.0 / 20.0)
        let reflGain0 = depthValue * powf(10.0, -12.0 / 20.0)
        let reflGain1 = depthValue * powf(10.0, -15.0 / 20.0)
        let reflGain2 = depthValue * powf(10.0, -18.0 / 20.0)
        let targetMix: Float = isBypassed ? 0.0 : 1.0
        let spatialActive = widthValue > 0.001 || depthValue > 0.001

        if spatialActive {
        for frame in 0..<frames {
            let left = dry[frame * 2 + 0]
            let right = dry[frame * 2 + 1]

            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5 * sideGain
            var wetL = mid + side
            var wetR = mid - side

            // crossfeed：对侧信号延迟 10 帧（0.2 ms）混入
            let xfRead = (xfIndex - xfDelay + xfSize) % xfSize
            let delayedL = xfL[xfRead]
            let delayedR = xfR[xfRead]
            wetL += delayedR * crossfeedGain
            wetR += delayedL * crossfeedGain
            xfL[xfIndex] = wetL
            xfR[xfIndex] = wetR
            xfIndex = (xfIndex + 1) % xfSize

            // 早期反射：L 5/11/17 ms，R 7/13/19 ms，低通后混入
            let readL0 = (reflIndex - 240 + reflSize) % reflSize
            let readL1 = (reflIndex - 528 + reflSize) % reflSize
            let readL2 = (reflIndex - 816 + reflSize) % reflSize
            let readR0 = (reflIndex - 336 + reflSize) % reflSize
            let readR1 = (reflIndex - 624 + reflSize) % reflSize
            let readR2 = (reflIndex - 912 + reflSize) % reflSize

            lpL[0] += lpAlpha * (reflL[readL0] - lpL[0])
            lpL[1] += lpAlpha * (reflL[readL1] - lpL[1])
            lpL[2] += lpAlpha * (reflL[readL2] - lpL[2])
            lpR[0] += lpAlpha * (reflR[readR0] - lpR[0])
            lpR[1] += lpAlpha * (reflR[readR1] - lpR[1])
            lpR[2] += lpAlpha * (reflR[readR2] - lpR[2])

            wetL += lpL[0] * reflGain0 + lpL[1] * reflGain1 + lpL[2] * reflGain2
            wetR += lpR[0] * reflGain0 + lpR[1] * reflGain1 + lpR[2] * reflGain2

            reflL[reflIndex] = wetL
            reflR[reflIndex] = wetR
            reflIndex = (reflIndex + 1) % reflSize

            spatialL[frame] = wetL
            spatialR[frame] = wetR
        }
        } else {
            for frame in 0..<frames {
                spatialL[frame] = dry[frame * 2 + 0]
                spatialR[frame] = dry[frame * 2 + 1]
            }
        }

        if reverbAmount > 0.0001 {
            var usedAU = false
            if mode == 1, let au = auMedium {
                memcpy(auL, spatialL, frames * MemoryLayout<Float>.size)
                memcpy(auR, spatialR, frames * MemoryLayout<Float>.size)
                usedAU = au.process(left: auL, right: auR, frames: frames)
            } else if mode == 2, let au = auLarge {
                memcpy(auL, spatialL, frames * MemoryLayout<Float>.size)
                memcpy(auR, spatialR, frames * MemoryLayout<Float>.size)
                usedAU = au.process(left: auL, right: auR, frames: frames)
            }

            if usedAU {
                // AUMatrixReverb 输出全 wet：按 Reverb 滑块做标准 dry/wet
                for frame in 0..<frames {
                    spatialL[frame] = spatialL[frame] * (1.0 - reverbAmount) + auL[frame] * reverbAmount
                    spatialR[frame] = spatialR[frame] * (1.0 - reverbAmount) + auR[frame] * reverbAmount
                }
            } else {
                // 原来的 Schroeder 是 send 式，保留 Custom 的听感
                for frame in 0..<frames {
                    let (reverbL, reverbR) = processReverb(spatialL[frame], spatialR[frame])
                    spatialL[frame] += reverbL * reverbAmount * 0.8
                    spatialR[frame] += reverbR * reverbAmount * 0.8
                }
            }
        }

        for frame in 0..<frames {
            mix += (targetMix - mix) * 0.001
            buffer[frame * 2 + 0] = dry[frame * 2 + 0] * (1.0 - mix) + spatialL[frame] * mix
            buffer[frame * 2 + 1] = dry[frame * 2 + 1] * (1.0 - mix) + spatialR[frame] * mix
        }

        if limiterEnabled.value {
            let threshold = powf(10.0, thresholdDB.value / 20.0)
            applyLimiter(buffer, frames: frames, threshold: threshold)
        }
    }

    private func processReverb(_ inputL: Float, _ inputR: Float) -> (Float, Float) {
        var sumL: Float = 0
        var sumR: Float = 0

        for c in 0..<combCount {
            let idxL = combIndexL[c]
            let readL = (idxL - combDelaysL[c] + combSize) % combSize
            let delayedL = combL[c][readL]
            combDampL[c] = delayedL + 0.3 * (combDampL[c] - delayedL)
            combL[c][idxL] = inputL + combDampL[c] * 0.78
            combIndexL[c] = (idxL + 1) % combSize
            sumL += delayedL

            let idxR = combIndexR[c]
            let readR = (idxR - combDelaysR[c] + combSize) % combSize
            let delayedR = combR[c][readR]
            combDampR[c] = delayedR + 0.3 * (combDampR[c] - delayedR)
            combR[c][idxR] = inputR + combDampR[c] * 0.78
            combIndexR[c] = (idxR + 1) % combSize
            sumR += delayedR
        }

        var outL = sumL * 0.25
        var outR = sumR * 0.25

        for a in 0..<apCount {
            let idxL = apIndexL[a]
            let readL = (idxL - apDelaysL[a] + apSize) % apSize
            let delayedL = apL[a][readL]
            let yL = -outL + delayedL
            apL[a][idxL] = outL + delayedL * 0.5
            apIndexL[a] = (idxL + 1) % apSize
            outL = yL

            let idxR = apIndexR[a]
            let readR = (idxR - apDelaysR[a] + apSize) % apSize
            let delayedR = apR[a][readR]
            let yR = -outR + delayedR
            apR[a][idxR] = outR + delayedR * 0.5
            apIndexR[a] = (idxR + 1) % apSize
            outR = yR
        }

        return (outL, outR)
    }

    private func applyLimiter(_ buffer: UnsafeMutablePointer<Float>,
                              frames: Int,
                              threshold: Float) {
        for frame in 0..<frames {
            let left = buffer[frame * 2 + 0]
            let right = buffer[frame * 2 + 1]

            limL[limIndex] = left
            limR[limIndex] = right

            let instantaneous = max(abs(left), abs(right))
            if instantaneous > limEnv {
                limEnv = instantaneous
            } else {
                limEnv += (instantaneous - limEnv) * 0.0005
            }

            let targetGain = limEnv > 0.000001 ? min(1.0, threshold / limEnv) : 1.0
            if targetGain < limGain {
                limGain += (targetGain - limGain) * 0.3   // 快速 attack
            } else {
                limGain += (targetGain - limGain) * 0.0005 // ~40 ms release
            }

            let readIndex = (limIndex - lookahead + limSize) % limSize
            buffer[frame * 2 + 0] = limL[readIndex] * limGain
            buffer[frame * 2 + 1] = limR[readIndex] * limGain

            limIndex = (limIndex + 1) % limSize
        }
    }
}
