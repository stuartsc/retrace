import Foundation
import Shared
import XCTest
@testable import App
@testable import Storage

final class AudioWriterPolicyTests: XCTestCase {
    func testProductionDefaultAndRollbackAreCapturedOnceWhilePrivateTestsStayOff() throws {
        let suite = "retrace-audio-writer-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let initial = AudioWriterPolicy.production(defaults: defaults)
        XCTAssertTrue(initial.compactContainerPadding)
        defaults.set(true, forKey: AudioWriterPolicy.rollbackDefaultsKey)
        let restarted = AudioWriterPolicy.production(defaults: defaults)
        XCTAssertFalse(restarted.compactContainerPadding)
        XCTAssertTrue(initial.compactContainerPadding, "Existing owners retain one consistent setting until restart")
        XCTAssertFalse(AudioWriterPolicy.isolatedTest.compactContainerPadding)
        defaults.set(false, forKey: AudioWriterPolicy.rollbackDefaultsKey)
        XCTAssertTrue(AudioWriterPolicy.production(defaults: defaults).compactContainerPadding)
        XCTAssertFalse(restarted.compactContainerPadding, "Turning rollback off also requires a fresh owner")
    }

    func testProductionWriterCompactsNewAACAndRollbackPreservesLegacyOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-writer-policy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "retrace-audio-writer-policy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pcm = try AudioFileDecoder.decodeToPCM(fileURL: project.appendingPathComponent("Processing/Tests/Fixtures/WhisperTimedWords/authored.wav")).data
        let enabled = AudioWriterPolicy.production(defaults: defaults).makeWriter(storageRoot: root)
        let compact = try await enabled.writeFullBatch(audioData: pcm, timestamp: Date(), source: .microphone)
        let compactURL = root.appendingPathComponent(compact.filePath)
        let compactBytes = try Data(contentsOf: compactURL)
        XCTAssertEqual(compact.fileSize, Int64(compactBytes.count))
        XCTAssertNil(AACContainerCompactor.compact(compactBytes), "Default production writer must already remove supported padding")
        XCTAssertEqual(try AudioFileDecoder.decodeToPCM(fileURL: compactURL).data.count, pcm.count)

        defaults.set(true, forKey: AudioWriterPolicy.rollbackDefaultsKey)
        let rollback = AudioWriterPolicy.production(defaults: defaults).makeWriter(storageRoot: root)
        let saved = try await rollback.writeFullBatch(audioData: pcm, timestamp: Date(), source: .microphone)
        let originalBytes = try Data(contentsOf: root.appendingPathComponent(saved.filePath))
        XCTAssertNotNil(AACContainerCompactor.compact(originalBytes), "Rollback must retain the native writer's original padding")
        XCTAssertLessThan(compactBytes.count, originalBytes.count)
        XCTAssertEqual(saved.fileSize, Int64(originalBytes.count))
        XCTAssertEqual(try Data(contentsOf: compactURL), compactBytes, "Creating a rollback writer cannot rewrite existing recordings")

        let privateWriter = AudioWriterPolicy.isolatedTest.makeWriter(storageRoot: root)
        let privateSaved = try await privateWriter.writeFullBatch(audioData: pcm, timestamp: Date(), source: .microphone)
        XCTAssertNotNil(AACContainerCompactor.compact(try Data(contentsOf: root.appendingPathComponent(privateSaved.filePath))))
    }
}
