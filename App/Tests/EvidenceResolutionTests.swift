import XCTest
import CoreGraphics
import Shared
import Database
import Storage
import SQLCipher
import Darwin
@testable import App

final class EvidenceResolutionTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var service: ProgressiveRecallService!
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:evidence-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let pointer = await database.getConnection()
        let root = FileManager.default.temporaryDirectory.path
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
                              retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root, source: .native, cutoffDate: nil),
                              retraceImageExtractor: HEVCStorageExtractor(storageRoot: root), database: database)
        try await adapter.initialize()
        service = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            throw EvidenceUnavailableReason.recordingMissing
        })
    }

    override func tearDown() async throws {
        await adapter.shutdown(); try await database.close()
    }

    func testDeniedBrokerCannotDiscoverWhetherAnySourceExists() async {
        let ref = ScreenEvidenceRef(storeID: UUID(), source: .rewind, observationID: UUID(), frameID: .init(value: 42), extractionRevision: 99)
        assertUnavailable(await service.resolve(.screen(ref), for: .agent(clientID: "local-broker-forwarding-remote")), .notPermitted)
    }

    func testActivityOnlyReferenceReturnsActivityWithoutInvokingMediaReader() async throws {
        let event = ActivityEvent(sessionID: UUID(), sequence: 1, observedAt: timestamp, monotonicTime: 10,
                                  kind: .focus, coverage: .observed,
                                  context: ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word", processID: 123,
                                                           processGeneration: "fixture-window", windowTitle: "Cedar proposal"), method: "reviewed-fixture")
        let stored = try await database.appendActivity(event)
        let ref = ActivityEvidenceRef(storeID: stored.storeID, eventID: event.id)
        let result = await service.resolve(.activity(ref), for: .localUser)
        guard case .activity(let actual) = result else { return XCTFail("Expected activity-only result, never a manufactured frame") }
        XCTAssertEqual(actual.id, event.id)
        XCTAssertEqual(actual.event.context?.windowTitle, "Cedar proposal")
    }

    func testDisconnectedRewindCannotResolveNativeIntegerID() async throws {
        let frameID = try await insertFrame()
        let nativeRef = try await service.reference(frameID: frameID, source: .native)
        let rewindRef = ScreenEvidenceRef(storeID: nativeRef.storeID, source: .rewind,
                                         observationID: nativeRef.observationID, frameID: frameID, extractionRevision: nativeRef.extractionRevision)
        assertUnavailable(await service.resolve(.screen(rewindRef), for: .localUser), .sourceDisconnected)
    }

    func testMissingMediaAndExplicitDeletionHaveDifferentStates() async throws {
        let frameID = try await insertFrame()
        let ref = try await service.reference(frameID: frameID, source: .native)
        assertUnavailable(await service.resolve(.screen(ref), for: .localUser), .recordingMissing)
        try await database.deleteFrame(id: frameID)
        assertUnavailable(await service.resolve(.screen(ref), for: .localUser), .evidenceDeleted)
    }

    func testCurrentExclusionOverridesRetainedCitationAndMetadataActivity() async throws {
        let frameID = try await insertFrame()
        let ref = try await service.reference(frameID: frameID, source: .native)
        let restricted = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig(excludedAppBundleIDs: ["com.microsoft.Word"]) },
            imageReader: { _ in XCTFail("Denied evidence must not decode"); throw EvidenceUnavailableReason.recordingMissing })
        assertUnavailable(await restricted.resolve(.screen(ref), for: .localUser), .notPermitted)
    }

    func testDeepLinkRoundTripPreservesStoreSourceObservationRevisionAndBlocks() {
        let ref = EvidenceRef.screen(ScreenEvidenceRef(storeID: UUID(), source: .rewind, observationID: UUID(),
                                                       frameID: .init(value: 42), extractionRevision: 7, blockIDs: [0, 3]))
        XCTAssertEqual(ref.deepLink.flatMap(EvidenceRef.init(deepLink:)), ref)
        XCTAssertNil(EvidenceRef(deepLink: URL(string: "retrace://evidence?ref=invalid")!))
    }

    func testDeletionDuringDecodeDiscardsLatePixels() async throws {
        let frameID = try await insertFrame()
        let ref = try await service.reference(frameID: frameID, source: .native)
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let image = try Self.image(width: 640, height: 360)
        let slow = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in
            didStart.yield(()); didStart.finish()
            for await _ in release { break }
            return image
        })
        let task = Task { await slow.resolve(.screen(ref), for: .localUser) }
        for await _ in started { break }
        try await database.deleteFrame(id: frameID)
        finish.yield(()); finish.finish()
        assertUnavailable(await task.value, .evidenceDeleted)
    }

    func testRetainedTextCannotReturnAfterDeletionDuringPermissionRead() async throws {
        let frameID = try await insertFrame()
        let ref = try await service.reference(frameID: frameID, source: .native)
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (release, finish) = AsyncStream<Void>.makeStream()
        let slow = ProgressiveRecallService(database: database, adapter: adapter, configuration: {
            didStart.yield(()); didStart.finish()
            for await _ in release { break }
            return CaptureConfig()
        }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let task = Task { await slow.retainedScreen(ref, for: .localUser) }
        for await _ in started { break }
        try await database.deleteFrame(id: frameID)
        finish.yield(()); finish.finish()
        let text = await task.value
        XCTAssertNil(text, "Deleting evidence also fences a late retained-text response")
    }

    func testWrongDimensionsAndInvalidExtractionCannotDisplayPixels() async throws {
        let frameID = try await insertFrame()
        let ref = try await service.reference(frameID: frameID, source: .native)
        let wrong = try Self.image(width: 320, height: 180)
        let reader = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in wrong })
        assertUnavailable(await reader.resolve(.screen(ref), for: .localUser), .integrityFailure)
        let invalid = ScreenEvidenceRef(storeID: ref.storeID, source: .native, observationID: ref.observationID,
                                        frameID: frameID, extractionRevision: ref.extractionRevision + 100)
        assertUnavailable(await reader.resolve(.screen(invalid), for: .localUser), .extractionUnavailable)
        let badBlock = ScreenEvidenceRef(storeID: ref.storeID, source: .native, observationID: ref.observationID,
                                         frameID: frameID, extractionRevision: ref.extractionRevision, blockIDs: [9_999])
        assertUnavailable(await reader.resolve(.screen(badBlock), for: .localUser), .extractionUnavailable)
    }

    func testRetainedRevisionResolvesSavedTextAndPixelsWithoutTakingNewerText() async throws {
        let frameID = try await insertFrame()
        let ref = try await service.reference(frameID: frameID, source: .native)
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: ExtractedText(frameID: frameID, timestamp: timestamp,
                regions: [TextRegion(frameID: frameID, text: "Later extraction says 99999", bounds: CGRect(x: 10, y: 10, width: 500, height: 40))],
                metadata: .empty), frameWidth: 640, frameHeight: 360)
        let image = try Self.image(width: 640, height: 360)
        let reader = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() }, imageReader: { _ in image })
        guard case .screen(let snapshot, let actual) = await reader.resolve(.screen(ref), for: .localUser) else {
            return XCTFail("A retained extraction revision must remain addressable")
        }
        XCTAssertEqual(snapshot.text?.fullText, "Amount 47000 Status SENT")
        XCTAssertEqual(snapshot.ref, ref)
        XCTAssertEqual(actual.width, 640)
        let current = try await reader.currentRevision(ref)
        XCTAssertGreaterThan(try XCTUnwrap(current), ref.extractionRevision)
    }

    func testImportedSearchSelectionCannotResolveAReplacementStoreWithTheSameFrameID() async throws {
        let sourceA = try importedStore(text: "contract source A amount 400")
        let sourceB = try importedStore(text: "contract source B amount 900")
        await configure(sourceA)
        let selectedA = try await importedHit()
        XCTAssertNil(selectedA.evidenceRef)
        await configure(sourceB)
        await assertSelectionChanged { _ = try await self.service.reference(searchResult: selectedA) }
        let selectedB = try await importedHit()
        XCTAssertNotEqual(selectedA.sourceQualifiedID, selectedB.sourceQualifiedID)
        let refB = try await service.reference(searchResult: selectedB)
        let savedB = try await database.screenEvidence(refB)
        XCTAssertEqual(savedB?.text?.fullText, "contract source B amount 900")
    }

    func testAtomicSamePathReplacementRejectsOldReaderUntilAReplacementIsConfigured() async throws {
        let sourceA = try importedStore(text: "contract source A amount 400")
        let sourceB = try importedStore(text: "contract source B amount 900")
        await configure(sourceA)
        let selectedA = try await importedHit()
        let storeA = try await adapter.evidenceStoreID(source: .rewind)
        func version() throws -> Int64 {
            let statement = try XCTUnwrap(sourceA.reader.prepare(sql: "PRAGMA data_version"))
            defer { sourceA.reader.finalize(statement) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
        let before = try version()
        let pathA = sourceA.config.storageRoot + "/source.sqlite"
        let pathB = sourceB.config.storageRoot + "/source.sqlite"
        XCTAssertEqual(rename(pathB, pathA), 0, "Fixture atomically replaces the pathname while A remains open")
        XCTAssertEqual(try version(), before, "SQLite's version counter does not detect a moved open handle")
        let stillA = try XCTUnwrap(sourceA.reader.prepare(sql: "SELECT text FROM searchRanking WHERE rowid=1"))
        XCTAssertEqual(sqlite3_step(stillA), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(stillA, 0).map { String(cString: $0) }, "contract source A amount 400")
        sourceA.reader.finalize(stillA)

        await assertSelectionChanged { _ = try await self.adapter.evidenceStoreID(source: .rewind) }
        await assertSelectionChanged { _ = try await self.service.reference(searchResult: selectedA) }
        await assertSelectionChanged { _ = try await self.adapter.search(query: SearchQuery(text: "contract")) }

        let replacement = ImportedStore(writer: sourceB.writer,
            reader: try SQLiteConnection(readOnlyDatabasePath: pathA), config: sourceA.config)
        await configure(replacement)
        let selectedB = try await importedHit()
        let refB = try await service.reference(searchResult: selectedB)
        XCTAssertNotEqual(refB.storeID, storeA)
        XCTAssertEqual(refB.extractionRevision, 0, "A's text must never have been persisted under B's identity")
        let savedB = try await database.screenEvidence(refB)
        XCTAssertEqual(savedB?.text?.fullText, "contract source B amount 900")
    }

    func testImportedIndexChangeDuringReferenceCreationCannotUseNewTextForAnOldHit() async throws {
        let source = try importedStore(text: "contract original amount 400")
        await configure(source)
        let selected = try await importedHit()
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let slow = ProgressiveRecallService(database: database, adapter: adapter, configuration: {
            signalStart.yield(()); signalStart.finish()
            for await _ in release { break }
            return CaptureConfig()
        }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let task = Task {
            defer { signalStart.finish() }
            return try await slow.reference(searchResult: selected)
        }
        for await _ in started { break }
        try source.writer.execute(sql: "UPDATE searchRanking SET text='contract changed amount 900' WHERE rowid=1")
        signalRelease.yield(()); signalRelease.finish()
        await assertSelectionChanged { _ = try await task.value }
    }

    func testReplacementDuringMaterializationNeverPersistsBTextUnderAIdentity() async throws {
        let sourceA = try importedStore(text: "contract original source A")
        let sourceB = try importedStore(text: "contract replacement source B")
        await configure(sourceA)
        let selected = try await importedHit()
        let storeA = try await adapter.evidenceStoreID(source: .rewind)
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let slow = ProgressiveRecallService(database: database, adapter: adapter, configuration: {
            signalStart.yield(()); signalStart.finish()
            for await _ in release { break }
            return CaptureConfig()
        }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let task = Task {
            defer { signalStart.finish() }
            return try await slow.reference(searchResult: selected)
        }
        for await _ in started { break }
        await configure(sourceB)
        signalRelease.yield(()); signalRelease.finish()
        await assertSelectionChanged { _ = try await task.value }
        let retainedA = try await database.currentScreenEvidence(frameID: .init(value: 42), storeID: storeA)
        XCTAssertNotEqual(retainedA?.text?.fullText, "contract replacement source B")
    }

    func testSelectedNativeImmutableReferenceSurvivesLaterOCRRevision() async throws {
        let id = try await insertFrame()
        let page = try await adapter.search(query: SearchQuery(text: "47000"))
        let selected = try XCTUnwrap(page.results.first)
        let original = try XCTUnwrap(selected.evidenceRef)
        _ = try await database.commitFrameOCR(frameID: id,
            text: ExtractedText(frameID: id, timestamp: timestamp, regions: [], fullText: "Amount 99999 changed"),
            frameWidth: 640, frameHeight: 360)
        let ref = try await service.reference(searchResult: selected)
        XCTAssertEqual(ref, original)
        let snapshot = try await database.screenEvidence(ref)
        XCTAssertEqual(snapshot?.text?.fullText, "Amount 47000 Status SENT")
    }

    func testNativeLegacyTextWithFinalizedMediaMaterializesBeforeExactOpen() async throws {
        let segmentID = try await database.insertSegment(bundleID: "com.test.legacy", startDate: timestamp,
            endDate: timestamp, windowName: "Legacy contract", browserUrl: nil, type: 0)
        let videoID = try await database.insertVideoSegment(VideoSegment(id: .init(value: 0),
            startTime: timestamp, endTime: timestamp, frameCount: 1, fileSizeBytes: 128,
            relativePath: "legacy.mp4", width: 640, height: 360))
        // A retained pre-migration row has media but no screen observation yet.
        let frameID = FrameID(value: 50_000_099)
        let pointer = await database.getConnection()
        let connection = SQLiteConnection(db: try XCTUnwrap(pointer))
        try connection.execute(sql: """
            INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus,processingStatus)
            VALUES(\(frameID.value),1700000000000,'legacy',\(segmentID),\(videoID),0,0,'success',0)
            """)
        _ = try await database.indexFrameText(mainText: "contract legacy amount 400", chromeText: nil,
            windowTitle: "Legacy contract", segmentId: segmentID, frameId: frameID.value)
        let storeID = try await database.activityStoreID()
        let flat = try await database.currentScreenEvidence(frameID: frameID, storeID: storeID)
        XCTAssertEqual(flat?.width, 0)
        let page = try await adapter.search(query: SearchQuery(text: "contract"))
        let selected = try XCTUnwrap(page.results.first)
        XCTAssertNil(selected.evidenceRef, "Unproved dimensions require bound lazy materialization")
        let ref: ScreenEvidenceRef
        if let bound = selected.evidenceRef { ref = bound }
        else { ref = try await service.reference(searchResult: selected) }
        let image = try Self.image(width: 640, height: 360)
        let reader = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig() }, imageReader: { _ in image })
        guard case .screen(let snapshot, _) = await reader.resolve(.screen(ref), for: .localUser) else {
            return XCTFail("Retained legacy text with finalized media must remain openable")
        }
        XCTAssertEqual(snapshot.text?.fullText, "contract legacy amount 400")
        XCTAssertEqual(snapshot.width, 640)
        XCTAssertFalse(snapshot.highlightsVerified)
    }

    func testLegacyNativeThumbnailMaterializationKeepsOriginalHitsAndNextPageUsable() async throws {
        let ids = try await insertLegacyNativeFrames(count: 3)
        let query = SearchQuery(text: "contract", limit: 2, mode: .all, sortOrder: .oldestFirst)
        let page = try await adapter.search(query: query)
        XCTAssertEqual(page.results.map(\.id), Array(ids.prefix(2)))
        let first = try XCTUnwrap(page.results.first)
        let second = try XCTUnwrap(page.results.last)
        XCTAssertNil(first.evidenceRef)
        XCTAssertNil(second.evidenceRef)
        let thumbnailRef = try await service.reference(searchResult: first)
        do {
            let clickRef = try await service.reference(searchResult: first)
            XCTAssertEqual(clickRef, thumbnailRef, "Loading a thumbnail cannot stale its unchanged selected hit")
        } catch { XCTFail("The original hit should remain selectable after its thumbnail: \(type(of: error))") }
        do {
            let sibling = try await service.reference(searchResult: second)
            XCTAssertEqual(sibling.frameID, ids[1], "Materialization must not invalidate a sibling hit")
        } catch { XCTFail("A sibling hit should remain selectable: \(type(of: error))") }
        let next = try await adapter.search(query: SearchQuery(text: "contract", limit: 2,
            cursor: try XCTUnwrap(page.nextCursor), mode: .all, sortOrder: .oldestFirst))
        XCTAssertEqual(next.results.map(\.id), [ids[2]])
        XCTAssertNil(next.nextCursor)
    }

    func testImportedThumbnailMaterializationDoesNotInvalidateItsNextPage() async throws {
        let source = try importedStore(text: "contract first amount 400")
        try source.writer.execute(sql: """
            INSERT INTO frame VALUES(43,'2023-11-14T22:13:20.000','fixture',1,7,1,'success');
            INSERT INTO frame VALUES(44,'2023-11-14T22:13:20.000','fixture',1,7,2,'success');
            INSERT INTO searchRanking(rowid,text) VALUES(2,'contract second amount 500');
            INSERT INTO searchRanking(rowid,text) VALUES(3,'contract third amount 600');
            INSERT INTO doc_segment VALUES(2,1,43);
            INSERT INTO doc_segment VALUES(3,1,44)
            """)
        await configure(source)
        let page = try await adapter.search(query: SearchQuery(text: "contract", limit: 2,
            mode: .all, sortOrder: .oldestFirst))
        XCTAssertEqual(page.results.map(\.id.value), [42, 43])
        for selected in page.results { _ = try await service.reference(searchResult: selected) }
        let next = try await adapter.search(query: SearchQuery(text: "contract", limit: 2,
            cursor: try XCTUnwrap(page.nextCursor), mode: .all, sortOrder: .oldestFirst))
        XCTAssertEqual(next.results.map(\.id.value), [44])
    }

    private func insertLegacyNativeFrames(count: Int) async throws -> [FrameID] {
        let segment = try await database.insertSegment(bundleID: "com.test.legacy", startDate: timestamp,
            endDate: timestamp.addingTimeInterval(Double(count)), windowName: "Legacy contract", browserUrl: nil, type: 0)
        let video = try await database.insertVideoSegment(VideoSegment(id: .init(value: 0), startTime: timestamp,
            endTime: timestamp.addingTimeInterval(Double(count)), frameCount: count, fileSizeBytes: 128,
            relativePath: "legacy.mp4", width: 640, height: 360))
        let pointer = await database.getConnection()
        let connection = SQLiteConnection(db: try XCTUnwrap(pointer))
        var ids: [FrameID] = []
        for index in 0..<count {
            let id = FrameID(value: 50_000_099 + Int64(index))
            try connection.execute(sql: """
                INSERT INTO frame(id,createdAt,imageFileName,segmentId,videoId,videoFrameIndex,isStarred,encodingStatus,processingStatus)
                VALUES(\(id.value),\(1_700_000_000_000 + index * 1000),'legacy',\(segment),\(video),\(index),0,'success',0)
                """)
            _ = try await database.indexFrameText(mainText: "contract amount \(400 + index)", chromeText: nil,
                windowTitle: "Legacy contract", segmentId: segment, frameId: id.value)
            ids.append(id)
        }
        return ids
    }

    func testUnprovedLegacySearchResultCannotFallBackToItsIntegerID() async throws {
        let source = try importedStore(text: "contract original")
        await configure(source)
        let hit = try await importedHit()
        let unproved = SearchResult(id: hit.id, timestamp: hit.timestamp, snippet: hit.snippet,
            matchedText: hit.matchedText, relevanceScore: hit.relevanceScore, metadata: hit.metadata,
            segmentID: hit.segmentID, videoID: hit.videoID, frameIndex: hit.frameIndex,
            videoPath: hit.videoPath, videoFrameRate: hit.videoFrameRate, source: hit.source)
        await assertSelectionChanged { _ = try await self.service.reference(searchResult: unproved) }
    }

    func testFreshImportedSelectionAppendsChangedTextWithoutReplacingTheOldRevision() async throws {
        let source = try importedStore(text: "contract original amount 400")
        await configure(source)
        let originalHit = try await importedHit()
        let originalRef = try await service.reference(searchResult: originalHit)
        try source.writer.execute(sql: "UPDATE searchRanking SET text='contract revised amount 900' WHERE rowid=1")
        let revisedHit = try await importedHit()
        let revisedRef = try await service.reference(searchResult: revisedHit)
        XCTAssertEqual(revisedRef.observationID, originalRef.observationID)
        XCTAssertGreaterThan(revisedRef.extractionRevision, originalRef.extractionRevision)
        let original = try await database.screenEvidence(originalRef)
        let revised = try await database.screenEvidence(revisedRef)
        XCTAssertEqual(original?.text?.fullText, "contract original amount 400")
        XCTAssertEqual(revised?.text?.fullText, "contract revised amount 900")
    }

    func testImportedConflictingDocumentLinksCannotMaterializeUnrelatedText() async throws {
        let source = try importedStore(text: "contract selected amount 400")
        try source.writer.execute(sql: """
            INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(2,'unrelated later document',NULL,'Other');
            INSERT INTO doc_segment VALUES(2,1,42)
            """)
        await configure(source)
        let selected = try await importedHit()
        await assertSelectionChanged { _ = try await self.service.reference(searchResult: selected) }
        let storeID = try await adapter.evidenceStoreID(source: .rewind)
        let saved = try await database.currentScreenEvidence(frameID: selected.id, storeID: storeID)
        XCTAssertNil(saved, "Ambiguous legacy links cannot assert an extraction for the selected match")
    }

    func testImportedIdenticalDocumentLinksCanResolveTheirRetainedText() async throws {
        let source = try importedStore(text: "contract selected amount 400")
        try source.writer.execute(sql: """
            INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(2,'contract selected amount 400',NULL,'Other');
            INSERT INTO doc_segment VALUES(2,1,42)
            """)
        await configure(source)
        let selected = try await importedHit()
        let ref = try await service.reference(searchResult: selected)
        let saved = try await database.screenEvidence(ref)
        XCTAssertEqual(saved?.text?.fullText, "contract selected amount 400")
    }

    func testImportedIndexChangeAfterMaterializationCannotPublishReference() async throws {
        actor PermissionReads {
            var count = 0
            func isSecond() -> Bool { count += 1; return count == 2 }
        }
        let source = try importedStore(text: "contract original amount 400")
        await configure(source)
        let selected = try await importedHit()
        let storeID = try await adapter.evidenceStoreID(source: .rewind)
        let reads = PermissionReads()
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let slow = ProgressiveRecallService(database: database, adapter: adapter, configuration: {
            if await reads.isSecond() {
                signalStart.yield(()); signalStart.finish()
                for await _ in release { break }
            }
            return CaptureConfig()
        }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let task = Task {
            defer { signalStart.finish() }
            return try await slow.reference(searchResult: selected)
        }
        for await _ in started { break }
        let persisted = try await database.currentScreenEvidence(frameID: selected.id, storeID: storeID)
        XCTAssertEqual(persisted?.text?.fullText, "contract original amount 400")
        try source.writer.execute(sql: "UPDATE searchRanking SET text='contract changed after materialization' WHERE rowid=1")
        signalRelease.yield(()); signalRelease.finish()
        await assertSelectionChanged { _ = try await task.value }
    }

    func testCancelledImportedSelectionCannotMaterializeAfterPermissionRead() async throws {
        let source = try importedStore(text: "contract original amount 400")
        await configure(source)
        let selected = try await importedHit()
        let storeID = try await adapter.evidenceStoreID(source: .rewind)
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (release, signalRelease) = AsyncStream<Void>.makeStream()
        let slow = ProgressiveRecallService(database: database, adapter: adapter, configuration: {
            signalStart.yield(()); signalStart.finish()
            for await _ in release { break }
            return CaptureConfig()
        }, imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        let task = Task {
            defer { signalStart.finish() }
            return try await slow.reference(searchResult: selected)
        }
        for await _ in started { break }
        task.cancel()
        signalRelease.yield(()); signalRelease.finish()
        do {
            _ = try await task.value
            XCTFail("Cancellation must discard selection before persistence")
        } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(type(of: error))") }
        let saved = try await database.currentScreenEvidence(frameID: selected.id, storeID: storeID)
        XCTAssertNil(saved)
    }

    func testNewExclusionPreventsLegacySearchMaterialization() async throws {
        let source = try importedStore(text: "contract original amount 400")
        await configure(source)
        let selected = try await importedHit()
        let restricted = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig(excludedAppBundleIDs: ["com.test.imported"]) },
            imageReader: { _ in throw EvidenceUnavailableReason.recordingMissing })
        do {
            _ = try await restricted.reference(searchResult: selected)
            XCTFail("A new exclusion must prevent importing retained text")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .notPermitted) }
        let storeID = try await adapter.evidenceStoreID(source: .rewind)
        let saved = try await database.currentScreenEvidence(frameID: selected.id, storeID: storeID)
        XCTAssertNil(saved)
    }

    private struct ImportedStore {
        let writer: SQLiteConnection
        let reader: SQLiteConnection
        let config: DatabaseConfig
    }

    private func importedStore(text: String) throws -> ImportedStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("imported-selection-\(UUID())")
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
        let config = DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter, storageRoot: root.path,
                                    source: .rewind, cutoffDate: .distantFuture)
        return ImportedStore(writer: writer, reader: try SQLiteConnection(readOnlyDatabasePath: path), config: config)
    }

    private func configure(_ source: ImportedStore) async {
        await adapter.configureRewind(connection: source.reader, config: source.config,
            imageExtractor: HEVCStorageExtractor(storageRoot: source.config.storageRoot), cutoffDate: .distantFuture)
    }

    private func importedHit() async throws -> SearchResult {
        let page = try await adapter.search(query: SearchQuery(text: "contract", limit: 5,
                                                               mode: .all, sortOrder: .oldestFirst))
        let result = try XCTUnwrap(page.results.first(where: { $0.source == .rewind }))
        _ = try await adapter.evidenceStoreID(source: .rewind)
        let frame = try await adapter.getFrameWithVideoInfoByID(id: result.id, source: .rewind)
        XCTAssertEqual(frame?.videoInfo?.width, 640)
        _ = try await adapter.savedEvidenceText(frame: try XCTUnwrap(frame).frame)
        return result
    }

    private func assertSelectionChanged(file: StaticString = #filePath, line: UInt = #line,
                                         operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("A stale or unproved selection must not resolve current evidence", file: file, line: line)
        } catch SearchPaginationError.dataChanged {
        } catch let reason as EvidenceUnavailableReason {
            XCTAssertTrue([.integrityFailure, .sourceDisconnected].contains(reason), file: file, line: line)
        } catch {
            XCTFail("Unexpected selection error: \(type(of: error))", file: file, line: line)
        }
    }

    private static func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func insertFrame() async throws -> FrameID {
        let metadata = FrameMetadata(appBundleID: "com.microsoft.Word", appName: "Word", windowName: "Cedar proposal")
        let segment = try await database.insertSegment(bundleID: "com.microsoft.Word", startDate: timestamp, endDate: timestamp,
                                                       windowName: "Cedar proposal", browserUrl: nil, type: 0)
        let frameID = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: timestamp,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata)))
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: ExtractedText(frameID: frameID, timestamp: timestamp,
                                regions: [TextRegion(frameID: frameID, text: "Amount 47000 Status SENT", bounds: CGRect(x: 10, y: 10, width: 500, height: 40))],
                                metadata: metadata), frameWidth: 640, frameHeight: 360)
        return frameID
    }

    private func assertUnavailable(_ result: EvidenceResolution, _ expected: EvidenceUnavailableReason,
                                   file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable(let reason) = result else { return XCTFail("Expected explicit unavailable state", file: file, line: line) }
        XCTAssertEqual(reason, expected, file: file, line: line)
    }
}
