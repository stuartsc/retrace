import AppKit
import Database
import Foundation
import Shared
import XCTest
@testable import Capture

/// The native inputs are test-owned, windowless AppKit processes. Launching their
/// executable directly deliberately exercises Apple's documented nil launchDate.
final class ActivityApplicationIdentityTests: XCTestCase {
    func testDirectlyLaunchedNativeApplicationWithoutLaunchDateIsSupported() async throws {
        let fixture = try await makeFixture()
        let child = try await launch(fixture)
        try await MainActor.run {
            let app = try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid))
            XCTAssertEqual(app.bundleIdentifier, NativeApplicationFixture.bundleID)
            XCTAssertGreaterThan(app.processIdentifier, 0)
            XCTAssertFalse(app.isTerminated)
            XCTAssertFalse(app.isActive)
            XCTAssertEqual(app.activationPolicy, .prohibited)
            XCTAssertNil(app.launchDate, "The fixture must exercise the documented non-LaunchServices path")
            XCTAssertNotNil(ActivityApplicationSnapshot(app), "A valid native process must not lose context solely because LaunchServices has no launch date")
        }
    }

    func testRepeatedNativeHandlesRetainOneProcessGeneration() async throws {
        let fixture = try await makeFixture()
        let child = try await launch(fixture)
        let retained = try await MainActor.run { try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid)) }
        let first = try await MainActor.run { try XCTUnwrap(ActivityApplicationSnapshot(retained)) }
        for index in 0..<12 {
            // AppKit caches native properties within a main run-loop turn.
            // Resume a later turn to exercise the actual polling lifetime.
            try await Task.sleep(for: .milliseconds(20), clock: .continuous)
            try await MainActor.run {
                let fresh = try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid))
                XCTAssertNil(fresh.launchDate)
                XCTAssertEqual(fresh.bundleIdentifier, NativeApplicationFixture.bundleID)
                XCTAssertGreaterThan(fresh.processIdentifier, 0)
                XCTAssertFalse(fresh.isTerminated)
                XCTAssertTrue(retained.isEqual(fresh), "Native equality is the process-lifetime oracle")
                if index == 6 { ObservedWindowGenerations.shared.reset() }
                XCTAssertEqual(ActivityApplicationSnapshot(fresh)?.generation, first.generation)
                XCTAssertEqual(ActivityApplicationSnapshot(retained)?.generation, first.generation)
            }
        }
    }

    func testConcurrentInstancesOfTheSameBundleHaveDistinctGenerations() async throws {
        let fixture = try await makeFixture()
        let first = try await launch(fixture)
        let second = try await launch(fixture)
        try await MainActor.run {
            let firstApp = try XCTUnwrap(NSRunningApplication(processIdentifier: first.pid))
            let secondApp = try XCTUnwrap(NSRunningApplication(processIdentifier: second.pid))
            XCTAssertEqual(firstApp.bundleIdentifier, secondApp.bundleIdentifier)
            XCTAssertEqual(firstApp.executableURL, secondApp.executableURL)
            XCTAssertFalse(firstApp.isEqual(secondApp))
            let firstSnapshot = try XCTUnwrap(ActivityApplicationSnapshot(firstApp))
            let secondSnapshot = try XCTUnwrap(ActivityApplicationSnapshot(secondApp))
            XCTAssertNotEqual(firstSnapshot.generation, secondSnapshot.generation)
        }
    }

    func testTerminatedHandleIsRefusedAndRestartGetsNewGeneration() async throws {
        let fixture = try await makeFixture()
        let first = try await launch(fixture)
        let retained = try await MainActor.run { try XCTUnwrap(NSRunningApplication(processIdentifier: first.pid)) }
        let firstSnapshot = try await MainActor.run { try XCTUnwrap(ActivityApplicationSnapshot(retained)) }
        let stoppedStatus = await first.stop()
        XCTAssertEqual(stoppedStatus, 0)
        try await waitUntil { await MainActor.run { retained.isTerminated } }
        let second = try await launch(fixture)
        try await MainActor.run {
            XCTAssertNil(ActivityApplicationSnapshot(retained), "A saved native handle must not remain admissible after observed termination")
            let restarted = try XCTUnwrap(NSRunningApplication(processIdentifier: second.pid))
            XCTAssertFalse(retained.isEqual(restarted))
            let secondSnapshot = try XCTUnwrap(ActivityApplicationSnapshot(restarted))
            XCTAssertNotEqual(firstSnapshot.generation, secondSnapshot.generation)
        }
        // An actual stop/restart is exercised; the OS need not reuse the PID.
    }

    func testMissingNativeApplicationFailsClosed() async throws {
        await MainActor.run {
            XCTAssertNil(ActivityApplicationSnapshot(nil))
            XCTAssertNil(ActivityApplicationSnapshot(NSRunningApplication(processIdentifier: -1)))
        }
    }

    func testSmallCapacityEvictsOneNativeInstanceAndPreservesOtherLiveGenerations() async throws {
        let fixture = try await makeFixture()
        let children = try await [launch(fixture), launch(fixture), launch(fixture)]
        try await MainActor.run {
            let registry = ActivityApplicationIdentityRegistry(capacity: 2)
            let apps = try children.map { try XCTUnwrap(NSRunningApplication(processIdentifier: $0.pid)) }
            let first = try XCTUnwrap(ActivityApplicationSnapshot(apps[0], registry: registry))
            let evicted = try XCTUnwrap(ActivityApplicationSnapshot(apps[1], registry: registry))
            XCTAssertEqual(ActivityApplicationSnapshot(apps[0], registry: registry)?.generation, first.generation)
            XCTAssertNotNil(ActivityApplicationSnapshot(apps[2], registry: registry))
            XCTAssertEqual(ActivityApplicationSnapshot(apps[0], registry: registry)?.generation, first.generation)
            let returned = try XCTUnwrap(ActivityApplicationSnapshot(apps[1], registry: registry))
            XCTAssertNotEqual(returned.generation, evicted.generation, "An evicted lifetime may get a fresh token, never a reused token")
            XCTAssertEqual(ActivityApplicationSnapshot(apps[0], registry: registry)?.generation, first.generation,
                           "Evicting one entry must not reset every live process")
        }
    }

    func testRegistryRefusesInvalidOrChangedCapturedProcessIdentifier() async throws {
        let fixture = try await makeFixture()
        let child = try await launch(fixture)
        try await MainActor.run {
            let app = try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid))
            let registry = ActivityApplicationIdentityRegistry()
            XCTAssertNil(registry.generation(for: app, observedPID: 0))
            XCTAssertNil(registry.generation(for: app, observedPID: -1))
            XCTAssertNil(registry.generation(for: app, observedPID: child.pid + 1))
            XCTAssertNotNil(registry.generation(for: app, observedPID: child.pid))
        }
    }

    func testNativeFallbackAndMissingBundleDiagnosticsHaveFixedRoutesAndReasons() async throws {
        let fixture = try await makeFixture()
        let bundled = try await launch(fixture)
        let unbundled = try await launch(fixture, unbundled: true)
        try await MainActor.run {
            var emissions: [ActivityApplicationDiagnostic] = []
            let diagnostics = ActivityApplicationDiagnostics(emit: { emissions.append($0) })
            let valid = try XCTUnwrap(NSRunningApplication(processIdentifier: bundled.pid))
            let missingBundle = try XCTUnwrap(NSRunningApplication(processIdentifier: unbundled.pid))
            XCTAssertNil(missingBundle.bundleIdentifier, "Use the real unbundled native process, not a simulated property")
            XCTAssertNotNil(ActivityApplicationSnapshot(valid, route: .workspace, diagnostics: diagnostics))
            XCTAssertNil(ActivityApplicationSnapshot(missingBundle, route: .current, diagnostics: diagnostics))
            XCTAssertNil(ActivityApplicationSnapshot(nil, route: .ax, diagnostics: diagnostics))
            XCTAssertEqual(emissions.map(\.route), [.workspace, .current, .ax])
            XCTAssertEqual(emissions.map(\.reason), [.availableWithoutLaunchDate, .missingBundleIdentifier, .missingApplication])
            XCTAssertEqual(emissions.first?.message,
                "[Activity] Native application snapshot route=workspace reason=available-without-launch-date suppressed=none")
        }
    }

    func testTerminatedNativeHandleReportsTerminationWithoutAdmittingMetadata() async throws {
        let fixture = try await makeFixture()
        let child = try await launch(fixture)
        let retained = try await MainActor.run { try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid)) }
        let stoppedStatus = await child.stop()
        XCTAssertEqual(stoppedStatus, 0)
        try await waitUntil { await MainActor.run { retained.isTerminated } }
        await MainActor.run {
            var emissions: [ActivityApplicationDiagnostic] = []
            let diagnostics = ActivityApplicationDiagnostics(emit: { emissions.append($0) })
            XCTAssertNil(ActivityApplicationSnapshot(retained, route: .workspace, diagnostics: diagnostics))
            XCTAssertEqual(emissions.map(\.reason), [.terminatedApplication])
        }
    }

    func testDiagnosticsBoundRepeatedAndFlappingSignalsWithoutLosingFailureReasonCounts() async throws {
        await MainActor.run {
            var now = 0.0
            var emissions: [ActivityApplicationDiagnostic] = []
            let diagnostics = ActivityApplicationDiagnostics(minimumInterval: 30, now: { now }, emit: { emissions.append($0) })
            diagnostics.record(.available, route: .current)
            for _ in 0..<10_000 { diagnostics.record(.available, route: .current) }
            XCTAssertEqual(emissions.count, 1, "Repeated native reads must not create a log stream")
            for _ in 0..<1_000 {
                diagnostics.record(.missingApplication, route: .current)
                diagnostics.record(.available, route: .current)
            }
            XCTAssertEqual(emissions.count, 1, "Rapid route-local flapping must also be bounded")
            now = 29.999
            diagnostics.record(.available, route: .current)
            XCTAssertEqual(emissions.count, 1)
            now = 30
            diagnostics.record(.available, route: .current)
            XCTAssertEqual(emissions.count, 2, "A stable later sample must flush the suppressed transitions")
            XCTAssertEqual(emissions.last?.suppressedTransitions[.missingApplication], 1_000)
            XCTAssertEqual(emissions.last?.suppressedTransitions[.available], 1_000)
            XCTAssertTrue(emissions.last?.message.contains("missing-app:1000") == true)
            now = 60
            diagnostics.record(.invalidProcessIdentifier, route: .current)
            XCTAssertEqual(emissions.last?.reason, .invalidProcessIdentifier)
            XCTAssertEqual(emissions.last?.suppressedTransitions.count, 0)
            let stableCount = emissions.count
            now = 90
            diagnostics.record(.invalidProcessIdentifier, route: .current)
            XCTAssertEqual(emissions.count, stableCount, "A stable state without suppressed transitions needs no periodic log")
            diagnostics.record(.missingBundleIdentifier, route: .workspace)
            diagnostics.record(.terminatedApplication, route: .ax)
            XCTAssertEqual(emissions.suffix(2).map(\.route), [.workspace, .ax], "Independent routes must not overwrite each other's diagnostic state")
        }
    }

    func testHeldDiagnosticFileWriteDoesNotBlockNativeSnapshotsOrMainActor() async throws {
        let fixture = try await makeFixture()
        let child = try await launch(fixture)
        let writer = HeldNativeDiagnosticFileWriter(file: fixture.directory.appendingPathComponent("diagnostic.log"))
        addTeardownBlock { writer.release() }
        let (first, diagnostics) = try await MainActor.run {
            let diagnostics = ActivityApplicationDiagnostics(emit: {
                ActivityApplicationDiagnosticDelivery.enqueue($0, write: { writer.write($0) })
            })
            let app = try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid))
            let first = try XCTUnwrap(ActivityApplicationSnapshot(app, diagnostics: diagnostics))
            return (first, diagnostics)
        }
        await fulfillment(of: [writer.started], timeout: 10)
        XCTAssertFalse(writer.ranOnMain, "The real production delivery boundary must dispatch the potentially blocking writer off main")
        // In RED, report the incorrect thread without deliberately blocking it.
        guard !writer.ranOnMain else { return }
        let whileHeld = try await MainActor.run {
            let app = try XCTUnwrap(NSRunningApplication(processIdentifier: child.pid))
            return try XCTUnwrap(ActivityApplicationSnapshot(app, diagnostics: diagnostics))
        }
        XCTAssertEqual(whileHeld.generation, first.generation,
                       "Native snapshot work and this MainActor receipt must complete while the writer is held")
        let existsWhileHeld = await Task.detached { FileManager.default.fileExists(atPath: writer.file.path) }.value
        XCTAssertFalse(existsWhileHeld)
        writer.release()
        await fulfillment(of: [writer.finished], timeout: 10)
        XCTAssertNil(writer.failure)
        let contents = try await Task.detached { try String(contentsOf: writer.file, encoding: .utf8) }.value
        XCTAssertEqual(contents,
            "[Activity] Native application snapshot route=current reason=available-without-launch-date suppressed=none")
    }

    func testUnavailableWorkspaceNotificationDoesNotBorrowLaterCurrentNativeApplication() async throws {
        let fixture = try await makeFixture()
        let current = try await launch(fixture)
        let unavailable = await MainActor.run { NSRunningApplication(processIdentifier: -1) }
        try await assertUnavailableNotification(unavailable, current: current)
    }

    func testTerminatedWorkspaceNotificationDoesNotBorrowLaterCurrentNativeApplication() async throws {
        let fixture = try await makeFixture()
        let notified = try await launch(fixture)
        let retained = try await MainActor.run { try XCTUnwrap(NSRunningApplication(processIdentifier: notified.pid)) }
        let stoppedStatus = await notified.stop()
        XCTAssertEqual(stoppedStatus, 0)
        try await waitUntil { await MainActor.run { retained.isTerminated } }
        let current = try await launch(fixture)
        try await assertUnavailableNotification(retained, current: current)
    }

    func testNilReconciliationStillSamplesCurrentNativeApplicationWithFreshProvenance() async throws {
        let fixture = try await makeFixture()
        let current = try await launch(fixture)
        let (database, _, observations) = try await makeMonitor(current: current)
        let signal = ActivityObservationSignal(kind: .reconciliation, app: nil)
        observations.send(signal)
        try await waitUntil {
            try await database.searchActivity(ActivityQuery()).events.contains { $0.event.kind == .reconciliation }
        }
        let records = try await database.searchActivity(ActivityQuery()).events
        let sampled = try XCTUnwrap(records.first { $0.event.kind == .reconciliation })
        let native = try await MainActor.run {
            try XCTUnwrap(ActivityApplicationSnapshot(NSRunningApplication(processIdentifier: current.pid)))
        }
        XCTAssertEqual(sampled.event.context?.processGeneration, native.generation)
        XCTAssertEqual(sampled.event.context?.processID, native.pid)
        XCTAssertEqual(sampled.event.method, "two-second-reconciliation")
        XCTAssertGreaterThanOrEqual(sampled.event.observedAt, signal.wallTime)
        XCTAssertFalse(records.contains { $0.event.method == "workspace-app-notification" })
    }

    private func assertUnavailableNotification(_ notified: NSRunningApplication?,
                                              current: NativeApplicationChild) async throws {
        try await MainActor.run {
            XCTAssertNotNil(ActivityApplicationSnapshot(NSRunningApplication(processIdentifier: current.pid)))
        }
        let (database, _, observations) = try await makeMonitor(current: current)
        let notification = await MainActor.run {
            ActivityObservationSignal(kind: .focus, app: ActivityApplicationSnapshot(notified, route: .workspace))
        }
        XCTAssertNil(notification.app, "The native notified identity is unavailable before it enters the stream")
        observations.send(notification)
        observations.send(.init(kind: .pause, app: nil))
        try await waitUntil {
            try await database.searchActivity(ActivityQuery()).events.contains { $0.event.kind == .pause }
        }
        let records = try await database.searchActivity(ActivityQuery()).events
        XCTAssertFalse(records.contains { $0.event.method == "workspace-app-notification" },
                       "A later current application must never be attributed to the unavailable notification's observation time")
        let gap = try XCTUnwrap(records.first { $0.event.method == "notified-app-unavailable" })
        XCTAssertEqual(gap.event.kind, .gap)
        XCTAssertEqual(gap.event.coverage, .unknown)
        XCTAssertEqual(gap.event.observedAt, notification.wallTime)
        XCTAssertNil(gap.event.context)
    }

    private func makeMonitor(current: NativeApplicationChild) async throws
        -> (DatabaseManager, ActivityMonitor, ActivityObservationBuffer) {
        // In-memory SQLite also prevents global encryption preferences from
        // invoking the application's real Keychain path during this fixture.
        let database = DatabaseManager(databasePath: ":memory:")
        try await database.initialize()
        let pid = current.pid
        // Control only which test-owned native process the source reports. The
        // real native factory, stream and SQLite writer preserve its provenance.
        // No desktop window or AX contents are needed for app-level attribution.
        let source = ActivityContextSource(
            frontmost: { await MainActor.run { ActivityApplicationSnapshot(NSRunningApplication(processIdentifier: pid)) } },
            window: { app, _, config in AppInfoProvider().activityContext(for: app, isStillFocused: false, config: config) },
            document: { _, _ in nil }, permission: { true })
        let monitor = ActivityMonitor(store: database, configuration: { CaptureConfig() }, source: source)
        let observations = ActivityObservationBuffer()
        addTeardownBlock { await monitor.stop(); try await database.close() }
        await monitor.start(observations: observations)
        return (database, monitor, observations)
    }

    private func makeFixture() async throws -> NativeApplicationFixture {
        let fixture = try await NativeApplicationFixture.make()
        addTeardownBlock { await fixture.remove() }
        return fixture
    }

    private func launch(_ fixture: NativeApplicationFixture, unbundled: Bool = false) async throws -> NativeApplicationChild {
        let child = try await fixture.launch(unbundled: unbundled)
        addTeardownBlock {
            let status = await child.stop()
            XCTAssertEqual(status, 0, "The owned helper must exit normally; a watchdog termination is a fixture failure")
        }
        try await waitUntil { await MainActor.run { NSRunningApplication(processIdentifier: child.pid) != nil } }
        return child
    }

    private func waitUntil(_ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while try await !predicate() {
            guard ContinuousClock.now < deadline else { throw NativeApplicationFixture.Failure.timeout }
            try await Task.sleep(for: .milliseconds(10), clock: .continuous)
        }
    }
}

private struct NativeApplicationFixture: Sendable {
    static let bundleID = "com.retrace.fixture.native-identity"
    let directory: URL
    let executable: URL

    enum Failure: Error { case timeout, compilerFailed, helperNotReady }

    static func make() async throws -> Self {
        try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityNativeIdentity-\(UUID())")
            let contents = directory.appendingPathComponent("IdentityFixture.app/Contents")
            let executable = contents.appendingPathComponent("MacOS/IdentityFixture")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                let info: [String: Any] = ["CFBundleIdentifier": bundleID,
                    "CFBundleExecutable": "IdentityFixture", "CFBundlePackageType": "APPL",
                    "LSUIElement": true, "LSBackgroundOnly": true]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                let source = directory.appendingPathComponent("IdentityFixture.m")
                try helperSource.write(to: source, atomically: true, encoding: .utf8)
                let compiler = Process()
                compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                compiler.arguments = ["clang", "-fobjc-arc", "-framework", "AppKit", source.path, "-o", executable.path]
                try compiler.run()
                terminateIfStillRunning(compiler, after: 45)
                compiler.waitUntilExit()
                guard compiler.terminationStatus == 0 else { throw Failure.compilerFailed }
                return Self(directory: directory, executable: executable)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    func launch(unbundled: Bool) async throws -> NativeApplicationChild {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let input = Pipe(), output = Pipe()
            let (termination, completion) = AsyncStream<Void>.makeStream()
            process.terminationHandler = { _ in completion.finish() }
            if unbundled {
                let copy = directory.appendingPathComponent("UnbundledFixture")
                try FileManager.default.copyItem(at: executable, to: copy)
                process.executableURL = copy
            } else {
                process.executableURL = executable
            }
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            // A broken native fixture cannot leave a subprocess or blocked pipe
            // behind indefinitely. This deadline only controls our own helper.
            Self.terminateIfStillRunning(process, after: 30)
            let ready = output.fileHandleForReading.readData(ofLength: 1)
            guard ready == Data([82]) else {
                if process.isRunning { process.terminate() }
                for await _ in termination {}
                throw Failure.helperNotReady
            }
            return NativeApplicationChild(process: process, input: input, termination: termination)
        }.value
    }

    func remove() async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }.value
    }

    private static func terminateIfStillRunning(_ process: Process, after seconds: Double) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
    }

    private static let helperSource = #"""
    #import <AppKit/AppKit.h>
    #import <unistd.h>
    @interface FixtureDelegate : NSObject <NSApplicationDelegate> @end
    @implementation FixtureDelegate
    - (void)applicationDidFinishLaunching:(NSNotification *)note {
        fputs("R", stdout); fflush(stdout);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char value; read(STDIN_FILENO, &value, 1);
            dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
        });
    }
    @end
    int main(void) {
        @autoreleasepool {
            NSApplication *app = NSApplication.sharedApplication;
            [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
            FixtureDelegate *delegate = [FixtureDelegate new];
            app.delegate = delegate;
            [app run];
        }
        return 0;
    }
    """#
}

private actor NativeApplicationChild {
    nonisolated let pid: Int32
    private let process: Process
    private let input: Pipe
    private let termination: AsyncStream<Void>
    private var stopTask: Task<Int32, Never>?

    init(process: Process, input: Pipe, termination: AsyncStream<Void>) {
        self.process = process; self.input = input; self.termination = termination; pid = process.processIdentifier
    }

    func stop() async -> Int32 {
        if let stopTask { return await stopTask.value }
        let input = self.input, process = self.process, termination = self.termination
        let task = Task.detached(priority: .utility) {
            try? input.fileHandleForWriting.close()
            for await _ in termination {}
            return process.terminationStatus
        }
        stopTask = task
        return await task.value
    }
}

/// Only the final potentially blocking writer is controlled; production delivery
/// and native snapshot admission run unchanged. All I/O belongs to this fixture.
private final class HeldNativeDiagnosticFileWriter: @unchecked Sendable {
    let file: URL
    let started = XCTestExpectation(description: "diagnostic writer entered")
    let finished = XCTestExpectation(description: "diagnostic file write completed")
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observedMainThread = false
    private var writeFailure: String?

    init(file: URL) { self.file = file }

    var ranOnMain: Bool { lock.withLock { observedMainThread } }
    var failure: String? { lock.withLock { writeFailure } }
    func release() { gate.signal() }

    func write(_ diagnostic: ActivityApplicationDiagnostic) {
        let onMain = Thread.isMainThread
        lock.withLock { observedMainThread = onMain }
        started.fulfill()
        defer { finished.fulfill() }
        guard !onMain else { return }
        guard gate.wait(timeout: .now() + 10) == .success else {
            lock.withLock { writeFailure = "The test did not release its held file writer" }
            return
        }
        do { try Data(diagnostic.message.utf8).write(to: file, options: .atomic) }
        catch { lock.withLock { writeFailure = String(describing: error) } }
    }
}
