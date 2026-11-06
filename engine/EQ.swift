import Foundation
import Darwin

// ============================================================
//  10-band peaking EQ（P6）
//
//  频点与 SpeakerAmp 的 Free 10-band 一致：
//    50 / 150 / 300 / 600 / 1k / 3k / 6k / 9k / 12k / 15k Hz
//  ±12 dB，固定 Q = 1.2
//
//  bypass 用 20 ms dry/wet 交叉淡化；所有增益为 0 时完全跳过，
//  不增加 CPU。状态/系数都在 init 预分配，实时线程不分配内存。
// ============================================================

final class EQDSP {
    static let bandCount = 10
    static let frequencies: [Float] = [50, 150, 300, 600, 1000, 3000, 6000, 9000, 12000, 15000]

    let gains: [AtomicFloat] = (0..<EQDSP.bandCount).map { _ in AtomicFloat(0) }
    let bypass = AtomicBool(false)

    private let sampleRate: Float = 48000
    private let q: Float = 1.2
    private let maxFrames = 4096
    private let channelCount = 2

    private let dry: UnsafeMutablePointer<Float>
    private let z1: UnsafeMutablePointer<Float>
    private let z2: UnsafeMutablePointer<Float>
    private let b0: UnsafeMutablePointer<Float>
    private let b1: UnsafeMutablePointer<Float>
    private let b2: UnsafeMutablePointer<Float>
    private let a1: UnsafeMutablePointer<Float>
    private let a2: UnsafeMutablePointer<Float>

    private var active = [Bool](repeating: false, count: EQDSP.bandCount)
    private var lastGains = [Float](repeating: -999, count: EQDSP.bandCount)
    private var mix: Float = 1.0

    init() {
        let bands = EQDSP.bandCount
        dry = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channelCount)
        dry.initialize(repeating: 0, count: maxFrames * channelCount)
        z1 = UnsafeMutablePointer<Float>.allocate(capacity: bands * channelCount)
        z2 = UnsafeMutablePointer<Float>.allocate(capacity: bands * channelCount)
        z1.initialize(repeating: 0, count: bands * channelCount)
        z2.initialize(repeating: 0, count: bands * channelCount)
        b0 = UnsafeMutablePointer<Float>.allocate(capacity: bands)
        b1 = UnsafeMutablePointer<Float>.allocate(capacity: bands)
        b2 = UnsafeMutablePointer<Float>.allocate(capacity: bands)
        a1 = UnsafeMutablePointer<Float>.allocate(capacity: bands)
        a2 = UnsafeMutablePointer<Float>.allocate(capacity: bands)
        b0.initialize(repeating: 1, count: bands)
        b1.initialize(repeating: 0, count: bands)
        b2.initialize(repeating: 0, count: bands)
        a1.initialize(repeating: 0, count: bands)
        a2.initialize(repeating: 0, count: bands)
        recompute()
    }

    deinit {
        dry.deallocate()
        z1.deallocate()
        z2.deallocate()
        b0.deallocate()
        b1.deallocate()
        b2.deallocate()
        a1.deallocate()
        a2.deallocate()
    }

    func process(_ buffer: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let target: Float = bypass.value ? 0 : 1
        if target == 0 && mix <= 0.0001 {
            mix = 0
            return
        }

        memcpy(dry, buffer, frames * channelCount * MemoryLayout<Float>.size)

        var changed = false
        for i in 0..<Self.bandCount {
            if abs(gains[i].value - lastGains[i]) > 0.001 {
                changed = true
                break
            }
        }
        if changed { recompute() }

        if active.contains(true) {
            for frame in 0..<frames {
                var left = buffer[frame * 2 + 0]
                var right = buffer[frame * 2 + 1]

                for band in 0..<Self.bandCount where active[band] {
                    let stateL = band * 2
                    let stateR = band * 2 + 1

                    let yL = b0[band] * left + z1[stateL]
                    z1[stateL] = b1[band] * left - a1[band] * yL + z2[stateL]
                    z2[stateL] = b2[band] * left - a2[band] * yL
                    left = yL

                    let yR = b0[band] * right + z1[stateR]
                    z1[stateR] = b1[band] * right - a1[band] * yR + z2[stateR]
                    z2[stateR] = b2[band] * right - a2[band] * yR
                    right = yR
                }

                buffer[frame * 2 + 0] = left
                buffer[frame * 2 + 1] = right
            }
        }

        if mix != target {
            for frame in 0..<frames {
                mix += (target - mix) * 0.001
                buffer[frame * 2 + 0] = dry[frame * 2 + 0] * (1.0 - mix) + buffer[frame * 2 + 0] * mix
                buffer[frame * 2 + 1] = dry[frame * 2 + 1] * (1.0 - mix) + buffer[frame * 2 + 1] * mix
            }
        }
    }

    private func recompute() {
        for band in 0..<Self.bandCount {
            let gain = gains[band].value
            lastGains[band] = gain

            if abs(gain) <= 0.01 {
                active[band] = false
                b0[band] = 1
                b1[band] = 0
                b2[band] = 0
                a1[band] = 0
                a2[band] = 0
                z1[band * 2] = 0
                z1[band * 2 + 1] = 0
                z2[band * 2] = 0
                z2[band * 2 + 1] = 0
                continue
            }

            active[band] = true
            let frequency = Self.frequencies[band]
            let a = powf(10.0, gain / 40.0)
            let w0 = 2.0 * Float.pi * frequency / sampleRate
            let cosW = cosf(w0)
            let sinW = sinf(w0)
            let alpha = sinW / (2.0 * q)
            let a0 = 1.0 + alpha / a

            b0[band] = (1.0 + alpha * a) / a0
            b1[band] = (-2.0 * cosW) / a0
            b2[band] = (1.0 - alpha * a) / a0
            a1[band] = (-2.0 * cosW) / a0
            a2[band] = (1.0 - alpha / a) / a0
        }
    }
}
