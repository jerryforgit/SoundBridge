// SoundBridge HAL plugin v0
//
// 目标（P2）：
//   - 发布一个 2ch / 48 kHz / float32 的虚拟输出设备 "SoundBridge"
//   - 同时提供 input stream（loopback），供用户态引擎读取
//   - 输出流带 Volume / Mute 控件，让系统音量键、OSD、控制中心原生可用
//   - 插件本身不做 DSP、不碰物理设备；这些在引擎里做
//
// 这里使用 libASPL（MIT）处理 AudioServerPlugIn 的样板代码和属性分发。
// 我们只实现 loopback ring 和少量设备参数。

#include <aspl/Device.hpp>
#include <aspl/Driver.hpp>
#include <aspl/IORequestHandler.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Stream.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include "SharedRing.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannelCount = 2;
constexpr UInt32 kRingFrames = 16384;

// 虚拟设备的 loopback 固定延迟。512 帧 = 10.7 ms @ 48 kHz。
// 读指针落后写指针这么多，保证输入侧拿到的是已经写进 ring 的数据。
constexpr UInt32 kLoopLatencyFrames = 512;

AudioStreamBasicDescription MakeFloat32Format()
{
    AudioStreamBasicDescription format = {};
    format.mSampleRate = kSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = kChannelCount;
    format.mBytesPerFrame = sizeof(Float32) * kChannelCount;
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = sizeof(Float32) * kChannelCount;
    return format;
}

// 输出流写入的混音数据 → ring → 输入流读出。
// 只由 HAL 的实时 IO 线程访问，不加锁、不分配内存。
class LoopbackHandler : public aspl::IORequestHandler
{
public:
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        if (bytes == nullptr || bytesCount < sizeof(Float32) * kChannelCount) {
            return;
        }
        const UInt32 frames = bytesCount / (sizeof(Float32) * kChannelCount);
        CopyIntoRing(static_cast<const Float32*>(bytes), frames, timestamp);
        sharedRing_.Write(static_cast<const Float32*>(bytes), frames);
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& /*client*/,
        const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        if (bytes == nullptr || bytesCount < sizeof(Float32) * kChannelCount) {
            return;
        }
        const UInt32 frames = bytesCount / (sizeof(Float32) * kChannelCount);
        CopyFromRing(static_cast<Float32*>(bytes), frames, timestamp - kLoopLatencyFrames);
    }

private:
    static UInt32 RingOffset(Float64 timestamp)
    {
        if (!std::isfinite(timestamp)) {
            return 0;
        }
        const int64_t frame = static_cast<int64_t>(timestamp);
        const int64_t wrapped = ((frame % static_cast<int64_t>(kRingFrames)) +
                                 static_cast<int64_t>(kRingFrames)) %
                                static_cast<int64_t>(kRingFrames);
        return static_cast<UInt32>(wrapped);
    }

    void CopyIntoRing(const Float32* source, UInt32 frames, Float64 timestamp)
    {
        const UInt32 offset = RingOffset(timestamp);
        const UInt32 first = std::min(frames, kRingFrames - offset);
        std::memcpy(&ring_[offset * kChannelCount], source,
            first * kChannelCount * sizeof(Float32));
        if (frames > first) {
            std::memcpy(&ring_[0], source + first * kChannelCount,
                (frames - first) * kChannelCount * sizeof(Float32));
        }
    }

    void CopyFromRing(Float32* destination, UInt32 frames, Float64 timestamp)
    {
        const UInt32 offset = RingOffset(timestamp);
        const UInt32 first = std::min(frames, kRingFrames - offset);
        std::memcpy(destination, &ring_[offset * kChannelCount],
            first * kChannelCount * sizeof(Float32));
        if (frames > first) {
            std::memcpy(destination + first * kChannelCount, &ring_[0],
                (frames - first) * kChannelCount * sizeof(Float32));
        }
    }

    std::array<Float32, kRingFrames * kChannelCount> ring_{};
    soundbridge::SharedRingWriter sharedRing_{};
};

std::shared_ptr<aspl::Driver> CreateDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "SoundBridge";
    deviceParams.Manufacturer = "Jerry";
    deviceParams.DeviceUID = "com.jerry.soundbridge.device";
    deviceParams.ModelUID = "com.jerry.soundbridge.model";
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    deviceParams.CanBeDefault = true;
    deviceParams.CanBeDefaultForSystemSounds = true;
    deviceParams.EnableMixing = true;
    deviceParams.ZeroTimeStampPeriod = 512;
    deviceParams.ClockIsStable = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    aspl::StreamParameters outputParams;
    outputParams.Direction = aspl::Direction::Output;
    outputParams.Format = MakeFloat32Format();
    auto outputStream = device->AddStreamWithControlsAsync(outputParams);

    aspl::StreamParameters inputParams;
    inputParams.Direction = aspl::Direction::Input;
    inputParams.Format = MakeFloat32Format();
    auto inputStream = device->AddStreamAsync(inputParams);

    auto handler = std::make_shared<LoopbackHandler>();
    device->SetIOHandler(handler);

    // 让流对象保持到设备生命周期结束（AddStream* 内部已经持有 shared_ptr，
    // 这里只是显式使用一下，避免编译器警告）。
    (void)outputStream;
    (void)inputStream;

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* SoundBridge_Create(CFAllocatorRef /*allocator*/, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateDriver();
    return driver->GetReference();
}
