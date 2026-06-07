/// Lock-free SPSC ring buffer for bridging IOProc (producer) to AVAudioEngine (consumer).
/// Power-of-2 capacity, wrapping integer arithmetic for correctness.
final class AudioRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    private var _writeHead: UInt64 = 0
    private var _readHead: UInt64 = 0

    init(capacityFrames: Int, channels: Int) {
        let cap = capacityFrames * channels
        var power = 1
        while power < cap { power *= 2 }
        self.capacity = power
        self.mask = power - 1
        self.buffer = .allocate(capacity: power)
        self.buffer.initialize(repeating: 0.0, count: power)
    }

    deinit { buffer.deallocate() }

    var availableToRead: Int {
        // Clamp to capacity: if the producer has lapped the consumer the raw
        // distance can exceed the backing store, and only the most recent
        // `capacity` samples are actually still present.
        return min(Int(_writeHead &- _readHead), capacity)
    }

    func write(_ data: UnsafePointer<Float>, count: Int) {
        for i in 0..<count {
            buffer[Int(_writeHead) & mask] = data[i]
            _writeHead &+= 1
        }
    }

    func read(_ dest: UnsafeMutablePointer<Float>, count: Int) -> Int {
        // Overrun recovery: if the producer lapped us, the slots between the
        // read head and (writeHead - capacity) hold data that has already been
        // overwritten. Fast-forward the read head (owned by this consumer
        // thread) to the oldest still-valid sample so we resync cleanly instead
        // of emitting a torn mix of old and new frames.
        if Int(_writeHead &- _readHead) > capacity {
            _readHead = _writeHead &- UInt64(capacity)
        }
        let toRead = min(count, availableToRead)
        for i in 0..<toRead {
            dest[i] = buffer[Int(_readHead) & mask]
            _readHead &+= 1
        }
        return toRead
    }
}
