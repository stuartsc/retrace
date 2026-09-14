import CoreGraphics
import Foundation
import ImageIO
import Processing
import Shared
import XCTest
@testable import Database

/// Real SQLite publication, including a rendered image through production Vision.
final class StructuredScreenObservationTests: XCTestCase {
    private var database: DatabaseManager!
    private var frame: FrameReference!
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        database = DatabaseManager(databasePath: "file:structured-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let segment = try await database.insertSegment(bundleID: "com.test.structured", startDate: capturedAt,
            endDate: capturedAt, windowName: "Foreground context only", browserUrl: nil, type: 0)
        let descriptor = FrameReference(id: .init(value: 0), timestamp: capturedAt,
            segmentID: .init(value: segment), frameIndexInSegment: 0,
            metadata: .init(appBundleID: "com.test.structured", windowName: "Foreground context only", displayID: 2))
        let id = try await database.insertFrame(descriptor)
        frame = FrameReference(id: .init(value: id), timestamp: capturedAt,
            segmentID: descriptor.segmentID, frameIndexInSegment: 0, metadata: descriptor.metadata)
    }

    override func tearDown() async throws { try await database.close() }

    func testOCRCommitPersistsOrderedBlocksAndUTF16RangesWithFTSParity() async throws {
        let values = ["Café 🧠", "e\u{301} 47000"]
        let text = extraction(values, chrome: ["DRAFT"])
        let snapshot = try await commit(text)
        let object = try await structure(snapshot)
        let blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        XCTAssertEqual(blocks.compactMap { $0["id"] as? Int }, [0, 1, 2])
        XCTAssertEqual(blocks.compactMap { $0["channel"] as? String }, ["main", "main", "chrome"])
        XCTAssertEqual(blocks.compactMap { $0["text"] as? String }, values + ["DRAFT"])
        let ranges = blocks.compactMap { $0["utf16Range"] as? [String: Int] }
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.compactMap { $0["location"] }, [0, values[0].utf16.count + 1, 0])
        XCTAssertEqual(ranges.compactMap { $0["length"] }, (values + ["DRAFT"]).map { $0.utf16.count })
        XCTAssertEqual((object["provenance"] as? [String: Any])?["origin"] as? String, "ocr")
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID))
        XCTAssertEqual(content?.mainText, blocks.prefix(2).compactMap { $0["text"] as? String }.joined(separator: " "))
        XCTAssertEqual(content?.chromeText, "DRAFT")
        XCTAssertEqual(snapshot.frame.metadata.windowName, "Foreground context only")
    }

    func testMismatchedFlatTextUsesExactUnstructuredFallbackWithoutInventedBlocks() async throws {
        let text = extraction(["Wrong OCR region"], fullText: "Actual saved text 🧠")
        let snapshot = try await commit(text)
        let object = try await structure(snapshot)
        XCTAssertTrue(try XCTUnwrap(object["blocks"] as? [[String: Any]]).isEmpty)
        let fallback = try XCTUnwrap(object["unstructuredText"] as? [[String: Any]])
        XCTAssertEqual(fallback.first?["channel"] as? String, "main")
        XCTAssertEqual(fallback.first?["text"] as? String, "Actual saved text 🧠")
        XCTAssertNil(fallback.first?["bounds"])
        XCTAssertNil(fallback.first?["blockID"])
        XCTAssertFalse(snapshot.highlightsVerified)
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID))
        XCTAssertEqual(content?.mainText, "Actual saved text 🧠")
    }

    func testInvalidGeometryRetainsTextButNeverClaimsOwnershipOrSemanticRoles() async throws {
        let snapshot = try await commit(extraction(["Visible words"], bounds: CGRect(x: -2, y: 4, width: 200, height: 30)))
        let object = try await structure(snapshot)
        let block = try XCTUnwrap((object["blocks"] as? [[String: Any]])?.first)
        XCTAssertEqual(block["text"] as? String, "Visible words")
        XCTAssertNil(block["bounds"])
        XCTAssertEqual(block["ownership"] as? String, "unknown")
        XCTAssertEqual(block["semanticRole"] as? String, "unknown")
        XCTAssertNil((object["provenance"] as? [String: Any])?["extractorVersion"])
        XCTAssertFalse(snapshot.highlightsVerified)
    }

    func testOldJSONStillDecodesWithoutStructureOrARewrite() async throws {
        let snapshot = try await commit(extraction(["Legacy readable text"]))
        let before = try await payload(snapshot)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(before.utf8)) as? [String: Any])
        old.removeValue(forKey: "structuredObservation")
        let decoded = try JSONDecoder().decode(ScreenEvidenceSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.ref, snapshot.ref)
        XCTAssertEqual(decoded.text?.fullText, "Legacy readable text")
        XCTAssertEqual(decoded.observation.mainText, "Legacy readable text")
        XCTAssertEqual(decoded.observation.provenance.origin, .legacyUnknown)
        XCTAssertTrue(decoded.observation.blocks.allSatisfy { $0.bounds == nil })
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(encoded["structuredObservation"])
        let after = try await payload(snapshot)
        XCTAssertEqual(after, before)
    }

    func testChromeOnlyOCRIsRetainedAndIndexedInTheSameTransaction() async throws {
        let snapshot = try await commit(extraction([], chrome: ["Chrome only 47000"]))
        XCTAssertEqual(snapshot.observation.mainText, "")
        XCTAssertEqual(snapshot.observation.chromeText, "Chrome only 47000")
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID, "Retained chrome text needs the matching FTS row"))
        XCTAssertEqual(content?.mainText, "")
        XCTAssertEqual(content?.chromeText, snapshot.observation.chromeText)
        let connection = await database.getConnection()
        let matches = try PipelineSQL.integers(XCTUnwrap(connection),
            "SELECT rowid FROM searchRanking WHERE searchRanking MATCH ?", [.text("47000")])
        XCTAssertEqual(matches, [try XCTUnwrap(docID)])
    }

    func testCanonicallyEquivalentUnicodeCannotFabricateUTF16RegionRanges() async throws {
        let nfc = "Caf\u{e9}"
        let nfd = "Cafe\u{301}"
        XCTAssertEqual(nfc, nfd, "Swift equality deliberately ignores the different code units")
        XCTAssertNotEqual(nfc.utf16.count, nfd.utf16.count)
        let snapshot = try await commit(extraction([nfc], fullText: nfd))
        XCTAssertFalse(snapshot.highlightsVerified)
        XCTAssertTrue(snapshot.observation.blocks.isEmpty)
        XCTAssertEqual(Array(snapshot.observation.mainText.utf8), Array(nfd.utf8))
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID))
        XCTAssertEqual(Array(try XCTUnwrap(content).mainText.utf8), Array(nfd.utf8))
    }

    func testOldPayloadHighlightFlagIsRevalidatedWithoutRewritingItsBytes() async throws {
        let nfc = "Caf\u{e9}", nfd = "Cafe\u{301}"
        let original = try await commit(extraction([nfc]))
        // Reproduce the old writer's canonical-equality proof in this disposable SQLite fixture.
        let legacy = ScreenEvidenceSnapshot(ref: original.ref, frame: original.frame, width: 1280, height: 800,
            text: extraction([nfc], fullText: nfd), legacyContext: false, highlightsVerified: true)
        let raw = try RecallSQL.encode(legacy)
        let connection = await database.getConnection()
        try PipelineSQL.execute(XCTUnwrap(connection),
            "UPDATE screen_extraction SET payload=? WHERE observationID=? AND revision=?",
            [.text(raw), .text(original.ref.observationID.uuidString), .integer(original.ref.extractionRevision)])
        let exact = try await database.screenEvidence(original.ref)
        let current = try await database.currentScreenEvidence(frameID: frame.id, storeID: original.ref.storeID)
        XCTAssertEqual(exact?.highlightsVerified, false)
        XCTAssertEqual(current?.highlightsVerified, false)
        XCTAssertEqual(exact?.observation.provenance.origin, .legacyUnknown)
        XCTAssertTrue(try XCTUnwrap(exact).observation.blocks.isEmpty)
        let selected = ScreenEvidenceRef(storeID: original.ref.storeID, source: .native,
            observationID: original.ref.observationID, frameID: frame.id,
            extractionRevision: original.ref.extractionRevision, blockIDs: [0])
        let selectedSnapshot = try await database.screenEvidence(selected)
        XCTAssertNil(selectedSnapshot)
        let after = try await payload(original)
        XCTAssertEqual(Array(after.utf8), Array(raw.utf8), "Reading an old proof must not rewrite its immutable payload")
    }

    func testExistingPayloadCapRejectsExpandedPayloadWithoutLosingPriorRevisionOrFTS() async throws {
        let retained = try await commit(extraction(["Retained amount 42000"]))
        let input = extraction([String(repeating: "a", count: 3_000_000)])
        let oldShape = ScreenEvidenceSnapshot(ref: retained.ref, frame: retained.frame, width: 1280, height: 800,
            text: input, legacyContext: false, highlightsVerified: true)
        let oldBytes = try RecallSQL.encode(oldShape).utf8.count
        XCTAssertLessThan(oldBytes, 8_388_608, "This input fitted the previous payload shape")
        let structure = StructuredScreenObservation.project(text: input, width: 1280, height: 800,
            provenance: .init(origin: .ocr), geometryVerified: true)
        let newShape = ScreenEvidenceSnapshot(ref: retained.ref, frame: retained.frame, width: 1280, height: 800,
            text: input, legacyContext: false, highlightsVerified: true, structuredObservation: structure)
        let newBytes = try RecallSQL.encode(newShape).utf8.count
        XCTAssertGreaterThan(newBytes, 8_388_608)
        print("STRUCTURED_PAYLOAD_BYTES oversized_fixture before=\(oldBytes) after=\(newBytes) cap=8388608")
        do { _ = try await commit(input); XCTFail("The unchanged payload bound must reject this input") }
        catch DatabaseError.queryFailed(_, let underlying) {
            XCTAssertEqual(underlying, "Extraction snapshot exceeds size bound")
        } catch { XCTFail("Unexpected error: \(type(of: error))") }
        let latest = try await database.currentScreenEvidence(frameID: frame.id, storeID: retained.ref.storeID)
        XCTAssertEqual(latest?.ref, retained.ref)
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID))
        XCTAssertEqual(content?.mainText, "Retained amount 42000")
    }

    func testLaterRevisionAndFailedCommitCannotAlterRetainedStructure() async throws {
        let first = try await commit(extraction(["Amount 42000"]))
        _ = try await structure(first)
        let retained = try await payload(first)
        let second = try await commit(extraction(["Amount 47000"]))
        XCTAssertEqual(second.ref.observationID, first.ref.observationID)
        XCTAssertEqual(second.ref.extractionRevision, first.ref.extractionRevision + 1)
        let connection = await database.getConnection()
        let pointer = try XCTUnwrap(connection)
        try PipelineSQL.execute(pointer, "CREATE TEMP TRIGGER reject_structure BEFORE INSERT ON screen_extraction BEGIN SELECT RAISE(ABORT,'test rollback'); END")
        do { _ = try await commit(extraction(["Must roll back"])); XCTFail("Expected transaction rollback") }
        catch { }
        let latest = try await database.currentScreenEvidence(frameID: frame.id, storeID: first.ref.storeID)
        XCTAssertEqual(latest?.ref, second.ref)
        let after = try await payload(first)
        XCTAssertEqual(after, retained)
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID))
        XCTAssertEqual(content?.mainText, "Amount 47000")
    }

    func testRenderedVisionOutputPublishesTheSameReadableBlocksAndIndexedText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("structured-vision-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try RenderedRecallFixture.write(to: directory)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(directory.appendingPathComponent("1700000000.jpeg") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * image.height)
        let processing = ProcessingManager()
        let result = try await processing.extractText(from: CapturedFrame(timestamp: capturedAt, imageData: pixels,
            width: image.width, height: image.height, bytesPerRow: context.bytesPerRow, metadata: frame.metadata))
        XCTAssertTrue(result.fullText.contains("42000"))
        let snapshot = try await commit(result)
        let oldShape = ScreenEvidenceSnapshot(ref: snapshot.ref, frame: snapshot.frame,
            width: snapshot.width, height: snapshot.height, text: snapshot.text,
            legacyContext: snapshot.legacyContext, highlightsVerified: snapshot.highlightsVerified)
        let oldBytes = try RecallSQL.encode(oldShape).utf8.count
        let newBytes = try await payload(snapshot).utf8.count
        print("STRUCTURED_PAYLOAD_BYTES rendered_vision_fixture before=\(oldBytes) after=\(newBytes) cap=8388608")
        let object = try await structure(snapshot)
        let blocks = try XCTUnwrap(object["blocks"] as? [[String: Any]])
        let main = blocks.filter { $0["channel"] as? String == "main" }.compactMap { $0["text"] as? String }.joined(separator: " ")
        XCTAssertEqual(main, result.fullText)
        let docID = try await database.getDocidForFrame(frameId: frame.id.value)
        let content = try await database.getFTSContent(docid: XCTUnwrap(docID))
        XCTAssertEqual(content?.mainText, main)
    }

    private func extraction(_ values: [String], chrome: [String] = [], fullText: String? = nil,
                            bounds: CGRect = CGRect(x: 20, y: 100, width: 600, height: 30)) -> ExtractedText {
        let regions = values.map { TextRegion(frameID: frame.id, text: $0, bounds: bounds, createdAt: capturedAt) }
        let chromeRegions = chrome.map { TextRegion(frameID: frame.id, text: $0, bounds: bounds, createdAt: capturedAt) }
        return ExtractedText(frameID: frame.id, timestamp: capturedAt, regions: regions,
            chromeRegions: chromeRegions, fullText: fullText, metadata: frame.metadata)
    }

    private func commit(_ text: ExtractedText) async throws -> ScreenEvidenceSnapshot {
        _ = try await database.commitFrameOCR(frameID: frame.id, text: text, frameWidth: 1280, frameHeight: 800)
        let storeID = try await database.activityStoreID()
        let snapshot = try await database.currentScreenEvidence(frameID: frame.id, storeID: storeID)
        return try XCTUnwrap(snapshot)
    }

    private func payload(_ snapshot: ScreenEvidenceSnapshot) async throws -> String {
        let connection = await database.getConnection()
        return try XCTUnwrap(PipelineSQL.query(XCTUnwrap(connection),
            "SELECT payload FROM screen_extraction WHERE observationID=? AND revision=?",
            [.text(snapshot.ref.observationID.uuidString), .integer(snapshot.ref.extractionRevision)]) {
                RecallSQL.string($0, 0)
            }.first)
    }

    private func structure(_ snapshot: ScreenEvidenceSnapshot) async throws -> [String: Any] {
        let raw = try await payload(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        return try XCTUnwrap(object["structuredObservation"] as? [String: Any], "New OCR payload must retain its immutable structure")
    }
}
