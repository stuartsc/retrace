import CoreGraphics
import Database
import Foundation
import Shared
import SQLCipher
import Storage
import XCTest
@testable import App

final class ImportedSourceLifecycleTests: XCTestCase {
    func testDisconnectJoinsHeldMediaAndRejectsOldResult() async throws {
        let fixture = try await Fixture.make()
        let reading = Task { try await fixture.adapter.getFrameCGImage(videoPath: "authored.mp4", frameIndex: 0, frameRate: 1, source: .rewind) }
        await fulfillment(of: [fixture.extractor.entered], timeout: 2)
        let finished = expectation(description: "disconnect must join media")
        finished.isInverted = true
        let disconnecting = Task { await fixture.adapter.disconnectRewind(); finished.fulfill() }
        await fulfillment(of: [finished], timeout: 0.05)
        let availableDuringDrain = await fixture.adapter.isSourceAvailable(.rewind)
        XCTAssertFalse(availableDuringDrain, "Revoke admission before waiting for native media")
        await fixture.extractor.release()
        await disconnecting.value
        do { _ = try await reading.value; XCTFail("Old-source image must not publish") } catch { }
        let final = await fixture.adapter.registeredSources
        XCTAssertEqual(final, [.native])
        try await fixture.close()
    }

    func testLaterDisableWinsAgainstEarlierReplacementWaitingForOldRead() async throws {
        let fixture = try await Fixture.make()
        let reading = Task { try await fixture.adapter.getFrameCGImage(videoPath: "authored.mp4", frameIndex: 0, frameRate: 1, source: .rewind) }
        await fulfillment(of: [fixture.extractor.entered], timeout: 2)
        let replacementStarted = expectation(description: "replacement detached old source")
        let replacing = Task {
            await fixture.adapter.configureRewind(connection: fixture.rewind, config: .rewind,
                imageExtractor: fixture.extractor, cutoffDate: Date.distantFuture)
        }
        // Observe the real actor's published state, without relying on a sleep to
        // decide which request owns the source generation.
        for _ in 0..<1000 {
            let available = await fixture.adapter.isSourceAvailable(.rewind)
            if !available { replacementStarted.fulfill(); break }
            await Task.yield()
        }
        await fulfillment(of: [replacementStarted], timeout: 2)
        let disableEntered = expectation(description: "later disable admitted on adapter")
        let disabling = Task { await fixture.adapter.disconnectForSourceTest(entered: disableEntered) }
        await fulfillment(of: [disableEntered], timeout: 2)
        await fixture.extractor.release()
        await replacing.value; await disabling.value
        _ = await reading.result
        let available = await fixture.adapter.isSourceAvailable(.rewind)
        XCTAssertFalse(available)
        try await fixture.close()
    }

    func testCheckedPublicationRejectsRevokedGrantAndReplacedSelection() async throws {
        let fixture = try await Fixture.make()
        await fixture.adapter.disconnectRewind()
        let fence = NativeMutationFence(); fence.invalidate()
        do {
            try await fixture.adapter.configureRewindChecked(connection: fixture.rewind, config: .rewind,
                imageExtractor: fixture.extractor, cutoffDate: Date.distantFuture, fences: [fence], selectionIsCurrent: { true })
            XCTFail("Revoked source publication")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            try await fixture.adapter.configureRewindChecked(connection: fixture.rewind, config: .rewind,
                imageExtractor: fixture.extractor, cutoffDate: Date.distantFuture, fences: [], selectionIsCurrent: { false })
            XCTFail("Replaced source selection")
        } catch { XCTAssertEqual(error as? SourceConfigurationError, .stalePreview) }
        let available = await fixture.adapter.isSourceAvailable(.rewind)
        XCTAssertFalse(available)
        try await fixture.close()
    }

    private struct Fixture {
        let database: DatabaseManager
        let adapter: DataAdapter
        let rewind: SQLCipherConnection
        let extractor: HeldImportedImageExtractor
        static func make() async throws -> Self {
            let database = DatabaseManager(databasePath: ":memory:")
            try await database.initialize()
            let pointer = await database.getConnection()
            let extractor = HeldImportedImageExtractor()
            let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
                retraceConfig: .init(dateFormatter: nil, storageRoot: "/private/tmp", source: .native, cutoffDate: nil),
                retraceImageExtractor: extractor, database: database)
            try await adapter.initialize()
            var raw: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(":memory:", &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
            let rewind = SQLCipherConnection(takingOwnershipOf: try XCTUnwrap(raw))
            await adapter.configureRewind(connection: rewind, config: .rewind, imageExtractor: extractor, cutoffDate: Date.distantFuture)
            return Self(database: database, adapter: adapter, rewind: rewind, extractor: extractor)
        }
        func close() async throws { await adapter.shutdown(); try await database.close() }
    }
}

private extension DataAdapter {
    func disconnectForSourceTest(entered: XCTestExpectation) async {
        entered.fulfill()
        await disconnectRewind()
    }
}

private actor HeldImportedImageExtractor: ImageExtractor {
    nonisolated let entered = XCTestExpectation(description: "imported native media held")
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    func extractFrame(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> Data {
        _ = try await extractFrameCGImage(videoPath: videoPath, frameIndex: frameIndex, frameRate: frameRate)
        return Data([1])
    }
    func extractFrameCGImage(videoPath: String, frameIndex: Int, frameRate: Double?) async throws -> CGImage {
        entered.fulfill()
        if !released { await withCheckedContinuation { waiter = $0 } }
        // Simulate a native decoder which cannot be interrupted while it owns its
        // output buffer. The adapter must still reject this late successful image.
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
