import Foundation
import AudioToolbox
import CoreAudio

// ============================================================
//  Apple AUMatrixReverb wrapper
//
//  SpeakerAmp 的 3D reverb 就是这个 Audio Unit（AVAudioUnitReverb 底层）。
//  我们用同一个 preset + full-wet 输出，再在 SpatialDSP 里按 Reverb
//  滑块做 dry/wet 混合，从而匹配 SpeakerAmp 的 Hall 50%。
//
//  process() 只在实时线程调用；初始化在 main thread 完成。
// ============================================================

final class MatrixReverbAU {
    private var unit: AudioUnit?
    private let abl: UnsafeMutableRawPointer
    private var sampleTime: Float64 = 0
    let latency: Float64

    // preset: 3 = Medium Hall, 4 = Large Hall
    init?(preset: Int, sampleRate: Double = 48000) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_MatrixReverb,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &description) else {
            return nil
        }

        var createdUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &createdUnit) == noErr,
              let createdUnit else {
            return nil
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat |
                           kAudioFormatFlagIsPacked |
                           kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(createdUnit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &format, formatSize) == noErr,
              AudioUnitSetProperty(createdUnit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 0, &format, formatSize) == noErr else {
            AudioComponentInstanceDispose(createdUnit)
            return nil
        }

        var maxFrames: UInt32 = 4096
        AudioUnitSetProperty(createdUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames,
                             UInt32(MemoryLayout<UInt32>.size))

        var auPreset = AUPreset()
        auPreset.presetNumber = Int32(preset)
        auPreset.presetName = nil
        AudioUnitSetProperty(createdUnit, kAudioUnitProperty_PresentPreset,
                             kAudioUnitScope_Global, 0, &auPreset,
                             UInt32(MemoryLayout<AUPreset>.size))

        // 我们在 DSP 里自己做 dry/wet，所以 AU 输出全 wet。
        AudioUnitSetParameter(createdUnit, AudioUnitParameterID(kReverbParam_DryWetMix),
                              kAudioUnitScope_Global, 0, 100.0, 0)

        guard AudioUnitInitialize(createdUnit) == noErr else {
            AudioComponentInstanceDispose(createdUnit)
            return nil
        }

        var reportedLatency: Float64 = 0
        var latencySize = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(createdUnit, kAudioUnitProperty_Latency,
                             kAudioUnitScope_Global, 0, &reportedLatency, &latencySize)

        unit = createdUnit
        latency = reportedLatency

        let ablSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        abl = UnsafeMutableRawPointer.allocate(byteCount: ablSize,
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
        let list = UnsafeMutableAudioBufferListPointer(
            abl.assumingMemoryBound(to: AudioBufferList.self)
        )
        list.count = 2
        for index in 0..<2 {
            list[index] = AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: 0,
                                      mData: nil)
        }
    }

    deinit {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        abl.deallocate()
    }

    func reset() {
        if let unit {
            AudioUnitReset(unit, kAudioUnitScope_Global, 0)
        }
        sampleTime = 0
    }

    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 frames: Int) -> Bool {
        guard let unit, frames > 0 else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            abl.assumingMemoryBound(to: AudioBufferList.self)
        )
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        list[0].mNumberChannels = 1
        list[0].mDataByteSize = byteSize
        list[0].mData = UnsafeMutableRawPointer(left)
        list[1].mNumberChannels = 1
        list[1].mDataByteSize = byteSize
        list[1].mData = UnsafeMutableRawPointer(right)

        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = sampleTime
        timestamp.mFlags = .sampleTimeValid

        let status = AudioUnitProcess(
            unit,
            nil,
            &timestamp,
            UInt32(frames),
            abl.assumingMemoryBound(to: AudioBufferList.self)
        )

        sampleTime += Float64(frames)
        return status == noErr
    }
}
