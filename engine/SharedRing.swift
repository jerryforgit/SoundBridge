import Foundation
import Darwin

// 读取插件写入的共享内存 ring。
// 插件（coreaudiod 驱动宿主）负责创建 /tmp/soundbridge_ring_v1，
// App 只读/发布 readIndex，不打开虚拟设备的 input stream，因此不需要麦克风权限。

final class SharedRing {
    static let path = "/tmp/soundbridge_ring_v1"
    static let headerSize = 128
    static let capacity = 16384
    static let channels = 2
    static let magic: UInt32 = 0x53425231
    static let version: UInt32 = 1

    private var fd: Int32 = -1
    private var base: UnsafeMutableRawPointer?
    private var size: Int = 0
    private var dataPointer: UnsafeMutablePointer<Float>?

    init?() {
        fd = open(Self.path, O_RDWR)
        guard fd >= 0 else { return nil }

        size = Self.headerSize + Self.capacity * Self.channels * MemoryLayout<Float>.size
        let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let mapped else {
            close(fd)
            fd = -1
            return nil
        }
        base = mapped

        let magic = mapped.load(fromByteOffset: 0, as: UInt32.self)
        let version = mapped.load(fromByteOffset: 4, as: UInt32.self)
        let channels = mapped.load(fromByteOffset: 8, as: UInt32.self)
        let capacity = mapped.load(fromByteOffset: 12, as: UInt32.self)
        guard magic == Self.magic,
              version == Self.version,
              channels == Self.channels,
              capacity == Self.capacity else {
            munmap(mapped, size)
            close(fd)
            fd = -1
            base = nil
            return nil
        }

        dataPointer = mapped.advanced(by: Self.headerSize)
            .assumingMemoryBound(to: Float.self)
    }

    deinit {
        if let base {
            munmap(base, size)
        }
        if fd >= 0 {
            close(fd)
        }
    }

    private var writeIndexPointer: UnsafeMutablePointer<Int64>? {
        guard let base else { return nil }
        return base.advanced(by: 24).assumingMemoryBound(to: Int64.self)
    }

    private var readIndexPointer: UnsafeMutablePointer<Int64>? {
        guard let base else { return nil }
        return base.advanced(by: 32).assumingMemoryBound(to: Int64.self)
    }

    var writePosition: Int64 {
        writeIndexPointer?.pointee ?? 0
    }

    var readPosition: Int64 {
        readIndexPointer?.pointee ?? 0
    }

    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard let dataPointer,
              let writePointer = writeIndexPointer,
              let readPointer = readIndexPointer,
              frames > 0 else {
            return 0
        }

        let write = writePointer.pointee
        var read = readPointer.pointee

        // 插件重启/重新初始化后 write 会回到 0，读指针也要跟上。
        if write < read {
            readPointer.pointee = write
            read = write
        }

        let available = min(frames, Int(write - read))
        guard available > 0 else { return 0 }

        OSMemoryBarrier()
        let offset = Int(read % Int64(Self.capacity))
        let first = min(available, Self.capacity - offset)
        memcpy(destination,
               dataPointer + offset * Self.channels,
               first * Self.channels * MemoryLayout<Float>.size)
        if available > first {
            memcpy(destination + first * Self.channels,
                   dataPointer,
                   (available - first) * Self.channels * MemoryLayout<Float>.size)
        }
        OSMemoryBarrier()
        readPointer.pointee = read + Int64(available)
        return available
    }
}
