import App
import Foundation
import Shared
import XCTest
@testable import Retrace

@MainActor
final class TimelineMarkersViewModelTests: XCTestCase {
    func testMarkerPageSearchEditAndStaleRevisionUseSharedDurableOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marker-pages-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        let owner = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        for index in 0..<52 {
            _ = try await owner.createManualMarker(.init(anchoredAt: time.addingTimeInterval(Double(index)),
                title: index == 0 ? "Cedar review" : "Ordinary moment \(index)"))
        }
        let model = TimelineMarkersViewModel(service: { owner })
        await model.refresh()
        XCTAssertEqual(model.loadedCount, 50)
        model.setQuery("cedar")
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertTrue(model.hasMore)
        await model.olderPage()
        let original = try XCTUnwrap(model.markers.first)
        XCTAssertEqual(original.title, "Cedar review")
        XCTAssertEqual(model.loadedCount, 2)
        XCTAssertTrue(model.canGoNewer)
        model.edit(original, title: "Cedar decision", note: "A reviewed note")
        await model.finishPendingWrite()
        let saved = try await owner.marker(id: original.id)
        XCTAssertEqual(saved?.note, "A reviewed note")
        XCTAssertEqual(saved?.anchoredAt, original.anchoredAt)
        model.edit(original, title: "Stale change", note: nil)
        await model.finishPendingWrite()
        XCTAssertNotNil(model.message)
        let retained = try await owner.marker(id: original.id)
        XCTAssertEqual(retained, saved)
        await model.newerPage()
        XCTAssertTrue(model.markers.isEmpty)
        model.setQuery("")
        XCTAssertEqual(model.markers.count, 50)
        model.hide()
        try await owner.close()
    }

    func testMarkNowAcknowledgesDurableTimestampAndUndoUsesLatestRevision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marker-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        let owner = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        let model = TimelineMarkersViewModel(service: { owner })
        model.markNow(at: time)
        await model.finishPendingWrite()
        let marked = try XCTUnwrap(model.markers.first)
        XCTAssertEqual(marked.anchoredAt, time)
        XCTAssertNil(marked.screenReference, "A timestamp marker must not imply nearby screen evidence")
        let stored = try await owner.marker(id: marked.id)
        XCTAssertEqual(stored, marked)
        model.undo()
        await model.finishPendingWrite()
        XCTAssertTrue(model.markers.isEmpty)
        let removed = try await owner.marker(id: marked.id, includeDeleted: true)
        XCTAssertNotNil(removed?.deletedAt)
        model.undo()
        await model.finishPendingWrite()
        XCTAssertEqual(model.markers.map(\.id), [marked.id])
        XCTAssertNotEqual(model.markers.first?.revision, marked.revision)
        model.hide()
        try await owner.close()
    }

    func testVoiceRulesStartDisabledAndSaveOnlyThroughTheSidecarOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("voice-rules-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nativeID = UUID()
        let owner = TimelineMarkerService(storageRoot: root, nativeStoreID: { nativeID })
        let model = VoiceMarkerRulesViewModel(service: { owner })
        model.save(phrase: "mark this", name: "Decision", meaning: "A decision to revisit", aliases: "save this point")
        await model.finishPendingWrite()
        let rule = try XCTUnwrap(model.rules.first)
        XCTAssertFalse(rule.enabled)
        XCTAssertEqual(rule.aliases, ["save this point"])
        XCTAssertEqual(rule.action, .markOnTimeline)
        model.setEnabled(rule, enabled: true)
        await model.finishPendingWrite()
        let stored = try await owner.listKeywordRules()
        XCTAssertEqual(stored.count, 1)
        XCTAssertTrue(try XCTUnwrap(stored.first).enabled)
        XCTAssertNotEqual(stored.first?.revision, rule.revision)
        try await owner.close()
    }
}
