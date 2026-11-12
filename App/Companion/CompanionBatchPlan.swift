import Foundation
import Database
import Shared

/// Exact source plan kept independent of transport and wall-clock windows.
struct CompanionBatchPlan {
    let manifest: AudioMediaManifest
    let identity: LiveAudioSampleIdentity
    let references: [V23TranscriptReference]
    let firstPassText: String
    let key: String
    private struct Identity: Codable {
        let enrollmentID: UUID
        let manifest: AudioMediaManifest
        let references: [V23TranscriptReference]
        let firstPassText: String
    }
    private struct Plan: Codable { let batchKey: String; let coverageJobIDs: [String] }
    init(manifest: AudioMediaManifest, records: [AudioTranscription], nativeStoreID: UUID, enrollmentID: UUID) throws {
        guard manifest.nativeStoreID == nativeStoreID, manifest.source == .microphone,
              let first = manifest.sourceRanges.first, manifest.sourceRanges.count <= 32 else { throw CompanionError.invalidPayload }
        references = try CompanionTranscriptSnapshot.firstPassReferences(for: records, nativeStoreID: nativeStoreID)
        guard records.allSatisfy({ $0.batchAudioPath == manifest.relativePath }) else { throw CompanionError.staleEvidence }
        firstPassText = records.map(\.text).joined(separator: "\n"); try CompanionBounds.text(firstPassText, max: 128 * 1024, empty: true)
        var end = first.source.startSample
        for range in manifest.sourceRanges {
            guard range.source.isValid, range.source.recordingGeneration == first.source.recordingGeneration,
                  range.source.continuityID == first.source.continuityID,
                  CompanionWire.sameWireDate(range.source.approximateOrigin, first.source.approximateOrigin),
                  range.source.startSample == end else { throw CompanionError.invalidPayload }
            end += range.source.sampleCount
        }
        identity = .init(recordingGeneration: first.source.recordingGeneration, continuityID: first.source.continuityID,
            startSample: first.source.startSample, sampleCount: end - first.source.startSample, sampleRate: 16000, approximateOrigin: first.source.approximateOrigin)
        guard identity.isValid else { throw CompanionError.invalidPayload }
        self.manifest = manifest
        let bytes = try CompanionWire.encode(Identity(enrollmentID: enrollmentID, manifest: manifest, references: references, firstPassText: firstPassText))
        guard bytes.count <= 768 * 1024 else { throw CompanionError.capacityExceeded }; key = CompanionWire.digest(bytes)
    }
    func planPayload(dependencyIDs: [String]) throws -> Data {
        guard dependencyIDs.count <= 256, Set(dependencyIDs).count == dependencyIDs.count else { throw CompanionError.capacityExceeded }
        return try CompanionWire.encode(Plan(batchKey: key, coverageJobIDs: dependencyIDs.sorted()))
    }
    func request(window: LiveAudioSampleIdentity, byteCount: Int) -> CompanionJobRequest {
        let mediaID = CompanionController.mediaID(manifest)
        let slices = manifest.sourceRanges.compactMap { range -> CompanionMediaSlice? in
            let start = max(range.source.startSample, window.startSample)
            let end = min(range.source.startSample + range.source.sampleCount, window.startSample + window.sampleCount)
            guard start < end else { return nil }
            return .init(sha256: manifest.sha256, byteCount: byteCount, mediaID: mediaID,
                offsetSamples: range.batchStartSample + start - range.source.startSample,
                countSamples: end - start, sourceStartSample: start)
        }
        return .init(sourceStoreID: manifest.nativeStoreID,
            observedAt: window.approximateOrigin.addingTimeInterval(Double(window.startSample) / 16000),
            speaker: .init(sourceIdentity: window, firstPassText: firstPassText, media: slices,
                firstPassReferences: references, firstPassSourceIdentity: identity))
    }
}
