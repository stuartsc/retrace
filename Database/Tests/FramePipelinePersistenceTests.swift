import Foundation
import SQLCipher
import Shared
import XCTest
@testable import Database

final class FramePipelinePersistenceTests: XCTestCase {
    private var database: DatabaseManager!
    private var segmentID: Int64 = 0
    private let timestamp = Date(timeIntervalSince1970: 1_780_000_000.125)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:pipeline_\(UUID().uuidString)?mode=memory&cache=private")
        try await database.initialize()
        segmentID = try await database.insertSegment(
            bundleID: "com.test.capture", startDate: timestamp, endDate: timestamp.addingTimeInterval(5),
            windowName: "Original window", browserUrl: nil, type: 0
        )
    }

    override func tearDown() async throws {
        try await database.close()
        database = nil
    }

    func testDeferredClaimReturnsToDurableQueueAtomically() async throws {
        let frameID = try await insertPendingFrame()
        _ = try await database.dequeueFrameForProcessing()
        try await execute("CREATE TEMP TRIGGER reject_retry BEFORE INSERT ON processing_queue BEGIN SELECT RAISE(ABORT, 'injected enqueue failure'); END;")
        do {
            try await database.releaseFrameProcessingClaim(frameID: frameID, priority: -1, retryCount: 0)
            XCTFail("Expected enqueue rollback")
        } catch { }
        var statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID])
        XCTAssertEqual(statuses[frameID], 1)
        try await execute("DROP TRIGGER reject_retry")
        try await database.releaseFrameProcessingClaim(frameID: frameID, priority: -1, retryCount: 0)
        statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID])
        XCTAssertEqual(statuses[frameID], 0)
        let next = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(next?.frameID, frameID)
    }

    func testCancellationAfterCommitDoesNotReopenCompletedOCR() async throws {
        let frameID = try await insertPendingFrame()
        _ = try await database.dequeueFrameForProcessing()
        _ = try await database.commitFrameOCR(frameID: FrameID(value: frameID), text: text(frameID, "Durable evidence"), frameWidth: 3840, frameHeight: 2160)
        try await database.releaseFrameProcessingClaim(frameID: frameID, priority: 10, retryCount: 0)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID])
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(statuses[frameID], 2)
        XCTAssertEqual(depth, 0)
    }

    func testDuplicateEnqueueDuringAndAfterOCRIsAnIdempotentNoOp() async throws {
        let frameID = try await insertPendingFrame()
        _ = try await database.dequeueFrameForProcessing()
        let insertedDuringClaim = try await database.enqueueFrameForProcessing(frameID: frameID, priority: 10)
        XCTAssertFalse(insertedDuringClaim)
        _ = try await database.commitFrameOCR(frameID: FrameID(value: frameID), text: text(frameID, "Published once"), frameWidth: 3840, frameHeight: 2160)
        let insertedAfterCommit = try await database.enqueueFrameForProcessing(frameID: frameID, priority: 10)
        XCTAssertFalse(insertedAfterCommit)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID])
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(statuses[frameID], 2)
        XCTAssertEqual(depth, 0)
    }

    func testOCRReplacementPublishesSearchNodesAndCompletionTogether() async throws {
        let frameID = try await insertPendingFrame()
        let id = try await database.commitFrameOCR(
            frameID: FrameID(value: frameID), text: text(frameID, "Invoice 42 café"),
            frameWidth: 3840, frameHeight: 2160
        )
        XCTAssertGreaterThan(id, 0)
        let nodes = try await database.getNodesWithText(frameID: FrameID(value: frameID), frameWidth: 3840, frameHeight: 2160)
        XCTAssertEqual(nodes.map(\.text), ["Invoice 42 café"])
        let content = try await database.getFTSContent(docid: id)
        XCTAssertEqual(content?.mainText, "Invoice 42 café")
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID])
        XCTAssertEqual(statuses[frameID], 2)
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 0)

        _ = try await database.commitFrameOCR(
            frameID: FrameID(value: frameID), text: text(frameID, "Invoice 43 café"),
            frameWidth: 3840, frameHeight: 2160
        )
        let documents = try await scalar("SELECT COUNT(*) FROM searchRanking")
        let nodeCount = try await scalar("SELECT COUNT(*) FROM node")
        XCTAssertEqual(documents, 1)
        XCTAssertEqual(nodeCount, 1)
    }

    func testFailedNodeWriteRollsBackSearchAndPreservesPendingQueue() async throws {
        let frameID = try await insertPendingFrame()
        let oldID = try await database.commitFrameOCR(
            frameID: FrameID(value: frameID), text: text(frameID, "Original evidence"),
            frameWidth: 3840, frameHeight: 2160
        )
        try await database.updateFrameProcessingStatus(frameID: frameID, status: 0)
        try await database.enqueueFrameForProcessing(frameID: frameID)
        try await execute("CREATE TEMP TRIGGER reject_test_node BEFORE INSERT ON node BEGIN SELECT RAISE(ABORT, 'injected node write failure'); END;")
        do {
            _ = try await database.commitFrameOCR(
                frameID: FrameID(value: frameID), text: text(frameID, "Replacement evidence"),
                frameWidth: 3840, frameHeight: 2160
            )
            XCTFail("Expected the SQLite trigger to abort the transaction")
        } catch { }
        let currentID = try await database.getDocidForFrame(frameId: frameID)
        let content = try await database.getFTSContent(docid: oldID)
        let nodes = try await database.getNodesWithText(frameID: FrameID(value: frameID), frameWidth: 3840, frameHeight: 2160)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [frameID])
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(currentID, oldID)
        XCTAssertEqual(content?.mainText, "Original evidence")
        XCTAssertEqual(nodes.map(\.text), ["Original evidence"])
        XCTAssertEqual(statuses[frameID], 0)
        XCTAssertEqual(depth, 1)
    }

    func testEmptyOCRRemovesOldSearchAndHighlights() async throws {
        let frameID = try await insertPendingFrame()
        _ = try await database.commitFrameOCR(
            frameID: FrameID(value: frameID), text: text(frameID, "No longer visible"),
            frameWidth: 3840, frameHeight: 2160
        )
        let empty = ExtractedText(frameID: FrameID(value: frameID), timestamp: timestamp, regions: [])
        let id = try await database.commitFrameOCR(frameID: FrameID(value: frameID), text: empty, frameWidth: 3840, frameHeight: 2160)
        let documents = try await scalar("SELECT COUNT(*) FROM searchRanking")
        let nodeCount = try await scalar("SELECT COUNT(*) FROM node")
        XCTAssertEqual(id, 0)
        XCTAssertEqual(documents, 0)
        XCTAssertEqual(nodeCount, 0)
    }

    func testEnqueueIsIdempotentAndPromotesPriority() async throws {
        let first = try await insertPendingFrame()
        let second = try await insertPendingFrame(offset: 1)
        try await database.enqueueFrameForProcessing(frameID: first, priority: 50)
        try await database.enqueueFrameForProcessing(frameID: first, priority: 0)
        let depth = try await database.getProcessingQueueDepth()
        XCTAssertEqual(depth, 2)
        let selected = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(selected?.frameID, first)
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [first, second])
        XCTAssertEqual(statuses[first], 1, "Claim must be durable before a second worker can dequeue")
        let next = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(next?.frameID, second)
    }

    func testDequeueRemovesLegacyDuplicatesWithoutClaimingFrameTwice() async throws {
        let id = try await insertPendingFrame()
        try await execute("INSERT INTO processing_queue(frameId,enqueuedAt,priority,retryCount) VALUES (\(id),0,0,0)")
        let first = try await database.dequeueFrameForProcessing()
        let second = try await database.dequeueFrameForProcessing()
        let rows = try await scalar("SELECT COUNT(*) FROM processing_queue WHERE frameId=\(id)")
        XCTAssertEqual(first?.frameID, id)
        XCTAssertNil(second)
        XCTAssertEqual(rows, 0)
    }

    func testPriorityCaptureDoesNotStarveDurableBacklog() async throws {
        let old = try await insertPendingFrame(offset: -86400)
        for index in 0..<4 {
            let id = try await insertPendingFrame(offset: Double(index))
            try await setQueueTiming(frameID: id, capturedAt: Date(), enqueuedAt: Double(index + 1))
            try await database.enqueueFrameForProcessing(frameID: id, priority: 10)
        }
        for _ in 0..<3 {
            let next = try await database.dequeueFrameForProcessing()
            XCTAssertNotEqual(next?.frameID, old)
        }
        let background = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(background?.frameID, old)
    }

    func testExpiredAutomaticPriorityDoesNotOvertakeCurrentCaptureOrRewriteEvidence() async throws {
        let expired = try await insertPendingFrame()
        let current = try await insertPendingFrame(offset: 1)
        let now = Date()
        try await setQueueTiming(frameID: expired, capturedAt: now.addingTimeInterval(-61), enqueuedAt: now.timeIntervalSince1970, priority: 10)
        try await setQueueTiming(frameID: current, capturedAt: now.addingTimeInterval(-30), enqueuedAt: 0, priority: 1)
        let originalDate = try await scalar("SELECT createdAt FROM frame WHERE id=\(expired)")

        let selected = try await database.dequeueFrameForProcessing()

        XCTAssertEqual(selected?.frameID, current, "Frame capture age, not recent enqueue time or priority 10, defines current work")
        let retainedDate = try await scalar("SELECT createdAt FROM frame WHERE id=\(expired)")
        let retainedPriority = try await scalar("SELECT priority FROM processing_queue WHERE frameId=\(expired)")
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [expired, current])
        XCTAssertEqual(retainedDate, originalDate)
        XCTAssertEqual(retainedPriority, 10, "Aging changes selection only, not durable metadata")
        XCTAssertEqual(statuses[expired], 0)
        XCTAssertEqual(statuses[current], 1)
    }

    func testHistoricalLaneUsesFIFOAcrossExpiredAutomaticZeroAndDeferredWork() async throws {
        let deferred = try await insertPendingFrame()
        let expired = try await insertPendingFrame(offset: 1)
        let ordinary = try await insertPendingFrame(offset: 2)
        try await setQueueTiming(frameID: deferred, enqueuedAt: 1, priority: -1)
        try await setQueueTiming(frameID: expired, enqueuedAt: 2, priority: 10)
        try await setQueueTiming(frameID: ordinary, enqueuedAt: 3, priority: 0)
        var current: [Int64] = []
        for index in 0..<4 {
            let id = try await insertPendingFrame(offset: Double(index + 3))
            try await setQueueTiming(frameID: id, capturedAt: Date(), enqueuedAt: Double(index + 4), priority: 10)
            current.append(id)
        }

        var selected: [Int64] = []
        while let next = try await database.dequeueFrameForProcessing() { selected.append(next.frameID) }

        XCTAssertEqual(selected, Array(current.prefix(3)) + [deferred, current[3], expired, ordinary])
        XCTAssertEqual(Set(selected).count, 7)
    }

    func testManualPriorityPrecedesHistoricalTurnWithoutConsumingCurrentFairness() async throws {
        let historical = try await insertPendingFrame()
        try await setQueueTiming(frameID: historical, enqueuedAt: 0)
        var current: [Int64] = []
        for index in 0..<4 {
            let id = try await insertPendingFrame(offset: Double(index + 1))
            try await setQueueTiming(frameID: id, capturedAt: Date(), enqueuedAt: Double(index + 1), priority: 10)
            current.append(id)
        }
        for expected in current.prefix(3) {
            let next = try await database.dequeueFrameForProcessing()
            XCTAssertEqual(next?.frameID, expected)
        }
        let manualLow = try await insertPendingFrame(offset: 10)
        let manualHigh = try await insertPendingFrame(offset: 11)
        try await setQueueTiming(frameID: manualLow, enqueuedAt: 0, priority: 11)
        try await setQueueTiming(frameID: manualHigh, enqueuedAt: 1, priority: 75)

        var selected: [Int64] = []
        while let next = try await database.dequeueFrameForProcessing() { selected.append(next.frameID) }

        XCTAssertEqual(selected, [manualHigh, manualLow, historical, current[3]])
    }

    func testDeferredReleaseReentersHistoricalFIFOTailWithRetryMetadata() async throws {
        let deferred = try await insertPendingFrame()
        let olderQueued = try await insertPendingFrame(offset: 1)
        try await setQueueTiming(frameID: deferred, enqueuedAt: 0, priority: -1)
        try await setQueueTiming(frameID: olderQueued, enqueuedAt: 1, priority: 0)
        let first = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(first?.frameID, deferred)
        try await database.releaseFrameProcessingClaim(frameID: deferred, priority: -1, retryCount: 2, errorMessage: "Media not readable yet")

        let second = try await database.dequeueFrameForProcessing()
        let third = try await database.dequeueFrameForProcessing()

        XCTAssertEqual(second?.frameID, olderQueued)
        XCTAssertEqual(third?.frameID, deferred)
        XCTAssertEqual(third?.retryCount, 2)
    }

    func testLegacyNullPriorityRemainsEligibleInHistoricalFIFO() async throws {
        let legacy = try await insertPendingFrame()
        let ordinary = try await insertPendingFrame(offset: 1)
        try await setQueueTiming(frameID: legacy, enqueuedAt: 0)
        try await execute("UPDATE processing_queue SET priority=NULL WHERE frameId=\(legacy)")
        try await setQueueTiming(frameID: ordinary, enqueuedAt: 1)

        let first = try await database.dequeueFrameForProcessing()
        let second = try await database.dequeueFrameForProcessing()

        XCTAssertEqual(first?.frameID, legacy)
        XCTAssertEqual(second?.frameID, ordinary)
    }

    func testFailedCurrentClaimDoesNotConsumeHistoricalFairnessTurn() async throws {
        let historical = try await insertPendingFrame()
        try await setQueueTiming(frameID: historical, enqueuedAt: 0)
        var current: [Int64] = []
        for index in 0..<4 {
            let id = try await insertPendingFrame(offset: Double(index + 1))
            try await setQueueTiming(frameID: id, capturedAt: Date(), enqueuedAt: Double(index + 1), priority: 10)
            current.append(id)
        }
        for expected in current.prefix(2) {
            let next = try await database.dequeueFrameForProcessing()
            XCTAssertEqual(next?.frameID, expected)
        }
        try await execute("CREATE TEMP TRIGGER reject_claim_delete BEFORE DELETE ON processing_queue BEGIN SELECT RAISE(ABORT, 'injected claim failure'); END;")
        do {
            _ = try await database.dequeueFrameForProcessing()
            XCTFail("Expected the transaction to roll back")
        } catch { }
        let statuses = try await database.getFrameProcessingStatuses(frameIDs: [current[2]])
        XCTAssertEqual(statuses[current[2]], 0)
        let queued = try await scalar("SELECT COUNT(*) FROM processing_queue WHERE frameId=\(current[2])")
        XCTAssertEqual(queued, 1)
        try await execute("DROP TRIGGER reject_claim_delete")

        let retried = try await database.dequeueFrameForProcessing()
        let historicalTurn = try await database.dequeueFrameForProcessing()
        XCTAssertEqual(retried?.frameID, current[2])
        XCTAssertEqual(historicalTurn?.frameID, historical)
    }

    func testClaimQueriesUseQueueIndexesThenFramePrimaryKeyWithoutTemporarySort() async throws {
        let historical = try await insertPendingFrame()
        let current = try await insertPendingFrame(offset: 1)
        let manual = try await insertPendingFrame(offset: 2)
        try await setQueueTiming(frameID: historical, enqueuedAt: 0, priority: -1)
        try await setQueueTiming(frameID: current, capturedAt: Date(), enqueuedAt: 1, priority: 10)
        try await setQueueTiming(frameID: manual, enqueuedAt: 2, priority: 75)
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let trace = ClaimQueryTrace()
        XCTAssertEqual(sqlite3_trace_v2(db, UInt32(SQLITE_TRACE_STMT), { _, context, statement, _ in
            guard let context, let statement,
                  let expanded = sqlite3_expanded_sql(OpaquePointer(statement)) else { return 0 }
            defer { sqlite3_free(expanded) }
            let sql = String(cString: expanded)
            if sql.hasPrefix("SELECT pq.id") {
                Unmanaged<ClaimQueryTrace>.fromOpaque(context).takeUnretainedValue().record(sql)
            }
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque()), SQLITE_OK)
        defer { sqlite3_trace_v2(db, 0, nil, nil) }
        while try await database.dequeueFrameForProcessing() != nil { }
        sqlite3_trace_v2(db, 0, nil, nil)

        let queries = Set(trace.statements)
        XCTAssertGreaterThanOrEqual(queries.count, 3, "Observe actual manual, current and historical production queries")
        var usedIndexes = Set<String>()
        for sql in queries {
            let plan = try PipelineSQL.query(db, "EXPLAIN QUERY PLAN \(sql)") {
                String(cString: sqlite3_column_text($0, 3))
            }
            XCTAssertTrue(plan.first.map { $0.contains("pq") && $0.contains("idx_processing_queue_") } ?? false, "\(plan)")
            // Manual claims can use the covering status index with the specific rowid;
            // that is still a queue-driven point lookup, not a scan of pending frames.
            XCTAssertTrue(plan.contains { $0.hasPrefix("SEARCH f ") && $0.contains("rowid=?") }, "\(plan)")
            XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "\(plan)")
            for name in ["idx_processing_queue_priority", "idx_processing_queue_enqueued"] where plan.contains(where: { $0.contains(name) }) {
                usedIndexes.insert(name)
            }
            print("QUEUE_CLAIM_QUERY_PLAN \(plan.joined(separator: " | "))")
        }
        XCTAssertEqual(usedIndexes, Set(["idx_processing_queue_priority", "idx_processing_queue_enqueued"]))
    }

    func testQueuePositionMatchesActualFairDequeueOrderWithLegacyDuplicates() async throws {
        let historical = try await insertPendingFrame()
        let expired = try await insertPendingFrame(offset: 1)
        try await setQueueTiming(frameID: historical, enqueuedAt: 0, priority: -1)
        try await setQueueTiming(frameID: expired, enqueuedAt: 1, priority: 10)
        var current: [Int64] = []
        for index in 0..<4 {
            let id = try await insertPendingFrame(offset: Double(index + 2))
            try await setQueueTiming(frameID: id, capturedAt: Date(), enqueuedAt: Double(index + 2), priority: 10)
            current.append(id)
        }
        let manual = try await insertPendingFrame(offset: 10)
        try await setQueueTiming(frameID: manual, enqueuedAt: 10, priority: 75)
        // Legacy duplicate rows must not count a manual/current frame again in history.
        try await execute("INSERT INTO processing_queue(frameId,enqueuedAt,priority,retryCount) VALUES (\(manual),-2,0,0),(\(current[3]),-1,-1,0),(\(historical),20,0,0)")
        var remaining = [manual] + Array(current.prefix(3)) + [historical, current[3], expired]

        while !remaining.isEmpty {
            for (index, id) in remaining.enumerated() {
                let position = try await database.getFrameQueuePosition(frameID: id)
                XCTAssertEqual(position, index + 1, "Snapshot position must agree with the next fair claims for frame \(id)")
            }
            let expected = remaining.removeFirst()
            let next = try await database.dequeueFrameForProcessing()
            XCTAssertEqual(next?.frameID, expected)
            let claimedPosition = try await database.getFrameQueuePosition(frameID: expected)
            XCTAssertNil(claimedPosition)
        }
    }

    func testQueuePositionExcludesClaimedAndCompletedLegacyRows() async throws {
        let active = try await insertPendingFrame()
        let complete = try await insertPendingFrame(offset: 1)
        let pending = try await insertPendingFrame(offset: 2)
        try await setQueueTiming(frameID: active, enqueuedAt: 0, priority: 75)
        try await setQueueTiming(frameID: complete, enqueuedAt: 1, priority: 75)
        try await setQueueTiming(frameID: pending, enqueuedAt: 2, priority: -1)
        try await database.updateFrameProcessingStatus(frameID: active, status: 1)
        try await database.updateFrameProcessingStatus(frameID: complete, status: 2)

        let pendingPosition = try await database.getFrameQueuePosition(frameID: pending)
        let activePosition = try await database.getFrameQueuePosition(frameID: active)
        let completePosition = try await database.getFrameQueuePosition(frameID: complete)

        XCTAssertEqual(pendingPosition, 1)
        XCTAssertNil(activePosition)
        XCTAssertNil(completePosition)
    }

    func testRecoveryUsesMappedIdentityAndIsIdempotentAcrossRepeatedCommit() async throws {
        let sourcePathID = VideoSegmentID(value: 1_780_000_000_125)
        let source = video(path: "chunks/202605/29/\(sourcePathID.value).mp4", count: 2)
        let originalVideoID = try await database.insertVideoSegment(source)
        let firstID = try await insertPendingFrame(videoID: originalVideoID)
        let secondID = try await insertPendingFrame(offset: 0.1, videoID: originalVideoID, index: 1)
        let output = video(path: "chunks/202605/29/1780000000999.mp4", count: 2)
        let descriptors = [
            reference(id: firstID, videoID: sourcePathID.value, index: 0),
            reference(id: secondID, offset: 0.1, videoID: sourcePathID.value, index: 1)
        ]
        let ids = try await database.commitRecoveredFrames(video: output, originalVideoPathID: sourcePathID, originalFrameIndices: [0, 1], frames: descriptors)
        let repeated = try await database.commitRecoveredFrames(video: output, originalVideoPathID: sourcePathID, originalFrameIndices: [0, 1], frames: descriptors)
        XCTAssertEqual(ids, [firstID, secondID])
        XCTAssertEqual(repeated, ids)
        let count = try await database.getFrameCount()
        let outputRows = try await scalar("SELECT COUNT(*) FROM video WHERE path='\(output.relativePath)'")
        let restored = try await database.getFrame(id: FrameID(value: secondID))
        XCTAssertEqual(count, 2)
        XCTAssertEqual(outputRows, 1)
        XCTAssertEqual(restored?.segmentID.value, segmentID)
        XCTAssertEqual(restored?.frameIndexInSegment, 1)
        XCTAssertNotEqual(restored?.videoID.value, sourcePathID.value)
    }

    func testRecoveryDoesNotCollapseDistinctFramesInSameSecondWithoutMap() async throws {
        let sourcePathID = VideoSegmentID(value: 1_780_000_000_125)
        let output = video(path: "chunks/202605/29/1780000000999.mp4", count: 2)
        let descriptors = [reference(index: 0), reference(offset: 0.1, index: 1)]
        let ids = try await database.commitRecoveredFrames(video: output, originalVideoPathID: sourcePathID, originalFrameIndices: [0, 1], frames: descriptors)
        let repeated = try await database.commitRecoveredFrames(video: output, originalVideoPathID: sourcePathID, originalFrameIndices: [0, 1], frames: descriptors)
        XCTAssertEqual(Set(ids).count, 2)
        XCTAssertEqual(repeated, ids)
        let count = try await database.getFrameCount()
        XCTAssertEqual(count, 2)
        let segmentCount = try await scalar("SELECT COUNT(DISTINCT segmentId) FROM frame")
        let duration = try await scalar("SELECT SUM(endDate-startDate) FROM segment WHERE id IN (SELECT segmentId FROM frame)")
        XCTAssertEqual(segmentCount, 1)
        XCTAssertEqual(duration, 100)
    }

    func testOCRDocumentOrphanLookupUsesLeadingDocidIndex() async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        let plans = try PipelineSQL.query(db, "EXPLAIN QUERY PLAN SELECT 1 FROM doc_segment WHERE docid=?", [.integer(42)]) {
            String(cString: sqlite3_column_text($0, 3))
        }
        XCTAssertTrue(plans.contains { $0.contains("SEARCH") && $0.contains("idx_doc_segment_docid") }, "\(plans)")
        for (table, column, index) in [("video", "path", "idx_video_path"), ("audio", "segmentId", "idx_audio_segment_id"), ("event", "segmentID", "idx_event_segment_id")] {
            let details = try PipelineSQL.query(db, "EXPLAIN QUERY PLAN SELECT 1 FROM \(table) WHERE \(column)=?", [.integer(42)]) {
                String(cString: sqlite3_column_text($0, 3))
            }
            XCTAssertTrue(details.contains { $0.contains("SEARCH") && $0.contains(index) }, "\(details)")
        }
    }

    func testRecoveryRejectsStaleMapToDifferentIndexAtSameTimestamp() async throws {
        let sourcePathID = VideoSegmentID(value: 1_780_000_000_125)
        let sourceID = try await database.insertVideoSegment(video(path: "chunks/202605/29/\(sourcePathID.value)", count: 5))
        let wrongFrame = try await insertPendingFrame(videoID: sourceID, index: 4)
        _ = try await database.commitFrameOCR(frameID: FrameID(value: wrongFrame), text: text(wrongFrame, "Different pixels"), frameWidth: 640, frameHeight: 360)
        let output = video(path: "chunks/202605/29/1780000000999", count: 1)
        do {
            _ = try await database.commitRecoveredFrames(video: output, originalVideoPathID: sourcePathID, originalFrameIndices: [0], frames: [reference(id: wrongFrame)])
            XCTFail("Same timestamp does not establish pixel identity")
        } catch { }
        let original = try await database.getFrame(id: FrameID(value: wrongFrame))
        let outputRows = try await scalar("SELECT COUNT(*) FROM video WHERE path='\(output.relativePath)'")
        XCTAssertEqual(original?.videoID.value, sourceID)
        XCTAssertEqual(original?.frameIndexInSegment, 4)
        XCTAssertEqual(outputRows, 0)
    }

    func testRecoveryRejectsMismatchedMappedFrameWithoutPublishingVideo() async throws {
        let id = try await insertPendingFrame(offset: 30)
        let output = video(path: "chunks/202605/29/1780000000999.mp4", count: 1)
        do {
            _ = try await database.commitRecoveredFrames(video: output, originalVideoPathID: VideoSegmentID(value: 12), originalFrameIndices: [0], frames: [reference(id: id)])
            XCTFail("A different frame must never be relinked by a stale mapping")
        } catch { }
        let rows = try await scalar("SELECT COUNT(*) FROM video WHERE path='\(output.relativePath)'")
        let original = try await database.getFrame(id: FrameID(value: id))
        XCTAssertEqual(rows, 0)
        XCTAssertEqual(original?.timestamp.timeIntervalSince1970 ?? 0, timestamp.timeIntervalSince1970 + 30, accuracy: 0.001)
    }

    private func insertPendingFrame(offset: Double = 0, videoID: Int64 = 0, index: Int = 0) async throws -> Int64 {
        let id = try await database.insertFrame(reference(offset: offset, videoID: videoID, index: index, appSegmentID: segmentID))
        try await database.updateFrameProcessingStatus(frameID: id, status: 0)
        try await database.enqueueFrameForProcessing(frameID: id)
        return id
    }

    private func reference(id: Int64 = 0, offset: Double = 0, videoID: Int64 = 0, index: Int = 0, appSegmentID: Int64 = 0) -> FrameReference {
        FrameReference(id: FrameID(value: id), timestamp: timestamp.addingTimeInterval(offset), segmentID: AppSegmentID(value: appSegmentID), videoID: VideoSegmentID(value: videoID), frameIndexInSegment: index, metadata: FrameMetadata(appBundleID: "com.test.capture", windowName: "Original window"))
    }

    private func video(path: String, count: Int) -> VideoSegment {
        VideoSegment(id: VideoSegmentID(value: 999), startTime: timestamp, endTime: timestamp.addingTimeInterval(1), frameCount: count, fileSizeBytes: 100, relativePath: path, width: 640, height: 360)
    }

    private func text(_ id: Int64, _ value: String) -> ExtractedText {
        ExtractedText(frameID: FrameID(value: id), timestamp: timestamp, regions: [TextRegion(frameID: FrameID(value: id), text: value, bounds: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.1))])
    }

    private func execute(_ sql: String) async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
    }

    private func setQueueTiming(frameID: Int64, capturedAt: Date? = nil, enqueuedAt: Double, priority: Int = 0) async throws {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        if let capturedAt {
            try PipelineSQL.execute(db, "UPDATE frame SET createdAt=? WHERE id=?", [.integer(Schema.dateToTimestamp(capturedAt)), .integer(frameID)])
        }
        try PipelineSQL.execute(db, "UPDATE processing_queue SET enqueuedAt=?,priority=? WHERE frameId=?", [.real(enqueuedAt), .integer(Int64(priority)), .integer(frameID)])
    }

    private func scalar(_ sql: String) async throws -> Int64 {
        let connection = await database.getConnection()
        let db = try XCTUnwrap(connection)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.queryFailed(query: sql, underlying: String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}

private final class ClaimQueryTrace {
    private let lock = NSLock()
    private var storage: [String] = []

    var statements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ sql: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(sql)
    }
}
