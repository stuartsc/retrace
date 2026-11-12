import AppKit
import AVFoundation
import CoreGraphics
import CryptoKit
import Darwin
import ObjectiveC.runtime
import SQLCipher
import Shared
import Storage
import SwiftUI
import XCTest
@testable import Retrace
@testable import App
@testable import Database

/// Opt-in native rendering of the production workspace with authored private
/// SQLite/AAC evidence. No AppCoordinator, capture device or live store is used.
@MainActor
final class LiveContextNativeViewTests: XCTestCase {
    private let preparedText = "Cedar launch review: Maya will prepare the onboarding checklist. We agreed to review the draft on Friday before sharing it with the pilot team."
    private var nativeInputRequested: Bool {
        ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_INPUT"] == "1"
    }

    func testActualWorkspaceRendersWideAndNarrowWithoutStartingPlaybackOrInference() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_NATIVE_LIVE_CONTEXT=1 to render the actual workspace offscreen")
        }
        if nativeInputRequested {
            #if !DEBUG
            throw XCTSkip("Native Live input validation requires debug process-local file logging isolation")
            #endif
            guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE"] == "1",
                  ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1" else {
                throw XCTSkip("Native Live input validation requires a visible fixture and process-local file logging disabled")
            }
        }
        if ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE"] == "1" {
            // Isolated opt-in xctest process only. Publish the normal AppKit
            // hierarchy. The separate INPUT opt-in permits native keyboard focus.
            _ = NSApplication.shared
            NSApp.setActivationPolicy(nativeInputRequested ? .regular : .accessory)
            NSApp.finishLaunching()
        }
        let exportDirectory = try renderDirectory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-live-context-native-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await makePrivateDatabase(at: root.appendingPathComponent("recordings.db"))
        var retainedFixture: Fixture?
        do {
            try await database.initialize()
            let fixture = try await makeFixture(database: database, root: root)
            retainedFixture = fixture
            let viewports: [(String, CGFloat)] = [("wide", 1_280), ("narrow", 820)]
            for (name, width) in viewports {
                try await render(fixture: fixture, database: database, root: root,
                    name: name, width: width, exportDirectory: exportDirectory)
            }
            let pending = try await fixture.queries.getUntranscribedBatchCount()
            XCTAssertEqual(pending, 1, "Rendering must leave the authored pending recording unprocessed")
            try await fixture.close()
            try await database.close()
        } catch {
            try? await retainedFixture?.close()
            try? await database.close()
            throw error
        }
    }

    func testPendingOnlyWorkspaceSupportsNativeReadingInputAtBothWidths() async throws {
        #if !DEBUG
        throw XCTSkip("Pending-only input validation requires debug process-local file logging isolation")
        #endif
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_PENDING_INPUT"] == "1",
              nativeInputRequested,
              ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE"] == "1",
              ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1" else {
            throw XCTSkip("Pending-only native input requires PENDING_INPUT, INPUT, VISIBLE and disabled debug file logging")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let exportDirectory = try renderDirectory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-live-pending-input-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await makePrivateDatabase(at: root.appendingPathComponent("recordings.db"))
        var retained: Fixture?
        do {
            try await database.initialize()
            let fixture = try await makeFixture(database: database, root: root)
            retained = fixture
            let media = try await makeRecording(root: root, timestamp: fixture.pendingAt.addingTimeInterval(25))
            var pendingIDs: [Int64] = []
            for index in 1...100 {
                let start = fixture.pendingAt.addingTimeInterval(Double(index) * 0.2)
                let recording = try copyAuthoredRecording(media, root: root)
                pendingIDs.append(try await fixture.queries.insertRawBatch(startTime: start,
                    endTime: start.addingTimeInterval(3), source: .microphone,
                    audioPath: recording.path, audioSize: recording.size))
            }
            var savedPending: [AudioTranscription] = []
            for id in [try XCTUnwrap(fixture.audioIDs.first)] + pendingIDs {
                let stored = try await fixture.queries.getContextEntry(id: id)
                let row = try XCTUnwrap(stored)
                XCTAssertEqual(row.transcriptStatus, "pending")
                XCTAssertTrue(row.text.isEmpty)
                savedPending.append(row)
            }
            XCTAssertEqual(Set(savedPending.map(\.id)).count, 101)
            for (name, width) in [("pending-wide", CGFloat(1_280)), ("pending-narrow", CGFloat(820))] {
                try await renderPendingOnly(fixture: fixture, root: root, name: name, width: width,
                    expectedIDs: Array(pendingIDs.reversed()), media: media, exportDirectory: exportDirectory)
            }
            // Worker backlog counts intentionally filter batch_ file names;
            // integrity is the exact saved fixture identity, independent of naming.
            for expected in savedPending {
                let stored = try await fixture.queries.getContextEntry(id: expected.id)
                let current = try XCTUnwrap(stored, "Native reading must retain every authored pending row")
                XCTAssertEqual(current.transcriptStatus, "pending")
                XCTAssertTrue(current.text.isEmpty)
                XCTAssertTrue(LiveContextPresentation.sameRecording(current, expected),
                    "Native reading must preserve each pending recording's complete canonical identity")
            }
            try await fixture.close()
            try await database.close()
        } catch {
            try? await retained?.close()
            try? await database.close()
            throw error
        }
    }

    private func renderPendingOnly(fixture: Fixture, root: URL, name: String, width: CGFloat,
                                   expectedIDs: [Int64], media: (path: String, size: Int64),
                                   exportDirectory: URL?) async throws {
        let completedReads = LiveContextNativeReadCounter()
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            let page = try await fixture.queries.getContextPage(from: interval.start, to: interval.end,
                limit: 100, before: cursor, query: query)
            completedReads.record(page.entries.map(\.id))
            return page
        }, loadScreens: { try await fixture.screenPage(in: $0) },
           readEntry: { try await fixture.queries.getContextEntry(id: $0) }, speakerChanges: { fixture.companion })
        let evidence = EvidenceViewModel(client: .live(service: fixture.recall))
        let playbackProbe = LiveContextNativePlaybackProbe()
        let playback = TranscriptAudioPlayback(resolve: { request in
            await playbackProbe.recordAttempt()
            return try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: root)
        }, isMuted: true)
        let view = LiveContextWorkspaceView(model: model, evidence: evidence, playback: playback,
            isActive: true, isRecording: false,
            validateScreen: { (try? await fixture.database.screenEvidence($0)) != nil },
            openEvidence: { _ in XCTFail("Pending-only reading must not open a timeline") },
            openVoiceMarkerSettings: { XCTFail("Pending-only reading must not open installed settings") })
        let height: CGFloat = 760
        let controller = NSHostingController(rootView: view.frame(width: width, height: height)
            .background(Color.retraceBackground).environment(\.colorScheme, .dark))
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let panel = LiveContextNativeInputWindow(contentRect: NSRect(x: screen.midX - width / 2,
            y: screen.midY - height / 2, width: width, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.contentViewController = controller
        panel.title = "Retrace Live \(name) — AUTHORED PENDING INPUT"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = controller.view
        panel.orderFront(nil)
        defer {
            model.setActive(false)
            evidence.closeEvidence()
            playback.stop(reason: .closed)
            panel.orderOut(nil)
            panel.contentViewController = nil
            panel.close()
        }
        try await waitUntil("all pending rows ready") {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return model.presentationReady && model.transcripts.map(\.id) == expectedIDs
        }
        XCTAssertTrue(model.transcripts.allSatisfy { $0.text.isEmpty && $0.transcriptStatus == "pending" })
        XCTAssertEqual(Set(model.transcripts.compactMap(\.audioPath)).count, 100,
            "Each authored recording must have its own batch identity")
        XCTAssertEqual(model.transcriptItems.count, 100)
        XCTAssertTrue(model.speakers.isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        let arrivalMedia = try copyAuthoredRecording(media, root: root)
        XCTAssertFalse(model.transcripts.contains { $0.audioPath == arrivalMedia.path || $0.batchAudioPath == arrivalMedia.path },
            "A newly saved arrival must not mutate a retained recording's batch identity")
        try await observeNativeInput(panel: panel, hosting: hosting, model: model,
            completedReads: completedReads, queries: fixture.queries, name: name,
            exportDirectory: exportDirectory, pendingArrival: arrivalMedia)
        let attempts = await playbackProbe.attempts
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(model.transcripts.allSatisfy { $0.text.isEmpty && $0.transcriptStatus == "pending" })
    }

    func testResponsiveWorkspaceRetainsPinnedTranscriptAcrossResizeAndCompactTabs() async throws {
        #if !DEBUG
        throw XCTSkip("Responsive native validation requires debug file logging isolation")
        #endif
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_LAYOUT"] == "1",
              ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_NATIVE_LIVE_CONTEXT_LAYOUT=1 with disabled debug file logging")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-live-responsive-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await makePrivateDatabase(at: root.appendingPathComponent("recordings.db"))
        var retained: Fixture?
        do {
            try await database.initialize()
            let fixture = try await makeFixture(database: database, root: root)
            retained = fixture
            let media = try await makeRecording(root: root, timestamp: fixture.pendingAt.addingTimeInterval(25))
            for index in 1...100 {
                let start = fixture.pendingAt.addingTimeInterval(Double(index) * 0.2)
                let recording = try copyAuthoredRecording(media, root: root)
                _ = try await fixture.queries.insertRawBatch(startTime: start, endTime: start.addingTimeInterval(3),
                    source: .microphone, audioPath: recording.path, audioSize: recording.size)
            }
            try await verifyResponsiveWorkspace(fixture: fixture, root: root)
            try await fixture.close()
            try await database.close()
        } catch {
            try? await retained?.close()
            try? await database.close()
            throw error
        }
    }

    private func verifyResponsiveWorkspace(fixture: Fixture, root: URL) async throws {
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            try await fixture.queries.getContextPage(from: interval.start, to: interval.end,
                limit: 100, before: cursor, query: query)
        }, loadScreens: { try await fixture.screenPage(in: $0) },
           readEntry: { try await fixture.queries.getContextEntry(id: $0) }, speakerChanges: { fixture.companion })
        let evidence = EvidenceViewModel(client: .live(service: fixture.recall))
        let playbackProbe = LiveContextNativePlaybackProbe()
        let playback = TranscriptAudioPlayback(resolve: { request in
            await playbackProbe.recordAttempt()
            return try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: root)
        }, isMuted: true)
        let view = LiveContextWorkspaceView(model: model, evidence: evidence, playback: playback,
            isActive: true, isRecording: false,
            validateScreen: { (try? await fixture.database.screenEvidence($0)) != nil },
            openEvidence: { _ in XCTFail("Responsive reading must not open a timeline") },
            openVoiceMarkerSettings: { XCTFail("Responsive reading must not open installed settings") })
        // The production view receives the actual window proposal, with no fixed
        // root width that could conceal a breakpoint transition from the test.
        let controller = NSHostingController(rootView: view.background(Color.retraceBackground).environment(\.colorScheme, .dark))
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let panel = LiveContextNativeInputWindow(contentRect: NSRect(x: screen.midX - 740,
            y: screen.midY - 380, width: 1_480, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.contentViewController = controller
        // Controller attachment adopts the root's small ideal size. Apply the
        // actual window proposal afterward; no fixed SwiftUI width masks resize.
        panel.setContentSize(NSSize(width: 1_480, height: 760))
        panel.setFrameOrigin(NSPoint(x: screen.midX - panel.frame.width / 2,
            y: screen.midY - panel.frame.height / 2))
        panel.title = "Retrace Live — AUTHORED RESPONSIVE LAYOUT"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let hosting = controller.view
        defer {
            model.setActive(false); evidence.closeEvidence(); playback.stop(reason: .closed)
            panel.orderOut(nil); panel.contentViewController = nil; panel.close()
        }
        panel.orderFront(nil)
        try await waitUntil("responsive pending history ready") {
            hosting.layoutSubtreeIfNeeded()
            return model.presentationReady && model.transcripts.count == 100 && !model.isLoading
        }
        XCTAssertTrue(model.transcripts.allSatisfy { $0.text.isEmpty })
        let finished = expectation(description: "Responsive native AppKit loop completed")
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0))
        var verification: Task<Void, Never>?
        var verified = false
        let loop = NativeAppKitObservationLoop(wake: wake, activate: {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeMain()
        }, verifyReadiness: {
            verification = Task { @MainActor in
                do {
                    try await self.verifyResponsiveTransitions(panel: panel, hosting: hosting, model: model)
                    verified = true
                } catch { XCTFail("Responsive native transition failed: \(error)") }
            }
        }, finished: { finished.fulfill() }, duration: 12)
        loop.schedule()
        await fulfillment(of: [finished], timeout: 20)
        loop.invalidateTimers()
        verification?.cancel()
        await verification?.value
        XCTAssertTrue(loop.checkedReadiness && loop.deadlineReached && loop.returnedFromRun)
        XCTAssertTrue(verified, "Every actual native resize/tab/input/Return assertion must complete within the bounded loop")
        let attempts = await playbackProbe.attempts
        XCTAssertEqual(attempts, 0)
    }

    private func verifyResponsiveTransitions(panel: NSWindow, hosting: NSView,
                                             model: LiveContextWorkspaceModel) async throws {
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(180))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        try await settle()
        XCTAssertEqual(hosting.bounds.width, 1_480, accuracy: 1, "The responsive fixture must begin at the actual wide content size")
        XCTAssertEqual(hosting.bounds.height, 760, accuracy: 1)
        let ids = model.transcriptItems.map(\.id)
        let displayed = ids
        let observer = try XCTUnwrap(Self.nativeDescendants(hosting).compactMap {
            $0 as? LiveContextScrollInteractionObserver.ObserverView
        }.first)
        let candidate = NativeLiveTranscriptGeometry.scroll(in: hosting, observer: observer, expectedIDs: displayed)
        if candidate == nil {
            // One bounded geometry-only failure receipt; never substitutes a
            // different scroll or alters the expected marker identity oracle.
            let scrolls = Self.nativeDescendants(hosting).compactMap { $0 as? NSScrollView }
            print("Responsive native lookup: window=\(panel.frame), hosting=\(hosting.bounds), observer=\(observer.bounds), observerAttached=\(observer.window === panel), active=\(observer.isActive()), expectedRows=\(displayed.count), nativeScrolls=\(scrolls.count)")
            for (index, scroll) in scrolls.prefix(8).enumerated() {
                let rect = observer.convert(scroll.bounds, from: scroll)
                let rendered = NativeLiveTranscriptGeometry.renderedRows(in: scroll)
                let markers = scroll.documentView.map { Self.nativeDescendants($0).compactMap { $0 as? LiveContextTranscriptRowIdentity.MarkerView } } ?? []
                print("Responsive native candidate \(index): scroll=\(scroll.bounds), converted=\(rect), contained=\(observer.bounds.insetBy(dx: -1, dy: -1).contains(rect)), document=\(String(describing: scroll.documentView?.bounds)), markers=\(markers.count), positiveMarkers=\(markers.filter { $0.bounds.width > 0 && $0.bounds.height > 0 }.count), renderedRows=\(rendered?.count ?? -1), expectedIDsEqual=\(rendered?.map(\.id) == displayed), hidden=\(scroll.isHiddenOrHasHiddenAncestor)")
            }
        }
        let scroll = try XCTUnwrap(candidate)
        let document = try XCTUnwrap(scroll.documentView)
        model.pauseFollowing()
        try await settle()
        let rows = try XCTUnwrap(NativeLiveTranscriptGeometry.rows(in: scroll, expectedIDs: displayed))
        let target = rows[rows.count / 2]
        let top = document.isFlipped ? target.frame.minY + 7 : target.frame.maxY - scroll.contentView.bounds.height - 7
        // One initial setup move; transition assertions never repair the viewport.
        document.scroll(NSPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle()
        let baseline = try XCTUnwrap(NativeLiveTranscriptGeometry.anchor(in: scroll, expectedIDs: displayed))
        let interval = model.interval
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        func verifyPosition(_ stage: String) throws {
            XCTAssertTrue(Self.nativeDescendants(hosting).contains { $0 === scroll }, stage)
            XCTAssertTrue(scroll.documentView === document, stage)
            XCTAssertEqual(model.transcriptItems.map(\.id), ids, stage)
            XCTAssertEqual(model.interval, interval, stage)
            XCTAssertFalse(model.followingLive, stage)
            let anchor = try XCTUnwrap(NativeLiveTranscriptGeometry.anchor(in: scroll, expectedIDs: displayed), stage)
            XCTAssertEqual(anchor.itemID, baseline.itemID, stage)
            XCTAssertEqual(anchor.offsetY, baseline.offsetY, accuracy: 1, stage)
        }
        panel.setContentSize(NSSize(width: 820, height: 760))
        try await settle()
        XCTAssertLessThan(hosting.bounds.width, DashboardLiveLayoutPolicy.minSplitWidth)
        try verifyPosition("wide to narrow")
        XCTAssertTrue(observer.isActive())

        // Click the actual pending text row without manufacturing a first
        // responder. The next hidden-pane key must not move this document.
        let visibleRows = try XCTUnwrap(NativeLiveTranscriptGeometry.rows(in: scroll, expectedIDs: displayed))
        let clickRow = try XCTUnwrap(visibleRows.first { scroll.documentVisibleRect.contains($0.frame) })
        let point = document.convert(NSPoint(x: clickRow.frame.minX + 90, y: clickRow.frame.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
        NSApp.sendEvent(try mouse(.leftMouseDown))
        try await settle()
        let responder = try XCTUnwrap(panel.firstResponder as? NSView)
        XCTAssertTrue(responder === document || responder.isDescendant(of: document), "Actual pending text click must establish scoped native focus")
        XCTAssertFalse((responder as? NSTextView)?.isEditable ?? false)
        try verifyPosition("pending text focus")
        try await pressLivePane("Screen", in: hosting)
        try await settle()
        XCTAssertFalse(observer.isActive(), "The mounted hidden transcript must not own native reading input")
        XCTAssertTrue(Self.nativeDescendants(hosting).contains { $0 === scroll })
        XCTAssertTrue(scroll.documentView === document)
        let hiddenOrigin = scroll.contentView.bounds.origin
        // Raw internal SwiftUI AX traversal can still enumerate ignored nodes.
        // External hidden-pane accessibility acceptance is a separate CUA check.
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{F72C}", charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116))
        NSApp.sendEvent(key)
        try await settle()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, hiddenOrigin.y, accuracy: 1,
            "A reading key on Screen must not move the hidden transcript")
        try await pressLivePane("Transcript", in: hosting)
        try await settle()
        XCTAssertTrue(observer.isActive())
        try verifyPosition("Screen to Transcript")
        panel.setContentSize(NSSize(width: 1_480, height: 760))
        try await settle()
        XCTAssertGreaterThan(hosting.bounds.width, DashboardLiveLayoutPolicy.minSplitWidth)
        try verifyPosition("narrow to wide")
        try pressAccessibleButton("Return to live", in: hosting)
        try await waitUntil("responsive Return follows newest") {
            hosting.layoutSubtreeIfNeeded()
            return model.followingLive && NativeLiveTranscriptGeometry.isAtNewestEnd(scroll, tolerance: 1)
        }
        print("Native Live responsive layout: same scroll/document, canonical page and row offset survived 1480/820/tab/1480; hidden transcript input withheld; Return reached newest end. External AX acceptance remains separate.")
    }

    private func pressLivePane(_ label: String, in root: NSView) async throws {
        func radio(_ title: String) -> NSObject? {
            Self.accessibleElements(in: root, includingNativeSubviews: false).first { element in
                let role = Self.modernAttribute("accessibilityRole", of: element) ?? element.accessibilityAttributeValue(.role)
                let labels = [Self.modernAttribute("accessibilityLabel", of: element),
                    Self.modernAttribute("accessibilityTitle", of: element), element.accessibilityAttributeValue(.title)].compactMap { $0 as? String }
                return (String(describing: role).contains("AXRadioButton") || String(describing: role).contains("AXButton")) && labels.contains(title)
            }
        }
        func selected(_ title: String) -> Bool? {
            guard let element = radio(title) else { return nil }
            let value = Self.modernAttribute("accessibilityValue", of: element) ?? element.accessibilityAttributeValue(.value)
            if let number = value as? NSNumber { return number.boolValue }
            if let string = value as? String, ["0", "1"].contains(string) { return string == "1" }
            return nil
        }
        let element = try XCTUnwrap(radio(label), "The compact Live pane must expose its actual \(label) segment")
        let callbackResult = try accessiblePressAction(element, label: label)()
        let other = label == "Screen" ? "Transcript" : "Screen"
        // SwiftUI may return false after performing the radio action. Re-read
        // current nodes and require the actual mutually exclusive selection.
        try await waitUntil("compact \(label) selected", diagnostics: { "pressCallback=\(callbackResult)" }) {
            selected(label) == true && selected(other) == false
        }
    }

    func testCanonicalResumeRevokesHiddenAudioDeletionOtherSpeakerCorrectionAndSelectedScreen() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_NATIVE_LIVE_CONTEXT=1 for private SQLite/AAC companion resume validation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-live-resume-sources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await makePrivateDatabase(at: root.appendingPathComponent("recordings.db"))
        var retained: Fixture?
        do {
            try await database.initialize()
            let fixture = try await makeFixture(database: database, root: root)
            retained = fixture
            let speakerGate = LiveContextNativeResumeGate()
            let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
                try await fixture.queries.getContextPage(from: interval.start, to: interval.end, limit: 100, before: cursor, query: query)
            }, loadScreens: { interval in
                try await fixture.screenPage(in: interval)
            }, readEntry: { try await fixture.queries.getContextEntry(id: $0) },
               loadSpeakers: { interval, cursor in try await fixture.companion.speakerPresentations(from: interval.start, to: interval.end, before: cursor) },
               resolveTurn: { try await fixture.companion.resolveTurn($0) }, readSpeaker: { id in
                   await speakerGate.waitIfHeld()
                   return try await fixture.companion.speakerPresentation(jobID: id)
               }, speakerChanges: { fixture.companion }, referenceRecordings: { rows in
                   try await fixture.search.transcriptReferences(rows).compactMap {
                       if case .transcript(let reference) = $0 { return reference }; return nil
                   }
               })
            model.setActive(true)
            await model.refresh()
            let batch = try XCTUnwrap(model.speakers.first)
            XCTAssertEqual(batch.turnReferences.count, 2)
            try await model.selectTurn(XCTUnwrap(batch.turnReferences.first))
            await model.refresh()
            let selected = try XCTUnwrap(model.selectedTurn)
            let screen = try XCTUnwrap(model.screens.first)
            model.selectScreen(screen)
            let originalInterval = model.interval
            let originalRows = model.transcripts
            model.setActive(false)
            XCTAssertFalse(model.presentationReady)
            let deletedAudio = fixture.audioIDs[2]
            _ = try await fixture.queries.deleteTranscription(id: deletedAudio)
            let otherSpeaker = try XCTUnwrap(batch.enhancement.turns.last)
            XCTAssertNotEqual(otherSpeaker.speakerID, selected.turn.speakerID,
                "The correction must target a different turn than the selected one")
            _ = try await fixture.companion.correctSpeaker(.init(jobID: batch.jobID, speakerID: otherSpeaker.speakerID,
                displayName: "Ravi (corrected while hidden)", expectedRevision: nil))
            let hiddenTag = try await database.getTag(name: "hidden")
            try await database.addTagToSegment(segmentId: SegmentID(value: fixture.snapshot.frame.segmentID.value), tagId: XCTUnwrap(hiddenTag).id)

            await speakerGate.holdNext()
            model.setActive(true)
            let resumed = Task { await model.refresh() }
            let entered = await speakerGate.waitUntilEntered()
            XCTAssertTrue(entered, "Resume must validate the complete retained speaker batch, including unselected turns")
            XCTAssertFalse(model.presentationReady)
            await speakerGate.release()
            await resumed.value
            XCTAssertTrue(model.presentationReady)
            XCTAssertFalse(model.followingLive)
            XCTAssertEqual(model.interval, originalInterval)
            XCTAssertFalse(model.transcripts.contains { $0.id == deletedAudio })
            XCTAssertTrue(model.speakers.isEmpty, "A changed unselected turn invalidates the retained batch revision")
            XCTAssertEqual(model.selectedTurn?.reference, selected.reference,
                "A correction to another speaker must not revoke an independently revalidated exact selected turn")
            XCTAssertEqual(model.selectedTurn?.displayLabel, selected.displayLabel)
            XCTAssertNil(model.selectedScreenID)
            XCTAssertTrue(model.screens.isEmpty, "A hidden screen cannot reappear when Settings closes")
            XCTAssertFalse(model.transcriptItems.compactMap(\.turn).contains { $0.reference == selected.reference })
            let stillValid = await model.validateForAction(originalRows)
            XCTAssertFalse(stillValid, "Copy/playback cannot retain a stale hidden deletion proof")
            model.setActive(false)
            try await fixture.close()
            try await database.close()
        } catch {
            try? await retained?.close()
            try? await database.close()
            throw error
        }
    }

    private func makePrivateDatabase(at url: URL) async throws -> DatabaseManager {
        #if DEBUG
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Private fixture database unavailable"
            if let opened { sqlite3_close_v2(opened) }
            throw DatabaseError.connectionFailed(underlying: message)
        }
        var needsClose = true
        defer { if needsClose { sqlite3_close_v2(handle) } }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try await MigrationRunner(db: handle).runMigrations()
        // The real manager treats this canonical sequence row as initialized.
        // Seed it before initialization so it never probes the installed Rewind
        // library to offset identifiers in this entirely authored database.
        let sequenceSQL = """
            INSERT INTO sqlite_sequence(name, seq)
            SELECT 'frame', 0 WHERE NOT EXISTS (
                SELECT 1 FROM sqlite_sequence WHERE name = 'frame'
            );
            """
        guard sqlite3_exec(handle, sequenceSQL, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(query: sequenceSQL, underlying: String(cString: sqlite3_errmsg(handle)))
        }
        guard sqlite3_close(handle) == SQLITE_OK else {
            throw DatabaseError.connectionFailed(underlying: "Private fixture bootstrap did not close")
        }
        needsClose = false
        // This DEBUG-only owner skips live encryption preferences and Keychain.
        return DatabaseManager(testingUnencryptedDatabasePath: url.path)
        #else
        throw XCTSkip("Private native database fixtures require the debug-only isolated database owner")
        #endif
    }

    private struct Fixture {
        let database: DatabaseManager
        let queries: AudioTranscriptionQueries
        let audioIDs: [Int64]
        let pendingAt: Date
        let snapshot: ScreenEvidenceSnapshot
        let screenText: String
        let recall: ProgressiveRecallService
        let adapter: DataAdapter
        let markers: TimelineMarkerService
        let companion: CompanionController
        let search: LiveContextSearchService
        let turnPlayback: CompanionTurnPlayback
        func screenPage(in interval: DateInterval) async throws -> LiveContextScreenPage {
            // Match the production coordinator's initialized DataAdapter route:
            // FilterCriteria applies canonical hidden-segment visibility, and
            // the identity policy brackets the read with current source tokens.
            let limit = LiveContextWorkspaceModel.maximumScreens
            let rows = try await DashboardScreenshotIdentityPolicy.readRows(
                sourceGeneration: { try await recall.sourceGeneration(source: $0) }
            ) {
                try await adapter.getMostRecentFramesWithVideoInfo(limit: limit + 1,
                    filters: FilterCriteria(startDate: interval.start, endDate: interval.end))
            }
            return .init(rows: Array(rows.prefix(limit)), hasMore: rows.count > limit)
        }
        func close() async throws {
            try await database.setSourceMutationObserver(nil)
            await turnPlayback.close(); try await companion.close(); try await markers.close(); await adapter.shutdown()
        }
    }

    private func makeFixture(database: DatabaseManager, root: URL) async throws -> Fixture {
        // Only the clock is current; every captured word, pixel and audio sample is authored.
        let pendingAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        let preparedAt = pendingAt.addingTimeInterval(-90)
        let connection = await database.getConnection()
        let queries = AudioTranscriptionQueries(db: try XCTUnwrap(connection))
        let pendingMedia = try await makeRecording(root: root, timestamp: pendingAt)
        let preparedMedia = try await makeRecording(root: root, timestamp: preparedAt)
        let pendingID = try await queries.insertRawBatch(startTime: pendingAt,
            endTime: pendingAt.addingTimeInterval(3), source: .microphone,
            audioPath: pendingMedia.path, audioSize: pendingMedia.size)
        let preparedID = try await queries.insertTranscription(sessionID: nil, text: preparedText,
            startTime: preparedAt, endTime: preparedAt.addingTimeInterval(3), source: .microphone,
            confidence: nil, words: [], audioPath: preparedMedia.path, batchAudioPath: preparedMedia.path)
        let earlierAt = preparedAt.addingTimeInterval(-90)
        let earlierID = try await queries.insertTranscription(sessionID: nil,
            text: "The pilot team needs a clear handover: one owner for each task, a visible due date, and an exact link back to the recorded decision.",
            startTime: earlierAt, endTime: earlierAt.addingTimeInterval(12), source: .system,
            confidence: nil, words: [])
        var readingIDs: [Int64] = []
        // Both the offscreen destination round trip and optional real-input run
        // require an overflowing actual transcript document; a three-row fixture cannot prove
        // that a pinned native viewport survives Settings.
        do {
            for index in 1...24 {
                let start = earlierAt.addingTimeInterval(-Double(index) * 30)
                readingIDs.append(try await queries.insertTranscription(sessionID: nil,
                    text: "Authored reading passage \(index). The Cedar pilot keeps a clear owner, a review date and a link to each decision. This fictional paragraph supplies native scrolling coverage without reading the installed library.",
                    startTime: start, endTime: start.addingTimeInterval(12), source: .system,
                    confidence: nil, words: []))
            }
        }
        let pendingEntry = try await queries.getContextEntry(id: pendingID)
        let clip = try await TranscriptAudioFileResolver.resolve(
            request: TranscriptAudioRequest(transcription: XCTUnwrap(pendingEntry)), storageRoot: root)
        XCTAssertEqual(clip.startTime, 0, accuracy: 0.002)
        XCTAssertEqual(clip.endTime, 3, accuracy: 0.02, "The fixture must be actual decodable authored AAC")

        let capturedAt = preparedAt.addingTimeInterval(1)
        let metadata = FrameMetadata(appBundleID: "test.retrace.cedar-notes", appName: "Cedar Notes",
            windowName: "Launch checklist — authored fixture")
        let segmentID = try await database.insertSegment(bundleID: "test.retrace.cedar-notes",
            startDate: capturedAt, endDate: capturedAt, windowName: metadata.windowName, browserUrl: nil, type: 0)
        let frameID = FrameID(value: try await database.insertFrame(FrameReference(id: .init(value: 0),
            timestamp: capturedAt, segmentID: .init(value: segmentID), frameIndexInSegment: 0, metadata: metadata)))
        let screenText = "Cedar launch checklist\nPrepare the onboarding draft\nReview with Maya on Friday\nShare with the pilot team after review"
        _ = try await database.commitFrameOCR(frameID: frameID,
            text: ExtractedText(frameID: frameID, timestamp: capturedAt, regions: [
                TextRegion(frameID: frameID, text: screenText, bounds: CGRect(x: 64, y: 64, width: 1_150, height: 400))
            ]), frameWidth: 1_280, frameHeight: 800)
        let storeID = try await database.activityStoreID()
        let stored = try await database.currentScreenEvidence(frameID: frameID, storeID: storeID)
        let snapshot = try XCTUnwrap(stored)
        let image = try authoredImage()
        let adapter = DataAdapter(retraceConnection: try SQLiteConnection(readOnlyDatabasePath: root.appendingPathComponent("recordings.db").path),
            retraceConfig: .init(dateFormatter: nil, storageRoot: root.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: root.path), database: database)
        try await adapter.initialize()
        let recall = ProgressiveRecallService(database: database, adapter: adapter, configuration: { CaptureConfig() },
            imageReader: { item in
                guard item.frame.id == snapshot.ref.frameID, item.frame.source == snapshot.ref.source,
                      item.frame.timestamp == snapshot.frame.timestamp else { throw EvidenceUnavailableReason.integrityFailure }
                return image
            })
        let markers = TimelineMarkerService(storageRoot: root, nativeStoreID: { storeID })
        let media = MarkerAudioMediaService(storageRoot: root, markers: markers, nativeStoreID: { storeID })
        let identity = LiveAudioSampleIdentity(recordingGeneration: UUID(), continuityID: UUID(), startSample: 0,
            sampleCount: 48_000, sampleRate: 16_000, approximateOrigin: preparedAt)
        let bytes = try Data(contentsOf: root.appendingPathComponent(preparedMedia.path))
        let manifest = try await markers.registerAudioManifest(.init(nativeStoreID: storeID, relativePath: preparedMedia.path,
            sha256: CompanionWire.digest(bytes), frameCount: 48_000, sourceRanges: [.init(source: identity, batchStartSample: 0)]))
        let rows = try await queries.getContextBatchEntries(batchAudioPath: preparedMedia.path)
        let request = CompanionJobRequest(sourceStoreID: storeID, observedAt: preparedAt,
            speaker: .init(sourceIdentity: identity, firstPassText: rows.map(\.text).joined(separator: "\n"),
                media: [.init(sha256: manifest.sha256, byteCount: bytes.count,
                    mediaID: CompanionWire.digest(Data(manifest.id.uuidString.lowercased().utf8)), offsetSamples: 0,
                    countSamples: 48_000, sourceStartSample: 0)],
                firstPassReferences: try CompanionTranscriptSnapshot.firstPassReferences(for: rows, nativeStoreID: storeID)))
        let requestData = try CompanionWire.encode(request), jobID = CompanionWire.digest(requestData)
        let requestedSpeaker = try XCTUnwrap(request.speaker)
        let source = try JSONSerialization.jsonObject(with: CompanionWire.encode(identity))
        let result: [String: Any] = ["version": 1, "jobID": jobID, "kind": "speaker", "sourceStoreID": storeID.uuidString,
            "speakerEnrichment": ["sourceIdentity": source, "firstPassSHA256": CompanionWire.digest(Data(requestedSpeaker.firstPassText.utf8)),
                "enhancedText": preparedText, "automaticNamesCalibrated": false, "modelFingerprint": String(repeating: "c", count: 64),
                "turns": [["start": 0.0, "end": 1.4, "text": "Cedar launch review: I will prepare the onboarding checklist.",
                           "speakerID": jobID + ":cluster:1", "speakerLabel": "Speaker 1", "speakerStatus": "unknown"],
                          ["start": 1.4, "end": 3.0, "text": "We agreed to review the draft on Friday before sharing it with the pilot team.",
                           "speakerID": jobID + ":cluster:2", "speakerLabel": "Speaker 2", "speakerStatus": "unknown"]]]]
        let resultData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let companionRoot = root.appendingPathComponent("companion"), spool = CompanionSpool(root: root.appendingPathComponent("companion/delivery"), nativeStoreID: storeID)
        do {
            let descriptor = try spool.acquire(); defer { Darwin.close(descriptor) }
            try spool.initialize()
            try spool.publish(requestData, to: spool.path("requests", jobID))
            try spool.publish(resultData, to: spool.path("results", jobID))
            try spool.publish(Data(CompanionWire.digest(resultData).utf8), to: spool.path("receipts", jobID, suffix: ".imported"))
        }
        let companion = CompanionController(storageRoot: companionRoot, nativeStoreID: storeID,
            databasePath: root.appendingPathComponent("recordings.db").path, adapter: adapter, recall: recall, markers: markers,
            verifiedBytes: { try await media.verifiedBytes(for: $0) }, policy: {})
        _ = try await companion.correctSpeaker(.init(jobID: jobID, speakerID: jobID + ":cluster:1", displayName: "Maya (authored)", expectedRevision: nil))
        // Mirror App ownership: the canonical database notifies the companion,
        // whose speaker/source subscription invalidates the actual Live model.
        // The previous native fixture omitted this production connection.
        try await database.setSourceMutationObserver { companion.sourceChanged($0) }
        let policy = NativeCaptureState(config: .init(), revision: UUID())
        let search = LiveContextSearchService(database: database, audio: queries, adapter: adapter, recall: recall, markers: markers,
            captureState: { policy }, speakerPage: { try await companion.speakerPresentations(from: $0, to: $1, before: $2, limit: $3) },
            speaker: { try await companion.speakerPresentation(jobID: $0) }, contextRanges: try await companion.contextRanges(),
            turn: { try await companion.resolveTurn($0) })
        let turnPlayback = CompanionTurnPlayback(controller: companion, media: media, gate: RetracePlaybackGate(), mutedForTesting: true)
        return Fixture(database: database, queries: queries, audioIDs: [pendingID, preparedID, earlierID] + readingIDs, pendingAt: pendingAt,
            snapshot: snapshot, screenText: screenText, recall: recall, adapter: adapter, markers: markers,
            companion: companion, search: search, turnPlayback: turnPlayback)
    }

    private func render(fixture: Fixture, database: DatabaseManager, root: URL,
                        name: String, width: CGFloat, exportDirectory: URL?) async throws {
        let queries = fixture.queries
        let audioPageSize = LiveContextWorkspaceModel.audioPageSize
        let completedReads = LiveContextNativeReadCounter()
        let resumeGate = LiveContextNativeResumeGate()
        let initialAudioGate = LiveContextNativeResumeGate()
        let coreAudioGate = LiveContextNativeResumeGate(), coreScreenGate = LiveContextNativeResumeGate()
        await initialAudioGate.holdNext()
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            await initialAudioGate.waitIfHeld()
            await coreAudioGate.waitIfHeld()
            let page = try await queries.getContextPage(from: interval.start, to: interval.end,
                limit: audioPageSize, before: cursor, query: query)
            completedReads.record(page.entries.map(\.id))
            return page
        }, loadScreens: { interval in
            await coreScreenGate.waitIfHeld()
            return try await fixture.screenPage(in: interval)
        }, readEntry: { id in await resumeGate.waitIfHeld(); return try await queries.getContextEntry(id: id) },
           loadSpeakers: { interval, cursor in try await fixture.companion.speakerPresentations(from: interval.start, to: interval.end, before: cursor) },
           resolveTurn: { try await fixture.companion.resolveTurn($0) },
           readSpeaker: { try await fixture.companion.speakerPresentation(jobID: $0) }, speakerChanges: { fixture.companion },
           referenceRecordings: { rows in try await fixture.search.transcriptReferences(rows).compactMap {
               if case .transcript(let reference) = $0 { return reference }; return nil
           } })
        let snapshot = fixture.snapshot
        // The same production client supplies image resolution, source identity
        // and bounded OCR expansion. Only image acquisition is authored above;
        // no text callback substitutes the oracle for a private SQLite read.
        let evidence = EvidenceViewModel(client: .live(service: fixture.recall))
        let playbackProbe = LiveContextNativePlaybackProbe()
        let playback = TranscriptAudioPlayback(resolve: { request in
            await playbackProbe.recordAttempt()
            return try await TranscriptAudioFileResolver.resolve(request: request, storageRoot: root)
        }, isMuted: true)
        let companionModel = CompanionWorkspaceModel(service: { fixture.companion }, playbackService: {
            await playbackProbe.recordAttempt(); return fixture.turnPlayback
        })
        let search = LiveContextSearchModel(service: { fixture.search }, rangePresentations: { try await fixture.companion.contextRanges() })
        model.setActive(true)
        let height: CGFloat = 760
        _ = NSApplication.shared
        let visibleFixture = ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_VISIBLE"] == "1"
        let panelOrigin: NSPoint
        if visibleFixture {
            let screen = try XCTUnwrap(NSScreen.main).visibleFrame
            panelOrigin = NSPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
        } else { panelOrigin = NSPoint(x: -20_000, y: -20_000) }
        let panel: NSWindow
        if nativeInputRequested {
            panel = LiveContextNativeInputWindow(
                contentRect: NSRect(origin: panelOrigin, size: NSSize(width: width, height: height)),
                styleMask: [.titled, .closable], backing: .buffered, defer: true)
            panel.title = "Retrace Live \(name) — AUTHORED INPUT VALIDATION"
        } else {
            panel = LiveContextNativeTestPanel(
                contentRect: NSRect(origin: panelOrigin, size: NSSize(width: width, height: height)),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        }
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let navigation = DashboardNavigationState()
        let view = DashboardDestinationView(navigation: navigation, dashboard: {
            LiveContextWorkspaceView(model: model, evidence: evidence, playback: playback,
                isActive: navigation.selectedView == .dashboard, isRecording: false,
                validateScreen: { (try? await database.screenEvidence($0)) != nil },
                openEvidence: { _ in XCTFail("Rendering must not open a live timeline") }, companion: companionModel, search: search,
                openVoiceMarkerSettings: { navigation.openSettings(tab: .audio, scrollTargetID: SettingsView.voiceMarkersTargetID) })
        }, settings: { destination in
            VStack {
                Text("Authored Settings · \(destination.tab?.rawValue ?? "unknown") · \(destination.scrollTargetID ?? "none")")
                Button("Back to Live") { _ = navigation.receive(Notification(name: .toggleSettings)) }
            }
        }, changelog: { Text("Authored changelog") }, monitor: { Text("Authored monitor") })
        let hosting = NSHostingView(rootView: view
            .frame(width: width, height: height)
            .background(Color.retraceBackground)
            .environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hosting
        panel.orderFront(nil)
        defer {
            Task {
                await initialAudioGate.release(); await resumeGate.release()
                await coreAudioGate.release(); await coreScreenGate.release()
            }
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            model.setActive(false)
            evidence.closeEvidence()
            playback.stop(reason: .closed)
            companionModel.hide()
        }
        do {
            // The actual production view mounts with an empty transcript document
            // while its independent screen read is available. Keep audio held
            // longer than all six 16 ms native initial-follow attempts.
            try await waitUntil { model.presentationReady && !model.screens.isEmpty && model.transcripts.isEmpty }
            let entered = await initialAudioGate.waitUntilEntered()
            XCTAssertTrue(entered)
            try await Task.sleep(for: .milliseconds(180))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertTrue(model.transcriptItems.isEmpty)
            XCTAssertTrue(model.followingLive)
            await initialAudioGate.release()
        } catch {
            await initialAudioGate.release()
            throw error
        }
        try await waitUntil {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return model.transcripts.map(\.id) == fixture.audioIDs && model.transcriptItems.compactMap(\.turn).count == 2 &&
                evidence.evidenceReference == .screen(snapshot.ref) && !evidence.resolvingEvidence
        }
        // Let native layout publish the final resolved-image and transcript accessibility state.
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let transcriptObserver = try XCTUnwrap(Self.nativeDescendants(hosting).compactMap {
            $0 as? LiveContextScrollInteractionObserver.ObserverView
        }.first)
        let transcriptScroll = try XCTUnwrap(NativeLiveTranscriptGeometry.scroll(in: hosting,
            observer: transcriptObserver, expectedIDs: model.transcriptItems.map(\.id)))
        let renderedRows = try XCTUnwrap(NativeLiveTranscriptGeometry.rows(in: transcriptScroll,
            expectedIDs: model.transcriptItems.map(\.id)))
        XCTAssertFalse(renderedRows.isEmpty)
        XCTAssertLessThanOrEqual(renderedRows.count, model.transcriptItems.count)
        XCTAssertTrue(NativeLiveTranscriptGeometry.isAtNewestEnd(transcriptScroll, tolerance: 1),
            "\(name) delayed initial audio must still reveal its newest end after the screen-only state outlives the native follow retry budget")
        if visibleFixture {
            XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) })
        } else { XCTAssertLessThan(panel.frame.maxX, 0, "The panel must remain off the shared desktop") }
        if !nativeInputRequested {
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(panel.isMainWindow)
        }
        XCTAssertNil(playback.player, "Opening and rendering Live must not start playback")
        XCTAssertEqual(playback.state.phase, .idle)
        let attempts = await playbackProbe.attempts
        XCTAssertEqual(attempts, 0, "Rendering must not even prepare a player")
        let turnState = await fixture.turnPlayback.snapshot()
        XCTAssertFalse(turnState.isPlaying)
        XCTAssertNil(turnState.reference)

        // Exercise the Text pane's actual model/selection boundary before the
        // external AX probe. This fails if the client forgets its expand reader,
        // returns another extraction, or loses the selected source proof.
        let text = EvidenceTextViewModel { try await evidence.expandText($0) }
        await text.open(snapshot.ref)
        XCTAssertNil(text.error)
        let textPage = try XCTUnwrap(text.page, "The Text pane must read the persisted authored OCR")
        XCTAssertEqual(textPage.reference, snapshot.ref)
        XCTAssertEqual(textPage.captureTimestamp, snapshot.frame.timestamp)
        XCTAssertEqual(textPage.provenance.origin, .ocr)
        XCTAssertTrue(textPage.fragments.allSatisfy { $0.id.reference == snapshot.ref })
        let actualScreenText = textPage.fragments.map(\.text).joined(separator: "\n")
        XCTAssertEqual(actualScreenText, fixture.screenText)
        XCTAssertNil(textPage.nextCursor)
        text.cancel()

        if nativeInputRequested {
            try await observeNativeInput(panel: panel, hosting: hosting, model: model,
                completedReads: completedReads, queries: queries, name: name, exportDirectory: exportDirectory)
            let finalAttempts = await playbackProbe.attempts
            XCTAssertEqual(finalAttempts, 0, "Keyboard/scroll interaction must not prepare playback")
            XCTAssertNil(playback.player)
            let finalTurnState = await fixture.turnPlayback.snapshot()
            XCTAssertFalse(finalTurnState.isPlaying)
            XCTAssertNil(finalTurnState.reference)
        } else if visibleFixture, ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_AX_PROBE"] == "1" {
            print("Native Live AX probe ready: \(name), PID \(ProcessInfo.processInfo.processIdentifier), 30 seconds")
            try await Task.sleep(for: .seconds(30))
        }

        let requiredLabels = ["Copy context", "Recording paused", "Voice markers settings", "Transcript", "Audio is saved", "Cedar launch review", "Maya (authored)", "Speaker 2",
            width >= 900 ? "Screen context" : "Screen"]
        var elements = Self.accessibleElements(in: hosting)
        var labels = elements.map(Self.accessibleText).filter { !$0.isEmpty }
        let accessibilityDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !requiredLabels.allSatisfy({ expected in labels.contains { $0.contains(expected) } }),
              ContinuousClock.now < accessibilityDeadline {
            try await Task.sleep(for: .milliseconds(20))
            hosting.layoutSubtreeIfNeeded()
            elements = Self.accessibleElements(in: hosting)
            labels = elements.map(Self.accessibleText).filter { !$0.isEmpty }
        }
        for expected in requiredLabels {
            XCTAssertTrue(labels.contains { $0.contains(expected) }, "\(name) native AX omitted: \(expected)")
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000, "The native workspace must render more than an empty surface")
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, Int(width))
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, Int(height))
        if let exportDirectory {
            try png.write(to: exportDirectory.appendingPathComponent("live-context-\(name).png"), options: .atomic)
            let diagnostics = elements.map { element in
                let role = Self.modernAttribute("accessibilityRole", of: element)
                    ?? element.accessibilityAttributeValue(.role)
                return "\(type(of: element)) role=\(String(describing: role)) text=\(Self.accessibleText(element))"
            }
            let receipt = "Authored private SQLite/AAC fixture; actual LiveContextWorkspaceView\nViewport: \(Int(width)) × \(Int(height))\nVisible fixture: \(visibleFixture)\nNative input opt-in: \(nativeInputRequested)\nPlayback preparations: \(attempts)\nNative AX labels:\n" + labels.joined(separator: "\n")
                + "\n\nNative AX tree:\n" + diagnostics.joined(separator: "\n")
            try receipt.write(to: exportDirectory.appendingPathComponent("live-context-\(name).txt"),
                atomically: true, encoding: .utf8)
            let textReceipt = "Actual EvidenceTextViewModel → EvidenceViewModel → ProgressiveRecallService → private SQLite\n"
                + "Frame: \(textPage.reference.frameID.value), extraction revision: \(textPage.reference.extractionRevision)\n"
                + "Origin: \(textPage.provenance.origin.rawValue)\n\n" + actualScreenText
            try textReceipt.write(to: exportDirectory.appendingPathComponent("live-context-\(name)-ocr.txt"),
                atomically: true, encoding: .utf8)
        }
        try await verifySubmittedSearchSurvivesHeldCore(panel: panel, hosting: hosting, model: model, search: search,
            audioGate: coreAudioGate, screenGate: coreScreenGate)
        try await verifySettingsRoundTrip(hosting: hosting, model: model, navigation: navigation,
            resumeGate: resumeGate, viewport: name)
    }

    private func verifySubmittedSearchSurvivesHeldCore(panel: NSWindow, hosting: NSView,
                                                      model: LiveContextWorkspaceModel, search: LiveContextSearchModel,
                                                      audioGate: LiveContextNativeResumeGate,
                                                      screenGate: LiveContextNativeResumeGate) async throws {
        let field = try XCTUnwrap(Self.nativeDescendants(hosting).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search recorded context"
        }, "The actual Live search must expose its native text field")
        func status() -> String {
            let editorEmpty = (field.currentEditor() as? NSTextView).map { $0.string.isEmpty.description } ?? "no-editor"
            return "ready=\(model.presentationReady), coreLoading=\(model.isLoading), searching=\(search.isSearching), queryIsCedar=\(search.query == "Cedar"), results=\(search.items.count), searchLoading=\(search.isLoading), fieldEmpty=\(field.stringValue.isEmpty), editorEmpty=\(editorEmpty), requestRevision=\(model.requestRevision), transcriptRevision=\(model.transcriptRevision)"
        }
        func submit(_ value: String) throws {
            // Native field-editor editing and Return exercise SwiftUI's actual
            // binding/onSubmit route without clipboard access or direct calls
            // to the view's private applyScope implementation.
            XCTAssertTrue(panel.makeFirstResponder(field))
            field.selectText(nil)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(value, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            print("Native Live search: submitted \(value.isEmpty ? "clear" : "authored query"); \(status())")
        }
        await audioGate.holdNext(); await screenGate.holdNext()
        do {
            try submit("Cedar")
            let audioEntered = await audioGate.waitUntilEntered(), screenEntered = await screenGate.waitUntilEntered()
            print("Native Live search: held-core entry audio=\(audioEntered), screens=\(screenEntered); \(status())")
            XCTAssertTrue(audioEntered && screenEntered, "A valid native submission must start the replacement core refresh")
            // Let the readiness=false onChange run while neither core reader
            // can immediately make the workspace ready again.
            try await Task.sleep(for: .milliseconds(120))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertFalse(model.presentationReady)
            XCTAssertEqual(search.query, "Cedar", "The readiness transition must not erase the search just submitted by this native field")
            await search.finishPendingRead()
            print("Native Live search: query reader joined; \(status())")
            XCTAssertTrue(search.items.contains { $0.kind == "Transcripts" && $0.text.contains("Cedar") },
                "The preserved query must execute against the real private SQLite service")
            await audioGate.release(); await screenGate.release()
        } catch {
            await audioGate.release(); await screenGate.release()
            throw error
        }
        await model.refresh()
        try await waitUntil("search ready after releasing core", diagnostics: status) { model.presentationReady }
        XCTAssertEqual(search.query, "Cedar")
        // This regression covers the held readiness transition. Exit through
        // the actual results-pane action instead of reusing an editor captured
        // before SwiftUI replaced the transcript with interval results.
        try pressAccessibleButton("Return to live", in: hosting)
        try await waitUntil("search Return to live clears results", diagnostics: status) {
            !search.isSearching && model.presentationReady && model.followingLive
        }
        await model.refresh()
    }

    private func observeNativeInput(panel: NSWindow, hosting: NSView,
                                    model: LiveContextWorkspaceModel,
                                    completedReads: LiveContextNativeReadCounter,
                                    queries: AudioTranscriptionQueries,
                                    name: String, exportDirectory: URL?,
                                    pendingArrival: (path: String, size: Int64)? = nil) async throws {
        // The model was preloaded before the production view mounted. Do not
        // repair following or scroll position here: native readiness must prove
        // that opening the populated view already shows its newest end.
        let originalIDs = model.transcripts.map(\.id)
        XCTAssertTrue(model.followingLive)
        let probe = LiveContextNativeInteractionProbe(window: panel, root: hosting,
            model: model, completedReads: completedReads, queries: queries, viewport: name, pendingArrival: pendingArrival)
        defer { probe.stop() }
        let finished = expectation(description: "Native Live \(name) input interval elapsed")
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0))
        let loop = NativeAppKitObservationLoop(wake: wake, activate: {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeMain()
        }, verifyReadiness: {
            XCTAssertTrue(NSApp.isActive)
            XCTAssertTrue(panel.isKeyWindow)
            XCTAssertTrue(panel.isMainWindow)
            probe.start()
            let focusTarget = pendingArrival == nil ? "selectable transcript text" : "the pending message Audio is saved. Transcript text is not ready. (no completed transcript exists)"
            print("Native Live input ready: \(name), PID \(ProcessInfo.processInfo.processIdentifier), 90 seconds. Click \(focusTarget) to give it keyboard focus, then press Page Down or End. A new fictional transcript will then arrive privately; wait for the stable-history receipt before clicking Return to live. Wait for the new-arrival-visible receipt, then scroll downward over the transcript with a real wheel gesture and click Return to live again. Use only these controls; do not open Voice markers settings or playback.")
        }, finished: { finished.fulfill() })
        loop.schedule()
        await fulfillment(of: [finished], timeout: 100)
        loop.invalidateTimers()
        probe.stop()
        await probe.finishArrival()
        XCTAssertTrue(loop.checkedReadiness)
        XCTAssertTrue(loop.deadlineReached)
        XCTAssertTrue(loop.returnedFromRun)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(probe.hasScrollableTranscript)
        XCTAssertTrue(probe.initiallyAtNewestEnd, "A populated following Live view must open at its newest end before any reading input")
        XCTAssertGreaterThan(probe.readingKeyEvents, 0, "Deliver a real reading key to the actual transcript scroll view")
        XCTAssertGreaterThan(probe.wheelEvents, 0, "Deliver a real wheel gesture over the actual transcript scroll view")
        XCTAssertTrue(probe.keyboardScrolledAndPinned, "A native reading key must move the document and stop following")
        XCTAssertTrue(probe.wheelScrolledAndPinned, "A native wheel gesture must move the document and stop following")
        XCTAssertTrue(probe.stableAcrossRefresh, "Pinned native position and original transcript IDs must survive nine seconds while a real SQLite refresh reads the newly inserted row")
        XCTAssertNotNil(probe.arrivalID)
        XCTAssertTrue(probe.arrivalObservedWhilePinned)
        XCTAssertTrue(probe.arrivalPresentedAtNewestEnd)
        XCTAssertFalse(probe.historyChangedWhilePinned)
        XCTAssertFalse(probe.sequenceViolation)
        XCTAssertGreaterThanOrEqual(probe.returnTransitions, 2, "Use the real Return to live action after both reading interactions")
        XCTAssertTrue(probe.returnedAfterStableHistory)
        XCTAssertTrue(probe.returnedToBottom, "Return to live must move the real viewport back to its newest end")
        XCTAssertTrue(model.followingLive)
        let receipt = probe.receipt
        print(receipt)
        if let pendingArrival {
            let arrivalID = try XCTUnwrap(probe.arrivalID)
            let stored = try await queries.getContextEntry(id: arrivalID)
            let arrival = try XCTUnwrap(stored, "The additional pending arrival must remain saved before explicit fixture cleanup")
            XCTAssertEqual(arrival.transcriptStatus, "pending")
            XCTAssertTrue(arrival.text.isEmpty)
            XCTAssertEqual(arrival.source, .microphone)
            XCTAssertEqual(arrival.audioPath, pendingArrival.path)
        }
        // Each viewport has its own arrival. Join its one write, remove only that
        // authored row, and restore the original page before the next viewport.
        // Observation has stopped, so cleanup cannot satisfy interaction checks.
        try await probe.removeArrival()
        model.returnToLive()
        await model.refresh()
        XCTAssertEqual(model.transcripts.map(\.id), originalIDs)
        if let exportDirectory {
            try receipt.write(to: exportDirectory.appendingPathComponent("live-context-\(name)-input.txt"),
                atomically: true, encoding: .utf8)
        }
    }

    private func verifySettingsRoundTrip(hosting: NSView, model: LiveContextWorkspaceModel,
                                        navigation: DashboardNavigationState,
                                        resumeGate: LiveContextNativeResumeGate, viewport: String) async throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let observer = try XCTUnwrap(descendants(hosting).compactMap { $0 as? LiveContextScrollInteractionObserver.ObserverView }.first)
        let scroll = try XCTUnwrap(NativeLiveTranscriptGeometry.scroll(in: hosting,
            observer: observer, expectedIDs: model.transcriptItems.map(\.id)))
        let originalDocument = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(originalDocument.bounds.height, scroll.contentView.bounds.height)
        model.pauseFollowing()
        let renderedRows = try XCTUnwrap(NativeLiveTranscriptGeometry.rows(in: scroll,
            expectedIDs: model.transcriptItems.map(\.id)))
        let midpoint = renderedRows[renderedRows.count / 2]
        let midpointY = originalDocument.isFlipped ? midpoint.frame.minY : midpoint.frame.maxY - scroll.contentView.bounds.height
        originalDocument.scroll(NSPoint(x: 0, y: max(0, min(midpointY, originalDocument.bounds.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(60))
        hosting.layoutSubtreeIfNeeded()
        let origin = scroll.contentView.bounds.origin
        let ids = model.transcriptItems.map(\.id), interval = model.interval
        XCTAssertGreaterThan(origin.y, 0, "The round trip must start at a nontrivial pinned reading position")
        try pressAccessibleButton("Voice markers settings", in: hosting)
        try await waitUntil("Voice markers Settings hides Live") { navigation.selectedView == .settings && !model.presentationReady }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(navigation.settingsDestination.tab, .audio)
        XCTAssertEqual(navigation.settingsDestination.scrollTargetID, SettingsView.voiceMarkersTargetID)
        XCTAssertTrue(descendants(hosting).contains { $0 === scroll }, "\(viewport) Settings must retain the actual transcript scroll view")
        XCTAssertTrue(scroll.documentView === originalDocument, "Settings must retain the actual transcript document")
        try await externalAXCheckpoint("Settings hidden", hosting: hosting, model: model, viewport: viewport)
        logInternalAXDiagnostic("Settings hidden", hosting: hosting, viewport: viewport)

        await resumeGate.holdNext()
        do {
            try pressAccessibleButton("Back to Live", in: hosting)
            let entered = await resumeGate.waitUntilEntered()
            XCTAssertTrue(entered, "Returning must reach canonical retained-row validation")
            hosting.layoutSubtreeIfNeeded()
            XCTAssertFalse(model.presentationReady)
            try await externalAXCheckpoint("canonical resume held", hosting: hosting, model: model, viewport: viewport)
            logInternalAXDiagnostic("canonical resume held", hosting: hosting, viewport: viewport)
            await resumeGate.release()
        } catch {
            await resumeGate.release()
            throw error
        }
        try await waitUntil("Back reveals canonically validated Live") { model.presentationReady && navigation.selectedView == .dashboard }
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(hosting).contains { $0 === scroll }, "\(viewport) Back must reuse the same NSScrollView")
        XCTAssertTrue(scroll.documentView === originalDocument, "Back must reuse the same native transcript document")
        XCTAssertEqual(model.transcriptItems.map(\.id), ids)
        XCTAssertEqual(model.interval, interval)
        XCTAssertFalse(model.followingLive)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y, accuracy: 1,
            "\(viewport) pinned native reading position must survive Settings and canonical revalidation")
        if descendants(hosting).contains(where: { $0 === scroll }), scroll.documentView === originalDocument,
           model.transcriptItems.map(\.id) == ids,
           model.interval == interval, !model.followingLive,
           abs(scroll.contentView.bounds.origin.y - origin.y) <= 1 {
            print("Native Live \(viewport) Settings round trip: scroll view, document, pinned viewport and canonical-resume assertions passed. Hidden accessibility acceptance requires the separate external AX checkpoint receipts.")
        }

        // Invalid user input is recoverable navigation, not permission to expose
        // retained evidence and not a reason to disable the entire workspace.
        let date = Date()
        model.configure(range: .custom, from: date, to: date.addingTimeInterval(-10), query: "")
        await model.refresh()
        try await Task.sleep(for: .milliseconds(40))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertNotNil(model.audioError)
        let publicLabels = Self.accessibleElements(in: hosting, includingNativeSubviews: false).map(Self.accessibleText)
        XCTAssertTrue(publicLabels.contains { $0.contains("Time range") || $0.contains("Search recorded context") },
            "An invalid interval must leave its editing controls available")
        try pressAccessibleButton("Voice markers settings", in: hosting)
        try await waitUntil("invalid interval allows Settings navigation") { navigation.selectedView == .settings }
        model.configure(range: .recent, from: date.addingTimeInterval(-1_800), to: date, query: "")
    }

    private func logInternalAXDiagnostic(_ phase: String, hosting: NSView, viewport: String) {
        // Directly asking retained SwiftUI nodes for all child arrays includes
        // ignored implementation nodes. It is not the OS's external AX tree.
        let containsAuthoredText = Self.accessibleElements(in: hosting, includingNativeSubviews: false)
            .map(Self.accessibleText).contains { $0.contains("Cedar launch review") }
        print("Native Live \(viewport) \(phase): raw internal AX walk contains retained authored text=\(containsAuthoredText); diagnostic only, not external AX acceptance")
    }

    private func externalAXCheckpoint(_ phase: String, hosting: NSView,
                                      model: LiveContextWorkspaceModel, viewport: String) async throws {
        guard nativeInputRequested else { return }
        let panel = try XCTUnwrap(hosting.window)
        XCTAssertFalse(model.presentationReady)
        let finished = expectation(description: "Native Live \(viewport) \(phase) external AX checkpoint")
        let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0))
        let loop = NativeAppKitObservationLoop(wake: wake, activate: {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }, verifyReadiness: {
            XCTAssertFalse(model.presentationReady)
            print("Native Live external AX checkpoint: \(viewport), \(phase), PID \(ProcessInfo.processInfo.processIdentifier), 20 seconds. Inspect the external accessibility tree and screenshot; no retained Cedar transcript may appear. Do not click or type. No external acceptance is inferred by this fixture.")
        }, finished: { finished.fulfill() }, duration: 20)
        loop.schedule()
        await fulfillment(of: [finished], timeout: 30)
        loop.invalidateTimers()
        XCTAssertTrue(loop.checkedReadiness)
        XCTAssertTrue(loop.deadlineReached)
        XCTAssertTrue(loop.returnedFromRun)
        XCTAssertFalse(model.presentationReady)
    }

    private func pressAccessibleButton(_ label: String, in root: NSView) throws {
        let action = try accessiblePressAction(label, in: root)
        let handled = action()
        XCTAssertTrue(handled, "The native accessibility action must be handled: \(label)")
        guard handled else { throw NSError(domain: "LiveContextNativePressUnhandled", code: 1) }
    }

    private func accessiblePressAction(_ label: String, in root: NSView) throws -> () -> Bool {
        let element = try XCTUnwrap(Self.accessibleButton(label, in: root),
            "The actual native button must exist: \(label)")
        return try accessiblePressAction(element, label: label)
    }

    private func accessiblePressAction(_ element: NSObject, label: String) throws -> () -> Bool {
        // SwiftUI virtual nodes implement this documented selector without
        // declaring protocol conformance. NSObject.perform assumes an object
        // return and is invalid for BOOL; validate the runtime ABI first.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: selector), "The native button must support accessibilityPerformPress: \(label)")
        guard element.responds(to: selector) else {
            throw NSError(domain: "LiveContextNativePressUnsupported", code: 1)
        }
        let runtimeClass = try XCTUnwrap(object_getClass(element))
        let method = try XCTUnwrap(class_getInstanceMethod(runtimeClass, selector))
        XCTAssertEqual(method_getNumberOfArguments(method), 2, "The documented press action takes only self and selector")
        guard method_getNumberOfArguments(method) == 2 else {
            throw NSError(domain: "LiveContextNativePressUnsupportedABI", code: 1)
        }
        let selfType = try XCTUnwrap(method_copyArgumentType(method, 0))
        defer { free(selfType) }
        let selectorType = try XCTUnwrap(method_copyArgumentType(method, 1))
        defer { free(selectorType) }
        guard String(cString: selfType) == "@", String(cString: selectorType) == ":" else {
            XCTFail("The documented press action must have object and selector arguments: \(label)")
            throw NSError(domain: "LiveContextNativePressUnsupportedABI", code: 3)
        }
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        let implementation = method_getImplementation(method)
        switch String(cString: returnType) {
        case "B":
            let invoke = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return { invoke(element, selector) }
        case "c":
            let invoke = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Int8).self)
            return { invoke(element, selector) != 0 }
        default:
            XCTFail("The documented press action must have a supported BOOL return encoding: \(label)")
            throw NSError(domain: "LiveContextNativePressUnsupportedABI", code: 2)
        }
    }

    /// Search shallow controls before a transcript's large native subtree can
    /// exhaust the bounded walk. Only a real AXButton with the requested full
    /// accessible label is eligible; action dispatch still validates its ABI.
    private static func accessibleButton(_ label: String, in root: NSObject) -> NSObject? {
        var queue: [(NSObject, Int)] = [(root, 0)], head = 0
        var visited = Set<ObjectIdentifier>(), depthLimited = false
        var buttonDiagnostics: [String] = []
        while head < queue.count, visited.count < 2_000 {
            let (element, depth) = queue[head]; head += 1
            guard depth < 40 else { depthLimited = true; continue }
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let role = modernAttribute("accessibilityRole", of: element) ?? element.accessibilityAttributeValue(.role)
            let roleText = String(describing: role)
            if roleText.contains("AXButton") {
                let text = accessibleText(element)
                if text.contains(label) { return element }
                if buttonDiagnostics.count < 32 { buttonDiagnostics.append("\(roleText): \(text.prefix(180))") }
            }
            var children: [NSObject] = []
            for accessor in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityVisibleChildren"] {
                children += modernAttribute(accessor, of: element) as? [NSObject] ?? []
            }
            children += element.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            queue.append(contentsOf: children.map { ($0, depth + 1) })
            if let view = element as? NSView { queue.append(contentsOf: view.subviews.map { ($0, depth + 1) }) }
        }
        print("Native Live button lookup failed: requested=\(label), visited=\(visited.count), pending=\(queue.count - head), nodeLimit=\(head < queue.count), depthLimit=\(depthLimited), actual authored button labels=\(buttonDiagnostics)")
        return nil
    }

    /// Each copied file represents a separate authored capture. Reusing one
    /// audio path makes a later insert a mutation of every retained batch row.
    private func copyAuthoredRecording(_ media: (path: String, size: Int64), root: URL) throws -> (path: String, size: Int64) {
        let path = "audio/authored-capture-\(UUID().uuidString.lowercased()).m4a"
        try FileManager.default.copyItem(at: root.appendingPathComponent(media.path), to: root.appendingPathComponent(path))
        return (path, media.size)
    }

    private func makeRecording(root: URL, timestamp: Date) async throws -> (path: String, size: Int64) {
        if let fixturePath = ProcessInfo.processInfo.environment["RETRACE_AUDIO_VISIBILITY_FIXTURE_AAC"] {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard digest == "12d984dc71bad6e5bacab2f8fceb4423911a46e7ae5a23c9c1c41c349f8830dd" else {
                throw NSError(domain: "LiveContextAuthoredAACHashMismatch", code: 1)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
            let path = "audio/batch_\(Int64(timestamp.timeIntervalSince1970 * 1_000))_microphone_authored.m4a"
            try bytes.write(to: root.appendingPathComponent(path))
            return (path, Int64(bytes.count))
        }
        let samples = (0..<48_000).map { Int16(sin(Double($0) * 2 * .pi * 440 / 16_000) * 4_000) }
        let result = try await AudioSegmentWriter(storageRoot: root).writeFullBatch(
            audioData: samples.withUnsafeBytes { Data($0) }, timestamp: timestamp, source: .microphone)
        return (result.filePath, result.fileSize)
    }

    private func authoredImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_280, height: 800,
            bitsPerComponent: 8, bytesPerRow: 1_280 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1_280, height: 800))
        context.setFillColor(CGColor(red: 0.16, green: 0.30, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 736, width: 1_280, height: 64))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let lines: [(String, CGFloat, NSFont, NSColor)] = [
            ("CEDAR NOTES · AUTHORED TEST FIXTURE", 755, .systemFont(ofSize: 19, weight: .semibold), .white),
            ("Cedar launch checklist", 645, .systemFont(ofSize: 40, weight: .semibold), .darkGray),
            ("Prepare the onboarding draft", 535, .systemFont(ofSize: 28), .darkGray),
            ("Review with Maya on Friday", 455, .systemFont(ofSize: 28), .darkGray),
            ("Share with the pilot team after review", 375, .systemFont(ofSize: 28), .darkGray),
            ("Fictional content for native workspace validation", 70, .systemFont(ofSize: 20), .gray)
        ]
        for (text, y, font, color) in lines {
            (text as NSString).draw(at: NSPoint(x: 64, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func renderDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_LIVE_CONTEXT_RENDER_DIR"] else { return nil }
        let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let output = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard path.hasPrefix("/"), output.path.hasPrefix(temporary.path + "/") else {
            throw NSError(domain: "LiveContextRenderDirectoryMustBeBelowTmp", code: 1)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        return output
    }

    private func waitUntil(_ boundary: String = "authored evidence rendered",
                           diagnostics: @MainActor () -> String = { "" },
                           file: StaticString = #filePath, line: UInt = #line,
                           _ predicate: @MainActor () -> Bool) async throws {
        print("Native Live waiting: \(boundary)")
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else {
            let detail = diagnostics()
            print("Native Live timeout: \(boundary); \(detail)")
            XCTFail("Native workspace timed out at \(boundary); \(detail)", file: file, line: line)
            throw NSError(domain: "LiveContextNativeRenderTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey: boundary])
        }
        print("Native Live completed: \(boundary); \(diagnostics())")
    }

    fileprivate static func accessibleElements(in root: NSObject, includingNativeSubviews: Bool = true) -> [NSObject] {
        var result: [NSObject] = []
        var remaining = [(root, 0)]
        var visited = Set<ObjectIdentifier>()
        while let (element, depth) = remaining.popLast(), visited.count < 2_000 {
            guard depth < 40, visited.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            // SwiftUI virtual AX elements may expose modern accessors without
            // declaring NSAccessibility conformance or populating the legacy
            // attribute bridge. Read both real interfaces; never infer labels
            // from the fixture strings or a rendered screenshot.
            var children = element.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            for accessor in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder", "accessibilityVisibleChildren"] {
                children += modernAttribute(accessor, of: element) as? [NSObject] ?? []
            }
            remaining.append(contentsOf: children.map { ($0, depth + 1) })
            if includingNativeSubviews, let view = element as? NSView { remaining.append(contentsOf: view.subviews.map { ($0, depth + 1) }) }
        }
        return result
    }

    private static func nativeDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(nativeDescendants)
    }

    fileprivate static func accessibleText(_ element: NSObject) -> String {
        let modern = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue", "accessibilityValueDescription"]
            .compactMap { modernAttribute($0, of: element) }
        let legacy = [NSAccessibility.Attribute.title, .description, .value]
            .compactMap { element.accessibilityAttributeValue($0) }
        return (modern + legacy).compactMap { value -> String? in
            if let text = value as? String { return text }
            if let text = value as? NSAttributedString { return text.string }
            return nil
        }.joined(separator: " ")
    }

    /// These SDK-declared accessibility getters return objects. Dynamic dispatch
    /// also reaches SwiftUI AX nodes that do not declare protocol conformance.
    private static func modernAttribute(_ name: String, of element: NSObject) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }
}

private final class LiveContextNativeTestPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class LiveContextNativeInputWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private actor LiveContextNativeResumeGate {
    private var held = false, entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func holdNext() { held = true; entered = false }
    func waitIfHeld() async {
        guard held else { return }
        held = false; entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered, ContinuousClock.now < deadline { await Task.yield() }
        return entered
    }
    func release() { held = false; waiter?.resume(); waiter = nil }
}

/// Counts completed private SQLite page reads without changing their scheduling.
private final class LiveContextNativeReadCounter: @unchecked Sendable {
    struct Snapshot {
        let count: Int
        let rows: [Int64]
    }
    private let lock = NSLock()
    private var value = 0
    private var rows: [Int64] = []
    func record(_ rows: [Int64]) {
        lock.lock(); defer { lock.unlock() }; value += 1; self.rows = rows
    }
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }; return Snapshot(count: value, rows: rows)
    }
}

/// Reads the actual eager transcript document. Identity is attached to each
/// rendered production row; neither ordinal table positions nor text estimates
/// substitute for the source-qualified model IDs.
@MainActor
private enum NativeLiveTranscriptGeometry {
    struct Row {
        let id: String
        let frame: NSRect
    }
    struct Anchor {
        let itemID: String
        let offsetY: CGFloat
        let frame: NSRect
    }

    static func scroll(in root: NSView, observer: NSView, expectedIDs: [String]) -> NSScrollView? {
        var pending = [root], visited = 0
        while let view = pending.popLast(), visited < 20_000 {
            visited += 1
            if let candidate = view as? NSScrollView {
                let rect = observer.convert(candidate.bounds, from: candidate)
                if !rect.isEmpty, observer.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                   rows(in: candidate, expectedIDs: expectedIDs) != nil { return candidate }
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func rows(in scroll: NSScrollView, expectedIDs: [String]) -> [Row]? {
        guard !expectedIDs.isEmpty, Set(expectedIDs).count == expectedIDs.count,
              let found = renderedRows(in: scroll) else { return nil }
        let positions = Dictionary(uniqueKeysWithValues: expectedIDs.enumerated().map { ($1, $0) })
        let indices = found.compactMap { positions[$0.id] }
        guard indices.count == found.count, indices == indices.sorted() else { return nil }
        return found
    }

    /// Enumerate every attached marker, including any accidentally retained
    /// offscreen page; do not filter to the expected IDs before checking bounds.
    static func renderedRows(in scroll: NSScrollView) -> [Row]? {
        guard let document = scroll.documentView else { return nil }
        var pending = [document], visited = 0, found: [Row] = []
        while let view = pending.popLast(), visited < 20_000 {
            visited += 1
            if let marker = view as? LiveContextTranscriptRowIdentity.MarkerView,
               marker.enclosingScrollView === scroll {
                let frame = document.convert(marker.bounds, from: marker)
                guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return nil }
                guard !marker.isHiddenOrHasHiddenAncestor, frame.width > 0, frame.height > 0 else { continue }
                found.append(.init(id: marker.rowID, frame: frame))
            }
            pending.append(contentsOf: view.subviews)
        }
        guard pending.isEmpty, !found.isEmpty,
              Set(found.map(\.id)).count == found.count else { return nil }
        found.sort { document.isFlipped ? $0.frame.minY < $1.frame.minY : $0.frame.maxY > $1.frame.maxY }
        return found
    }

    static func anchor(in scroll: NSScrollView, expectedIDs: [String]) -> Anchor? {
        guard let document = scroll.documentView, let rendered = rows(in: scroll, expectedIDs: expectedIDs),
              let top = rendered.first(where: { $0.frame.intersects(scroll.documentVisibleRect) }) else { return nil }
        let visible = scroll.documentVisibleRect
        let offset = document.isFlipped ? top.frame.minY - visible.minY : visible.maxY - top.frame.maxY
        guard offset.isFinite else { return nil }
        return .init(itemID: top.id, offsetY: offset, frame: top.frame)
    }

    static func isAtNewestEnd(_ scroll: NSScrollView, tolerance: CGFloat) -> Bool {
        guard let document = scroll.documentView else { return false }
        return document.isFlipped
            ? scroll.documentVisibleRect.minY <= document.bounds.minY + tolerance
            : scroll.documentVisibleRect.maxY >= document.bounds.maxY - tolerance
    }
}

/// Passive observations only: no event is consumed, synthesized, or redirected.
/// Geometry is relative to the real native clip view, never a fixed row height.
@MainActor
private final class LiveContextNativeInteractionProbe: NSObject {
    private enum Phase {
        case keyboard, settlingKeyboard, awaitingArrival, pinnedHistory, firstReturn,
             arrivalPresentation, wheel, finalReturn, finalPresentation, complete, failed
    }
    private struct PendingInteraction {
        let origin: NSPoint
        let time: ContinuousClock.Instant
    }
    private typealias ReadingAnchor = NativeLiveTranscriptGeometry.Anchor
    private struct StablePosition {
        let origin: NSPoint
        let rows: [Int64]
        let since: ContinuousClock.Instant
        let reads: Int
        let documentBounds: NSRect
        let clipBounds: NSRect
        let visibleRect: NSRect
        let itemIDs: [String]
        let anchor: ReadingAnchor?
        let transcriptRevision: UInt64
        let requestRevision: UInt64
        let sourceInvalidationRevision: UInt64
    }
    private let window: NSWindow
    private let root: NSView
    private let model: LiveContextWorkspaceModel
    private let completedReads: LiveContextNativeReadCounter
    private let queries: AudioTranscriptionQueries
    private let viewport: String
    private let pendingArrival: (path: String, size: Int64)?
    // This input flow pins the newest presentation page and never invokes Earlier/Later.
    private var displayedIDs: [String] { model.transcriptItems.map(\.id) }
    private weak var scroll: NSScrollView?
    private var monitor: Any?
    private var timer: Timer?
    private var lastFollowing = true
    private var lastOrigin = NSPoint.zero
    private var pendingKey: PendingInteraction?
    private var pendingWheel: PendingInteraction?
    private var stable: StablePosition?
    private var phase: Phase = .keyboard
    private var pinnedRows: [Int64] = []
    private var arrivalTask: Task<Void, Never>?
    private(set) var hasScrollableTranscript = false
    private(set) var initiallyAtNewestEnd = false
    private(set) var readingKeyEvents = 0
    private(set) var wheelEvents = 0
    private(set) var keyboardScrolledAndPinned = false
    private(set) var wheelScrolledAndPinned = false
    private(set) var stableAcrossRefresh = false
    private(set) var stableRefreshCount = 0
    private(set) var returnTransitions = 0
    private(set) var returnedAfterStableHistory = false
    private(set) var returnedToBottom = false
    private(set) var arrivalID: Int64?
    private(set) var arrivalObservedWhilePinned = false
    private(set) var arrivalPresentedAtNewestEnd = false
    private(set) var historyChangedWhilePinned = false
    private(set) var sequenceViolation = false
    private var firstFailureDiagnostic: String?

    init(window: NSWindow, root: NSView, model: LiveContextWorkspaceModel,
         completedReads: LiveContextNativeReadCounter, queries: AudioTranscriptionQueries, viewport: String,
         pendingArrival: (path: String, size: Int64)? = nil) {
        self.window = window; self.root = root; self.model = model
        self.completedReads = completedReads; self.queries = queries; self.viewport = viewport
        self.pendingArrival = pendingArrival
    }

    func start() {
        root.layoutSubtreeIfNeeded()
        let views = Self.descendants(root)
        guard let observer = views.compactMap({ $0 as? LiveContextScrollInteractionObserver.ObserverView }).first,
              let scroll = NativeLiveTranscriptGeometry.scroll(in: root, observer: observer,
                  expectedIDs: displayedIDs), let document = scroll.documentView,
              document.bounds.height > scroll.contentView.bounds.height else {
            XCTFail("The authored transcript must expose its overflowing native scroll view and rendered row identities")
            return
        }
        self.scroll = scroll
        hasScrollableTranscript = true
        lastFollowing = model.followingLive
        lastOrigin = scroll.contentView.bounds.origin
        XCTAssertTrue(lastFollowing)
        initiallyAtNewestEnd = Self.isAtNewestEnd(scroll)
        XCTAssertTrue(initiallyAtNewestEnd, "The mounted production scroll view must show its newest end before input")
        // SwiftUI's native scroll wrapper need not accept first-responder status.
        // The user clicks actual transcript text; observe(_:) accepts reading
        // keys only from a non-editable responder inside this exact document.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            self?.observe(event)
            return event
        }
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(sample(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observe(_ event: NSEvent) {
        guard event.windowNumber == window.windowNumber, let scroll else { return }
        let pending = PendingInteraction(origin: lastOrigin, time: ContinuousClock.now)
        switch event.type {
        case .keyDown:
            guard [UInt16(115), 116, 119, 121, 125, 126, 49].contains(event.keyCode),
                  !event.modifierFlags.contains(.control),
                  let responder = window.firstResponder as? NSView,
                  let document = scroll.documentView,
                  responder === scroll || responder === document || responder.isDescendant(of: document),
                  !((responder as? NSTextView)?.isEditable ?? false) else { return }
            readingKeyEvents += 1
            // One origin change cannot satisfy both input kinds. A different
            // reading input invalidates pending attribution, and the wheel phase
            // is admitted only after the first actual Return to live completes.
            pendingWheel = nil
            if phase == .keyboard, lastFollowing { pendingKey = pending }
        case .scrollWheel:
            guard event.scrollingDeltaY != 0,
                  scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) else { return }
            wheelEvents += 1
            pendingKey = nil
            if phase == .wheel, lastFollowing { pendingWheel = pending }
        default: break
        }
    }

    @objc private func sample(_ timer: Timer) {
        guard let scroll, scroll.window === window else { return }
        let now = ContinuousClock.now, origin = scroll.contentView.bounds.origin
        let following = model.followingLive
        let rows = model.transcripts.map(\.id)
        if phase == .keyboard, let pending = pendingKey {
            if !following, abs(origin.y - pending.origin.y) > 1 {
                keyboardScrolledAndPinned = true; pendingKey = nil
                pinnedRows = rows
                stable = stablePosition(origin: origin, rows: rows, since: now, scroll: scroll)
                phase = .settlingKeyboard
            } else if pending.time.duration(to: now) > .seconds(1) { pendingKey = nil }
        }
        if phase == .wheel, let pending = pendingWheel {
            if !following, abs(origin.y - pending.origin.y) > 1 {
                wheelScrolledAndPinned = true; pendingWheel = nil; phase = .finalReturn
            } else if pending.time.duration(to: now) > .seconds(1) { pendingWheel = nil }
        }
        if phase == .settlingKeyboard {
            if following || rows != pinnedRows {
                recordFirstFailure("keyboard settlement changed", baseline: stable, origin: origin, rows: rows, scroll: scroll)
                sequenceViolation = true; phase = .failed
            } else if let stable, stable.anchor == nil || readingAnchor(in: scroll) == nil {
                recordFirstFailure("native reading anchor unavailable", baseline: stable, origin: origin, rows: rows, scroll: scroll)
                sequenceViolation = true; phase = .failed
            } else if let stable, sameReadingPosition(stable, in: scroll) {
                if stable.since.duration(to: now) >= .milliseconds(500) {
                    // Freeze position/IDs before the private arrival, after the
                    // native reading-key scroll has settled. A subsequent jump
                    // cannot reset the baseline and later manufacture a pass.
                    self.stable = stablePosition(origin: origin, rows: pinnedRows, since: now, scroll: scroll)
                    phase = .awaitingArrival
                    insertArrival()
                }
            } else {
                stable = stablePosition(origin: origin, rows: pinnedRows, since: now, scroll: scroll)
            }
        }
        if [.awaitingArrival, .pinnedHistory, .firstReturn].contains(phase), !following, let stable {
            if rows != stable.rows || !sameReadingPosition(stable, in: scroll) {
                recordFirstFailure("pinned history changed", baseline: stable, origin: origin, rows: rows, scroll: scroll)
                historyChangedWhilePinned = true; phase = .failed
            } else if let arrivalID {
                let read = completedReads.snapshot
                if read.count > stable.reads, read.rows.first == arrivalID,
                   !rows.contains(arrivalID), model.hasNewerContent {
                    arrivalObservedWhilePinned = true
                    if phase == .awaitingArrival { phase = .pinnedHistory }
                    if !stableAcrossRefresh, stable.since.duration(to: now) >= .seconds(9) {
                        stableAcrossRefresh = true; stableRefreshCount = read.count - stable.reads
                        phase = .firstReturn
                        print("Native Live \(viewport): a real SQLite refresh saw the new fictional transcript while original IDs and native position stayed pinned for nine seconds. Click Return to live, then wait for the new-arrival-visible receipt.")
                    }
                }
            }
        }
        if following, !lastFollowing {
            switch phase {
            case .firstReturn:
                returnTransitions += 1; returnedAfterStableHistory = true; phase = .arrivalPresentation
            case .finalReturn:
                returnTransitions += 1; phase = .finalPresentation
            default:
                recordFirstFailure("unexpected following transition", baseline: stable, origin: origin, rows: rows, scroll: scroll)
                sequenceViolation = true; phase = .failed
            }
        }
        if following, [.arrivalPresentation, .finalPresentation].contains(phase), let arrivalID,
           rows.first == arrivalID, model.transcriptItems.first?.recording?.id == arrivalID,
           Self.isAtNewestEnd(scroll) {
            if phase == .arrivalPresentation {
                arrivalPresentedAtNewestEnd = true; phase = .wheel
                print("Native Live \(viewport): new fictional arrival is displayed at the newest end after Return to live. Now perform the wheel gesture, then Return to live again.")
            } else {
                returnedToBottom = true; phase = .complete
            }
        }
        lastFollowing = following
        lastOrigin = origin
    }

    private func stablePosition(origin: NSPoint, rows: [Int64], since: ContinuousClock.Instant,
                                scroll: NSScrollView) -> StablePosition {
        .init(origin: origin, rows: rows, since: since, reads: completedReads.snapshot.count,
            documentBounds: scroll.documentView?.bounds ?? .zero, clipBounds: scroll.contentView.bounds,
            visibleRect: scroll.documentVisibleRect, itemIDs: model.transcriptItems.map(\.id),
            anchor: readingAnchor(in: scroll),
            transcriptRevision: model.transcriptRevision, requestRevision: model.requestRevision,
            sourceInvalidationRevision: model.sourceInvalidationRevision)
    }

    /// One bounded categorical/identity receipt per authored fixture. It does not
    /// log text, observe another process, relax the assertion, or reset its baseline.
    private func recordFirstFailure(_ reason: String, baseline: StablePosition?, origin: NSPoint,
                                    rows: [Int64], scroll: NSScrollView) {
        guard firstFailureDiagnostic == nil else { return }
        let oldRows = baseline?.rows ?? [], oldItems = baseline?.itemIDs ?? []
        let items = model.transcriptItems.map(\.id)
        let oldRowSet = Set(oldRows), rowSet = Set(rows), oldItemSet = Set(oldItems), itemSet = Set(items)
        let renderedRows = NativeLiveTranscriptGeometry.rows(in: scroll, expectedIDs: displayedIDs)
        let visibleRows = renderedRows?.filter { $0.frame.intersects(scroll.documentVisibleRect) } ?? []
        let detail = "reason=\(reason), phase=\(phase), uptime=\(ProcessInfo.processInfo.systemUptime), "
            + "audioIDsEqual=\(oldRows == rows), removedAudioIDs=\(Array(oldRowSet.subtracting(rowSet).sorted().prefix(32))), addedAudioIDs=\(Array(rowSet.subtracting(oldRowSet).sorted().prefix(32))), "
            + "projectedIDsEqual=\(oldItems == items), removedItemIDs=\(Array(oldItemSet.subtracting(itemSet).sorted().prefix(16))), addedItemIDs=\(Array(itemSet.subtracting(oldItemSet).sorted().prefix(16))), "
            + "oldOrigin=\(String(describing: baseline?.origin)), newOrigin=\(origin), oldDocument=\(String(describing: baseline?.documentBounds)), newDocument=\(String(describing: scroll.documentView?.bounds)), "
            + "oldClip=\(String(describing: baseline?.clipBounds)), newClip=\(scroll.contentView.bounds), oldVisible=\(String(describing: baseline?.visibleRect)), newVisible=\(scroll.documentVisibleRect), "
            + "oldAnchor=\(String(describing: baseline?.anchor)), newAnchor=\(String(describing: readingAnchor(in: scroll))), "
            + "renderedRows=\(renderedRows?.count ?? -1), visibleItemIDs=\(Array(visibleRows.map(\.id).prefix(16))), topRowFrame=\(String(describing: readingAnchor(in: scroll)?.frame)), "
            + "ready=\(model.presentationReady), loading=\(model.isLoading), following=\(model.followingLive), speakerJobs=\(model.speakers.count), speakerTurns=\(model.transcriptItems.compactMap(\.turn).count), "
            + "requestRevision=\(String(describing: baseline?.requestRevision))->\(model.requestRevision), transcriptRevision=\(String(describing: baseline?.transcriptRevision))->\(model.transcriptRevision), sourceInvalidationRevision=\(String(describing: baseline?.sourceInvalidationRevision))->\(model.sourceInvalidationRevision), "
            + "readCount=\(baseline?.reads ?? -1)->\(completedReads.snapshot.count), readingKeys=\(readingKeyEvents), wheelEvents=\(wheelEvents)"
        firstFailureDiagnostic = detail
        print("Native Live \(viewport) first failure: \(detail)")
    }

    private func insertArrival() {
        guard arrivalTask == nil else { return }
        let queries = queries, viewport = viewport, pendingArrival = pendingArrival
        arrivalTask = Task { @MainActor [weak self] in
            do {
                let timestamp = Date()
                let id: Int64
                if let pendingArrival {
                    id = try await queries.insertRawBatch(startTime: timestamp,
                        endTime: timestamp.addingTimeInterval(0.1), source: .microphone,
                        audioPath: pendingArrival.path, audioSize: pendingArrival.size)
                } else {
                    id = try await queries.insertTranscription(sessionID: nil,
                        text: "New authored \(viewport) arrival. The fictional Cedar review has one additional update while the reader is looking at earlier context.",
                        startTime: timestamp, endTime: timestamp.addingTimeInterval(0.1), source: .system,
                        confidence: nil, words: [])
                }
                self?.arrivalID = id
            } catch {
                self?.phase = .failed
                XCTFail("The private authored arrival could not be inserted")
            }
        }
    }

    func finishArrival() async { await arrivalTask?.value }

    func removeArrival() async throws {
        await finishArrival()
        if let arrivalID {
            let removed = try await queries.deleteTranscription(id: arrivalID)
            XCTAssertTrue(removed, "Remove only this viewport's authored arrival")
        }
    }

    /// The production row background supplies its actual rendered bounds and
    /// canonical identity, including original-text and speaker-only rows.
    private func readingAnchor(in scroll: NSScrollView) -> ReadingAnchor? {
        NativeLiveTranscriptGeometry.anchor(in: scroll, expectedIDs: displayedIDs)
    }

    private func sameReadingPosition(_ baseline: StablePosition, in scroll: NSScrollView) -> Bool {
        guard baseline.itemIDs == model.transcriptItems.map(\.id),
              let old = baseline.anchor, let current = readingAnchor(in: scroll) else { return false }
        let visible = scroll.documentVisibleRect
        // AppKit may resolve estimated heights above the viewport, moving its
        // absolute origin without moving what is being read. The frozen content
        // anchor and its actual viewport offset must nevertheless stay fixed.
        return old.itemID == current.itemID
            && abs(old.offsetY - current.offsetY) <= 0.5
            && abs(baseline.visibleRect.minX - visible.minX) <= 0.5
            && abs(baseline.visibleRect.width - visible.width) <= 0.5
            && abs(baseline.visibleRect.height - visible.height) <= 0.5
    }

    private static func isAtNewestEnd(_ scroll: NSScrollView) -> Bool {
        NativeLiveTranscriptGeometry.isAtNewestEnd(scroll, tolerance: max(2, scroll.contentView.bounds.height * 0.02))
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    var receipt: String {
        "Native Live \(viewport) input: phase=\(phase), initially at newest end=\(initiallyAtNewestEnd), reading keys=\(readingKeyEvents), wheel events=\(wheelEvents), keyboard scrolled/pinned=\(keyboardScrolledAndPinned), wheel scrolled/pinned=\(wheelScrolledAndPinned), private arrival committed=\(arrivalID != nil), arrival observed while pinned=\(arrivalObservedWhilePinned), stable across arrival refresh=\(stableAcrossRefresh), completed stable refreshes=\(stableRefreshCount), history changed while pinned=\(historyChangedWhilePinned), sequence violation=\(sequenceViolation), Return to live transitions=\(returnTransitions), arrival presented at newest end=\(arrivalPresentedAtNewestEnd), returned to newest end=\(returnedToBottom).\nAuthored private SQLite/AAC only; native events observed unchanged; no typed text or event characters logged."
            + "\nFirst failure: \(firstFailureDiagnostic ?? "none")"
    }

    private static func descendants(_ root: NSView) -> [NSView] {
        var found: [NSView] = [], pending = [root]
        while let view = pending.popLast(), found.count < 5_000 {
            found.append(view); pending.append(contentsOf: view.subviews)
        }
        return found
    }
}

private actor LiveContextNativePlaybackProbe {
    private(set) var attempts = 0
    func recordAttempt() { attempts += 1 }
}

// Append to LiveContextNativeViewTests.swift: these private helpers deliberately
// reuse its real private SQLite/AAC fixture and native production-row geometry.
extension LiveContextNativeViewTests {
    func testLazyHistoryScrollsAcrossDaysWithoutManualPagingAtBothWidths() async throws {
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_LIVE_CONTEXT_MAX_LAYOUT"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_NATIVE_LIVE_CONTEXT_MAX_LAYOUT=1 for native lazy-history validation")
        }
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1" else {
            throw XCTSkip("Native validation requires isolated debug logging")
        }
        let output = try renderDirectory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-lazy-history-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await makePrivateDatabase(at: root.appendingPathComponent("recordings.db"))
        var retained: Fixture?
        do {
            try await database.initialize()
            let fixture = try await makeFixture(database: database, root: root)
            retained = fixture
            let now = Date()
            for index in 0..<620 {
                let start = now.addingTimeInterval(-Double(index / 2) * 300 - 5)
                _ = try await fixture.queries.insertTranscription(sessionID: nil,
                    text: "Authored history \(index). Cedar onboarding review: check the owner, Friday deadline and pilot feedback before the next step.",
                    startTime: start, endTime: start.addingTimeInterval(3), source: .microphone, confidence: nil, words: [])
            }
            for (name, width) in [("wide", CGFloat(1_280)), ("narrow", CGFloat(820))] {
                try await verifyLazyHistory(fixture, root: root, name: name, width: width, output: output)
            }
            try await fixture.close(); retained = nil
            try await database.close()
        } catch {
            try? await retained?.close(); try? await database.close(); throw error
        }
    }

    private func verifyLazyHistory(_ fixture: Fixture, root: URL, name: String, width: CGFloat, output: URL?) async throws {
        let readers = MaximumLayoutReadDrain()
        let model = LiveContextWorkspaceModel(loadAudio: { interval, cursor, query in
            try await readers.read {
                try await fixture.queries.getContextPage(from: interval.start, to: interval.end, limit: 100, before: cursor, query: query)
            }
        }, loadScreens: { interval in try await readers.read { try await fixture.screenPage(in: interval) } },
           readEntry: { id in try await readers.read { try await fixture.queries.getContextEntry(id: id) } })
        let evidence = EvidenceViewModel(client: maximumLayoutEvidenceClient(fixture, readers: readers))
        let playback = TranscriptAudioPlayback(resolve: { _ in
            XCTFail("Browsing may not prepare playback"); throw CancellationError()
        }, isMuted: true)
        _ = NSApplication.shared
        let panel = LiveContextNativeTestPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 760),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        let view = LiveContextWorkspaceView(model: model, evidence: evidence, playback: playback,
            isActive: true, isRecording: false, validateScreen: { _ in true }, openEvidence: { _ in XCTFail("No navigation during browsing") })
        let hosting = NSHostingView(rootView: view.frame(width: width, height: 760).background(Color.retraceBackground).environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 760)
        let before = NativeResourceUsageProbe.read()
        @MainActor func close() async {
            model.setActive(false); evidence.closeEvidence(); playback.stop(reason: .closed)
            panel.orderOut(nil); panel.contentView = nil; panel.close()
            await readers.close()
        }
        do {
            panel.contentView = hosting; panel.orderFront(nil)
            model.setActive(true); await model.refresh()
            try await waitUntil("lazy history first page") { hosting.layoutSubtreeIfNeeded(); return model.presentationReady && !model.isLoading }
            XCTAssertEqual(model.transcripts.count, 100, "Opening Live must not scan the whole library")
            let observer = try XCTUnwrap(Self.nativeDescendants(hosting).compactMap { $0 as? LiveContextScrollInteractionObserver.ObserverView }.first)
            let scroll = try XCTUnwrap(NativeLiveTranscriptGeometry.scroll(in: hosting, observer: observer, expectedIDs: model.transcriptItems.map(\.id)))
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertTrue(NativeLiveTranscriptGeometry.isAtNewestEnd(scroll, tolerance: 1))
            let firstRows = try XCTUnwrap(NativeLiveTranscriptGeometry.renderedRows(in: scroll))
            XCTAssertEqual(firstRows.first?.id, model.transcriptItems.first?.id)
            XCTAssertLessThan(firstRows.count, model.transcriptItems.count, "Only realized rows should have native views")
            var readCounts = [model.transcripts.count]
            model.pauseFollowing()
            // Move the real scroll view. Only the production lazy row/footer can request another page.
            for _ in 0..<20 where model.canLoadOlder {
                let count = model.transcripts.count
                let bottom = document.isFlipped ? max(0, document.bounds.maxY - scroll.contentView.bounds.height) : document.bounds.minY
                document.scroll(NSPoint(x: 0, y: bottom)); scroll.reflectScrolledClipView(scroll.contentView)
                hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
                try await waitUntil("scroll-driven older page") {
                    hosting.layoutSubtreeIfNeeded()
                    return model.transcripts.count > count || !model.canLoadOlder || model.audioError != nil
                }
                XCTAssertNil(model.audioError)
                readCounts.append(model.transcripts.count)
            }
            XCTAssertFalse(model.canLoadOlder)
            XCTAssertGreaterThan(model.transcripts.count, 620)
            XCTAssertEqual(Set(model.transcripts.map(\.id)).count, model.transcripts.count)
            XCTAssertEqual(model.transcriptItems.map(\.startedAt), model.transcriptItems.map(\.startedAt).sorted(by: >))
            XCTAssertGreaterThan(try XCTUnwrap(model.transcripts.first).startTime.timeIntervalSince(try XCTUnwrap(model.transcripts.last).startTime), 86_400)
            let rows = try XCTUnwrap(NativeLiveTranscriptGeometry.renderedRows(in: scroll))
            XCTAssertLessThan(rows.count, model.transcripts.count)
            let pinned = try XCTUnwrap(NativeLiveTranscriptGeometry.anchor(in: scroll, expectedIDs: model.transcriptItems.map(\.id)))
            let pinnedIDs = model.transcriptItems.map(\.id)
            let arrival = Date()
            let newID = try await fixture.queries.insertTranscription(sessionID: nil, text: "Authored arrival while reading old history",
                startTime: arrival, endTime: arrival.addingTimeInterval(0.001), source: .microphone, confidence: nil, words: [])
            await model.refresh(now: arrival.addingTimeInterval(1))
            hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(model.transcriptItems.map(\.id), pinnedIDs)
            let retainedAnchor = try XCTUnwrap(NativeLiveTranscriptGeometry.anchor(in: scroll, expectedIDs: pinnedIDs))
            XCTAssertEqual(retainedAnchor.itemID, pinned.itemID)
            XCTAssertEqual(retainedAnchor.offsetY, pinned.offsetY, accuracy: 1)
            XCTAssertTrue(model.hasNewerContent)
            try pressAccessibleButton("Return to live", in: hosting)
            try await waitUntil("Return to live reaches newest row at top") {
                hosting.layoutSubtreeIfNeeded()
                return model.followingLive && model.transcripts.first?.id == newID && NativeLiveTranscriptGeometry.isAtNewestEnd(scroll, tolerance: 1)
            }
            let after = NativeResourceUsageProbe.read()
            let footprintGrowth = (after.physicalFootprintBytes ?? 0) - min(after.physicalFootprintBytes ?? 0, before.physicalFootprintBytes ?? 0)
            XCTAssertLessThan(footprintGrowth, 300 * 1_024 * 1_024, "A 620-row lazy traversal must not allocate the old eager-page footprint")
            let report: [String: Any] = ["viewport": name, "loadedCounts": readCounts, "firstRealizedRows": firstRows.count,
                "lastRealizedRows": rows.count, "footprintGrowthBytes": footprintGrowth,
                "elapsedSeconds": after.uptime - before.uptime, "processCPUSeconds": (after.cpuSeconds ?? 0) - (before.cpuSeconds ?? 0),
                "scope": "private authored SQLite and native lazy scroll; not whole-app CPU acceptance"]
            print("Lazy history receipt: \(report)")
            if let output {
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("lazy-history-\(name).json"))
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("lazy-history-\(name).png"))
            }
            await close()
            _ = try await fixture.queries.deleteTranscription(id: newID)
        } catch { await close(); throw error }
    }

    private func maximumLayoutEvidenceClient(_ fixture: Fixture, readers: MaximumLayoutReadDrain) -> EvidenceClient {
        let live = EvidenceClient.live(service: fixture.recall)
        return EvidenceClient(reference: { result in try await readers.read { try await live.reference(result) } },
            frameReference: { id, source in try await readers.read { try await live.frameReference(id, source) } },
            resolve: { reference in
                (try? await readers.read { await live.resolve(reference) }) ?? .unavailable(.sourceDisconnected)
            }, currentRevision: { reference in try await readers.read { try await live.currentRevision(reference) } },
            track: { action, outcome, count in
                _ = try? await readers.read { await live.track(action, outcome, count) }
            }, retainedScreen: { reference in
                try? await readers.read { await live.retainedScreen(reference) }
            }, sourceGeneration: { source in try await readers.read { try await live.sourceGeneration(source) } },
            expand: { request in try await readers.read { try await live.expand(request) } })
    }
}

/// Scoped to one measured viewport. Sealing rejects late queued callbacks before
/// they touch the private store; close returns only after admitted reads unwind.
private actor MaximumLayoutReadDrain {
    private var sealed = false
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func read<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        guard !sealed else { throw CancellationError() }
        try Task.checkCancellation()
        active += 1
        defer {
            active -= 1
            if active == 0 {
                let completed = waiters
                waiters = []
                for waiter in completed { waiter.resume() }
            }
        }
        let value = try await operation()
        try Task.checkCancellation()
        guard !sealed else { throw CancellationError() }
        return value
    }

    func close() async {
        sealed = true
        guard active > 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
