import CoreGraphics
import Foundation
import Shared
import Database
import Storage
import SQLCipher
import XCTest
@testable import App

/// Every page is read through the real persistence and source adapter, without media decoding.
final class ScreenEvidenceExpansionTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var service: ProgressiveRecallService!
    private var frame: FrameReference!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("expansion-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // In-memory initialization never consults the user's encryption preference or Keychain.
        let path = "file:expansion-\(UUID())?mode=memory&cache=private"
        database = DatabaseManager(databasePath: path)
        try await database.initialize()
        // Bundled SQLCipher omits shared-cache support. Borrow the actual FULLMUTEX
        // connection; fixture writes finish before reads, and race gates hold no SQL transaction.
        let connection = await database.getConnection()
        let pointer = try XCTUnwrap(connection)
        let reader = SQLiteConnection(db: pointer)
        adapter = DataAdapter(retraceConnection: reader,
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: directory.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: directory.path), database: database)
        try await adapter.initialize()
        service = makeService()
        let segment = try await database.insertSegment(bundleID: "com.test.expansion", startDate: timestamp,
            endDate: timestamp, windowName: "Captured foreground", browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(VideoSegment(id: .init(value: 0), startTime: timestamp,
            endTime: timestamp, frameCount: 1, fileSizeBytes: 100, relativePath: "authored-missing.mp4", width: 640, height: 360))
        let metadata = FrameMetadata(appBundleID: "com.test.expansion", windowName: "Captured foreground", displayID: 2)
        let descriptor = FrameReference(id: .init(value: 0), timestamp: timestamp, segmentID: .init(value: segment),
            videoID: .init(value: video), frameIndexInSegment: 0, encodingStatus: .success, metadata: metadata)
        let id = try await database.insertFrame(descriptor)
        frame = FrameReference(id: .init(value: id), timestamp: timestamp, segmentID: descriptor.segmentID,
            videoID: descriptor.videoID, frameIndexInSegment: 0, encodingStatus: .success, metadata: metadata)
    }

    override func tearDown() async throws {
        service = nil
        await adapter.shutdown()
        adapter = nil
        try await database.close()
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testUnicodePagesAreBoundedAndReassembleWithoutInventedFragmentSeparators() async throws {
        let values = ["🧠é e\u{301} 東京", "Approval 47000"]
        let ref = try await commit(values, chrome: ["DRAFT"])
        var cursor: ScreenEvidenceExpansionCursor?
        var fragments: [ScreenEvidenceTextFragment] = []
        repeat {
            let page = try await service.expandScreenEvidence(.init(reference: ref, blockLimit: 1, maximumUTF8Bytes: 4, cursor: cursor), for: .localUser)
            XCTAssertEqual(page.reference, ref)
            XCTAssertLessThanOrEqual(page.fragments.count, 1)
            XCTAssertEqual(page.textUTF8Bytes, page.fragments.reduce(0) { $0 + $1.text.utf8.count })
            XCTAssertLessThanOrEqual(page.textUTF8Bytes, 4)
            XCTAssertFalse(page.fragments.isEmpty, "A continuation must make progress")
            XCTAssertEqual(page.context.windowName, "Captured foreground")
            XCTAssertEqual(page.width, 640)
            for fragment in page.fragments {
                let channelText = fragment.channel == .main ? values.joined(separator: " ") : "DRAFT"
                XCTAssertEqual((channelText as NSString).substring(with: NSRange(location: fragment.utf16Range.location,
                    length: fragment.utf16Range.length)), fragment.text)
                XCTAssertEqual(fragment.ownership, .unknown)
                XCTAssertEqual(fragment.semanticRole, .unknown)
                XCTAssertNotNil(fragment.blockBounds)
            }
            fragments += page.fragments
            cursor = page.nextCursor
            XCTAssertLessThan(fragments.count, 100)
        } while cursor != nil && fragments.count < 100
        XCTAssertNil(cursor)
        XCTAssertEqual(Set(fragments.map(\.id)).count, fragments.count)
        for (id, text) in (values + ["DRAFT"]).enumerated() {
            let parts = fragments.filter { $0.blockID == id }
            XCTAssertEqual(parts.map(\.text).joined(), text)
            XCTAssertEqual(parts.first?.blockUTF8Offset, 0)
            XCTAssertEqual(parts.last?.isLastFragment, true)
            XCTAssertEqual(parts.dropLast().allSatisfy { !$0.isLastFragment }, true)
        }
    }

    func testOversizedSingleGraphemeMakesScalarProgressAndEmptyEvidenceCompletes() async throws {
        let grapheme = "e" + String(repeating: "\u{301}", count: 40)
        XCTAssertEqual(grapheme.count, 1)
        let ref = try await commit([grapheme])
        var cursor: ScreenEvidenceExpansionCursor?
        var recovered = ""
        var pages = 0
        repeat {
            let page = try await service.expandScreenEvidence(.init(reference: ref, maximumUTF8Bytes: 4, cursor: cursor), for: .localUser)
            XCTAssertGreaterThan(page.textUTF8Bytes, 0)
            recovered += page.fragments.map(\.text).joined()
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 50
        XCTAssertNil(cursor)
        XCTAssertEqual(recovered, grapheme)
        let empty = try await commit([])
        let page = try await service.expandScreenEvidence(.init(reference: empty), for: .localUser)
        XCTAssertTrue(page.fragments.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    func testCursorRetainsOldRevisionAndExactSelectedSubset() async throws {
        let first = try await commit(["Old amount 42000", "Unselected words"], chrome: ["DRAFT"])
        let selected = select(first, blocks: [0, 2])
        let page = try await service.expandScreenEvidence(.init(reference: selected, blockLimit: 1, maximumUTF8Bytes: 4), for: .localUser)
        let cursor = try XCTUnwrap(page.nextCursor)
        let second = try await commit(["New amount 47000"], chrome: ["SENT"])
        XCTAssertNotEqual(first.extractionRevision, second.extractionRevision)
        let next = try await service.expandScreenEvidence(.init(reference: selected, cursor: cursor), for: .localUser)
        XCTAssertEqual(next.reference, selected)
        XCTAssertTrue(next.fragments.allSatisfy { [0, 2].contains($0.blockID ?? -1) })
        XCTAssertFalse(next.fragments.contains { $0.text.contains("47000") || $0.text.contains("Unselected") })
        for other in [first, select(first, blocks: [2, 0]), select(second, blocks: [0, 2])] {
            await assertExpansionError(.invalidContinuation) {
                _ = try await self.service.expandScreenEvidence(.init(reference: other, cursor: cursor), for: .localUser)
            }
        }
    }

    func testInvalidLimitsAndMalformedScalarOffsetsFailClosed() async throws {
        let ref = try await commit(["🧠é rest"])
        for (blocks, bytes) in [(0, 10), (501, 10), (1, 3), (1, 262_145)] {
            await assertExpansionError(.invalidLimits) {
                _ = try await self.service.expandScreenEvidence(.init(reference: ref, blockLimit: blocks, maximumUTF8Bytes: bytes), for: .localUser)
            }
        }
        let first = try await service.expandScreenEvidence(.init(reference: ref, maximumUTF8Bytes: 4), for: .localUser)
        let data = try JSONEncoder().encode(XCTUnwrap(first.nextCursor))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [("utf8Offset", 5), ("utf8Offset", -1), ("itemIndex", 99), ("formatVersion", 999)] {
            var invalid = original
            invalid[key] = value
            let cursor = try JSONDecoder().decode(ScreenEvidenceExpansionCursor.self, from: JSONSerialization.data(withJSONObject: invalid))
            await assertExpansionError(.invalidContinuation) {
                _ = try await self.service.expandScreenEvidence(.init(reference: ref, cursor: cursor), for: .localUser)
            }
        }
    }

    func testUnstructuredLegacyTextIsCompleteAndHasNoFabricatedBlocksOrBounds() async throws {
        let ref = try await commit(["Region mismatch"], chrome: ["Chrome mismatch"], mainText: "Actual 🧠 main", chromeText: "Actual chrome")
        let page = try await service.expandScreenEvidence(.init(reference: ref), for: .localUser)
        XCTAssertEqual(page.fragments.map(\.text), ["Actual 🧠 main", "Actual chrome"])
        XCTAssertEqual(page.fragments.map(\.channel), [.main, .chrome])
        XCTAssertTrue(page.fragments.allSatisfy { $0.blockID == nil && $0.blockBounds == nil })
        XCTAssertNil(page.nextCursor)
    }

    func testCurrentPrivacyIsCheckedAgainForEveryPage() async throws {
        actor Policy {
            var config = CaptureConfig()
            func read() -> CaptureConfig { config }
            func deny() { config = CaptureConfig(excludedAppBundleIDs: ["com.test.expansion"]) }
        }
        let policy = Policy()
        let service = makeService(configuration: { await policy.read() })
        let ref = try await commit(["Read only while permitted"])
        let first = try await service.expandScreenEvidence(.init(reference: ref, maximumUTF8Bytes: 4), for: .localUser)
        await policy.deny()
        await assertUnavailable(.notPermitted) {
            _ = try await service.expandScreenEvidence(.init(reference: ref, cursor: first.nextCursor), for: .localUser)
        }
    }

    func testDeletionDuringFinalPrivacyReadDiscardsAnAlreadyComputedPage() async throws {
        let ref = try await commit(["Do not return deleted evidence"])
        let (slow, reached, release) = suspendedService(read: 2)
        let task = Task { try await slow.expandScreenEvidence(.init(reference: ref), for: .localUser) }
        defer { task.cancel(); release.finish() }
        await fulfillment(of: [reached], timeout: 10)
        try await database.deleteFrame(id: frame.id)
        release.yield(()); release.finish()
        await assertUnavailable(.evidenceDeleted) { _ = try await task.value }
    }

    func testPrivacyRevocationDuringTheFinalReadDiscardsAnAlreadyComputedPage() async throws {
        actor Reads { var count = 0; func next() -> Int { count += 1; return count } }
        let reads = Reads()
        let ref = try await commit(["Must not be returned after revocation"])
        let restricted = makeService(configuration: {
            await reads.next() < 2 ? CaptureConfig() : CaptureConfig(excludedAppBundleIDs: ["com.test.expansion"])
        })
        await assertUnavailable(.notPermitted) {
            _ = try await restricted.expandScreenEvidence(.init(reference: ref), for: .localUser)
        }
    }

    func testCancellationDuringPrivacyReadIsPropagated() async throws {
        let ref = try await commit(["Cancelled evidence"])
        let (slow, reached, release) = suspendedService(read: 1)
        let task = Task { try await slow.expandScreenEvidence(.init(reference: ref), for: .localUser) }
        defer { task.cancel(); release.finish() }
        await fulfillment(of: [reached], timeout: 10)
        task.cancel()
        release.yield(()); release.finish()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(type(of: error))") }
    }

    func testAgentAudienceIsDeniedBeforePermissionOrSourceLookup() async {
        let denied = makeService(configuration: { XCTFail("No source or permission existence oracle"); return CaptureConfig() })
        let ref = ScreenEvidenceRef(storeID: UUID(), source: .rewind, observationID: UUID(), frameID: .init(value: 42), extractionRevision: 8)
        await assertUnavailable(.notPermitted) {
            _ = try await denied.expandScreenEvidence(.init(reference: ref), for: .agent(clientID: "untrusted-broker"))
        }
    }

    func testImportedSourceReplacementBetweenPagesCannotUseCollidingFrameID() async throws {
        let firstSource = try importedStore(text: "contract source A words")
        await configure(firstSource)
        let ref = try await service.reference(frameID: .init(value: 42), source: .rewind)
        let first = try await service.expandScreenEvidence(.init(reference: ref, maximumUTF8Bytes: 4), for: .localUser)
        let secondSource = try importedStore(text: "contract source B private words")
        await configure(secondSource)
        await assertUnavailable(.sourceDisconnected) {
            _ = try await self.service.expandScreenEvidence(.init(reference: ref, cursor: first.nextCursor), for: .localUser)
        }
    }

    func testImportedSourceReplacementDuringFinalPermissionReadDiscardsPage() async throws {
        let firstSource = try importedStore(text: "contract original source")
        await configure(firstSource)
        let ref = try await service.reference(frameID: .init(value: 42), source: .rewind)
        let secondSource = try importedStore(text: "contract replacement source")
        let (slow, reached, release) = suspendedService(read: 2)
        let task = Task { try await slow.expandScreenEvidence(.init(reference: ref), for: .localUser) }
        defer { task.cancel(); release.finish() }
        await fulfillment(of: [reached], timeout: 10)
        await configure(secondSource)
        // Even returning to the same file/store cannot erase a source change during this page.
        await configure(firstSource)
        release.yield(()); release.finish()
        await assertUnavailable(.sourceDisconnected) { _ = try await task.value }
    }

    #if DEBUG
    func testImportedSourceABADuringFinalDatabaseReadDiscardsComputedPage() async throws {
        actor Reads { var count = 0; func next() -> Int { count += 1; return count } }
        let firstSource = try importedStore(text: "contract original durable evidence")
        let secondSource = try importedStore(text: "contract colliding replacement evidence")
        await configure(firstSource)
        let ref = try await service.reference(frameID: .init(value: 42), source: .rewind)
        let slow = makeService()
        let reads = Reads()
        let reached = expectation(description: "Final real frame and retained extraction reads completed")
        let (stream, release) = AsyncStream<Void>.makeStream()
        await slow.setExpansionFinalReadCheckpoint {
            if await reads.next() == 2 {
                reached.fulfill()
                for await _ in stream { break }
            }
        }
        let task = Task { try await slow.expandScreenEvidence(.init(reference: ref), for: .localUser) }
        defer { task.cancel(); release.finish() }
        await fulfillment(of: [reached], timeout: 10)
        // This boundary is later than the final permission/generation read. Both authored
        // stores deliberately share frame ID and timestamp; returning to A retains its UUID.
        await configure(secondSource)
        await configure(firstSource)
        release.yield(()); release.finish()
        await assertUnavailable(.sourceDisconnected) { _ = try await task.value }
    }
    #endif

    func testRetainedSnapshotKeepsItsOptionalImmutableStructure() async throws {
        let ref = try await commit(["Retained without media"])
        let stored = try await database.screenEvidence(ref)
        let retained = await service.retainedScreen(ref, for: .localUser)
        XCTAssertNotNil(retained?.structuredObservation)
        XCTAssertEqual(retained?.structuredObservation, stored?.structuredObservation)
        XCTAssertEqual(retained?.observation.provenance.origin, .ocr)
    }

    func testDisconnectedRewindOCRCannotReturnCollidingNativeFrameNodes() async throws {
        _ = try await commit(["Authored native-only words"])
        let native = try await adapter.getAllOCRNodes(frameID: frame.id, source: .native)
        XCTAssertFalse(native.isEmpty, "The collision fixture must actually contain retained native nodes")
        do {
            _ = try await adapter.getAllOCRNodes(frameID: frame.id, source: .rewind)
            XCTFail("Disconnected Rewind must not fall back to this native frame's OCR")
        } catch DataAdapterError.sourceNotAvailable { }
        catch { XCTFail("Unexpected error: \(type(of: error))") }
    }

    func testSourceGenerationDetectsReconfigureABAButNotNewOCRInTheSameNativeStore() async throws {
        let first = try importedStore(text: "contract original store")
        let second = try importedStore(text: "contract alternate store")
        await configure(first)
        let storeA = try await adapter.evidenceStoreID(source: .rewind)
        let tokenA = try await service.sourceGeneration(source: .rewind)
        let repeated = try await service.sourceGeneration(source: .rewind)
        XCTAssertEqual(repeated, tokenA)
        await configure(second)
        let tokenB = try await service.sourceGeneration(source: .rewind)
        await configure(first)
        let returnedStore = try await adapter.evidenceStoreID(source: .rewind)
        let returnedToken = try await service.sourceGeneration(source: .rewind)
        XCTAssertEqual(returnedStore, storeA)
        XCTAssertNotEqual(tokenA, tokenB)
        XCTAssertNotEqual(tokenA, returnedToken, "Returning to the same file must not hide source reconfiguration")
        XCTAssertFalse([tokenA, tokenB, returnedToken].contains { $0.contains(directory.path) || $0.contains("contract") })
        let native = try await service.sourceGeneration(source: .native)
        _ = try await commit(["A new extraction is not a source replacement"])
        let nativeAfterOCR = try await service.sourceGeneration(source: .native)
        XCTAssertEqual(native, nativeAfterOCR)
        await adapter.disconnectRewind()
        await assertUnavailable(.sourceDisconnected) { _ = try await self.service.sourceGeneration(source: .rewind) }
    }

    func testSourceGenerationRejectsReplacementBehindAnOpenImportedReader() async throws {
        let first = try importedStore(text: "contract original inode")
        let second = try importedStore(text: "contract replacement inode")
        await configure(first)
        _ = try await service.sourceGeneration(source: .rewind)
        let firstPath = URL(fileURLWithPath: first.config.storageRoot).appendingPathComponent("source.sqlite")
        let secondPath = URL(fileURLWithPath: second.config.storageRoot).appendingPathComponent("source.sqlite")
        try FileManager.default.moveItem(at: firstPath, to: firstPath.deletingLastPathComponent().appendingPathComponent("retained-original.sqlite"))
        try FileManager.default.copyItem(at: secondPath, to: firstPath)
        await assertUnavailable(.sourceDisconnected) { _ = try await self.service.sourceGeneration(source: .rewind) }
    }

    private func commit(_ main: [String], chrome: [String] = [], mainText: String? = nil,
                        chromeText: String? = nil) async throws -> ScreenEvidenceRef {
        let bounds = CGRect(x: 10, y: 40, width: 200, height: 25)
        let text = ExtractedText(frameID: frame.id, timestamp: timestamp,
            regions: main.map { TextRegion(frameID: frame.id, text: $0, bounds: bounds) },
            chromeRegions: chrome.map { TextRegion(frameID: frame.id, text: $0, bounds: bounds) },
            fullText: mainText, chromeText: chromeText, metadata: frame.metadata)
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text, frameWidth: 640, frameHeight: 360)
        let store = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frame.id, storeID: store)
        return try XCTUnwrap(snapshot).ref
    }

    private func select(_ ref: ScreenEvidenceRef, blocks: [Int]) -> ScreenEvidenceRef {
        ScreenEvidenceRef(storeID: ref.storeID, source: ref.source, observationID: ref.observationID,
            frameID: ref.frameID, extractionRevision: ref.extractionRevision, blockIDs: blocks)
    }

    private func makeService(configuration: @escaping @Sendable () async -> CaptureConfig = { CaptureConfig() }) -> ProgressiveRecallService {
        ProgressiveRecallService(database: database, adapter: adapter, configuration: configuration,
            imageReader: { _ in XCTFail("Text expansion must not read or decode media"); throw EvidenceUnavailableReason.recordingMissing })
    }

    private struct ImportedStore {
        let reader: SQLiteConnection
        let config: DatabaseConfig
    }

    private func importedStore(text: String) throws -> ImportedStore {
        let root = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("source.sqlite").path
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &pointer), SQLITE_OK)
        let db = try XCTUnwrap(pointer)
        defer { sqlite3_close_v2(db) }
        let writer = SQLiteConnection(db: db)
        try writer.execute(sql: """
            CREATE TABLE segment(id INTEGER PRIMARY KEY,bundleID TEXT,startDate TEXT,endDate TEXT,windowName TEXT,browserUrl TEXT,type INTEGER);
            CREATE TABLE frame(id INTEGER PRIMARY KEY,createdAt TEXT,imageFileName TEXT,segmentId INTEGER,videoId INTEGER,videoFrameIndex INTEGER,encodingStatus TEXT);
            CREATE TABLE video(id INTEGER PRIMARY KEY,path TEXT,frameRate REAL,width INTEGER,height INTEGER);
            CREATE VIRTUAL TABLE searchRanking USING fts5(text,otherText,title);
            CREATE TABLE doc_segment(docid INTEGER,segmentId INTEGER,frameId INTEGER);
            INSERT INTO segment VALUES(1,'com.test.imported','2023-11-14T22:13:20.000','2023-11-14T22:13:20.000','Imported contract',NULL,0);
            INSERT INTO video VALUES(7,'recording.mp4',30,640,360);
            INSERT INTO frame VALUES(42,'2023-11-14T22:13:20.000','fixture',1,7,0,'success');
            INSERT INTO doc_segment VALUES(1,1,42);
            """)
        let statement = try XCTUnwrap(writer.prepare(sql: "INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(1,?,NULL,'Imported contract')"))
        sqlite3_bind_text(statement, 1, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        writer.finalize(statement)
        return ImportedStore(reader: try SQLiteConnection(readOnlyDatabasePath: path),
            config: DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter,
                storageRoot: root.path, source: .rewind, cutoffDate: .distantFuture))
    }

    private func configure(_ source: ImportedStore) async {
        await adapter.configureRewind(connection: source.reader, config: source.config,
            imageExtractor: HEVCStorageExtractor(storageRoot: source.config.storageRoot), cutoffDate: .distantFuture)
    }

    private func suspendedService(read: Int) -> (ProgressiveRecallService, XCTestExpectation, AsyncStream<Void>.Continuation) {
        actor Reads { var count = 0; func next() -> Int { count += 1; return count } }
        let reads = Reads()
        let reached = expectation(description: "Permission read \(read)")
        let (stream, release) = AsyncStream<Void>.makeStream()
        return (makeService(configuration: {
            if await reads.next() == read {
                reached.fulfill()
                for await _ in stream { break }
            }
            return CaptureConfig()
        }), reached, release)
    }

    private func assertExpansionError(_ expected: ScreenEvidenceExpansionError,
        operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected bounded expansion rejection") }
        catch let actual as ScreenEvidenceExpansionError { XCTAssertEqual(actual, expected) }
        catch { XCTFail("Unexpected error: \(type(of: error))") }
    }

    private func assertUnavailable(_ expected: EvidenceUnavailableReason,
        operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected current evidence rejection") }
        catch let actual as EvidenceUnavailableReason { XCTAssertEqual(actual, expected) }
        catch { XCTFail("Unexpected error: \(type(of: error))") }
    }
}
