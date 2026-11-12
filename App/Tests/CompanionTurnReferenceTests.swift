import Foundation
import Shared
import XCTest
@testable import App

final class CompanionTurnReferenceTests: XCTestCase {
    func testLateCancellationOfSupersededPreparationPreservesNewPlaybackAdmission() throws {
        let admission = CompanionTurnPlaybackAdmission(), fixture = make(start: 0, end: 1)
        let old = admission.begin(fixture.1)
        let current = admission.begin(fixture.1)
        // Simulates the old caller's cancellation handler running after the replacement
        // play has joined that preparation and begun its own admission.
        admission.cancel(old)
        XCTAssertNoThrow(try admission.check(current))
        XCTAssertThrowsError(try admission.check(old))
        admission.cancel(current)
        XCTAssertThrowsError(try admission.check(current))
    }

    func testTurnUsesEnclosingSamplesAndPreservesOriginalFirstPassScope() throws {
        let fixture = make(start: 0.00001, end: 0.10001)
        let turn = try CompanionTurnResolver.resolve(fixture.0, reference: fixture.1)
        XCTAssertEqual(turn.sourceIdentity.startSample, 32000)
        XCTAssertEqual(turn.sourceIdentity.sampleCount, 1601)
        XCTAssertEqual(turn.firstPassText, "Full original first-pass text")
        XCTAssertEqual(turn.firstPassSourceIdentity.startSample, 0)
        XCTAssertEqual(turn.speakerStatus, .anonymous)
        XCTAssertEqual(turn.displayLabel, "Speaker 1")
    }
    func testReferenceCannotChangeResultTurnOrCorrectionAndInvalidTimingFails() throws {
        let (batch, reference) = make(start: 0, end: 1)
        for forged in [
            CompanionTurnReference(nativeStoreID: UUID(), jobID: reference.jobID, resultSHA256: reference.resultSHA256, turnIndex: 0, correctionRevision: nil),
            CompanionTurnReference(nativeStoreID: reference.nativeStoreID, jobID: reference.jobID, resultSHA256: String(repeating: "f", count: 64), turnIndex: 0, correctionRevision: nil),
            CompanionTurnReference(nativeStoreID: reference.nativeStoreID, jobID: reference.jobID, resultSHA256: reference.resultSHA256, turnIndex: 1, correctionRevision: nil),
            CompanionTurnReference(nativeStoreID: reference.nativeStoreID, jobID: reference.jobID, resultSHA256: reference.resultSHA256, turnIndex: 0, correctionRevision: UUID())
        ] { XCTAssertThrowsError(try CompanionTurnResolver.resolve(batch, reference: forged)) }
        for bounds in [(Double.nan, 1.0), (-0.1, 1.0), (0.0, 1.01), (0.5, 0.5)] {
            let fixture = make(start: bounds.0, end: bounds.1)
            XCTAssertThrowsError(try CompanionTurnResolver.resolve(fixture.0, reference: fixture.1))
        }
    }
    private func make(start: Double, end: Double) -> (CompanionSpeakerPresentation, CompanionTurnReference) {
        let native = UUID(), job = String(repeating: "a", count: 64)
        let source = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 32000,
            sampleCount: 16000, sampleRate: 16000, approximateOrigin: Date(timeIntervalSince1970: 1_800_000_000.123456))
        let original = LiveAudioSampleIdentity(recordingGeneration: source.recordingGeneration, continuityID: source.continuityID,
            startSample: 0, sampleCount: 48000, sampleRate: 16000, approximateOrigin: source.approximateOrigin)
        let reference = CompanionTurnReference(nativeStoreID: native, jobID: job, resultSHA256: String(repeating: "b", count: 64), turnIndex: 0, correctionRevision: nil)
        let enhancement = CompanionSpeakerEnrichment(sourceIdentity: source, firstPassSHA256: String(repeating: "c", count: 64),
            enhancedText: "Inferred turn", turns: [.init(start: start, end: end, text: "Inferred turn", speakerID: job + ":cluster:1",
                speakerLabel: "Speaker 1", speakerStatus: .unknown)], automaticNamesCalibrated: false, modelFingerprint: String(repeating: "d", count: 64))
        return (.init(jobID: job, nativeStoreID: native, firstPassText: "Full original first-pass text", enhancement: enhancement,
            corrections: [], firstPassSourceIdentity: original, firstPassReferences: [.init(nativeStoreID: native, source: .microphone,
                rowID: 1, snapshotSHA256: String(repeating: "e", count: 64))], turnReferences: [reference]), reference)
    }
}
