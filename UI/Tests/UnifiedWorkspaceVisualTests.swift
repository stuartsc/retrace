import AppKit
import ImageIO
import SwiftUI
import XCTest
import App
import Database
import Shared
import Storage
@testable import Retrace

/// Opt-in real-view evidence, independent of the installed application. The
/// reviewed Cedar JPEGs and authored extraction text are UI fixtures, not a new
/// OCR accuracy result. No capture, service initialization or network is used.
@MainActor
final class UnifiedWorkspaceVisualTests: XCTestCase {
    private var database: DatabaseManager?
    private var adapter: DataAdapter?
    private var session: UnifiedWorkspaceSession?
    private var panel: WorkspaceVisualPanel?
    private var hosting: NSHostingView<AnyView>?
    private var defaults: UserDefaults?
    private var defaultsName: String?
    private var intelSession: URLSession?
    private var actions: WorkspaceVisualActions?
    private var pendingSearch: Task<Void, Never>?
    private let gate = WorkspaceVisualSearchGate()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func tearDown() async throws {
        await gate.release()
        pendingSearch?.cancel()
        await pendingSearch?.value
        pendingSearch = nil
        session?.model.close()
        session?.audio.clear()
        session?.timeline.invalidateWorkspaceTape()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        hosting = nil; panel = nil; session = nil
        intelSession?.invalidateAndCancel()
        await actions?.flush()
        await adapter?.shutdown()
        try await database?.close()
        if let defaultsName { defaults?.removePersistentDomain(forName: defaultsName) }
        defaults = nil; adapter = nil; database = nil
    }

    func testActualWorkspaceAtWideAndMinimumWidths() async throws {
        guard let requested = ProcessInfo.processInfo.environment["RETRACE_WORKSPACE_VISUAL_EXPORT"] else {
            throw XCTSkip("Opt in with RETRACE_WORKSPACE_VISUAL_EXPORT=/tmp/retrace-unified-20260924/workspace-visual")
        }
        guard ProcessInfo.processInfo.environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1" else {
            throw XCTSkip("The visual harness requires RETRACE_TEST_DISABLE_FILE_LOGGING=1 at process launch")
        }
        let output = try await Self.makeOutput(requested)
        let database = DatabaseManager(databasePath: ":memory:")
        self.database = database
        try await database.initialize()
        let pointer = await database.getConnection()
        let adapter = DataAdapter(retraceConnection: SQLiteConnection(db: try XCTUnwrap(pointer)),
            retraceConfig: DatabaseConfig(dateFormatter: nil, storageRoot: output.path, source: .native, cutoffDate: nil),
            retraceImageExtractor: HEVCStorageExtractor(storageRoot: output.path), database: database)
        self.adapter = adapter
        try await adapter.initialize()
        let first = try await insert(at: 0, amount: "42000", status: "DRAFT", database: database)
        let second = try await insert(at: 2, amount: "47000", status: "SENT", database: database)
        let images = try await Self.authoredImages()
        let service = ProgressiveRecallService(database: database, adapter: adapter,
            configuration: { CaptureConfig() }, imageReader: { snapshot in
                let key: String
                switch snapshot.frame.timestamp {
                case first.timestamp: key = "draft"
                case second.timestamp, first.timestamp.addingTimeInterval(4): key = "sent"
                default: throw EvidenceUnavailableReason.integrityFailure
                }
                guard let image = images[key] else {
                    throw EvidenceUnavailableReason.recordingMissing
                }
                return image
            })

        // This dormant handle satisfies existing view/tape APIs. It uses the
        // in-memory test constructor and is never initialized or called by the
        // fixture view. Every evidence read below uses the private DB above.
        let coordinator = AppCoordinator(services: ServiceContainer(inMemory: true))
        let dashboard = DashboardViewModel(visualFixtureCoordinator: coordinator)
        let timeline = SimpleTimelineViewModel(coordinator: coordinator, evidenceClient: .live(service: service),
            transientDirectory: output.appendingPathComponent("unused-tape-buffer"), workspace: true)
        timeline.test_windowFetchHooks.getFramesWithVideoInfo = { from, to, limit, filters, _ in
            try await adapter.getFramesWithVideoInfo(from: from, to: to, limit: limit, filters: filters)
        }
        let actions = WorkspaceVisualActions(database: database)
        self.actions = actions
        let defaultsName = "Retrace.UnifiedWorkspaceVisualTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        self.defaultsName = defaultsName; self.defaults = defaults
        defaults.set(0.0, forKey: "scrubbingAnimationDuration")
        defaults.set("horizontal", forKey: "timelineScrollOrientation")
        let gate = self.gate
        let model = UnifiedWorkspaceModel(evidence: timeline.evidence, latest: {
            try await DashboardScreenshotIdentityPolicy.readRows(sourceGeneration: {
                try await service.sourceGeneration(source: $0)
            }) { try await adapter.getMostRecentFramesWithVideoInfo(limit: 100) }
        }, search: { query in
            let results = try await adapter.search(query: SearchQuery(text: query, limit: 100)).results
            await gate.pauseIfArmed()
            return results
        }, track: { await actions.record($0) }, bookmarkStore: WorkspaceBookmarkStore(suiteName: defaultsName))
        let playback = TranscriptAudioPlayback(resolve: { _ in throw TranscriptAudioError.unreadable }, isMuted: true)
        let audio = WorkspaceAudioContext(playback: playback, query: { _ in [] })
        let session = UnifiedWorkspaceSession(visualFixtureTimeline: timeline, model: model,
            playback: playback, audio: audio)
        self.session = session
        let intelConfiguration = URLSessionConfiguration.ephemeral
        intelConfiguration.protocolClasses = [WorkspaceVisualIntelProtocol.self]
        let intelSession = URLSession(configuration: intelConfiguration)
        self.intelSession = intelSession
        let intelURL = try XCTUnwrap(URL(string: "https://workspace-fixture.invalid"))
        let intel = FuseIntelViewModel(baseURL: intelURL,
            client: FuseIntelClient(baseURL: intelURL, session: intelSession))
        await intel.refresh(force: true)
        XCTAssertTrue(intel.isConnected, "The static URLProtocol fixture must decode through the real Intel client")

        _ = NSApplication.shared
        let view = UnifiedWorkspaceView(coordinator: coordinator, dashboard: dashboard, session: session,
            fixtureDefaults: defaults, fixtureNotifications: NotificationCenter(), fixtureIntel: intel,
            fixtureMetric: { actions.record($0) })
            // The system motion preference is read-only. Freeze fixture
            // animations without changing the user's accessibility setting.
            .transaction { $0.animation = nil; $0.disablesAnimations = true }
            .preferredColorScheme(.dark)
        let hosting = NSHostingView(rootView: AnyView(view))
        let panel = WorkspaceVisualPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 800),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.hosting = hosting; self.panel = panel
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.orderFront(nil)
        try await settled("wide view has real pixels and tape") {
            model.evidence.selectedFrame?.id == second.id && timeline.frames.count == 2 && self.element("workspace.search") != nil
        }
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
        XCTAssertLessThan(panel.frame.maxX, 0, "The fixture must remain offscreen")
        XCTAssertFalse(dashboard.isWindowVisible, "The fixture must not enable production polling")
        try await capture("wide-now", output: output, width: 1100, height: 800)

        // Pin through the production selection owner, then deliver a genuine
        // SQLite refresh. Native Return to now must be the only advancement.
        let firstRow = try XCTUnwrap(model.rows.first { $0.frame.id == first.id })
        await model.select(firstRow)
        await timeline.anchorWorkspaceEvidence()
        let pinned = try XCTUnwrap(model.presentedReference)
        let newest = try await insert(at: 4, amount: "47000", status: "SENT", database: database)
        await model.refresh()
        await timeline.anchorWorkspaceEvidence()
        XCTAssertEqual(model.presentedReference, pinned)
        XCTAssertEqual(model.evidence.retainedSnapshot?.text?.fullText.contains("42000"), true)
        try await settled("historical Return to now control") { self.element("workspace.returnNow") != nil }
        try await capture("wide-pinned-history", output: output, width: 1100, height: 800)
        try press("workspace.bookmark")
        try await settled("private bookmark persisted") { model.bookmarks.count == 1 }
        try press("workspace.returnNow")
        try await settled("native Return to now selected new capture") {
            model.mode == .now && model.evidence.selectedFrame?.id == newest.id
        }

        // Set and submit the actual native field; no synthetic search view is
        // used. A failed native bridge fails the harness rather than silently
        // substituting a model-only search and claiming input acceptance.
        try submitNativeSearch("Cedar")
        try await settled("native search submitted into private SQLite") { model.searchResults.count == 3 && !model.isSearching }
        XCTAssertTrue(model.searchResults.allSatisfy { $0.evidenceRef != nil })
        try await capture("wide-search", output: output, width: 1100, height: 800)
        let hit = try XCTUnwrap(model.searchResults.first { $0.id == first.id })
        try press("workspace.result.\(hit.sourceQualifiedID)")
        try await settled("native search result selected exact old capture") {
            model.mode == .history && model.evidence.selectedFrame?.id == first.id
        }

        // The suspension is controlled, not a timing guess. Start through the
        // production owner and press the real Cancel button while its SQLite
        // result is held. Joining the task proves a late result cannot return.
        await gate.arm()
        let pending = Task { await model.submitSearch("Cedar") }
        pendingSearch = pending
        try await settled("native Cancel is visible") { self.element("workspace.search.cancel") != nil }
        let gateDeadline = ContinuousClock.now + .seconds(10)
        while !(await gate.isWaiting), ContinuousClock.now < gateDeadline {
            try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        }
        let waiting = await gate.isWaiting
        XCTAssertTrue(waiting)
        try press("workspace.search.cancel")
        try await settled("native Cancel invalidates the pending search") { !model.isSearching }
        await gate.release()
        await pending.value
        pendingSearch = nil
        XCTAssertTrue(model.searchResults.isEmpty)
        try press("workspace.search.clear")
        try await settled("clear search returned the main canvas") { self.element("workspace.search.clear") == nil }

        panel.setContentSize(NSSize(width: 760, height: 620))
        try await settled("minimum width starts with drawer closed") {
            abs(hosting.bounds.width - 760) < 0.5 && self.element("workspace.drawer.close") == nil
        }
        try await capture("minimum-history", output: output, width: 760, height: 620)
        try press("workspace.inspector.toggle")
        try await settled("native context button opens drawer") { self.element("workspace.drawer.close") != nil }
        try await capture("minimum-text-drawer", output: output, width: 760, height: 620)
        try pressInspectorTab("Intel")
        try await settled("static Intel is rendered in the actual inspector") {
            self.accessibilityElements().contains { self.label($0).contains("Review Cedar proposal decision") }
        }
        try await capture("minimum-intel-drawer", output: output, width: 760, height: 620)
        try press("workspace.drawer.close")
        try await settled("native drawer Close restores canvas") { self.element("workspace.drawer.close") == nil }
        await actions.flush()
        XCTAssertFalse(actions.values.contains("fixture_external_route_suppressed"))
        XCTAssertTrue(actions.values.contains("workspace_inspector_toggled"))
        let metrics = try await database.getDailyMetricCount(metricType: .dashboardScreenshotAction,
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(60))
        XCTAssertGreaterThan(metrics, 0)
        let receipt: [String: Any] = [
            "scope": "Private SQLite and reviewed authored Cedar JPEGs; actual native SwiftUI view; not installed acceptance",
            "renderSizes": ["1100x800", "760x620"],
            "nativeControls": ["Return to now", "Bookmark", "Search field submit", "Search result", "Cancel search", "Clear search", "Context and Intel", "Intel tab", "Close drawer"],
            "modelChecks": ["Historical exact citation stays pinned across real SQLite refresh", "Controlled cancelled search rejects late results"],
            "audio": "No audio fixture requested; muted player with no clips. Playback acceptance is separate.",
            "capture": "No capture or device initialization. Nonactivating panel at negative screen coordinates.",
            "intel": "Static authored response through an ephemeral session and intercept-all URLProtocol; no network",
            "defaultsSuite": defaultsName, "fixtureMetrics": metrics, "actions": actions.values
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try await Task.detached { try data.write(to: output.appendingPathComponent("receipt.json"), options: .withoutOverwriting) }.value
        print("WORKSPACE_VISUAL_ARTIFACTS=\(output.path)")
    }

    private func insert(at offset: TimeInterval, amount: String, status: String, database: DatabaseManager) async throws -> FrameReference {
        let at = start.addingTimeInterval(offset)
        let metadata = FrameMetadata(appBundleID: "org.retrace.fixture.cedar", appName: "Cedar fixture", windowName: "Cedar proposal")
        let segment = try await database.insertSegment(bundleID: "org.retrace.fixture.cedar", startDate: at,
            endDate: at, windowName: "Cedar proposal", browserUrl: nil, type: 0)
        let id = try await database.insertFrame(FrameReference(id: .init(value: 0), timestamp: at,
            segmentID: .init(value: segment), frameIndexInSegment: 0, metadata: metadata))
        let frame = FrameReference(id: .init(value: id), timestamp: at, segmentID: .init(value: segment),
            frameIndexInSegment: 0, metadata: metadata)
        let lines = ["Cedar proposal", "Amount \(amount)", "Status \(status)", "Approval NOT GRANTED", "Meeting tomorrow"]
        let regions = lines.enumerated().map { row, text in
            TextRegion(frameID: frame.id, text: text, bounds: CGRect(x: 64, y: 70 + row * 110, width: 900, height: 48))
        }
        _ = try await database.commitFrameOCR(frameID: frame.id,
            text: ExtractedText(frameID: frame.id, timestamp: at, regions: regions, metadata: metadata),
            frameWidth: 1280, frameHeight: 800)
        try await database.markFrameReadable(frameID: frame.id.value)
        return frame
    }

    private func settled(_ reason: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            hosting?.layoutSubtreeIfNeeded()
            hosting?.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25), clock: .continuous)
        } while ContinuousClock.now < deadline
        XCTFail("Visual harness did not settle: \(reason)")
        throw WorkspaceVisualError.unsettled
    }

    // The NSObject compatibility bridge reaches SwiftUI's native AX elements
    // in-process. It does not use cross-application AX or request permission.
    private func accessibilityElements() -> [NSObject] {
        guard let hosting else { return [] }
        var found: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func visit(_ value: NSObject, depth: Int) {
            guard depth < 40, found.count < 3000, visited.insert(ObjectIdentifier(value)).inserted else { return }
            found.append(value)
            for child in value.accessibilityAttributeValue(.children) as? [NSObject] ?? [] { visit(child, depth: depth + 1) }
            if let view = value as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(hosting, depth: 0)
        return found
    }
    private func element(_ identifier: String) -> NSObject? {
        accessibilityElements().first { $0.accessibilityAttributeValue(.identifier) as? String == identifier }
    }
    private func label(_ element: NSObject) -> String {
        [NSAccessibility.Attribute.title, .description, .value]
            .compactMap { element.accessibilityAttributeValue($0) as? String }.joined(separator: " ")
    }
    private func press(_ identifier: String) throws {
        let control = try XCTUnwrap(element(identifier), "Missing actual control \(identifier)")
        XCTAssertTrue(control.accessibilityActionNames().contains(.press), "Control must support native press: \(identifier)")
        control.accessibilityPerformAction(.press)
    }
    private func pressInspectorTab(_ name: String) throws {
        let picker = try XCTUnwrap(element("workspace.inspector.tabs"))
        let children = picker.accessibilityAttributeValue(.children) as? [NSObject] ?? []
        let control = try XCTUnwrap(children.first { label($0).contains(name) && $0.accessibilityActionNames().contains(.press) })
        control.accessibilityPerformAction(.press)
    }
    private func submitNativeSearch(_ query: String) throws {
        let field = try XCTUnwrap(accessibilityElements().compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == "Search recorded text"
        }, "The actual SwiftUI TextField must expose its native field")
        field.stringValue = query
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        let handled = field.delegate?.control?(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))) ?? false
        if !handled {
            XCTAssertNotNil(field.action, "The native search field must have a submit action")
            XCTAssertTrue(field.sendAction(field.action, to: field.target), "Native Return must submit the real field")
        }
    }

    private func capture(_ name: String, output: URL, width: CGFloat, height: CGFloat) async throws {
        let hosting = try XCTUnwrap(hosting)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        // Allow SwiftUI's display transaction to finish after an observed-state
        // change; this is not a capture/search latency measurement.
        try await Task.sleep(for: .milliseconds(80), clock: .continuous)
        XCTAssertEqual(hosting.bounds.width, width, accuracy: 0.5)
        XCTAssertEqual(hosting.bounds.height, height, accuracy: 0.5)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 15_000, "Refuse a blank/tiny render as visual evidence")
        try await Task.detached { try data.write(to: output.appendingPathComponent("\(name).png"), options: .withoutOverwriting) }.value
    }

    nonisolated private static func makeOutput(_ requested: String) async throws -> URL {
        try await Task.detached {
            let parent = URL(fileURLWithPath: requested, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard parent.path.hasPrefix("/private/tmp/retrace-unified-20260924/") || parent.path.hasPrefix("/tmp/retrace-unified-20260924/") else {
                throw WorkspaceVisualError.outputOutsidePrivateRoot
            }
            let output = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return output
        }.value
    }
    nonisolated private static func authoredImages() async throws -> [String: CGImage] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/fixtures/progressive-recall")
        return try await Task.detached {
            var images: [String: CGImage] = [:]
            for (name, filename) in [("draft", "1700000000.jpeg"), ("sent", "1700000002.jpeg")] {
                guard let source = CGImageSourceCreateWithURL(root.appendingPathComponent(filename) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                    throw WorkspaceVisualError.missingAuthoredImage
                }
                images[name] = image
            }
            return images
        }.value
    }
}

private enum WorkspaceVisualError: Error { case unsettled, outputOutsidePrivateRoot, missingAuthoredImage }

private final class WorkspaceVisualPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
private final class WorkspaceVisualActions {
    let database: DatabaseManager
    private var tasks: [Task<Void, Never>] = []
    private(set) var values: [String] = []
    init(database: DatabaseManager) { self.database = database }
    func record(_ action: String) {
        values.append(action)
        tasks.append(Task { [database] in
            let payload = ["action": action, "surface": "unified_workspace_fixture"]
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let metadata = String(data: data, encoding: .utf8) else { return }
            try? await database.recordMetricEvent(metricType: .dashboardScreenshotAction, metadata: metadata)
        })
    }
    func flush() async { let pending = tasks; tasks = []; for task in pending { await task.value } }
}

private actor WorkspaceVisualSearchGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func arm() { armed = true }
    func pauseIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// Intercepts every request, including unexpected URLs. No fallback to a real
/// transport is possible and no mutable shared request handler is installed.
private final class WorkspaceVisualIntelProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "workspace-fixture.invalid", url.path == "/api/command",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body = #"{"data":{"nextMoves":[{"id":"fixture:cedar","kind":"move","title":"Review Cedar proposal decision","context":"Cedar proposal","status":"todo","priority":"high","confidence":1,"whyNow":"Authored fixture: amount changed; approval still NOT GRANTED.","sourceRefs":[{"source":"fixture","citation":"Cedar authored oracle · screens 1700000000 and 1700000002"}]}],"radar":[],"recentIntel":[],"waiting":[],"upcoming":[],"system":{"state":"healthy","ready":true,"signalCount":1,"freshnessAt":"2026-09-24T00:00:00Z","alerts":[]}},"generatedAt":"2026-09-24T00:00:00Z","freshness":"2026-09-24T00:00:00Z","degraded":false,"warnings":[],"correlationId":"authored-workspace-fixture"}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
