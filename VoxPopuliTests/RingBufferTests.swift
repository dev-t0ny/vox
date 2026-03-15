import XCTest
@testable import VoxPopuli

final class RingBufferTests: XCTestCase {

    func testWriteAndRead() {
        let buffer = RingBuffer(capacity: 16)
        buffer.write([1, 2, 3, 4, 5])
        let result = buffer.readAll()
        XCTAssertEqual(result, [1, 2, 3, 4, 5])
    }

    func testReadAllClearsBuffer() {
        let buffer = RingBuffer(capacity: 16)
        buffer.write([1, 2, 3])
        _ = buffer.readAll()
        let result = buffer.readAll()
        XCTAssertEqual(result, [])
    }

    func testOverflowWrapsAround() {
        let buffer = RingBuffer(capacity: 8)
        buffer.write([1, 2, 3, 4, 5, 6, 7, 8])
        buffer.write([9, 10])
        let result = buffer.readAll()
        // Should contain the 8 most recent samples
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result, [3, 4, 5, 6, 7, 8, 9, 10])
    }

    func testAvailableSamplesCount() {
        let buffer = RingBuffer(capacity: 16)
        XCTAssertEqual(buffer.availableSamples, 0)
        buffer.write([1, 2, 3])
        XCTAssertEqual(buffer.availableSamples, 3)
    }

    func testRMSCalculation() {
        let buffer = RingBuffer(capacity: 16)
        buffer.write([0, 0, 0, 0])
        XCTAssertEqual(buffer.currentRMS, 0.0, accuracy: 0.0001)

        // Reset and write new values
        buffer.reset()
        buffer.write([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(buffer.currentRMS, 0.5, accuracy: 0.0001)
    }

    func testReset() {
        let buffer = RingBuffer(capacity: 16)
        buffer.write([1, 2, 3, 4, 5])
        buffer.reset()
        XCTAssertEqual(buffer.availableSamples, 0)
        XCTAssertEqual(buffer.readAll(), [])
    }
}
