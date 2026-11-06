#pragma once

#include <algorithm>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace soundbridge {

constexpr uint32_t kRingMagic = 0x53425231; // "SBR1"
constexpr uint32_t kRingVersion = 1;
constexpr uint32_t kRingChannels = 2;
constexpr uint32_t kRingCapacity = 16384;
constexpr size_t kRingHeaderSize = 128;
constexpr const char* kRingPath = "/tmp/soundbridge_ring_v1";

struct RingHeader {
    uint32_t magic;
    uint32_t version;
    uint32_t channels;
    uint32_t capacity;
    uint32_t sampleRate;
    uint32_t reserved;
    std::atomic<int64_t> writeIndex;
    std::atomic<int64_t> readIndex;
    uint8_t padding[kRingHeaderSize - 40];
};

static_assert(sizeof(RingHeader) == kRingHeaderSize, "ring header size");
static_assert(offsetof(RingHeader, writeIndex) == 24, "write index offset");
static_assert(offsetof(RingHeader, readIndex) == 32, "read index offset");

class SharedRingWriter {
public:
    SharedRingWriter() {
        fd_ = ::open(kRingPath, O_CREAT | O_RDWR, 0666);
        if (fd_ < 0) {
            return;
        }
        // Ensure both _coreaudiod and the user app can read/write.
        ::chmod(kRingPath, 0666);

        size_ = kRingHeaderSize + kRingCapacity * kRingChannels * sizeof(float);
        if (::ftruncate(fd_, static_cast<off_t>(size_)) != 0) {
            ::close(fd_);
            fd_ = -1;
            return;
        }

        base_ = ::mmap(nullptr, size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
        if (base_ == MAP_FAILED) {
            base_ = nullptr;
            ::close(fd_);
            fd_ = -1;
            return;
        }

        header_ = static_cast<RingHeader*>(base_);
        header_->magic = kRingMagic;
        header_->version = kRingVersion;
        header_->channels = kRingChannels;
        header_->capacity = kRingCapacity;
        header_->sampleRate = 48000;
        header_->reserved = 0;
        header_->writeIndex.store(0, std::memory_order_relaxed);
        header_->readIndex.store(0, std::memory_order_relaxed);

        data_ = reinterpret_cast<float*>(
            static_cast<uint8_t*>(base_) + kRingHeaderSize
        );
    }

    ~SharedRingWriter() {
        if (base_ != nullptr) {
            ::munmap(base_, size_);
        }
        if (fd_ >= 0) {
            ::close(fd_);
        }
    }

    SharedRingWriter(const SharedRingWriter&) = delete;
    SharedRingWriter& operator=(const SharedRingWriter&) = delete;

    bool valid() const {
        return header_ != nullptr && data_ != nullptr;
    }

    void Write(const float* source, uint32_t frames) {
        if (!valid() || source == nullptr || frames == 0) {
            return;
        }

        const int64_t write = header_->writeIndex.load(std::memory_order_relaxed);
        const int64_t read = header_->readIndex.load(std::memory_order_acquire);
        const int64_t available = static_cast<int64_t>(kRingCapacity) - (write - read);
        const int64_t count = std::min<int64_t>(
            static_cast<int64_t>(frames),
            std::max<int64_t>(available, 0)
        );
        if (count <= 0) {
            return;
        }

        const uint32_t offset = static_cast<uint32_t>(write % kRingCapacity);
        const uint32_t first = std::min<uint32_t>(
            static_cast<uint32_t>(count),
            kRingCapacity - offset
        );
        std::memcpy(data_ + offset * kRingChannels, source,
                    first * kRingChannels * sizeof(float));
        if (static_cast<uint32_t>(count) > first) {
            std::memcpy(data_, source + first * kRingChannels,
                        (static_cast<uint32_t>(count) - first) *
                            kRingChannels * sizeof(float));
        }

        header_->writeIndex.store(write + count, std::memory_order_release);
    }

private:
    int fd_ = -1;
    size_t size_ = 0;
    void* base_ = nullptr;
    RingHeader* header_ = nullptr;
    float* data_ = nullptr;
};

} // namespace soundbridge
