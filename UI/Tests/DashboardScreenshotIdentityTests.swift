import XCTest
import CoreGraphics
import Shared
import Database
import Storage
import App
import SQLCipher
@testable import Retrace

/// The same native/imported SQLite rows used by Dashboard's combined source
/// query exercise its merge, selection and navigation path without a window.
@MainActor
final class DashboardScreenshotIdentityTests: XCTestCase {
    private var database: DatabaseManager!
    private var adapter: DataAdapter!
    private var root: URL!
    private var importedWriter: OpaquePointer?
    private var nativeInput: FrameReference!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-identity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let segment = try await database.insertSegment(bundleID: "com.test.native", startDate: capturedAt,
            endDate: capturedAt, windowName: "Native authored capture", browserUrl: nil, type: 0)
        let id = try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: capturedAt,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: FrameMetadata(appBundleID: "com.test.native")))
        nativeInput = FrameReference(id: .init(value: id), timestamp: capturedAt, segmentID: .init(value: segment),
            frameIndexInSegment: 0, metadata: FrameMetadata(appBundleID: "com.test.native"))
        let pointer = await database.getConnection()
        adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()

        let path = root.appendingPathComponent("authored-import.sqlite").path
        XCTAssertEqual(sqlite3_open(path, &importedWriter), SQLITE_OK)
        try executeImported("""
            CREATE TABLE segment(id INTEGER PRIMARY KEY,bundleID TEXT,startDate TEXT,endDate TEXT,windowName TEXT,browserUrl TEXT,type INTEGER);
            CREATE TABLE frame(id INTEGER PRIMARY KEY,createdAt TEXT,imageFileName TEXT,segmentId INTEGER,videoId INTEGER,videoFrameIndex INTEGER,encodingStatus TEXT);
            CREATE TABLE video(id INTEGER PRIMARY KEY,path TEXT,frameRate REAL,width INTEGER,height INTEGER);
            INSERT INTO segment VALUES(1,'com.test.imported','2023-11-14T22:13:25.123','2023-11-14T22:13:25.123','Imported authored capture',NULL,0);
            INSERT INTO video VALUES(7,'authored.mp4',30,640,360);
            INSERT INTO frame VALUES(\(id),'2023-11-14T22:13:25.123','authored',1,7,0,'encoded');
            CREATE VIRTUAL TABLE searchRanking USING fts5(text,otherText,title);
            CREATE TABLE doc_segment(docid INTEGER,segmentId INTEGER,frameId INTEGER);
            INSERT INTO searchRanking(rowid,text,otherText,title) VALUES(1,'Imported authored OCR',NULL,'Imported authored capture');
            INSERT INTO doc_segment VALUES(1,1,\(id));
            CREATE TABLE node(id INTEGER PRIMARY KEY,frameId INTEGER,nodeOrder INTEGER,textOffset INTEGER,textLength INTEGER,leftX REAL,topY REAL,width REAL,height REAL,text TEXT);
            INSERT INTO node VALUES(1,\(id),0,0,21,0.1,0.1,0.7,0.1,'Imported authored OCR');
            """)
        let configuration = DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter,
            storageRoot: root.path, source: .rewind, cutoffDate: .distantFuture)
        await adapter.configureRewind(connection: try SQLiteConnection(readOnlyDatabasePath: path), config: configuration,
            imageExtractor: HEVCStorageExtractor(storageRoot: root.path), cutoffDate: .distantFuture)
    }

    override func tearDown() async throws {
        await adapter?.shutdown()
        try await database?.close()
        if let importedWriter { XCTAssertEqual(sqlite3_close_v2(importedWriter), SQLITE_OK) }
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testCombinedSQLiteSourcesSurviveActualAppendAndLatestMerge() async throws {
        let (native, imported) = try await sourceRows()
        let appended = DashboardScreenshotIdentityPolicy.appending([imported], to: [native])
        XCTAssertEqual(appended.count, 2, "A colliding imported ID is a separate captured screenshot")
        let merged = DashboardScreenshotIdentityPolicy.mergedLatest([imported], into: [native], maxCount: nil)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.frame.source), [.rewind, .native])
        XCTAssertEqual(merged.map(\.frame.metadata.windowName), ["Imported authored capture", "Native authored capture"])
    }

    func testSelectingAndNavigatingCollidingRowsRetainsTheChosenSource() async throws {
        let (native, imported) = try await sourceRows()
        let rows = [imported, native]
        let selection = ScreenshotEvidenceSelection(native.frame)
        let selected = DashboardScreenshotIdentityPolicy.selectedFrame(in: rows, selection: selection)
        XCTAssertEqual(selected?.frame.source, .native)
        XCTAssertEqual(selected?.frame.timestamp, native.frame.timestamp)
        let newer = DashboardScreenshotIdentityPolicy.adjacentSelection(from: selection, direction: .newer, frames: rows)
        XCTAssertEqual(newer, ScreenshotEvidenceSelection(imported.frame))
        let older = DashboardScreenshotIdentityPolicy.adjacentSelection(from: ScreenshotEvidenceSelection(imported.frame),
            direction: .older, frames: rows)
        XCTAssertEqual(older, selection)
    }

    func testRemovedExplicitSelectionNeverFallsBackToAnotherSourceOrFirstRow() async throws {
        let (native, imported) = try await sourceRows()
        let selected = ScreenshotEvidenceSelection(native.frame)
        try await database.deleteFrame(id: native.frame.id)
        let remaining = try await adapter.getMostRecentFramesWithVideoInfo(limit: 20)
        XCTAssertEqual(remaining.map(\.frame.source), [.rewind])
        XCTAssertNil(DashboardScreenshotIdentityPolicy.selectedFrame(in: remaining, selection: selected))
        XCTAssertNil(DashboardScreenshotIdentityPolicy.adjacentSelection(from: selected, direction: .older, frames: remaining))
        XCTAssertEqual(DashboardScreenshotIdentityPolicy.selectedFrame(in: remaining, selection: nil)?.frame.source, imported.frame.source,
            "Only an initial selection may choose the first available screenshot")
    }

    func testImportedRowReuseKeepsOldCaptureIdentitySeparate() async throws {
        let (_, original) = try await sourceRows()
        try executeImported("UPDATE frame SET createdAt='2023-11-14T22:14:25.123' WHERE id=\(original.frame.id.value)")
        let (_, replacement) = try await sourceRows()
        XCTAssertEqual(original.frame.id, replacement.frame.id)
        XCTAssertNotEqual(original.frame.timestamp, replacement.frame.timestamp)
        XCTAssertNil(DashboardScreenshotIdentityPolicy.selectedFrame(in: [replacement], selection: ScreenshotEvidenceSelection(original.frame)))
        let merged = DashboardScreenshotIdentityPolicy.mergedLatest([replacement], into: [original], maxCount: nil)
        XCTAssertEqual(merged.count, 2, "A new capture cannot mutate an existing captured selection")
    }

    func testSnapshotMatchingAcceptsOnlySQLiteSubMillisecondRounding() async throws {
        let (native, imported) = try await sourceRows()
        let delta = abs(nativeInput.timestamp.timeIntervalSince(native.frame.timestamp))
        XCTAssertGreaterThan(delta, 0, "Fixture must cross the real SQLite timestamp persistence boundary")
        XCTAssertLessThan(delta, 0.001)
        XCTAssertTrue(ScreenshotEvidenceSelection(nativeInput).matches(native.frame))
        XCTAssertFalse(ScreenshotEvidenceSelection(nativeInput).matches(imported.frame))
        try await corruptNativeCaptureTime(with: native.frame.timestamp.addingTimeInterval(2))
        let (replacement, _) = try await sourceRows()
        XCTAssertFalse(ScreenshotEvidenceSelection(nativeInput).matches(replacement.frame))
    }

    func testNativeRefresherRejectsSameRowAfterActualCaptureTimeReplacement() async throws {
        let (selected, _) = try await sourceRows()
        try await corruptNativeCaptureTime(with: selected.frame.timestamp.addingTimeInterval(20))
        let database = database!
        let refresher = DashboardSelectedFrameRefresher()
        let result = try await refresher.refresh(selected, loadedStatus: nil,
            loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) },
            loadNodes: { _ in XCTFail("A different capture must not reach the OCR loader"); return [] })
        XCTAssertNil(result, "Native row ID alone cannot establish the selected capture")
    }

    func testListAdmissionRetriesRatherThanRelabelingHeldRowsFromAnotherStore() async throws {
        let service = service()
        let entered = expectation(description: "original source rows captured")
        let gate = ScreenshotReadGate(entered: entered)
        defer { Task { await gate.release() } }
        let adapter = adapter!
        let pending = Task {
            try await DashboardScreenshotIdentityPolicy.readRows(sourceGeneration: { try await service.sourceGeneration(source: $0) }) {
                let rows = try await adapter.getMostRecentFramesWithVideoInfo(limit: 20)
                await gate.holdFirstRead()
                return rows
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        try await replaceImportedStore()
        let expectedToken = try await service.sourceGeneration(source: .rewind)
        await gate.release()
        let rows = try await pending.value
        let imported = try XCTUnwrap(rows.first { $0.frame.source == .rewind })
        XCTAssertEqual(imported.frame.metadata.windowName, "Replacement authored capture")
        XCTAssertEqual(imported.sourceGeneration, expectedToken)
        let reads = await gate.reads
        XCTAssertEqual(reads, 2, "The original read must be discarded after source replacement")
    }

    func testFrameThumbnailRejectsReplacementStoreWithCoincidentIDAndTime() async throws {
        let (_, imported) = try await sourceRows()
        let probe = ScreenshotImageProbe(image: try image())
        let service = service(probe: probe)
        let generation = try await service.sourceGeneration(source: .rewind)
        try await replaceImportedStore()
        let (_, replacement) = try await sourceRows()
        XCTAssertEqual(imported.frame.id, replacement.frame.id)
        XCTAssertEqual(imported.frame.timestamp, replacement.frame.timestamp)
        do {
            _ = try await SearchEvidenceThumbnailLoader().load(imported.frame, expectedSourceGeneration: generation,
                service: service, size: CGSize(width: 82, height: 50))
            XCTFail("A stale row cannot expose pixels from a replacement source")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .sourceDisconnected) }
        let reads = await probe.reads
        XCTAssertEqual(reads, 0)
    }

    func testFrameThumbnailPrivacyDenialDoesNotReadPixels() async throws {
        let (_, imported) = try await sourceRows()
        let probe = ScreenshotImageProbe(image: try image())
        let service = service(probe: probe, excluded: ["com.test.imported"])
        let generation = try await service.sourceGeneration(source: .rewind)
        do {
            _ = try await SearchEvidenceThumbnailLoader().load(imported.frame, expectedSourceGeneration: generation,
                service: service, size: CGSize(width: 82, height: 50))
            XCTFail("Denied evidence must not enter a row thumbnail")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .notPermitted) }
        let reads = await probe.reads
        XCTAssertEqual(reads, 0)
    }

    func testNativeRefreshRequestsForDifferentCaptureTimesDoNotJoin() async throws {
        let (old, _) = try await sourceRows()
        let entered = expectation(description: "older native row held")
        let gate = ScreenshotReadGate(entered: entered)
        defer { Task { await gate.release() } }
        let database = database!
        let refresher = DashboardSelectedFrameRefresher()
        let first = Task {
            try await refresher.refresh(old, loadedStatus: nil, loadFrame: { id in
                let frame = try await database.getFrameWithVideoInfoByID(id: id)
                await gate.holdFirstRead()
                return frame
            }, loadNodes: { _ in [] })
        }
        await fulfillment(of: [entered], timeout: 2)
        try await corruptNativeCaptureTime(with: old.frame.timestamp.addingTimeInterval(20))
        let (newer, _) = try await sourceRows()
        let newerFinished = expectation(description: "newer capture read completed independently")
        let second = Task {
            let result = try await refresher.refresh(newer, loadedStatus: nil,
                loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { _ in [] })
            newerFinished.fulfill()
            return result
        }
        await fulfillment(of: [newerFinished], timeout: 2)
        await gate.release()
        _ = try? await first.value
        let result = try await second.value
        XCTAssertEqual(result?.frame.frame.timestamp, newer.frame.timestamp)
    }

    func testSourceQualifiedRefreshCannotChangeAnImportedSelectionOrItsOCRCache() async throws {
        let (native, imported) = try await sourceRows()
        let service = service()
        let nativeRow = DashboardScreenshotRow(value: native, sourceGeneration: try await service.sourceGeneration(source: .native))
        let importedRow = DashboardScreenshotRow(value: imported, sourceGeneration: try await service.sourceGeneration(source: .rewind))
        let database = database!
        let refreshed = try await DashboardSelectedFrameRefresher().refresh(native, loadedStatus: nil,
            loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) }, loadNodes: { _ in [] })
        let snapshot = try XCTUnwrap(refreshed)
        let importedNodes = try await adapter.getAllOCRNodes(frameID: imported.frame.id, source: .rewind)
        XCTAssertEqual(importedNodes.first?.text, "Imported authored OCR")
        var rows = [importedRow, nativeRow]
        var nodes = [importedRow.id: importedNodes]
        var statuses = [importedRow.id: imported.processingStatus]
        XCTAssertFalse(DashboardSelectedFrameRefresher.apply(snapshot, selected: importedRow.id,
            frames: &rows, nodes: &nodes, loadedStatuses: &statuses))
        XCTAssertEqual(rows.first?.frame.source, .rewind)
        XCTAssertEqual(nodes[importedRow.id]?.first?.text, "Imported authored OCR")
    }

    func testOCRContextAdmissionRejectsExcludedAndReplacedImportedRows() async throws {
        let (_, imported) = try await sourceRows()
        let service = service()
        let row = DashboardScreenshotRow(value: imported, sourceGeneration: try await service.sourceGeneration(source: .rewind))
        let adapter = adapter!
        do {
            _ = try await DashboardScreenshotIdentityPolicy.readContext(row, service: self.service(excluded: ["com.test.imported"])) {
                try await adapter.getAllOCRNodes(frameID: imported.frame.id, source: .rewind)
            }
            XCTFail("Excluded OCR cannot enter a screenshot filter cache")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .notPermitted) }
        try await replaceImportedStore()
        do {
            _ = try await DashboardScreenshotIdentityPolicy.readContext(row, service: service) {
                try await adapter.getAllOCRNodes(frameID: imported.frame.id, source: .rewind)
            }
            XCTFail("Old rows cannot read replacement-store OCR")
        } catch let reason as EvidenceUnavailableReason { XCTAssertEqual(reason, .sourceDisconnected) }
    }

    func testAllowedImportedThumbnailAndOCRUseExactSQLiteEvidence() async throws {
        let (_, imported) = try await sourceRows()
        let probe = ScreenshotImageProbe(image: try image())
        let service = service(probe: probe)
        let row = DashboardScreenshotRow(value: imported, sourceGeneration: try await service.sourceGeneration(source: .rewind))
        let thumbnail = try await SearchEvidenceThumbnailLoader().load(row.frame, expectedSourceGeneration: row.sourceGeneration,
            service: service, size: CGSize(width: 82, height: 50))
        XCTAssertEqual(thumbnail.width, 82)
        XCTAssertEqual(thumbnail.height, 50)
        let adapter = adapter!
        let nodes = try await DashboardScreenshotIdentityPolicy.readContext(row, service: service) {
            try await adapter.getAllOCRNodes(frameID: imported.frame.id, source: .rewind)
        }
        XCTAssertEqual(nodes.first?.text, "Imported authored OCR")
        let reads = await probe.reads
        XCTAssertEqual(reads, 1)
    }

    func testUnannouncedSourceReplacementPrunesOldSelectedRowsWithoutFallback() async throws {
        let service = service()
        let adapter = adapter!
        let rows = try await DashboardScreenshotIdentityPolicy.readRows(sourceGeneration: { try await service.sourceGeneration(source: $0) }) {
            try await adapter.getMostRecentFramesWithVideoInfo(limit: 20)
        }
        let selected = try XCTUnwrap(rows.first { $0.frame.source == .rewind }).id
        try await replaceImportedStore()
        let tokens = try await DashboardScreenshotIdentityPolicy.sourceGenerations { try await service.sourceGeneration(source: $0) }
        let retained = DashboardScreenshotIdentityPolicy.retainingCurrentRows(rows, generations: tokens)
        XCTAssertEqual(retained.map(\.frame.source), [.native])
        XCTAssertNil(DashboardScreenshotIdentityPolicy.selectedFrame(in: retained, selection: selected))
    }

    func testOCRFilterEvaluatesRealSourceRowsOffMainAndKeepsQualifiedIDs() async throws {
        let (native, imported) = try await sourceRows()
        let service = service()
        let rows = [DashboardScreenshotRow(value: native, sourceGeneration: try await service.sourceGeneration(source: .native)),
                    DashboardScreenshotRow(value: imported, sourceGeneration: try await service.sourceGeneration(source: .rewind))]
        let nodes = try await adapter.getAllOCRNodes(frameID: imported.frame.id, source: .rewind)
        let text = DashboardOCRContextPolicy.fullText(from: nodes)
        XCTAssertFalse(text.isEmpty)
        let importedKey = rows[1].id
        let matched = try await DashboardScreenshotIdentityPolicy.filterRows(rows) { row in
            XCTAssertFalse(Thread.isMainThread, "Real OCR query evaluation must leave the MainActor")
            return DashboardScreenshotFilterPolicy.matches(query: "IMPORTED OCR", appName: nil,
                windowName: nil, browserURL: nil, ocrText: row.id == importedKey ? text : nil)
        }
        XCTAssertEqual(matched, [importedKey])
    }

    func testPendingSelectedSQLiteFrameRetriesWhenReadyAndKeepsItsCitedRevision() async throws {
        let (pending, _) = try await sourceRows()
        let probe = ScreenshotImageProbe(image: try image())
        let service = service(probe: probe)
        let generation = try await service.sourceGeneration(source: .native)
        let model = EvidenceViewModel(client: .live(service: service))
        let presenter = DashboardScreenshotEvidencePresenter()
        await presenter.show(DashboardScreenshotRow(value: pending, sourceGeneration: generation), model: model)
        if case .unavailable(.frameFinalising) = model.resolution { }
        else { XCTFail("The real pending row must have no dimensions or resolvable citation yet") }
        XCTAssertNil(model.evidenceReference)
        let text = ExtractedText(frameID: pending.frame.id, timestamp: pending.frame.timestamp,
            regions: [TextRegion(frameID: pending.frame.id, text: "Authored ready screenshot", bounds: CGRect(x: 10, y: 20, width: 200, height: 30))])
        _ = try await database.commitFrameOCR(frameID: pending.frame.id, text: text, frameWidth: 640, frameHeight: 360)
        let (ready, _) = try await sourceRows()
        XCTAssertEqual(ready.processingStatus, 2)
        await presenter.show(DashboardScreenshotRow(value: ready, sourceGeneration: generation), model: model)
        guard case .screen(let selected, _) = model.resolution else {
            XCTFail("The same selected row must recover after real OCR readiness without reselecting another row")
            return
        }
        XCTAssertEqual(selected.text?.fullText, "Authored ready screenshot")
        let citation = model.evidenceReference
        _ = try await database.commitFrameOCR(frameID: pending.frame.id,
            text: ExtractedText(frameID: pending.frame.id, timestamp: pending.frame.timestamp,
                regions: [TextRegion(frameID: pending.frame.id, text: "Authored refined screenshot", bounds: CGRect(x: 10, y: 20, width: 200, height: 30))]),
            frameWidth: 640, frameHeight: 360)
        await presenter.show(DashboardScreenshotRow(value: ready, sourceGeneration: generation), model: model)
        XCTAssertEqual(model.evidenceReference, citation, "A ready citation must not automatically upgrade during polling")
        if case .screen(let retained, _) = model.resolution { XCTAssertEqual(retained.text?.fullText, "Authored ready screenshot") }
        let reads = await probe.reads
        XCTAssertEqual(reads, 1)
        presenter.close(model: model)
        XCTAssertFalse(model.isPresentingEvidence)
    }

    func testQualifiedNativeCompletionPreservesCollidingImportedRowAndStatusOnlyText() async throws {
        let (native, imported) = try await sourceRows()
        let service = service()
        let nativeRow = DashboardScreenshotRow(value: native, sourceGeneration: try await service.sourceGeneration(source: .native))
        let importedRow = DashboardScreenshotRow(value: imported, sourceGeneration: try await service.sourceGeneration(source: .rewind))
        let importedNodes = try await adapter.getAllOCRNodes(frameID: imported.frame.id, source: .rewind)
        XCTAssertEqual(importedNodes.first?.text, "Imported authored OCR")
        var rows = [importedRow, nativeRow]
        var nodes: [ScreenshotEvidenceSelection: [OCRNodeWithText]] = [importedRow.id: importedNodes, nativeRow.id: []]
        var statuses = [importedRow.id: imported.processingStatus, nativeRow.id: native.processingStatus]
        let originalIDs = rows.map(\.id)
        _ = try await database.commitFrameOCR(frameID: native.frame.id,
            text: ExtractedText(frameID: native.frame.id, timestamp: native.frame.timestamp,
                regions: [TextRegion(frameID: native.frame.id, text: "Native completed OCR retained on refresh",
                    bounds: CGRect(x: 10, y: 20, width: 300, height: 30))]), frameWidth: 640, frameHeight: 360)
        let database = database!, adapter = adapter!
        let refresher = DashboardSelectedFrameRefresher()
        let read = try await refresher.refresh(native, loadedStatus: statuses[nativeRow.id],
            loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) },
            loadNodes: { frame in
                try await DashboardScreenshotIdentityPolicy.readContext(
                    DashboardScreenshotRow(value: frame, sourceGeneration: nativeRow.sourceGeneration), service: service) {
                    try await adapter.getAllOCRNodes(frameID: frame.frame.id, source: frame.frame.source)
                }
            })
        let completed = try XCTUnwrap(read)
        XCTAssertTrue(DashboardSelectedFrameRefresher.apply(completed, selected: nativeRow.id,
            frames: &rows, nodes: &nodes, loadedStatuses: &statuses))
        XCTAssertEqual(rows.map(\.id), originalIDs)
        XCTAssertEqual(rows.map(\.frame.source), [.rewind, .native])
        XCTAssertEqual(rows[0].value, imported)
        XCTAssertEqual(rows[1].processingStatus, 2)
        XCTAssertEqual(nodes[importedRow.id]?.map(\.text), ["Imported authored OCR"])
        XCTAssertEqual(nodes[nativeRow.id]?.map(\.text), ["Native completed OCR retained on refresh"])
        XCTAssertEqual(statuses[nativeRow.id], 2)
        XCTAssertEqual(statuses[importedRow.id], imported.processingStatus)

        let statusRead = try await refresher.refresh(rows[1].value, loadedStatus: statuses[nativeRow.id],
            loadFrame: { try await database.getFrameWithVideoInfoByID(id: $0) },
            loadNodes: { _ in XCTFail("A completed status-only refresh must retain the already read OCR"); return [] })
        let statusOnly = try XCTUnwrap(statusRead)
        XCTAssertNil(statusOnly.nodes)
        XCTAssertTrue(DashboardSelectedFrameRefresher.apply(statusOnly, selected: nativeRow.id,
            frames: &rows, nodes: &nodes, loadedStatuses: &statuses))
        XCTAssertEqual(rows.map(\.id), originalIDs)
        XCTAssertEqual(rows[0].value, imported)
        XCTAssertEqual(DashboardOCRContextPolicy.fullText(from: try XCTUnwrap(nodes[nativeRow.id])),
            "Native completed OCR retained on refresh")
        XCTAssertEqual(nodes[importedRow.id]?.map(\.text), ["Imported authored OCR"])
    }

    private func service(probe: ScreenshotImageProbe? = nil, excluded: Set<String> = []) -> ProgressiveRecallService {
        ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig(excludedAppBundleIDs: excluded) }, imageReader: { _ in
                guard let probe else { throw EvidenceUnavailableReason.recordingMissing }
                return await probe.read()
            })
    }

    private func replaceImportedStore() async throws {
        let replacement = root.appendingPathComponent("replacement.sqlite")
        try FileManager.default.copyItem(at: root.appendingPathComponent("authored-import.sqlite"), to: replacement)
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(replacement.path, &pointer), SQLITE_OK)
        let writer = try XCTUnwrap(pointer)
        XCTAssertEqual(sqlite3_exec(writer, "UPDATE segment SET windowName='Replacement authored capture'", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close_v2(writer), SQLITE_OK)
        let configuration = DatabaseConfig(dateFormatter: DatabaseConfig.rewind.dateFormatter,
            storageRoot: root.path, source: .rewind, cutoffDate: .distantFuture)
        await adapter.configureRewind(connection: try SQLiteConnection(readOnlyDatabasePath: replacement.path), config: configuration,
            imageExtractor: HEVCStorageExtractor(storageRoot: root.path), cutoffDate: .distantFuture)
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8,
            bytesPerRow: 2560, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        return try XCTUnwrap(context.makeImage())
    }

    private func sourceRows() async throws -> (FrameWithVideoInfo, FrameWithVideoInfo) {
        let rows = try await adapter.getMostRecentFramesWithVideoInfo(limit: 20)
        let native = try XCTUnwrap(rows.first { $0.frame.source == .native })
        let imported = try XCTUnwrap(rows.first { $0.frame.source == .rewind })
        XCTAssertEqual(native.frame.id, imported.frame.id, "The real database IDs must collide")
        return (native, imported)
    }

    private func corruptNativeCaptureTime(with timestamp: Date) async throws {
        let pointer = await database.getConnection()
        let database = try XCTUnwrap(pointer)
        // V22 rejects this mutation on canonical writers. Deliberately corrupt
        // only this test-owned in-memory fixture to keep exercising reader-side
        // selection defenses against externally altered/legacy rows.
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER screen_evidence_native_capture_time", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "UPDATE frame SET createdAt=? WHERE id=?", -1, &statement, nil), SQLITE_OK)
        let prepared = try XCTUnwrap(statement)
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_double(prepared, 1, timestamp.timeIntervalSince1970 * 1_000)
        sqlite3_bind_int64(prepared, 2, nativeInput.id.value)
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_DONE)
    }

    private func executeImported(_ sql: String) throws {
        let pointer = try XCTUnwrap(importedWriter)
        let result = sqlite3_exec(pointer, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw NSError(domain: "AuthoredDashboardSQLite", code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(pointer))])
        }
    }
}

private actor ScreenshotImageProbe {
    let image: CGImage
    var reads = 0
    init(image: CGImage) { self.image = image }
    func read() -> CGImage { reads += 1; return image }
}

private actor ScreenshotReadGate {
    let entered: XCTestExpectation
    var reads = 0
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(entered: XCTestExpectation) { self.entered = entered }
    func holdFirstRead() async {
        reads += 1
        guard reads == 1, !released else { return }
        entered.fulfill()
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}
