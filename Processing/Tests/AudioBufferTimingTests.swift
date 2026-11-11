import AVFoundation
import Database
import Foundation
import Shared
import Storage
import XCTest
@testable import Processing

/// Authored PCM runs through the actual batcher, native AAC writer/decoder and
/// SQLite source-receipt trigger. No model or installed history is accessed.
final class AudioBufferTimingTests: XCTestCase {
    func testSingleMicrophoneChunkPersistsItsFullInterval() async throws {
        try await checkSingleChunk(source: .microphone)
    }

    func testSingleSystemChunkPersistsItsFullInterval() async throws {
        try await checkSingleChunk(source: .system)
    }

    func testFlushIncludesFinalChunkDurationForBothSources() async throws {
        for source in [AudioSource.microphone, .system] {
            let start = Date(timeIntervalSince1970: 1_700_000_000.125)
            let buffer = AudioBufferManager(maxBufferDuration: 30)
            let first = await buffer.addSample(Self.sample(at: start, duration: 0.25, source: source))
            let second = await buffer.addSample(Self.sample(at: start.addingTimeInterval(0.25),
                                                          duration: 0.5, source: source))
            XCTAssertNil(first); XCTAssertNil(second)
            let batches = await buffer.flush()
            XCTAssertEqual(batches.count, 1)
            let batch = try XCTUnwrap(batches.first)
            XCTAssertEqual(batch.startTimestamp, start)
            XCTAssertEqual(batch.endTimestamp.timeIntervalSince(start), 0.75, accuracy: 0.000_001)
            try await assertDurableInterval(batch, expectedDuration: 0.75)
        }
    }

    func testOverlapStartsFiveSecondsBeforeActualPCMEndForBothSources() async throws {
        for source in [AudioSource.microphone, .system] {
            let start = Date(timeIntervalSince1970: 1_700_000_000.125)
            let buffer = AudioBufferManager(maxBufferDuration: 6)
            let firstValue = await buffer.addSample(Self.sample(at: start, duration: 6, source: source))
            let first = try XCTUnwrap(firstValue)
            XCTAssertEqual(first.endTimestamp.timeIntervalSince(start), 6, accuracy: 0.000_001)
            let secondValue = await buffer.addSample(Self.sample(at: start.addingTimeInterval(6),
                                                               duration: 2, source: source))
            let second = try XCTUnwrap(secondValue)
            XCTAssertEqual(second.startTimestamp.timeIntervalSince(start), 1, accuracy: 0.000_001)
            XCTAssertEqual(second.endTimestamp.timeIntervalSince(start), 8, accuracy: 0.000_001)
            XCTAssertEqual(second.audioData.count, 7 * 16_000 * MemoryLayout<Int16>.size)
            try await assertDurableInterval(first, expectedDuration: 6)
            try await assertDurableInterval(second, expectedDuration: 7)
        }
    }

    private func checkSingleChunk(source: AudioSource) async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000.125)
        let buffer = AudioBufferManager(maxBufferDuration: 0.25)
        let value = await buffer.addSample(Self.sample(at: start, duration: 0.25, source: source))
        let batch = try XCTUnwrap(value)
        XCTAssertEqual(batch.startTimestamp, start)
        XCTAssertEqual(batch.endTimestamp.timeIntervalSince(start), 0.25, accuracy: 0.000_001)
        try await assertDurableInterval(batch, expectedDuration: 0.25)
    }

    private func assertDurableInterval(_ batch: AudioBatch, expectedDuration: Double) async throws {
        let database = DatabaseManager(databasePath: "file:audio-buffer-timing-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-buffer-timing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? await database.close(); try? FileManager.default.removeItem(at: root) }
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let writer = AudioSegmentWriter(storageRoot: root)
        let saved = try await writer.writeFullBatch(audioData: batch.audioData, sampleRate: batch.sampleRate,
            channels: batch.channels, timestamp: batch.startTimestamp, source: batch.source)
        XCTAssertGreaterThan(saved.fileSize, 0)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(saved.filePath))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        XCTAssertGreaterThan(pcm.frameLength, 0)
        let decodedDuration = Double(pcm.frameLength) / file.processingFormat.sampleRate
        XCTAssertEqual(decodedDuration, expectedDuration, accuracy: 0.1, "Allow AAC priming/padding only")
        _ = try await queries.insertRawBatch(startTime: batch.startTimestamp, endTime: batch.endTimestamp,
            source: batch.source, audioPath: saved.filePath, audioSize: saved.fileSize)
        let receipt = try await queries.originalSourceReceipt(forBatchPath: saved.filePath)
        XCTAssertEqual(receipt.source, batch.source)
        let pending = try await queries.getUntranscribedBatches()
        XCTAssertEqual(pending.count, 1)
        let row = try XCTUnwrap(pending.first)
        XCTAssertEqual(row.startTime, batch.startTimestamp)
        XCTAssertEqual(row.endTime.timeIntervalSince(row.startTime), expectedDuration, accuracy: 0.001)
    }

    private static func sample(at start: Date, duration: Double, source: AudioSource) -> CapturedAudio {
        let sampleCount = Int(duration * 16_000)
        let radiansPerSample = 2.0 * Double.pi * 220.0 / 16_000.0
        let samples: [Int16] = (0..<sampleCount).map { index in
            Int16(6_000.0 * sin(Double(index) * radiansPerSample))
        }
        let data = samples.withUnsafeBytes { Data($0) }
        return CapturedAudio(timestamp: start, audioData: data, duration: duration, source: source,
                             sampleRate: 16_000, channels: 1)
    }
}
