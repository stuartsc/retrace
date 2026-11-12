import App
import AppKit
import Foundation
import Shared
import XCTest
@testable import Retrace

@MainActor
final class CommandAccessViewModelTests: XCTestCase {
    func testExplicitGrantRemainsDisabledAndTokenCannotBeRecoveredAfterDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-access-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = RetraceCommandAccessService(storageRoot: root, handlers: { [] })
        let model = CommandAccessViewModel(service: { owner })
        await model.refresh()
        XCTAssertFalse(try XCTUnwrap(model.state).enabled)
        XCTAssertTrue(try XCTUnwrap(model.state).clients.isEmpty)
        let expiry = Date().addingTimeInterval(3_600)
        let grants: Set<RetraceCapability> = [.evidenceRead, .markersRead]
        model.createClient(name: "Authored client", capabilities: grants, expiresAt: expiry)
        await model.finishPendingWrite()
        let issued = try XCTUnwrap(model.issuedClient)
        let state = try XCTUnwrap(model.state)
        XCTAssertFalse(state.enabled)
        XCTAssertFalse(state.listening)
        XCTAssertEqual(state.clients.first?.capabilities, grants)
        XCTAssertEqual(state.clients.first?.expiresAt, expiry)
        let file = root.appendingPathComponent("context/native-access/clients.json")
        let persisted = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: persisted, as: UTF8.self).contains(issued.bearerToken), "The private store contains no plaintext bearer")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("retrace-command-token-test-\(UUID())"))
        defer { pasteboard.clearContents() }
        XCTAssertTrue(model.copyIssuedToken(to: pasteboard))
        XCTAssertTrue(pasteboard.string(forType: .string) == issued.bearerToken)
        XCTAssertNotNil(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
        XCTAssertNotNil(pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        model.dismissToken()
        XCTAssertNil(model.issuedClient)
        XCTAssertFalse(model.copyIssuedToken(to: pasteboard))
        await model.refresh()
        XCTAssertNil(model.issuedClient, "Refreshing never recovers a credential from its digest")
        model.revoke(issued.summary)
        await model.finishPendingWrite()
        XCTAssertTrue(try XCTUnwrap(model.state).clients.isEmpty)
        await owner.close()
    }

    func testClosingDuringProvisioningDiscardsLateOneTimeToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-access-hide-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = RetraceCommandAccessService(storageRoot: root, handlers: { [] })
        let gate = CommandAccessReadGate()
        let model = CommandAccessViewModel(service: { await gate.wait(); return owner })
        model.createClient(name: "Authored hidden client", capabilities: [.manifest], expiresAt: nil)
        model.hide()
        model.show()
        await gate.release()
        await model.finishPendingWrite()
        XCTAssertNil(model.issuedClient)
        XCTAssertEqual(model.state?.clients.count, 1, "A committed grant is preserved and remains revocable")
        XCTAssertFalse(try XCTUnwrap(model.state).enabled)
        let summary = try XCTUnwrap(model.state?.clients.first)
        model.revoke(summary)
        await model.finishPendingWrite()
        await owner.close()
    }
}

private actor CommandAccessReadGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
