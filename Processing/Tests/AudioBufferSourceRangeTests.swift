import Foundation
import Shared
import XCTest
@testable import Processing

final class AudioBufferSourceRangeTests: XCTestCase {
    private let generation = UUID()
    private let continuity = UUID()
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testContiguousPacketsCoalesceAndFiveSecondOverlapClipsSourceOffsetsExactly() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6)
        _ = await buffer.addSample(packet(startSample: 0, count: 48_000))
        let firstValue = await buffer.addSample(packet(startSample: 48_000, count: 48_000))
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.sourceRanges.count, 1)
        XCTAssertEqual(first.sourceRanges.first?.source.startSample, 0)
        XCTAssertEqual(first.sourceRanges.first?.source.sampleCount, 96_000)
        XCTAssertEqual(first.sourceRanges.first?.batchStartSample, 0)
        let secondValue = await buffer.addSample(packet(startSample: 96_000, count: 16_000))
        let second = try XCTUnwrap(secondValue)
        XCTAssertEqual(second.sourceRanges.count, 1)
        XCTAssertEqual(second.sourceRanges.first?.source.startSample, 16_000)
        XCTAssertEqual(second.sourceRanges.first?.source.sampleCount, 96_000)
        XCTAssertEqual(second.sourceRanges.first?.batchStartSample, 0)
        let flushed = await buffer.flush()
        XCTAssertTrue(flushed.isEmpty, "Overlap that already belongs to a saved batch is never emitted twice")
    }

    func testLegacyGapAndNewContinuityNeverManufactureSourceContinuity() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 10)
        _ = await buffer.addSample(packet(startSample: 0, count: 16_000))
        _ = await buffer.addSample(CapturedAudio(timestamp: origin.addingTimeInterval(1), audioData: Data(count: 32_000),
            duration: 1, source: .microphone))
        _ = await buffer.addSample(packet(startSample: 32_000, count: 16_000))
        let otherContinuity = UUID()
        _ = await buffer.addSample(packet(startSample: 0, count: 16_000, continuity: otherContinuity))
        let batches = await buffer.flush()
        let ranges = try XCTUnwrap(batches.first).sourceRanges
        XCTAssertEqual(ranges.map(\.batchStartSample), [0, 32_000, 48_000])
        XCTAssertEqual(ranges.map(\.source.sampleCount), [16_000, 16_000, 16_000])
        XCTAssertEqual(ranges.last?.source.continuityID, otherContinuity)
    }

    func testMalformedPacketIdentityIsNotUsedAndGenerationChangeDoesNotCoalesce() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 10)
        _ = await buffer.addSample(packet(startSample: 0, count: 16_000))
        let invalid = LiveAudioSampleIdentity(recordingGeneration: generation, continuityID: continuity,
            startSample: 16_000, sampleCount: 99, sampleRate: 16_000, approximateOrigin: origin)
        _ = await buffer.addSample(CapturedAudio(timestamp: origin.addingTimeInterval(1), audioData: Data(count: 32_000),
            duration: 1, source: .microphone, sampleIdentity: invalid))
        _ = await buffer.addSample(packet(startSample: 32_000, count: 16_000, generation: UUID()))
        let batches = await buffer.flush()
        XCTAssertEqual(batches.first?.sourceRanges.map(\.batchStartSample), [0, 32_000])
    }

    func testOverlapAcrossTwoContinuitiesPreservesEachExactSlice() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6)
        _ = await buffer.addSample(packet(startSample: 0, count: 48_000))
        let secondContinuity = UUID()
        _ = await buffer.addSample(packet(startSample: 0, count: 48_000, continuity: secondContinuity))
        let batchValue = await buffer.addSample(packet(startSample: 48_000, count: 16_000, continuity: secondContinuity))
        let batch = try XCTUnwrap(batchValue)
        XCTAssertEqual(batch.sourceRanges.map(\.batchStartSample), [0, 32_000])
        XCTAssertEqual(batch.sourceRanges.map(\.source.startSample), [16_000, 0])
        XCTAssertEqual(batch.sourceRanges.map(\.source.sampleCount), [32_000, 64_000])
    }

    func testShutdownTailIncludesExactRetainedOverlapAndNewSamplesOnce() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6)
        _ = await buffer.addSample(packet(startSample: 0, count: 96_000))
        let prematureBatch = await buffer.addSample(packet(startSample: 96_000, count: 8_000))
        XCTAssertNil(prematureBatch)
        let batches = await buffer.flush()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.sourceRanges.first?.source.startSample, 16_000)
        XCTAssertEqual(batches.first?.sourceRanges.first?.source.sampleCount, 88_000)
        XCTAssertEqual(batches.first?.sourceRanges.first?.batchStartSample, 0)
        let secondFlush = await buffer.flush()
        XCTAssertTrue(secondFlush.isEmpty)
    }

    func testOverlapClippingDoesNotOverflowLargeValidSourceCoordinates() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6)
        let start = Int64.max - 112_000
        _ = await buffer.addSample(packet(startSample: start, count: 96_000))
        let batchValue = await buffer.addSample(packet(startSample: start + 96_000, count: 16_000))
        let batch = try XCTUnwrap(batchValue)
        XCTAssertEqual(batch.sourceRanges.first?.source.startSample, start + 16_000)
        XCTAssertEqual(batch.sourceRanges.first?.source.sampleCount, 96_000)
    }

    func testLineageCountIsBoundedAndOmittedPrefixDispositionRecoversAfterOverlap() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6.25)
        var batch: AudioBatch?
        for _ in 0..<400 {
            batch = await buffer.addSample(packet(startSample: 0, count: 250, continuity: UUID())) ?? batch
        }
        let first = try XCTUnwrap(batch)
        XCTAssertEqual(first.audioData.count, 200_000, "The metadata bound never drops PCM")
        XCTAssertEqual(first.sourceRanges.count, AudioBufferManager.maximumSourceRanges)
        XCTAssertTrue(first.sourceMappingIncomplete)
        // The omitted prefix lasts 2.25 seconds; it leaves after a second overlap step.
        let secondValue = await buffer.addSample(packet(startSample: 0, count: 20_000, continuity: UUID()))
        let second = try XCTUnwrap(secondValue)
        XCTAssertLessThanOrEqual(second.sourceRanges.count, AudioBufferManager.maximumSourceRanges)
        XCTAssertTrue(second.sourceMappingIncomplete)
        let thirdValue = await buffer.addSample(packet(startSample: 0, count: 20_000, continuity: UUID()))
        let third = try XCTUnwrap(thirdValue)
        XCTAssertLessThanOrEqual(third.sourceRanges.count, AudioBufferManager.maximumSourceRanges)
        XCTAssertFalse(third.sourceMappingIncomplete, "Dropped provenance stops poisoning later complete batches")
    }

    func testMalformedPrefixAgesOutWhileExactValidTailSurvives() async throws {
        let buffer = AudioBufferManager(maxBufferDuration: 6)
        _ = await buffer.addSample(CapturedAudio(timestamp: origin, audioData: Data([0]), duration: 0,
            source: .microphone))
        let malformedValue = await buffer.addSample(packet(startSample: 0, count: 96_000))
        let malformed = try XCTUnwrap(malformedValue)
        XCTAssertTrue(malformed.sourceMappingIncomplete)
        XCTAssertTrue(malformed.sourceRanges.isEmpty)
        let recoveredValue = await buffer.addSample(packet(startSample: 96_000, count: 16_000))
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertFalse(recovered.sourceMappingIncomplete)
        XCTAssertEqual(recovered.sourceRanges.count, 1)
        XCTAssertEqual(recovered.sourceRanges.first?.source.startSample, 16_000)
        XCTAssertEqual(recovered.sourceRanges.first?.source.sampleCount, 96_000)
        XCTAssertEqual(recovered.sourceRanges.first?.batchStartSample, 0)
    }

    private func packet(startSample: Int64, count: Int64, continuity: UUID? = nil, generation: UUID? = nil) -> CapturedAudio {
        let identity = LiveAudioSampleIdentity(recordingGeneration: generation ?? self.generation,
            continuityID: continuity ?? self.continuity, startSample: startSample, sampleCount: count,
            sampleRate: 16_000, approximateOrigin: origin)
        return CapturedAudio(timestamp: origin.addingTimeInterval(Double(startSample) / 16_000),
            audioData: Data(count: Int(count) * 2), duration: Double(count) / 16_000,
            source: .microphone, sampleIdentity: identity)
    }
}

