import Foundation
import XCTest
@testable import Retrace

private final class FuseIntelURLProtocolStub: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FuseIntelViewModelTests: XCTestCase {
    override func tearDown() {
        FuseIntelURLProtocolStub.requestHandler = nil
        super.tearDown()
    }

    func testCommandEnvelopeDecodesTheLiveFuseIntelWireShape() throws {
        let json = """
        {
          "data": {
            "nextMoves": [{
              "id": "move:renewal",
              "kind": "move",
              "title": "Confirm Acme renewal owner",
              "context": "Acme renewal",
              "status": "todo",
              "priority": "high",
              "confidence": 0.82,
              "whyNow": "Decision due this week",
              "sourceRefs": [{"source": "outlook", "citation": "thread:acme"}]
            }],
            "radar": [],
            "recentIntel": [],
            "waiting": [],
            "upcoming": [],
            "system": {
              "state": "healthy",
              "ready": true,
              "signalCount": 4,
              "freshnessAt": "2026-08-16T00:10:00Z",
              "alerts": []
            }
          },
          "generatedAt": "2026-08-16T00:10:01Z",
          "freshness": "2026-08-16T00:10:00Z",
          "degraded": false,
          "warnings": [],
          "correlationId": "test-command"
        }
        """

        let envelope = try JSONDecoder().decode(
            FuseIntelEnvelope<FuseIntelCommandResponse>.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(envelope.data.nextMoves.first?.title, "Confirm Acme renewal owner")
        XCTAssertEqual(envelope.data.nextMoves.first?.sourceRefs.first?.source, "outlook")
        XCTAssertEqual(envelope.data.system.state, "healthy")
        XCTAssertFalse(envelope.degraded)
    }

    func testCommandEnvelopeDecodesBusinessOperatingContext() throws {
        let json = """
        {
          "data": {
            "nextMoves": [],
            "radar": [],
            "recentIntel": [],
            "waiting": [],
            "upcoming": [],
            "commercialPriorities": [{
              "id": "commercial:udc",
              "kind": "move",
              "title": "Progress UDC expansion",
              "status": "todo",
              "priority": "high",
              "impact": {"label": "$16k expansion", "kind": "revenue"},
              "sourceRefs": [{"source": "outlook", "citation": "thread:udc"}]
            }],
            "businessForesight": [{
              "id": "foresight:stale",
              "kind": "decision",
              "title": "Re-engage stale opportunities",
              "status": "todo",
              "priority": "high",
              "sourceRefs": [{"source": "neo4j", "citation": "stale_opportunities"}]
            }],
            "delegated": [{
              "id": "jira:FS-742",
              "kind": "delegated",
              "title": "Review delivery evidence",
              "status": "in_progress",
              "priority": "medium",
              "sourceRefs": [{"source": "jira", "citation": "FS-742"}]
            }],
            "threads": [{
              "threadId": "thread-1",
              "subject": "UDC software revenue",
              "msgs": 4,
              "source": "outlook",
              "last": "2026-08-16T00:08:00Z"
            }],
            "judgements": {
              "inboxDepth": 2,
              "byKind": {"resolve_identity": 2},
              "items": [{
                "id": "judgement:marcus",
                "kind": "decision",
                "title": "Resolve Marcus identity",
                "status": "blocked",
                "priority": "high",
                "sourceRefs": [{"source": "judgement", "citation": "marcus"}]
              }]
            },
            "unwiredPanels": ["shortcuts"],
            "system": {
              "state": "healthy",
              "ready": true,
              "signalCount": 4,
              "alerts": []
            }
          },
          "generatedAt": "2026-08-16T00:10:01Z",
          "degraded": false,
          "warnings": [],
          "correlationId": "business-context"
        }
        """

        let envelope = try JSONDecoder().decode(
            FuseIntelEnvelope<FuseIntelCommandResponse>.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(envelope.data.commercialPriorities.first?.impact?.label, "$16k expansion")
        XCTAssertEqual(envelope.data.businessForesight.first?.id, "foresight:stale")
        XCTAssertEqual(envelope.data.delegated.first?.id, "jira:FS-742")
        XCTAssertEqual(envelope.data.threads.first?.subject, "UDC software revenue")
        XCTAssertEqual(envelope.data.judgements.inboxDepth, 2)
        XCTAssertEqual(envelope.data.unwiredPanels, ["shortcuts"])
    }

    func testRecentActivityBriefExplainsCurrentWorkWithoutExternalInference() {
        let base = Date(timeIntervalSince1970: 10_000)
        let brief = RetraceActivityBriefPolicy.make(
            moments: [
                RetraceActivityMoment(
                    timestamp: base,
                    appName: "Microsoft Outlook",
                    windowTitle: "UDC renewal proposal",
                    browserURL: nil
                ),
                RetraceActivityMoment(
                    timestamp: base.addingTimeInterval(240),
                    appName: "Codex",
                    windowTitle: "DashboardView.swift - backintime",
                    browserURL: nil
                ),
                RetraceActivityMoment(
                    timestamp: base.addingTimeInterval(480),
                    appName: "Codex",
                    windowTitle: "FuseIntelViewModel.swift - backintime",
                    browserURL: nil
                ),
                RetraceActivityMoment(
                    timestamp: base.addingTimeInterval(600),
                    appName: "Retrace",
                    windowTitle: "Dashboard",
                    browserURL: nil,
                    isSelfCapture: true
                )
            ],
            speech: [
                RetraceSpeechMoment(
                    startedAt: base.addingTimeInterval(450),
                    endedAt: base.addingTimeInterval(470),
                    text: "Connect the current dashboard work to the UDC commercial priority."
                )
            ]
        )

        XCTAssertEqual(brief.currentApp, "Codex")
        XCTAssertEqual(brief.primaryApp, "Codex")
        XCTAssertEqual(brief.appTrail, ["Codex", "Microsoft Outlook"])
        XCTAssertTrue(brief.headline.contains("FuseIntelViewModel.swift"))
        XCTAssertTrue(brief.summary.contains("Codex"))
        XCTAssertTrue(brief.contextText.localizedCaseInsensitiveContains("UDC renewal proposal"))
        XCTAssertTrue(brief.focusTerms.contains("fuseintelviewmodel"))
        XCTAssertFalse(brief.focusTerms.contains("codex"))
        XCTAssertFalse(brief.focusTerms.contains("dashboard"))
        XCTAssertFalse(brief.focusTerms.contains("microsoft"))
        XCTAssertFalse(brief.focusTerms.contains("outlook"))
        XCTAssertFalse(brief.appTrail.contains("Retrace"))
        XCTAssertEqual(brief.capturedMomentCount, 3)
    }

    func testOperatingBriefChoosesSourceBackedContextMatchOverUnsupportedPriority() {
        let command = FuseIntelCommandResponse(
            nextMoves: [
                FuseIntelActionItem(
                    id: "unsupported",
                    kind: "move",
                    title: "Review everything",
                    priority: "critical",
                    whyNow: "Generic priority without a source trail"
                ),
                FuseIntelActionItem(
                    id: "udc",
                    kind: "move",
                    title: "Send the UDC expansion proposal",
                    priority: "high",
                    whyNow: "The renewal thread is active",
                    sourceRefs: [FuseIntelSourceRef(source: "outlook", citation: "thread:udc")]
                )
            ]
        )
        let items = FuseIntelPresentationPolicy.items(
            command: command,
            feed: [],
            section: .now,
            contextText: "Working on the UDC renewal proposal"
        )
        let brief = FuseIntelOperatingBriefPolicy.make(from: items)

        XCTAssertEqual(brief.recommendation?.id, "move:udc")
        XCTAssertEqual(brief.recommendation?.relevance, .contextMatch)
        XCTAssertFalse(brief.recommendation?.sourceRefs.isEmpty ?? true)
        XCTAssertFalse(brief.broaderPriorities.contains(where: { $0.id == "move:unsupported" }))
    }

    func testBriefIncludesCommercialForesightAndThreadsWithoutDuplicateActions() {
        let duplicate = FuseIntelActionItem(
            id: "udc",
            kind: "move",
            title: "Progress UDC expansion",
            context: "UDC",
            priority: "high",
            sourceRefs: [FuseIntelSourceRef(source: "outlook", citation: "thread:udc")]
        )
        let command = FuseIntelCommandResponse(
            nextMoves: [duplicate],
            commercialPriorities: [duplicate],
            businessForesight: [FuseIntelActionItem(
                id: "stale",
                kind: "decision",
                title: "Re-engage stale opportunities",
                priority: "high",
                sourceRefs: [FuseIntelSourceRef(source: "neo4j", citation: "stale")]
            )],
            threads: [FuseIntelThread(
                threadId: "thread-1",
                subject: "UDC software revenue",
                messageCount: 4,
                source: "outlook",
                lastAt: "2026-08-16T00:08:00Z"
            )]
        )

        let items = FuseIntelPresentationPolicy.items(
            command: command,
            feed: [],
            section: .now,
            contextText: "UDC expansion"
        )

        XCTAssertEqual(items.filter { $0.title == "Progress UDC expansion" }.count, 1)
        XCTAssertTrue(items.contains(where: { $0.kind == .foresight }))
        XCTAssertTrue(items.contains(where: { $0.kind == .thread }))
    }

    func testContextMatchesAreRankedAheadOfGeneralIntel() {
        let command = FuseIntelCommandResponse(
            nextMoves: [
                FuseIntelActionItem(
                    id: "general",
                    kind: "move",
                    title: "Review internal process",
                    priority: "critical",
                    whyNow: "Important this week"
                ),
                FuseIntelActionItem(
                    id: "acme",
                    kind: "follow_up",
                    title: "Confirm Acme renewal budget",
                    context: "Acme commercial renewal",
                    priority: "high",
                    whyNow: "Budget owner mentioned today"
                )
            ]
        )

        let items = FuseIntelPresentationPolicy.items(
            command: command,
            feed: [],
            section: .now,
            contextText: "We need to settle the Acme renewal budget with Julia."
        )

        XCTAssertEqual(items.first?.id, "move:acme")
        XCTAssertEqual(items.first?.relevance, .contextMatch)
        XCTAssertTrue(items.first?.matchedTerms.contains("acme") == true)
        XCTAssertEqual(items.last?.relevance, .acrossWork)
    }

    func testGenericOwnerAndAppTermsDoNotCreateFalseBusinessContextMatches() {
        let command = FuseIntelCommandResponse(
            businessForesight: [FuseIntelActionItem(
                id: "relationship:waco",
                kind: "decision",
                title: "Stuart Bond and Waco had a strong relationship that went silent",
                priority: "high",
                sourceRefs: [FuseIntelSourceRef(source: "neo4j", citation: "waco")]
            )]
        )

        let items = FuseIntelPresentationPolicy.items(
            command: command,
            feed: [],
            section: .now,
            contextText: "Stuart is using Codex to improve the Retrace live dashboard"
        )

        XCTAssertEqual(items.first?.relevance, .acrossWork)
        XCTAssertTrue(items.first?.matchedTerms.isEmpty == true)
    }

    func testSignalFeedSuppressesDuplicateItemsFromCommandAndFeed() {
        let duplicate = FuseIntelFeedItem(
            id: "signal:acme",
            category: "buying_signal",
            title: "Acme",
            detail: "Renewal discussed",
            at: "2026-08-16T00:10:00Z"
        )
        let command = FuseIntelCommandResponse(recentIntel: [duplicate])

        let items = FuseIntelPresentationPolicy.items(
            command: command,
            feed: [duplicate, FuseIntelFeedItem(
                id: "change:new-contact",
                category: "NEW_CONTACT",
                title: "New contact",
                detail: "Added from Outlook",
                at: "2026-08-16T00:11:00Z"
            )],
            section: .signals,
            contextText: ""
        )

        XCTAssertEqual(items.filter { $0.id == "signal:signal:acme" }.count, 1)
        XCTAssertEqual(items.count, 2)
    }

    func testPresentationSnapshotPrecomputesSectionsAndDeduplicatesContextMatches() {
        let command = FuseIntelCommandResponse(
            businessForesight: [FuseIntelActionItem(
                id: "relationship:acme",
                kind: "relationship",
                title: "Acme renewal relationship needs attention",
                context: "Acme renewal",
                priority: "high",
                sourceRefs: [FuseIntelSourceRef(source: "outlook", citation: "thread:acme")]
            )]
        )

        let snapshot = FuseIntelPresentationSnapshotPolicy.make(
            command: command,
            feed: [],
            contextText: "Review the Acme renewal before replying."
        )

        XCTAssertEqual(snapshot.items(for: .now).first?.id, "foresight:relationship:acme")
        XCTAssertEqual(snapshot.items(for: .signals).first?.id, "foresight:relationship:acme")
        XCTAssertTrue(snapshot.items(for: .upcoming).isEmpty)
        XCTAssertEqual(snapshot.contextItems.map(\.id), ["foresight:relationship:acme"])
        XCTAssertEqual(snapshot.contextMatchCount, 1)
    }

    func testSnapshotUsesCommandRecentIntelWithoutCallingSlowFeedEndpoint() async throws {
        FuseIntelURLProtocolStub.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/api/command" {
                let data = Data(Self.commandEnvelopeJSON.utf8)
                return (
                    try XCTUnwrap(HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )),
                    data
                )
            }

            XCTFail("Unexpected hot-path request to \(url.path)")
            throw URLError(.unsupportedURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FuseIntelURLProtocolStub.self]
        let client = FuseIntelClient(
            baseURL: URL(string: "http://127.0.0.1:9010")!,
            session: URLSession(configuration: configuration)
        )

        let snapshot = try await client.fetchSnapshot()

        XCTAssertEqual(snapshot.commandEnvelope.data.nextMoves.first?.title, "Confirm Acme renewal owner")
        XCTAssertEqual(snapshot.commandEnvelope.data.recentIntel.first?.title, "Acme buying signal")
        XCTAssertTrue(snapshot.feedEnvelope.data.isEmpty)
        XCTAssertFalse(snapshot.feedEnvelope.degraded)
        XCTAssertTrue(snapshot.feedEnvelope.warnings.isEmpty)
    }

    func testRefreshPolicyAllowsSlowLocalQueriesWithoutRetryStorms() {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertGreaterThanOrEqual(FuseIntelRefreshPolicy.requestTimeout, 30)
        XCTAssertFalse(FuseIntelRefreshPolicy.shouldRefresh(
            force: false,
            isLoading: false,
            lastAttemptAt: now.addingTimeInterval(-30),
            lastSuccessAt: nil,
            now: now
        ))
        XCTAssertTrue(FuseIntelRefreshPolicy.shouldRefresh(
            force: false,
            isLoading: false,
            lastAttemptAt: now.addingTimeInterval(-61),
            lastSuccessAt: nil,
            now: now
        ))
        XCTAssertFalse(FuseIntelRefreshPolicy.shouldRefresh(
            force: false,
            isLoading: false,
            lastAttemptAt: now.addingTimeInterval(-120),
            lastSuccessAt: now.addingTimeInterval(-120),
            now: now
        ))
        XCTAssertTrue(FuseIntelRefreshPolicy.shouldRefresh(
            force: true,
            isLoading: false,
            lastAttemptAt: now,
            lastSuccessAt: now,
            now: now
        ))

        XCTAssertFalse(FuseIntelRefreshPolicy.shouldRefresh(
            force: false,
            isLoading: false,
            lastAttemptAt: now.addingTimeInterval(-120),
            lastSuccessAt: nil,
            consecutiveFailures: 2,
            now: now
        ))
        XCTAssertTrue(FuseIntelRefreshPolicy.shouldRefresh(
            force: false,
            isLoading: false,
            lastAttemptAt: now.addingTimeInterval(-301),
            lastSuccessAt: nil,
            consecutiveFailures: 2,
            now: now
        ))
    }

    func testLiveFuseIntelBFFWireContractWhenAvailable() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_FUSEINTEL_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_FUSEINTEL_TESTS=1 for the resource-intensive local contract check")
        }
        let client = FuseIntelClient(baseURL: URL(string: "http://127.0.0.1:9010")!)

        do {
            let snapshot = try await client.fetchSnapshot()
            XCTAssertFalse(snapshot.commandEnvelope.correlationId.isEmpty)
            XCTAssertFalse(snapshot.feedEnvelope.correlationId.isEmpty)
            XCTAssertGreaterThanOrEqual(snapshot.feedEnvelope.data.count, 0)
        } catch let error as URLError where [
            .cannotConnectToHost,
            .networkConnectionLost,
            .timedOut
        ].contains(error.code) {
            throw XCTSkip("Local FuseIntel BFF is not running: \(error.localizedDescription)")
        }
    }

    private static let commandEnvelopeJSON = """
    {
      "data": {
        "nextMoves": [{
          "id": "move:renewal",
          "kind": "move",
          "title": "Confirm Acme renewal owner",
          "context": "Acme renewal",
          "status": "todo",
          "priority": "high",
          "confidence": 0.82,
          "whyNow": "Decision due this week",
          "sourceRefs": [{"source": "outlook", "citation": "thread:acme"}]
        }],
        "radar": [],
        "recentIntel": [{
          "id": "signal:acme",
          "category": "buying_signal",
          "title": "Acme buying signal",
          "detail": "Renewal discussed",
          "at": "2026-08-16T00:09:00Z",
          "labels": ["commercial"],
          "sourceRefs": [{"source": "outlook", "citation": "thread:acme"}]
        }],
        "waiting": [],
        "upcoming": [],
        "system": {
          "state": "healthy",
          "ready": true,
          "signalCount": 4,
          "freshnessAt": "2026-08-16T00:10:00Z",
          "alerts": []
        }
      },
      "generatedAt": "2026-08-16T00:10:01Z",
      "freshness": "2026-08-16T00:10:00Z",
      "degraded": false,
      "warnings": [],
      "correlationId": "test-command"
    }
    """
}
