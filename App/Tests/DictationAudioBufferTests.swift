import XCTest
import Shared
@testable import App

final class DictationAudioBufferTests: XCTestCase {
    func testSliceReturnsOnlyAudioInsideRequestedInterval() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let buffer = DictationAudioBuffer(maxDuration: 10)

        await buffer.append(makeAudio(values: Array(0..<10), timestamp: start))
        await buffer.append(makeAudio(values: Array(10..<20), timestamp: start.addingTimeInterval(1)))

        let slice = await buffer.slice(
            from: start.addingTimeInterval(0.3),
            to: start.addingTimeInterval(1.2)
        )

        XCTAssertNotNil(slice)
        XCTAssertEqual(readInt16Values(slice!.audioData), Array(3..<12))
        XCTAssertEqual(slice!.sampleRate, 10)
        XCTAssertEqual(slice!.channels, 1)
        XCTAssertEqual(slice!.duration, 0.9, accuracy: 0.0001)
    }

    func testAppendDropsSamplesOlderThanRetentionWindow() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let buffer = DictationAudioBuffer(maxDuration: 1.5)

        await buffer.append(makeAudio(values: Array(0..<10), timestamp: start))
        await buffer.append(makeAudio(values: Array(10..<20), timestamp: start.addingTimeInterval(1)))
        await buffer.append(makeAudio(values: Array(20..<30), timestamp: start.addingTimeInterval(2)))

        let slice = await buffer.slice(from: start, to: start.addingTimeInterval(3))

        XCTAssertEqual(readInt16Values(slice!.audioData), Array(10..<30))
    }

    func testSliceRemainsChronologicalWhenSamplesArriveOutOfOrder() async {
        let start = Date(timeIntervalSince1970: 1_000)
        let buffer = DictationAudioBuffer(maxDuration: 10)

        await buffer.append(makeAudio(values: Array(10..<20), timestamp: start.addingTimeInterval(1)))
        await buffer.append(makeAudio(values: Array(0..<10), timestamp: start))

        let slice = await buffer.slice(from: start, to: start.addingTimeInterval(2))

        XCTAssertEqual(readInt16Values(slice!.audioData), Array(0..<20))
    }

    private func makeAudio(values: [Int], timestamp: Date) -> CapturedAudio {
        CapturedAudio(
            timestamp: timestamp,
            audioData: Data(int16Values: values.map(Int16.init)),
            duration: 1,
            source: .microphone,
            sampleRate: 10,
            channels: 1
        )
    }

    private func readInt16Values(_ data: Data) -> [Int] {
        stride(from: 0, to: data.count, by: 2).map { offset in
            let value = data.withUnsafeBytes { rawBuffer -> Int16 in
                rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            }
            return Int(value)
        }
    }
}

private extension Data {
    init(int16Values values: [Int16]) {
        self = values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
