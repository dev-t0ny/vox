import Foundation
import os

/// SPSC lock-free ring buffer for audio samples.
final class RingBuffer: @unchecked Sendable {

    private let capacity: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex: Int = 0
    private var count: Int = 0
    private var sumOfSquares: Double = 0.0
    private var rmsCount: Int = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Number of samples currently available to read.
    var availableSamples: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count
    }

    /// Root mean square of all samples written since last readAll/reset.
    var currentRMS: Float {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard rmsCount > 0 else { return 0.0 }
        return Float(sqrt(sumOfSquares / Double(rmsCount)))
    }

    /// Write samples into the buffer, overwriting oldest data on overflow.
    func write(_ samples: [Float]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity {
                count += 1
            }
            sumOfSquares += Double(sample * sample)
            rmsCount += 1
        }
    }

    /// Read all available samples in order from oldest to newest, clearing the buffer.
    func readAll() -> [Float] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard count > 0 else { return [] }

        var result = [Float]()
        result.reserveCapacity(count)

        // The oldest sample is at (writeIndex - count + capacity) % capacity
        let readStart = (writeIndex - count + capacity) % capacity
        for i in 0..<count {
            let idx = (readStart + i) % capacity
            result.append(buffer[idx])
        }

        count = 0
        sumOfSquares = 0.0
        rmsCount = 0

        return result
    }

    /// Reset the buffer to empty state.
    func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writeIndex = 0
        count = 0
        sumOfSquares = 0.0
        rmsCount = 0
    }
}
