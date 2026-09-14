import AppKit
import ApplicationServices
import Database
import Foundation
import Shared
import XCTest
@testable import Capture

/// Opt-in acceptance against a visible, independently reviewed application.
/// A fixture describes the expected surface, never replaces the native APIs.
/// No capture, OCR, live library, preference or permission changes are made.
final class InstalledActivityAdapterTests: XCTestCase {
    private struct Fixture: Decodable {
        let appBundleID: String
        let windowTitle: String
        let adapter: String
        let documentURL: String?
        let documentUnavailable: Bool
    }

    private enum FixtureFailure: Error { case prerequisiteOrObservationMismatch }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else {
            XCTFail(message)
            throw FixtureFailure.prerequisiteOrObservationMismatch
        }
    }

    func testVisibleInstalledApplicationIsSearchableBeforeOCR() async throws {
        guard let path = ProcessInfo.processInfo.environment["RETRACE_INSTALLED_ADAPTER_FIXTURE"] else {
            throw XCTSkip("Requires a reviewed visible app fixture; see progressive-recall-validation.md")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try require(AXIsProcessTrusted(), "The test runner must already have Accessibility permission")
        try require(CGPreflightScreenCaptureAccess(), "The test runner must already have screen metadata permission")
        try require((fixture.documentURL != nil) != fixture.documentUnavailable,
                    "Fixture must declare exactly one expected document-identity state")
        if let url = fixture.documentURL {
            try require(CapturedURLPolicy.sanitize(url) != nil,
                        "Expected document URL must be supported by the capture privacy policy")
        }
        let source = ActivityContextSource.live
        let application = await source.frontmost()
        let app = try XCTUnwrap(application, "No frontmost application was available")
        try require(app.bundleID == fixture.appBundleID, "The reviewed application must remain frontmost")
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let sample = await source.window(app, true, .default)
        let base = try XCTUnwrap(sample, "The reviewed window was not safely observable")
        let enriched = await source.document(base, app)
        let context = enriched ?? base
        let after = await source.frontmost()
        try require(app == after, "Application changed while the native context was sampled")
        try require(context.windowTitle == fixture.windowTitle, "Observed title differs from the reviewed visible title")
        try require(context.adapter == fixture.adapter, "The native adapter differs from the reviewed application adapter")
        try require(context.windowGeneration != nil, "Missing observed window generation")
        let display = try XCTUnwrap(context.displayID)
        try require(display != 0, "Missing actual display identity")
        try require(CGDisplayIsActive(display) != 0, "Attribution must identify an actual active display")
        if let url = fixture.documentURL {
            try require(context.safeURL == CapturedURLPolicy.sanitize(url), "Visible document URL was not preserved safely")
            try require(context.documentID == CapturedURLPolicy.navigationIdentity(url), "Document identity does not match the reviewed document")
        }
        if fixture.documentUnavailable {
            try require(context.documentID == nil, "An unavailable document identity must remain explicit")
            try require(context.safeURL == nil, "A generic title must not manufacture a document URL")
        }
        try require(context.paneID == nil, "The current generic adapter does not establish pane identity")

        let nativeSampleMilliseconds = (ProcessInfo.processInfo.systemUptime - sampledAt) * 1000
        // Disk fixtures must never generate or modify the application's Keychain key.
        let defaults = UserDefaults(suiteName: "io.retrace.app") ?? .standard
        try require(defaults.object(forKey: "encryptionEnabled") as? Bool != true,
                    "Disk adapter acceptance requires encryption disabled; do not change the live setting for this test")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("InstalledAdapter-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = DatabaseManager(databasePath: root.appendingPathComponent("fixture.db").path)
        let monitor = ActivityMonitor(store: database, configuration: {
            let excluded = await MainActor.run {
                Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                    .subtracting([fixture.appBundleID])
            }
            return CaptureConfig(excludedAppBundleIDs: excluded)
        })
        do {
            try await database.initialize()
            await monitor.start()
            var rows: [PersistedActivityEvent] = []
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            repeat {
                let current = await source.frontmost()
                try require(current == app, "The reviewed application changed during native observer acceptance")
                let page = try await database.searchActivity(ActivityQuery(text: fixture.windowTitle,
                    appBundleIDs: [fixture.appBundleID]))
                rows = page.events.filter { $0.event.context?.windowTitle == fixture.windowTitle }
                if rows.contains(where: { $0.event.context?.documentID == context.documentID }) { break }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            await monitor.stop()
            try require(!rows.isEmpty, "Native activity must be searchable without OCR or a retained image")
            try require(rows.contains { $0.event.context?.documentID == context.documentID },
                          "The native observer must persist the reviewed document identity")
            let count = try await database.getFrameCount()
            try require(count == 0, "The activity trial must not capture or invent images")
            let latencies = rows.map { $0.persistedAt.timeIntervalSince($0.event.observedAt) * 1000 }.sorted()
            let receipt: [String: Any] = [
                "appBundleID": fixture.appBundleID, "adapter": context.adapter,
                "windowObserved": context.windowID != nil, "documentObserved": context.documentID != nil,
                "paneObserved": context.paneID != nil, "displayID": display,
                "matchingDurableEvents": rows.count, "imageCount": count,
                "nativeSampleMilliseconds": nativeSampleMilliseconds,
                "sampleAndTrialMilliseconds": (ProcessInfo.processInfo.systemUptime - sampledAt) * 1000,
                "observationToCommitWallClockMilliseconds": latencies
            ]
            let json = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            print("INSTALLED_ADAPTER_RECEIPT \(String(decoding: json, as: UTF8.self))")
            try await database.close()
        } catch {
            await monitor.stop()
            try? await database.close()
            throw error
        }
    }
}
