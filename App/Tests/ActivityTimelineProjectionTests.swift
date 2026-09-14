import XCTest
import Shared
import Database
@testable import App

final class ActivityTimelineProjectionTests: XCTestCase {
    func testExactSelectedLabelOutranksLaterInheritedDocumentMapping() async throws {
        let database = DatabaseManager(databasePath: "file:episodes-label-priority-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let session = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ActivityContext(appBundleID: "word", appName: "Word", processID: 1,
            processGeneration: "word", windowID: 1, windowTitle: "Proposal", documentID: "doc-a")
        var stored: [PersistedActivityEvent] = []
        for index in 0..<2 {
            stored.append(try await database.appendActivity(ActivityEvent(sessionID: session, sequence: Int64(index + 1),
                observedAt: date.addingTimeInterval(Double(index * 20)), monotonicTime: Double(index * 20),
                kind: .focus, coverage: .observed, context: context, method: "focus-fixture")))
        }
        let exact = try await database.submitActivityCorrection(ActivityCorrection(targetEventIDs: [stored[0].id],
            expectedRevision: 0, action: .rename, label: "Selected exception", confirmed: true))
        let reusable = try await database.submitActivityCorrection(ActivityCorrection(targetEventIDs: [stored[1].id],
            expectedRevision: exact.revision, action: .rename, scope: .document, label: "Document default",
            documentKey: context.stableDocumentKey, confirmed: true))
        try await database.acknowledgeActivityCorrection(id: reusable.command.id, expectedRevision: reusable.revision, applied: true)
        let corrections = try await database.activityCorrections()
        let episodes = ActivityTimelineProjection.build(events: stored, corrections: corrections)
        XCTAssertEqual(episodes.first { $0.intervals.flatMap(\.eventIDs).contains(stored[0].id) }?.title, "Selected exception")
        XCTAssertEqual(episodes.first { $0.intervals.flatMap(\.eventIDs).contains(stored[1].id) }?.title, "Document default")
        try await database.close()
    }

    func testSelectedObservationCorrectionDoesNotExtendIntoLaterHeartbeat() async throws {
        let database = DatabaseManager(databasePath: "file:episodes-heartbeat-scope-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let session = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let context = ActivityContext(appBundleID: "word", appName: "Word", processID: 1,
            processGeneration: "word", windowID: 1, windowTitle: "Proposal", documentID: "doc-a")
        let first = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: 1,
            observedAt: date, monotonicTime: 0, kind: .focus, coverage: .observed,
            context: context, method: "focus-fixture"))
        let hidden = try await database.submitActivityCorrection(ActivityCorrection(targetEventIDs: [first.id],
            expectedRevision: 0, action: .hide, confirmed: true))
        let later = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: 2,
            observedAt: date.addingTimeInterval(20), monotonicTime: 20, kind: .heartbeat, coverage: .observed,
            context: context, method: "heartbeat-fixture"))
        let page = try await database.searchActivity(ActivityQuery())
        let episodes = ActivityTimelineProjection.build(events: page.events, corrections: [hidden])
        XCTAssertEqual(episodes.filter(\.hidden).flatMap(\.intervals).flatMap(\.eventIDs), [first.id])
        XCTAssertEqual(episodes.filter { !$0.hidden }.flatMap(\.intervals).flatMap(\.eventIDs), [later.id])
        XCTAssertEqual(episodes.flatMap(\.intervals).reduce(0) { $0 + $1.focusDuration }, 20)
        try await database.close()
    }

    func testSelectedGlanceCorrectionDoesNotHideOrRenameOtherIntervalsInGroupedEpisode() async throws {
        let database = DatabaseManager(databasePath: "file:episodes-scope-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let session = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        var stored: [PersistedActivityEvent] = []
        for (index, offset) in [0.0, 20, 22].enumerated() {
            let chat = index == 1
            stored.append(try await database.appendActivity(ActivityEvent(sessionID: session, sequence: Int64(index + 1),
                observedAt: date.addingTimeInterval(offset), monotonicTime: offset, kind: .focus, coverage: .observed,
                context: ActivityContext(appBundleID: chat ? "chat" : "word", appName: chat ? "Chat" : "Word",
                    processID: chat ? 2 : 1, processGeneration: chat ? "chat" : "word", windowID: chat ? 2 : 1,
                    windowTitle: chat ? "Short chat" : "Proposal", documentID: chat ? "chat-a" : "doc-a"), method: "focus-fixture")))
        }
        XCTAssertEqual(ActivityTimelineProjection.build(events: stored).count, 1, "The fixture first forms an interrupted episode")
        let hidden = try await database.submitActivityCorrection(ActivityCorrection(targetEventIDs: [stored[1].id],
            expectedRevision: 0, action: .hide, confirmed: true))
        let renamed = try await database.submitActivityCorrection(ActivityCorrection(targetEventIDs: [stored[1].id],
            expectedRevision: hidden.revision, action: .rename, label: "Only this chat", confirmed: true))
        let episodes = ActivityTimelineProjection.build(events: stored, corrections: [hidden, renamed])
        let visible = episodes.filter { !$0.hidden }
        XCTAssertEqual(Set(visible.flatMap(\.intervals).flatMap(\.eventIDs)), [stored[0].id, stored[2].id])
        XCTAssertEqual(Set(visible.map(\.title)), ["Proposal"])
        XCTAssertEqual(episodes.filter(\.hidden).flatMap(\.intervals).flatMap(\.eventIDs), [stored[1].id])
        try await database.close()
    }

    func testLaterDocumentEnrichmentDoesNotBackdateIdentityOntoEarlierFocus() async throws {
        let database = DatabaseManager(databasePath: "file:episodes-enrichment-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let session = UUID(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let base = ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word", processID: 1,
            processGeneration: "word", windowID: 10, windowGeneration: "window-1", windowTitle: "Proposal", displayID: 2)
        let document = ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word", processID: 1,
            processGeneration: "word", windowID: 10, windowGeneration: "window-1", windowTitle: "Proposal", displayID: 2,
            documentID: "observed-later-document")
        let focus = ActivityEvent(sessionID: session, sequence: 1, observedAt: date, monotonicTime: 100,
            kind: .focus, coverage: .observed, context: base, method: "window-sample")
        _ = try await database.appendActivity(focus)
        _ = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: 2,
            observedAt: date.addingTimeInterval(5), monotonicTime: 105, kind: .enrichment, coverage: .observed,
            context: document, relatedEventID: focus.id, method: "captured-window-document"))
        _ = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: 3,
            observedAt: date.addingTimeInterval(10), monotonicTime: 110, kind: .pause, coverage: .paused, method: "master-pause"))
        let page = try await database.searchActivity(ActivityQuery())
        let intervals = ActivityTimelineProjection.build(events: page.events).flatMap(\.intervals)
        let earlier = try XCTUnwrap(intervals.first { $0.eventIDs.contains(focus.id) })
        XCTAssertNil(earlier.context?.documentID, "A later sample cannot establish an earlier document identity")
        XCTAssertEqual(earlier.focusDuration, 5, accuracy: 0.001)
        let enriched = try XCTUnwrap(intervals.first { $0.context?.documentID != nil })
        XCTAssertEqual(enriched.startedAt, date.addingTimeInterval(5))
        XCTAssertEqual(enriched.focusDuration, 5, accuracy: 0.001)
        try await database.close()
    }

    func testRealStoredTransitionsKeepGlancesGapsAndSeparateSpanFromFocus() async throws {
        let database = DatabaseManager(databasePath: "file:episodes-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let session = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let contexts = [
            ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word", processID: 1,
                            processGeneration: "word-session", windowID: 10, windowTitle: "Cedar proposal", documentID: "doc-a"),
            ActivityContext(appBundleID: "com.openai.chat", appName: "ChatGPT", processID: 2,
                            processGeneration: "chat-session", windowID: 20, windowTitle: "Two-second glance", documentID: "chat-a")
        ]
        let inputs: [(Double, ActivityEventKind, ActivityCoverage, ActivityContext?)] = [
            (0, .focus, .observed, contexts[0]), (20, .focus, .observed, contexts[1]),
            (22, .focus, .observed, contexts[0]), (42, .heartbeat, .observed, contexts[0]),
            (60, .gap, .unknown, nil), (90, .focus, .uncertain, contexts[0]), (100, .pause, .paused, nil)
        ]
        for (index, input) in inputs.enumerated() {
            _ = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: Int64(index + 1),
                observedAt: start.addingTimeInterval(input.0), monotonicTime: input.0 + 100,
                kind: input.1, coverage: input.2, context: input.3, method: "fixed-action-script"))
        }
        let page = try await database.searchActivity(ActivityQuery())
        let episodes = ActivityTimelineProjection.build(events: page.events)
        let intervals = episodes.flatMap(\.intervals)
        XCTAssertEqual(intervals.filter { $0.context?.appBundleID == "com.openai.chat" }.map(\.focusDuration), [2])
        XCTAssertTrue(intervals.contains { $0.coverage == .unknown })
        XCTAssertEqual(Set(intervals.flatMap(\.eventIDs)), Set(page.events.map(\.id)))
        let joined = try XCTUnwrap(episodes.first(where: { $0.intervals.filter { $0.context?.documentID == "doc-a" }.count == 2 }))
        XCTAssertEqual(joined.focusDuration, 42, accuracy: 0.001)
        XCTAssertEqual(joined.spanDuration, 42, accuracy: 0.001)
        XCTAssertEqual(joined.intervals.filter { $0.context?.documentID == "doc-a" }.reduce(0) { $0 + $1.focusDuration }, 40)
        XCTAssertEqual(episodes.filter { $0.intervals.first?.startedAt == start.addingTimeInterval(90) }.count, 1,
                       "An unknown gap prevents inferred continuity")
        try await database.close()
    }

    func testSameTitleWithoutDocumentIdentityNeverMergesAndDraftCorrectionIsNotApproval() async throws {
        let database = DatabaseManager(databasePath: "file:episodes-title-\(UUID())?mode=memory&cache=private")
        try await database.initialize()
        let session = UUID(); let date = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<2 {
            _ = try await database.appendActivity(ActivityEvent(sessionID: session, sequence: Int64(index + 1),
                observedAt: date.addingTimeInterval(Double(index)), monotonicTime: Double(index), kind: .focus,
                coverage: .uncertain, context: ActivityContext(appBundleID: "com.microsoft.Word", appName: "Word",
                    processID: 1, processGeneration: "word", windowID: UInt32(index + 10), windowTitle: "Proposal"), method: "window-list"))
        }
        let page = try await database.searchActivity(ActivityQuery())
        let command = ActivityCorrection(targetEventIDs: [page.events[0].id], expectedRevision: 0,
                                         action: .rename, label: "Draft guess", confirmed: false)
        let receipt = try await database.submitActivityCorrection(command)
        let episodes = ActivityTimelineProjection.build(events: page.events, corrections: [receipt])
        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(episodes.map(\.title), ["Proposal", "Proposal"])
        try await database.close()
    }
}
