import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Shared
import XCTest
@testable import Capture

/// These tests own every application/window whose text or pixels they read.
/// Permission checks never request grants. The fixture uses actual AppKit text,
/// secure, scrolling and overlapping windows and actual AXObserver delivery.
final class CaptureVisibleTextTests: XCTestCase {
    private func makeFixture() async throws -> NativeCaptureTextFixture {
        let fixture = try await NativeCaptureTextFixture.launch()
        addTeardownBlock { await fixture.stop() }
        return fixture
    }

    func testOwnedFixtureRepeatedStopJoinsThePrelaunchNativeTerminationReceipt() async throws {
        let fixture = try await makeFixture()
        async let first: Void = fixture.stop()
        async let second: Void = fixture.stop()
        _ = await (first, second)
        let receipt = try XCTUnwrap(fixture.terminationReceipt)
        XCTAssertEqual(receipt.status, 0)
        XCTAssertFalse(receipt.wasSignalled)
        XCTAssertFalse(fixture.process.isRunning)
        await fixture.stop() // Completed cleanup must not wait on Foundation again.
    }

    func testVisibleNativeTextKeepsExactUnicodeAndExcludesSecureHiddenAndOffscreenText() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof,
            context: context, enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                try await fixture.capture(displayID: context.displayID!)
            }
        let result = try XCTUnwrap(captured)
        let observation = try XCTUnwrap(result.captureText)
        XCTAssertFalse(observation.runs.isEmpty, "Owned NSTextView must provide supported visible ranges")
        XCTAssertEqual(observation.consistency, .sameWindowBracketed)
        let text = observation.runs.map(\.text).joined()
        XCTAssertTrue(text.contains("Visible e\u{301} 😀 token 7319"))
        XCTAssertFalse(text.contains("SECURE_NEVER_RETAIN"))
        XCTAssertFalse(text.contains("HIDDEN_NEVER_RETAIN"))
        XCTAssertFalse(text.contains("OFFSCREEN_NEVER_RETAIN"))
        XCTAssertEqual(observation.captureAttemptID, result.pixelReceipt.attemptID)
        XCTAssertEqual(observation.pixelRead, result.pixelReceipt.interval)
        XCTAssertNoThrow(try observation.retainedTextEncoding(frameWidth: result.image.width,
            frameHeight: result.image.height, displayID: context.displayID!,
            frameTimestamp: result.pixelReceipt.interval.startedAt,
            frameMonotonicTime: result.pixelReceipt.interval.startedUptime,
            pixelReceipt: result.pixelReceipt, sourceContext: context))
    }

    func testNativeTerminalVisibleLineIsRetainedWithAndWithoutATrailingNewline() async throws {
        let fixture = try await makeFixture()
        for command in ["terminal-line", "terminal-line-newline"] {
            try await fixture.command(command)
            let context = try await fixture.context()
            let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
                includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
            let captured = try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
                enabled: true, backend: .screenCaptureKitCandidate,
                diagnostic: nativeTextDiagnostic(for: #function + ":" + command)) {
                    try await fixture.capture(displayID: context.displayID!)
                }
            let observation = try XCTUnwrap(captured?.captureText)
            XCTAssertFalse(observation.runs.isEmpty, "Actual native terminal line was discarded")
            XCTAssertTrue(observation.runs.map(\.text).joined().contains("FINAL_NATIVE_1847"))
            XCTAssertEqual(observation.consistency, .sameWindowBracketed)
        }
    }

    func testNativeLineQueryErrorInsideVisibleTextIsNotTreatedAsSuccessfulEndOfText() async throws {
        let fixture = try await makeFixture()
        try await fixture.command("invalid-line-query")
        let context = try await fixture.context()
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                try await fixture.capture(displayID: context.displayID!)
            }
        XCTAssertEqual(captured?.captureText?.availability, .unavailable)
        XCTAssertEqual(captured?.captureText?.runs.count, 0)
        XCTAssertTrue(captured?.captureText?.reasons.contains(.visibilityUnverified) == true)
    }

    func testNativeNotificationABATextChangeCannotPassIdenticalPostRead() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        for command in ["aba", "ancestor-aba"] {
        let notifications = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { notifications.continuation.finish() }
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof,
            context: context, enabled: true, backend: .screenCaptureKitCandidate,
            diagnostic: nativeTextDiagnostic(for: #function + ":" + command), observedMutation: { notifications.continuation.yield(()) }) {
                try await fixture.command(command)
                // Wait for the real AXObserver callback, not a timing guess.
                try await awaitOwnedMutation(notifications.stream)
                return try await fixture.capture(displayID: context.displayID!)
            }
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.captureText?.availability, .unavailable)
        XCTAssertEqual(result.captureText?.runs.count, 0)
        XCTAssertTrue(result.captureText?.reasons.contains(.textChanged) == true, command)
        }
    }

    func testDuplicateWindowGeometryAndTitleRefusesIdentityBeforeReadingText() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        try await fixture.command("duplicate")
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof,
            context: context, enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                try await fixture.capture(displayID: context.displayID!)
            }
        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result.captureText?.availability, .unavailable)
        XCTAssertTrue(result.captureText?.reasons.contains(.windowIdentityUnproved) == true)
        XCTAssertTrue(result.captureText?.runs.isEmpty == true)
    }

    func testHiddenNativeSiblingBecomingVisibleInvalidatesTextAwayFromHitTestPoints() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        try await fixture.command("install-overlay")
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof,
            context: context, enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                try await fixture.command("show-overlay")
                return try await fixture.capture(displayID: context.displayID!)
            }
        XCTAssertEqual(captured?.captureText?.availability, .unavailable)
        XCTAssertEqual(captured?.captureText?.runs.count, 0)
    }

    func testWholeRunBoundsRejectOcclusionAndPixelPolicyOmission() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        try await fixture.command("occlude")
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof,
            context: context, enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                try await fixture.capture(displayID: context.displayID!)
            }
        let result = try XCTUnwrap(captured)
        XCTAssertFalse(result.captureText?.runs.map(\.text).joined().contains("Visible e\u{301}") == true)
        let omitted = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [], privacyMaskBounds: []))
        let denied = try await CaptureVisibleTextReader.readImage(proof: omitted,
            context: context, enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                try await fixture.capture(displayID: context.displayID!)
            }
        let unavailable = try XCTUnwrap(denied)
        XCTAssertEqual(unavailable.captureText?.runs.count, 0)
        XCTAssertTrue(unavailable.captureText?.reasons.contains(.privacyMasked) == true)
    }

    func testScrollingUsesElementLocalUTF16RangesAndRejectsHorizontallyClippedText() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        try await fixture.command("scroll")
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let scrolled = try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { try await fixture.capture(displayID: context.displayID!) }
        let observation = try XCTUnwrap(scrolled?.captureText)
        XCTAssertTrue(observation.runs.map(\.text).joined().contains("LAST_VISIBLE_9041"))
        XCTAssertFalse(observation.runs.map(\.text).joined().contains("Visible e\u{301}"))
        XCTAssertTrue(observation.runs.allSatisfy { $0.elementUTF16Range.location > 0 })
        try await fixture.command("horizontal")
        let clippedProof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let clipped = try await CaptureVisibleTextReader.readImage(proof: clippedProof, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { try await fixture.capture(displayID: context.displayID!) }
        XCTAssertFalse(clipped?.captureText?.runs.map(\.text).joined().contains("HORIZONTAL_HIDDEN") == true)
    }

    func testAnIncompleteLargeNativeVisibilityTreeDoesNotReturnEarlierText() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        try await fixture.command("large")
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { try await fixture.capture(displayID: context.displayID!) }
        XCTAssertEqual(captured?.captureText?.availability, .unavailable)
        XCTAssertEqual(captured?.captureText?.runs.count, 0)
        XCTAssertTrue(captured?.captureText?.reasons.contains(.budgetExceeded) == true)
    }

    func testSlowNativeTextReplyFailsClosedAndJoinsTheReader() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        try await fixture.command("slow-text")
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let captured = try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { try await fixture.capture(displayID: context.displayID!) }
        XCTAssertEqual(captured?.captureText?.availability, .unavailable)
        XCTAssertEqual(captured?.captureText?.runs.count, 0)
        XCTAssertTrue(captured?.captureText?.reasons.contains(where: {
            $0 == .visibilityUnverified || $0 == .budgetExceeded
        }) == true)
        XCTAssertEqual(CaptureVisibleTextReader.activeNativeReaderCount, 0)
    }

    func testCancelledPixelReadJoinsNativeObserverAndCannotPublishText() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: context.displayID!,
            includedWindowIDs: [context.windowID!], privacyMaskBounds: []))
        let began = expectation(description: "actual native pre-read completed")
        let read = Task {
            try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
                enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) {
                    began.fulfill()
                    try await Task.sleep(for: .seconds(2), clock: .continuous)
                    return try await fixture.capture(displayID: context.displayID!)
                }
        }
        await fulfillment(of: [began], timeout: 10)
        XCTAssertEqual(CaptureVisibleTextReader.activeNativeReaderCount, 1,
                       "Exercise cancellation of a successfully prepared native observer")
        read.cancel()
        do { _ = try await read.value; XCTFail("Cancellation must not finish as captured text") }
        catch is CancellationError { }
        XCTAssertEqual(CaptureVisibleTextReader.activeNativeReaderCount, 0)
        // A retired native registration must not observe the next mutation.
        try await fixture.command("aba")
        XCTAssertEqual(CaptureVisibleTextReader.activeNativeReaderCount, 0)
    }

    func testSequencerUsesTheActualPixelStartAndPreservesItsReceiptThroughLinking() async throws {
        let image = try fixtureRaster()
        let context = captureTestContext()
        let captured = try await CaptureSnapshotSequencer.captureAttributed(displayID: 42,
            readContext: { CapturedWindowSample(context: context, privacySignature: "owned-raster") }) { _ in
                let actual = await CaptureVisibleTextReader.readImage(proof: nil, context: nil,
                    enabled: false, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { image }
                let read = try XCTUnwrap(actual)
                return CaptureAttributedPixelRead(frame: try rasterFrame(read.image),
                    pixelReceipt: read.pixelReceipt, captureText: read.captureText)
            }
        let frame = try XCTUnwrap(captured)
        let receipt = try XCTUnwrap(frame.metadata.pixelReceipt)
        XCTAssertEqual(frame.timestamp, receipt.interval.startedAt)
        XCTAssertEqual(frame.metadata.captureMonotonicTime, receipt.interval.startedUptime)
        XCTAssertEqual(frame.metadata.linkingActivity(nil).pixelReceipt, receipt)
        XCTAssertEqual(frame.width, image.width)
        XCTAssertEqual(frame.height, image.height)
    }

    func testPriorNativeTextCannotAttachToALaterNativePixelAttempt() async throws {
        let fixture = try await makeFixture()
        let context = try await fixture.context()
        let display = try XCTUnwrap(context.displayID)
        let proof = try XCTUnwrap(CaptureTextPixelProof.copy(displayID: display,
            includedWindowIDs: [try XCTUnwrap(context.windowID)], privacyMaskBounds: []))
        let prior = try await CaptureVisibleTextReader.readImage(proof: proof, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { try await fixture.capture(displayID: display) }
        let previous = try XCTUnwrap(prior)
        XCTAssertFalse(previous.captureText?.runs.isEmpty ?? true, "Require a real admitted native observation")
        let next = try await CaptureSnapshotSequencer.captureAttributed(displayID: display,
            readContext: { CapturedWindowSample(context: context, privacySignature: "owned-native-window") }) { _ in
                let actual = try await CaptureVisibleTextReader.readImage(proof: nil, context: nil,
                    enabled: false, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { try await fixture.capture(displayID: display) }
                let read = try XCTUnwrap(actual)
                return CaptureAttributedPixelRead(frame: try rasterFrame(read.image),
                    pixelReceipt: read.pixelReceipt, captureText: previous.captureText)
            }
        let frame = try XCTUnwrap(next)
        XCTAssertNotEqual(frame.metadata.pixelReceipt?.attemptID, previous.pixelReceipt.attemptID)
        XCTAssertEqual(frame.metadata.captureText?.availability, .unavailable)
        XCTAssertEqual(frame.metadata.captureText?.runs.count, 0)
        XCTAssertTrue(frame.metadata.captureText?.reasons.contains(.sourceChanged) == true)
        XCTAssertNoThrow(try frame.metadata.captureText?.retainedTextEncoding(frameWidth: frame.width,
            frameHeight: frame.height, displayID: display, frameTimestamp: frame.timestamp,
            frameMonotonicTime: frame.metadata.captureMonotonicTime, pixelReceipt: frame.metadata.pixelReceipt,
            sourceContext: frame.metadata.captureContext))
    }

    func testUnavailableWindowProofRetainsSafePixelsWithAValidUnavailableObservation() async throws {
        let image = try fixtureRaster()
        let context = captureTestContext(generation: nil)
        let captured = await CaptureVisibleTextReader.readImage(proof: nil, context: context,
            enabled: true, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { image }
        let read = try XCTUnwrap(captured)
        let unavailable = try XCTUnwrap(read.captureText)
        XCTAssertEqual(unavailable.availability, .unavailable)
        XCTAssertTrue(unavailable.runs.isEmpty)
        XCTAssertNil(unavailable.sourceContext)
        XCTAssertNoThrow(try unavailable.retainedTextEncoding(frameWidth: image.width, frameHeight: image.height,
            displayID: 42, frameTimestamp: read.pixelReceipt.interval.startedAt,
            frameMonotonicTime: read.pixelReceipt.interval.startedUptime, pixelReceipt: read.pixelReceipt,
            sourceContext: context))
        XCTAssertEqual(CaptureVisibleTextReader.activeNativeReaderCount, 0)
    }

    func testDisabledTextKeepsExactPixelReceiptWithoutStartingNativeReader() async throws {
        let image = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let firstRead = await CaptureVisibleTextReader.readImage(proof: nil, context: nil,
            enabled: false, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { image }
        let first = try XCTUnwrap(firstRead)
        let secondRead = await CaptureVisibleTextReader.readImage(proof: nil, context: nil,
            enabled: false, backend: .screenCaptureKitCandidate, diagnostic: nativeTextDiagnostic(for: #function)) { image }
        let second = try XCTUnwrap(secondRead)
        XCTAssertNil(first.captureText)
        XCTAssertNotEqual(first.pixelReceipt.attemptID, second.pixelReceipt.attemptID)
        XCTAssertLessThanOrEqual(first.pixelReceipt.interval.startedUptime, first.pixelReceipt.interval.endedUptime)
        XCTAssertEqual(CaptureVisibleTextReader.activeNativeReaderCount, 0)
    }
}

private func fixtureRaster() throws -> CGImage {
    let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
        bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return try XCTUnwrap(context.makeImage())
}

private func rasterFrame(_ image: CGImage) throws -> CapturedFrame {
    let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return CapturedFrame(timestamp: Date(),
        imageData: Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4),
        width: image.width, height: image.height, bytesPerRow: image.width * 4, metadata: .empty)
}

private func awaitOwnedMutation(_ events: AsyncStream<Void>) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            var iterator = events.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(2), clock: .continuous)
            throw NSError(domain: "RetraceOwnedCaptureFixture", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Native AX mutation callback was not observed before the fixture deadline"])
        }
        defer { group.cancelAll() }
        _ = try await group.next()
    }
}

/// Registered before Process.run, including the fast-exit case. Its callback
/// stores only a terminal receipt and never touches XCTest, files or the fixture.
private final class NativeCaptureTextExit: @unchecked Sendable {
    struct Receipt: Sendable {
        let status: Int32
        let wasSignalled: Bool
    }
    private let lock = NSLock()
    private var receipt: Receipt?

    func record(_ process: Process) {
        let value = Receipt(status: process.terminationStatus,
            wasSignalled: process.terminationReason == .uncaughtSignal)
        lock.withLock { receipt = value }
    }

    var snapshot: Receipt? { lock.withLock { receipt } }

    func wait(for duration: Duration) async -> Receipt? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if let value = snapshot { return value }
            do { try await Task.sleep(for: .milliseconds(20), clock: .continuous) }
            catch { return snapshot }
        }
        return snapshot
    }

    /// Only the private compiler/helper launched by this fixture may be signalled.
    /// A missing callback remains a test failure, never an unbounded Foundation wait.
    func finishOwned(_ process: Process) async -> Receipt? {
        if let value = await wait(for: .seconds(2)) { return value }
        if process.isRunning { process.terminate() }
        if let value = await wait(for: .seconds(2)) { return value }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return await wait(for: .seconds(2))
    }
}

private final class NativeCaptureTextFixture: @unchecked Sendable {
    private struct Ready: Sendable {
        let pid: Int32
        let windowID: UInt32
        let isVisible: Bool
    }
    let process: Process
    let directory: URL
    private let input: FileHandle
    private let output: FileHandle
    private let exit: NativeCaptureTextExit
    // Written once before launch publishes this instance.
    private var ready: Ready?
    private let commandQueue = DispatchQueue(label: "retrace.tests.capture-text-fixture")
    private let lifecycleLock = NSLock()
    private var stopTask: Task<Void, Never>?
    private init(process: Process, directory: URL, input: FileHandle, output: FileHandle,
                 exit: NativeCaptureTextExit) {
        self.process = process; self.directory = directory; self.input = input; self.output = output
        self.exit = exit
    }

    var terminationReceipt: NativeCaptureTextExit.Receipt? { exit.snapshot }

    static func launch() async throws -> NativeCaptureTextFixture {
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Native AX fixture needs already-granted Accessibility and Screen Recording; no prompt is made")
        }
        return try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-ax-text-\(UUID())")
            var keepDirectory = false
            defer { if !keepDirectory { try? FileManager.default.removeItem(at: directory) } }
            let bundle = directory.appendingPathComponent("VisibleTextFixture.app/Contents")
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let executable = bundle.appendingPathComponent("MacOS/VisibleTextFixture")
            let source = directory.appendingPathComponent("VisibleTextFixture.m")
            try nativeCaptureTextFixtureSource.write(to: source, atomically: true, encoding: .utf8)
            try """
                <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
                <key>CFBundleIdentifier</key><string>io.retrace.tests.visible-text</string>
                <key>CFBundleExecutable</key><string>VisibleTextFixture</string>
                <key>CFBundleName</key><string>VisibleTextFixture</string>
                <key>LSUIElement</key><true/></dict></plist>
                """.write(to: bundle.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            let compile = Process(); compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compile.arguments = ["-fobjc-arc", "-framework", "AppKit", source.path, "-o", executable.path]
            let compileExit = NativeCaptureTextExit()
            compile.terminationHandler = { compileExit.record($0) }
            try compile.run()
            guard let compiled = await compileExit.wait(for: .seconds(30)) else {
                let stopped = await compileExit.finishOwned(compile)
                keepDirectory = stopped == nil && compile.isRunning
                throw CocoaError(.executableNotLoadable)
            }
            compile.terminationHandler = nil
            guard compiled.status == 0, !compiled.wasSignalled else { throw CocoaError(.executableNotLoadable) }
            let process = Process(); process.executableURL = executable
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
            let exit = NativeCaptureTextExit()
            process.terminationHandler = { exit.record($0) }
            try process.run()
            let fixture = NativeCaptureTextFixture(process: process, directory: directory,
                input: input.fileHandleForWriting, output: output.fileHandleForReading, exit: exit)
            // The fixture now owns cleanup, including startup failure. Keep the
            // private tree if native termination itself cannot be confirmed.
            keepDirectory = true
            do {
                let reply = try fixture.readReply().split(separator: " ", omittingEmptySubsequences: false)
                guard reply.count == 4, reply[0] == "READY",
                      let pid = Int32(reply[1]), pid == process.processIdentifier,
                      let windowID = UInt32(reply[2]), windowID > 0,
                      reply[3] == "0" || reply[3] == "1" else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                fixture.ready = Ready(pid: pid, windowID: windowID, isVisible: reply[3] == "1")
            } catch { await fixture.stop(); throw error }
            return fixture
        }.value
    }

    func command(_ command: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            // Registration and stop are ordered before entering the pipe queue.
            let accepted = lifecycleLock.withLock {
                guard stopTask == nil else { return false }
                commandQueue.async {
                    do {
                        try self.input.write(contentsOf: Data((command + "\n").utf8))
                        guard try self.readReply() == "ACK" else { throw CocoaError(.fileReadCorruptFile) }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
                return true
            }
            if !accepted { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func readReply() throws -> String {
        // poll bounds native-helper failure; never blocks MainActor. The helper
        // returns fixed ACKs only, never a captured text dump.
        var line = Data()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline, line.count < 128 {
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) >= 0 else { throw CocoaError(.fileReadUnknown) }
            if descriptor.revents & Int16(POLLIN) != 0 {
                guard let next = try output.read(upToCount: 1), !next.isEmpty else { throw CocoaError(.fileReadUnknown) }
                if next == Data([10]) {
                    guard let reply = String(data: line, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                    return reply
                }
                line.append(next)
            } else if descriptor.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw CocoaError(.fileReadUnknown)
            }
        }
        throw CocoaError(.fileReadUnknown)
    }

    func context() async throws -> ActivityContext {
        guard process.isRunning, exit.snapshot == nil else { throw CocoaError(.executableNotLoadable) }
        let ready = try XCTUnwrap(ready)
        let app = try await MainActor.run {
            try XCTUnwrap(ActivityApplicationSnapshot(NSRunningApplication(processIdentifier: self.process.processIdentifier)))
        }
        return try await Task.detached {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            var present = false, onscreen = false, titleMatches = false, opaque = false, normalLayer = false
            var stableBounds: CGRect?, stableDisplay: UInt32?
            var stableSince: ContinuousClock.Instant?
            var activeDisplayCount: UInt32 = 0
            repeat {
                guard self.process.isRunning, self.exit.snapshot == nil else { throw CocoaError(.executableNotLoadable) }
                // Query only the exact window ID acknowledged by our helper.
                // READY is AppKit readiness; WindowServer publication is separate.
                let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, ready.windowID) as? [[String: Any]] ?? []
                let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ready.pid &&
                    ($0[kCGWindowNumber as String] as? UInt32) == ready.windowID }
                present = owned.count == 1
                let window = owned.count == 1 ? owned[0] : [:]
                onscreen = window[kCGWindowIsOnscreen as String] as? Bool == true
                titleMatches = window[kCGWindowName as String] as? String == "Retrace owned text fixture"
                opaque = window[kCGWindowAlpha as String] as? Double == 1
                normalLayer = window[kCGWindowLayer as String] as? Int == 0
                var displays = [UInt32](repeating: 0, count: 64)
                activeDisplayCount = 0
                let displayStatus = CGGetActiveDisplayList(64, &displays, &activeDisplayCount)
                if present, onscreen, titleMatches, opaque, normalLayer, displayStatus == .success,
                   let raw = window[kCGWindowBounds as String] as? [String: Any],
                   let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                   bounds.minX.isFinite, bounds.minY.isFinite,
                   bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                   let display = displays.prefix(Int(activeDisplayCount)).first(where: { CGDisplayBounds($0).contains(bounds) }) {
                    if stableBounds == bounds, stableDisplay == display, let stableSince,
                       stableSince.duration(to: clock.now) >= .milliseconds(75) {
                        return ActivityContext(appBundleID: app.bundleID, appName: app.name, processID: app.pid,
                            processGeneration: app.generation, windowID: ready.windowID, windowGeneration: UUID().uuidString,
                            windowTitle: "Retrace owned text fixture", displayID: display, adapter: "native-owned-test-v1")
                    }
                    if stableBounds != bounds || stableDisplay != display || stableSince == nil {
                        stableBounds = bounds; stableDisplay = display; stableSince = clock.now
                    }
                } else { stableBounds = nil; stableDisplay = nil; stableSince = nil }
                try await Task.sleep(for: .milliseconds(25), clock: .continuous)
            } while clock.now < deadline
            // A locked/asleep/unavailable graphical session is not a permission
            // diagnosis or a reason to silently skip a failed native fixture.
            throw NSError(domain: "RetraceOwnedCaptureFixture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Owned window unavailable: pid=\(ready.pid) windowID=\(ready.windowID) readyVisible=\(ready.isVisible) " +
                "present=\(present) onscreen=\(onscreen) titleMatches=\(titleMatches) opaque=\(opaque) " +
                "normalLayer=\(normalLayer) stable=\(stableSince != nil) activeDisplayCount=\(activeDisplayCount)"])
        }.value
    }

    func capture(displayID: UInt32) async throws -> CGImage? {
        guard process.isRunning, exit.snapshot == nil else { throw CocoaError(.executableNotLoadable) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard process.isRunning, exit.snapshot == nil else { throw CocoaError(.executableNotLoadable) }
        let display = try XCTUnwrap(content.displays.first { $0.displayID == displayID })
        let windowID = try XCTUnwrap(ready?.windowID)
        let owned = content.windows.filter { $0.windowID == windowID &&
            $0.owningApplication?.processID == process.processIdentifier &&
            $0.title == "Retrace owned text fixture" }
        XCTAssertFalse(owned.isEmpty)
        let configuration = SCStreamConfiguration()
        configuration.width = CGDisplayPixelsWide(displayID); configuration.height = CGDisplayPixelsHigh(displayID)
        configuration.captureResolution = .best; configuration.includeChildWindows = false
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, including: owned),
            configuration: configuration)
    }

    func stop() async {
        await owningStop().value
    }

    private func owningStop() -> Task<Void, Never> {
        lifecycleLock.withLock {
            if let stopTask { return stopTask }
            let task = Task.detached(priority: .utility) { [self] in
                // Drain any already-owned bounded command before closing its pipe.
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    commandQueue.async { [self] in
                        if exit.snapshot == nil, process.isRunning {
                            try? input.write(contentsOf: Data("stop\n".utf8))
                        }
                        continuation.resume()
                    }
                }
                if let receipt = await exit.finishOwned(process) {
                    XCTAssertEqual(receipt.status, 0, "Owned AppKit helper must terminate normally")
                    XCTAssertFalse(receipt.wasSignalled, "Forced native teardown is a fixture failure")
                    process.terminationHandler = nil
                } else {
                    XCTFail("Owned helper termination ACK missing after bounded cleanup; running=\(process.isRunning)")
                }
                if exit.snapshot != nil || !process.isRunning {
                    try? input.close(); try? output.close()
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            stopTask = task
            return task
        }
    }

}

// BEGIN OWNED APPKIT FIXTURE
private let nativeCaptureTextFixtureSource = #"""
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <unistd.h>
@interface FixtureWindow : NSWindow
@property NSArray *forcedChildren;
@end
@implementation FixtureWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (NSArray *)accessibilityChildren { return self.forcedChildren ?: [super accessibilityChildren]; }
@end
@interface FixtureHiddenOverlay : NSView @end
@implementation FixtureHiddenOverlay
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole { return NSAccessibilityButtonRole; }
- (id)accessibilityParent { return self.window; }
- (NSArray *)accessibilityAttributeNames {
    return [[super accessibilityAttributeNames] arrayByAddingObject:@"AXHidden"];
}
- (id)accessibilityAttributeValue:(NSString *)attribute {
    if ([attribute isEqualToString:@"AXHidden"]) return @(self.hidden);
    return [super accessibilityAttributeValue:attribute];
}
- (void)drawRect:(NSRect)rect { [NSColor.blackColor setFill]; NSRectFill(self.bounds); }
@end
@interface FixtureTextView : NSTextView
@property BOOL slowAX;
@property BOOL invalidLineQuery;
@end
@implementation FixtureTextView
- (NSRange)accessibilityRangeForLine:(NSInteger)line {
    if (self.invalidLineQuery) return NSMakeRange(NSNotFound, 0);
    return [super accessibilityRangeForLine:line];
}
- (NSString *)accessibilityStringForRange:(NSRange)range {
    // Controlled hostile native provider; production never sleeps its reader.
    if (self.slowAX) usleep(100000);
    return [super accessibilityStringForRange:range];
}
@end
@interface Fixture : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property NSWindow *other;
@property FixtureTextView *text;
@property NSScrollView *scroll;
@property FixtureHiddenOverlay *overlay;
@end
@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSRect frame = NSMakeRect(80, 100, 560, 380);
    self.window = [[FixtureWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Retrace owned text fixture";
    self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 100, 510, 230)];
    self.scroll.hasVerticalScroller = YES;
    self.text = [[FixtureTextView alloc] initWithFrame:NSMakeRect(0, 0, 490, 900)];
    self.text.string = @"Visible e\u0301 😀 token 7319\nSecond visible line 42\nThird visible line\n";
    self.text.font = [NSFont systemFontOfSize:16]; self.text.editable = NO;
    self.scroll.documentView = self.text; [self.window.contentView addSubview:self.scroll];
    NSSecureTextField *secure = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 50, 480, 24)];
    secure.stringValue = @"SECURE_NEVER_RETAIN"; [self.window.contentView addSubview:secure];
    NSTextField *hidden = [NSTextField labelWithString:@"HIDDEN_NEVER_RETAIN"];
    hidden.frame = NSMakeRect(20, 20, 300, 20); hidden.hidden = YES; [self.window.contentView addSubview:hidden];
    NSTextField *offscreen = [NSTextField labelWithString:@"OFFSCREEN_NEVER_RETAIN"];
    offscreen.frame = NSMakeRect(1000, 1000, 300, 20); [self.window.contentView addSubview:offscreen];
    [self.window makeKeyAndOrderFront:nil];
    [self.window.contentView layoutSubtreeIfNeeded];
    [self.text.layoutManager ensureLayoutForTextContainer:self.text.textContainer];
    [self.window displayIfNeeded];
    // ACK after the launch callback returns to AppKit. A visible WindowServer
    // row alone did not establish that its AX message service was ready.
    dispatch_async(dispatch_get_main_queue(), ^{
        printf("READY %d %ld %d\n", getpid(), (long)self.window.windowNumber, self.window.isVisible ? 1 : 0); fflush(stdout);
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char line[128];
        while (fgets(line, sizeof line, stdin)) {
            NSString *command = [[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ [self command:command]; });
        }
    });
}
- (void)command:(NSString *)command {
    if ([command isEqualToString:@"aba"]) {
        NSString *saved = self.text.string;
        self.text.string = @"Changed during native pixel read";
        NSAccessibilityPostNotification(self.text, NSAccessibilityValueChangedNotification);
        self.text.string = saved;
        NSAccessibilityPostNotification(self.text, NSAccessibilityValueChangedNotification);
    } else if ([command isEqualToString:@"ancestor-aba"]) {
        NSPoint saved = self.scroll.contentView.bounds.origin;
        [self.scroll.contentView scrollToPoint:NSMakePoint(saved.x, saved.y + 25)];
        NSAccessibilityPostNotification(self.scroll, NSAccessibilityValueChangedNotification);
        [self.scroll.contentView scrollToPoint:saved];
        NSAccessibilityPostNotification(self.scroll, NSAccessibilityValueChangedNotification);
    } else if ([command isEqualToString:@"install-overlay"]) {
        self.overlay = [[FixtureHiddenOverlay alloc] initWithFrame:NSMakeRect(70, 310, 20, 18)];
        self.overlay.hidden = YES; [self.window.contentView addSubview:self.overlay];
        ((FixtureWindow *)self.window).forcedChildren = @[self.scroll, self.overlay];
    } else if ([command isEqualToString:@"show-overlay"]) {
        self.overlay.hidden = NO; [self.overlay setNeedsDisplay:YES];
        NSAccessibilityPostNotification(self.overlay, NSAccessibilityValueChangedNotification);
    } else if ([command isEqualToString:@"duplicate"]) {
        self.other = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        self.other.title = self.window.title; [self.other setFrame:self.window.frame display:YES]; [self.other orderBack:nil];
    } else if ([command isEqualToString:@"occlude"]) {
        self.other = [[NSWindow alloc] initWithContentRect:self.window.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        self.other.title = @"Retrace owned occluder"; self.other.backgroundColor = NSColor.blackColor;
        [self.other orderFrontRegardless];
    } else if ([command isEqualToString:@"scroll"]) {
        NSMutableString *text = [@"Visible e\u0301 😀 token 7319\n" mutableCopy];
        for (int i = 0; i < 120; i++) [text appendFormat:@"Authored row %d\n", i];
        [text appendString:@"LAST_VISIBLE_9041\n"];
        [self.text setFrameSize:NSMakeSize(490, 4000)]; self.text.string = text;
        [self.text scrollRangeToVisible:NSMakeRange(text.length - 1, 1)];
        NSAccessibilityPostNotification(self.scroll, NSAccessibilityLayoutChangedNotification);
    } else if ([command isEqualToString:@"horizontal"]) {
        self.text.horizontallyResizable = YES;
        self.text.textContainer.widthTracksTextView = NO;
        self.text.textContainer.containerSize = NSMakeSize(4000, 4000);
        [self.text setFrameSize:NSMakeSize(4000, 4000)];
        self.text.string = [@"Visible prefix " stringByAppendingString:[[@"wide text " stringByPaddingToLength:250 withString:@"wide text " startingAtIndex:0] stringByAppendingString:@"HORIZONTAL_HIDDEN"]];
        [self.text scrollRangeToVisible:NSMakeRange(0, 1)];
        NSAccessibilityPostNotification(self.scroll, NSAccessibilityLayoutChangedNotification);
    } else if ([command isEqualToString:@"terminal-line"] || [command isEqualToString:@"terminal-line-newline"]) {
        self.text.string = [command isEqualToString:@"terminal-line"] ? @"FINAL_NATIVE_1847" : @"FINAL_NATIVE_1847\n";
        [self.text scrollRangeToVisible:NSMakeRange(0, 1)];
    } else if ([command isEqualToString:@"invalid-line-query"]) {
        self.text.invalidLineQuery = YES;
    } else if ([command isEqualToString:@"slow-text"]) {
        self.text.slowAX = YES;
    } else if ([command isEqualToString:@"large"]) {
        for (int i = 0; i < 10000; i++) {
            NSTextField *label = [NSTextField labelWithString:@"bounded fixture label"];
            label.frame = NSMakeRect(20, 80, 200, 20); [self.window.contentView addSubview:label];
        }
    } else if ([command isEqualToString:@"stop"]) { [NSApp terminate:nil]; return; }
    puts("ACK"); fflush(stdout);
}
@end
int main(void) { @autoreleasepool {
    NSApplication *application = NSApplication.sharedApplication;
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    Fixture *fixture = [Fixture new]; application.delegate = fixture; [application run];
} return 0; }
"""#
// END OWNED APPKIT FIXTURE

/// Only fixed reader categories and native status/counts cross this test trace.
/// Do not print AX titles, text, raw roles, process IDs or window inventories.
private func nativeTextDiagnostic(for label: String) -> @Sendable (CaptureVisibleTextDiagnostic) -> Void {
    { diagnostic in
        let rejected = diagnostic.rejections.sorted { $0.key.rawValue < $1.key.rawValue }.map { reason, count in
            "\(reason.rawValue):\(count.count):\(count.operation.rawValue):\(count.nativeStatus.map(String.init) ?? "none")"
        }.joined(separator: ",")
        let line = "CAPTURE_AX_DIAGNOSTIC test=\(label) phase=\(diagnostic.phase.rawValue) operation=\(diagnostic.operation.rawValue) status=\(diagnostic.nativeStatus.map(String.init) ?? "none") proof=\(diagnostic.proofFailure?.rawValue ?? "none") match=\(diagnostic.windowMatch?.rawValue ?? "none") nodes=\(diagnostic.visitedNodes) registrations=\(diagnostic.registrations) runs=\(diagnostic.retainedRuns) reasons=\(diagnostic.reasons.map(\.rawValue).joined(separator: ",")) rejected=\(rejected)\n"
        // A single bounded stderr write stays with XCTest's test-start/failure
        // lines; stdout buffering previously separated receipts from their test.
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}
