import XCTest
import CoreGraphics
import Shared
import Database
import Storage
import App
import SQLCipher
@testable import Retrace

final class SearchEvidenceThumbnailTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    private let size = CGSize(width: 280, height: 175)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:thumbnail-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
    }

    override func tearDown() async throws {
        await adapter.shutdown()
        try await database.close()
    }

    func testImportedCollisionCannotExposeReplacementPixels() async throws {
        let sourceA = try importedStore(text: "contract source A amount 400")
        let sourceB = try importedStore(text: "contract source B amount 900")
        await configure(sourceA)
        let hitA = try await hit(source: .rewind)
        await configure(sourceB)
        let probe = DecodeProbe(image: try Self.image())
        let service = makeService(probe: probe)
        let loader = SearchEvidenceThumbnailLoader()
        await assertSelectionUnavailable {
            _ = try await loader.load(hitA, service: service, size: self.size)
        }
        let before = await probe.total
        XCTAssertEqual(before, 0, "The stale source must be rejected before reading replacement media")
        let hitB = try await hit(source: .rewind)
        let thumbnail = try await loader.load(hitB, service: service, size: size)
        XCTAssertEqual(thumbnail.width, 280)
        let after = await probe.total
        XCTAssertEqual(after, 1, "A fresh search of the replacement source remains usable")
    }

    func testUnprovedLegacyHitDoesNotDecodeByBareID() async throws {
        let source = try importedStore(text: "contract retained text")
        await configure(source)
        let selected = try await hit(source: .rewind)
        let unproved = SearchResult(id: selected.id, timestamp: selected.timestamp,
            snippet: selected.snippet, matchedText: selected.matchedText,
            relevanceScore: selected.relevanceScore, metadata: selected.metadata,
            segmentID: selected.segmentID, videoID: selected.videoID, frameIndex: selected.frameIndex,
            videoPath: selected.videoPath, videoFrameRate: selected.videoFrameRate, source: selected.source)
        let probe = DecodeProbe(image: try Self.image())
        let service = makeService(probe: probe)
        let loader = SearchEvidenceThumbnailLoader()
        await assertSelectionUnavailable {
            _ = try await loader.load(unproved, service: service, size: self.size)
        }
        let decoded = await probe.total
        XCTAssertEqual(decoded, 0)
    }

    func testThumbnailFitsWholeVerifiedImageWithoutCurrentOCRCrop() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let probe = DecodeProbe(image: try Self.image())
        let thumbnail = try await SearchEvidenceThumbnailLoader().load(selected, service: makeService(probe: probe), size: size)
        XCTAssertEqual(thumbnail.width, 280)
        XCTAssertEqual(thumbnail.height, 175)
        let left = try Self.pixel(thumbnail, x: 20, y: 87)
        let right = try Self.pixel(thumbnail, x: 260, y: 87)
        let border = try Self.pixel(thumbnail, x: 140, y: 2)
        XCTAssertGreaterThan(left[0], 240)
        XCTAssertLessThan(left[2], 10)
        XCTAssertGreaterThan(right[2], 240)
        XCTAssertLessThan(right[0], 10)
        XCTAssertLessThan(border[0], 60, "Aspect fitting must preserve the whole source, with letterboxing")
        XCTAssertLessThan(border[2], 60)
    }

    @MainActor
    func testRepeatedAppearanceHidesPreviousPixelsUntilCurrentPermissionCompletes() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let probe = DecodeProbe(image: try Self.image())
        let allowed = makeService(probe: probe)
        let preview = SearchEvidenceThumbnailPreview()
        let loader = SearchEvidenceThumbnailLoader()
        await preview.show(selected, key: "same-key", loader: loader, size: size, service: { allowed })
        XCTAssertNotNil(preview.image(for: "same-key"))
        preview.hide()
        XCTAssertNil(preview.image(for: "same-key"), "A cached key must not authorize the next appearance")

        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let denied = ProgressiveRecallService(database: database, adapter: adapter, configuration: {
            start.yield(()); start.finish()
            for await _ in release { break }
            return CaptureConfig(excludedAppBundleIDs: ["com.microsoft.Word"])
        }, imageReader: { _ in await probe.read() })
        let task = Task { await preview.show(selected, key: "same-key", loader: loader, size: size, service: { denied }) }
        for await _ in started { break }
        XCTAssertNil(preview.image(for: "same-key"), "No stale pixels during asynchronous privacy validation")
        finish.yield(()); finish.finish()
        await task.value
        XCTAssertNil(preview.image(for: "same-key"))
        XCTAssertTrue(preview.isUnavailable(for: "same-key"))
        let decoded = await probe.total
        XCTAssertEqual(decoded, 1, "The denied second appearance must not decode")
    }

    func testSourceSwapDuringDecodeDiscardsLateImportedPixels() async throws {
        let sourceA = try importedStore(text: "contract source A")
        let sourceB = try importedStore(text: "contract source B")
        await configure(sourceA)
        let selected = try await hit(source: .rewind)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let image = try Self.image()
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return image
        })
        let task = Task { try await SearchEvidenceThumbnailLoader().load(selected, service: service, size: size) }
        for await _ in started { break }
        await configure(sourceB)
        finish.yield(()); finish.finish()
        await assertSelectionUnavailable { _ = try await task.value }
    }

    func testDeletionDuringDecodeDiscardsLatePixels() async throws {
        let frameID = try await insertFrame()
        let selected = try await hit(source: .native)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let image = try Self.image()
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return image
        })
        let task = Task { try await SearchEvidenceThumbnailLoader().load(selected, service: service, size: size) }
        for await _ in started { break }
        try await database.deleteFrame(id: frameID)
        finish.yield(()); finish.finish()
        do {
            _ = try await task.value
            XCTFail("Deleted evidence must never become a thumbnail")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .evidenceDeleted) }
    }

    @MainActor
    func testDisappearedRowCannotRestorePixelsAfterAnUncancelledCompletion() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let image = try Self.image()
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return image
        })
        let preview = SearchEvidenceThumbnailPreview()
        let loader = SearchEvidenceThumbnailLoader()
        let task = Task { await preview.show(selected, key: "row", loader: loader, size: size, service: { service }) }
        for await _ in started { break }
        preview.hide()
        finish.yield(()); finish.finish()
        await task.value
        XCTAssertNil(preview.image(for: "row"), "Disappearance invalidates completion even when cancellation is delayed")
        XCTAssertFalse(preview.isUnavailable(for: "row"))
    }

    @MainActor
    func testCancelledPresentationDoesNotPublishFailureOrPixels() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let image = try Self.image()
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return image
        })
        let preview = SearchEvidenceThumbnailPreview()
        let loader = SearchEvidenceThumbnailLoader()
        let task = Task { await preview.show(selected, key: "cancelled", loader: loader, size: size, service: { service }) }
        for await _ in started { break }
        task.cancel()
        finish.yield(()); finish.finish()
        await task.value
        XCTAssertNil(preview.image(for: "cancelled"))
        XCTAssertFalse(preview.isUnavailable(for: "cancelled"))
    }

    func testConcurrentSearchRowsBoundRealEvidenceDecodes() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let probe = DecodeProbe(image: try Self.image(), delay: .milliseconds(40))
        let loader = SearchEvidenceThumbnailLoader(maxConcurrent: 2, maxQueued: 16)
        let service = makeService(probe: probe)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try await loader.load(selected, service: service, size: self.size) }
            }
            try await group.waitForAll()
        }
        let total = await probe.total
        let maximum = await probe.maximum
        XCTAssertEqual(total, 12)
        XCTAssertEqual(maximum, 2, "Visible rows must not launch unbounded media decoding")
    }

    func testCancelledQueuedRowCompletesBeforeActiveDecodeAndReleasesItsPlace() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let probe = DecodeProbe(image: try Self.image())
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return await probe.read()
        })
        let loader = SearchEvidenceThumbnailLoader(maxConcurrent: 1, maxQueued: 1)
        let active = Task { try await loader.load(selected, service: service, size: size) }
        for await _ in started { break }
        let queued = Task { try await loader.load(selected, service: service, size: size) }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("Cancellation must remove a waiting row without decoding it")
        } catch is CancellationError {}
        finish.yield(()); finish.finish()
        _ = try await active.value
        _ = try await loader.load(selected, service: service, size: size)
        let decoded = await probe.total
        XCTAssertEqual(decoded, 2, "Cancellation must preserve the next row's available slot")
    }

    func testFullQueueRejectsAdditionalRowsBeforeReadingMedia() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let probe = DecodeProbe(image: try Self.image())
        let service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return await probe.read()
        })
        let loader = SearchEvidenceThumbnailLoader(maxConcurrent: 1, maxQueued: 0)
        let active = Task { try await loader.load(selected, service: service, size: size) }
        for await _ in started { break }
        do {
            _ = try await loader.load(selected, service: service, size: size)
            XCTFail("The pending queue must be bounded")
        } catch SearchEvidenceThumbnailError.capacity {}
        finish.yield(()); finish.finish()
        _ = try await active.value
        let decoded = await probe.total
        XCTAssertEqual(decoded, 1)
    }

    @MainActor
    func testNewPresentationCannotBeOverwrittenByOlderCompletion() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let (started, start) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let image = try Self.image()
        let oldService = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            start.yield(()); start.finish()
            for await _ in release { break }
            return image
        })
        let newService = makeService(probe: DecodeProbe(image: image))
        let preview = SearchEvidenceThumbnailPreview()
        let loader = SearchEvidenceThumbnailLoader()
        let old = Task { await preview.show(selected, key: "old", loader: loader, size: size, service: { oldService }) }
        for await _ in started { break }
        await preview.show(selected, key: "new", loader: loader, size: size, service: { newService })
        let current = try XCTUnwrap(preview.image(for: "new"))
        XCTAssertNil(preview.image(for: "old"))
        finish.yield(()); finish.finish()
        await old.value
        XCTAssertTrue(preview.image(for: "new") === current, "A late row must not republish even if its search result is otherwise valid")
        XCTAssertNil(preview.image(for: "old"))
    }

    func testInvalidThumbnailSizeDoesNotReadEvidence() async throws {
        _ = try await insertFrame()
        let selected = try await hit(source: .native)
        let probe = DecodeProbe(image: try Self.image())
        let service = makeService(probe: probe)
        for invalid in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 175), CGSize(width: 2048, height: 175)] {
            do {
                _ = try await SearchEvidenceThumbnailLoader().load(selected, service: service, size: invalid)
                XCTFail("Invalid or oversized preview requests must be rejected")
            } catch {}
        }
        let decoded = await probe.total
        XCTAssertEqual(decoded, 0)
    }

    private func makeService(probe: DecodeProbe) -> ProgressiveRecallService {
        ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in await probe.read() })
    }

    private actor DecodeProbe {
        let image: CGImage
        let delay: Duration
        var total = 0
        var active = 0
        var maximum = 0
        init(image: CGImage, delay: Duration = .zero) { self.image = image; self.delay = delay }
        func read() async -> CGImage {
            total += 1; active += 1; maximum = max(maximum, active)
            if delay > .zero { try? await Task.sleep(for: delay) }
            active -= 1
            return image
        }
    }

    private func insertFrame() async throws -> FrameID {
        let metadata = FrameMetadata(appBundleID: "com.microsoft.Word", appName: "Word", windowName: "Cedar proposal")
        let segment = try await database.insertSegment(bundleID: "com.microsoft.Word", startDate: timestamp, endDate: timestamp,
            windowName: "Cedar proposal", browserUrl: nil, type: 0)
        let frameID = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: frameID, text: ExtractedText(frameID: frameID, timestamp: timestamp,
            regions: [TextRegion(frameID: frameID, text: "contract Amount 47000 Status SENT", bounds: CGRect(x: 10, y: 10, width: 100, height: 40))],
            metadata: metadata), frameWidth: 640, frameHeight: 360)
        return frameID
    }

    private func hit(source: FrameSource) async throws -> SearchResult {
        let page = try await adapter.search(query: SearchQuery(text: "contract", limit: 5, mode: .all, sortOrder: .oldestFirst))
        return try XCTUnwrap(page.results.first { $0.source == source })
    }

    private struct ImportedStore {
        let reader: SQLiteConnection
        let config: DatabaseConfig
    }

    private func importedStore(text: String) throws -> ImportedStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-import-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("source.sqlite").path
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        let writer = SQLiteConnection(db: db)
        addTeardownBlock { sqlite3_close_v2(db); try? FileManager.default.removeItem(at: root) }
        try writer.execute(sql: """
            CREATE TABLE segment(id INTEGER PRIMARY KEY,bundleID TEXT,startDate TEXT,endDate TEXT,windowName TEXT,browserUrl TEXT,type INTEGER);
            CREATE TABLE frame(id INTEGER PRIMARY KEY,createdAt TEXT,imageFileName TEXT,segmentId INTEGER,videoId INTEGER,videoFrameIndex INTEGER,encodingStatus TEXT);
            CREATE TABLE video(id INTEGER PRIMARY KEY,path TEXT,frameRate REAL,width INTEGER,height INTEGER);
            CREATE VIRTUAL TABLE searchRanking USING fts5(text,otherText,title);
            CREATE TABLE doc_segment(docid INTEGER,segmentId INTEGER,frameId INTEGER);
            INSERT INTO segment VALUES(1,'com.test.imported','2023-11-14T22:13:20.000','2023-11-14T22:13:20.000','Imported contract',NULL,0);
            INSERT INTO video VALUES(7,'recording.mp4',30,640,360);
            INSERT INTO frame VALUES(42,'2023-11-14T22:13:20.000','fixture',1,7,0,'encoded');
            INSERT INTO doc_segment VALUES(1,1,42);
            """)
        let statement = try XCTUnwrap(writer.prepare(sql: "INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(1,?,NULL,'Imported contract')"))
        sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        writer.finalize(statement)
        return ImportedStore(reader: try SQLiteConnection(readOnlyDatabasePath: path),
            config: DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter, storageRoot: root.path, source: .rewind, cutoffDate: .distantFuture))
    }

    private func configure(_ source: ImportedStore) async {
        await adapter.configureRewind(connection: source.reader, config: source.config,
            imageExtractor: HEVCStorageExtractor(storageRoot: source.config.storageRoot), cutoffDate: .distantFuture)
    }

    private func assertSelectionUnavailable(_ operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await operation()
            XCTFail("Stale or unproved source pixels must be unavailable", file: file, line: line)
        } catch SearchPaginationError.dataChanged {
        } catch let reason as EvidenceUnavailableReason {
            XCTAssertTrue([.sourceDisconnected, .integrityFailure].contains(reason), file: file, line: line)
        } catch { XCTFail("Unexpected error: \(type(of: error))", file: file, line: line) }
    }

    private static func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 360))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 320, y: 0, width: 320, height: 360))
        return try XCTUnwrap(context.makeImage())
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
