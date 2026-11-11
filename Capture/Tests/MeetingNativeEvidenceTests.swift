import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import Shared
import XCTest
@testable import Capture

final class MeetingNativeEvidenceTests: XCTestCase {
    func testOwnProcessCoreAudioReadDoesNotStartAnyIOOrClaimAMeeting() async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let birth = try XCTUnwrap(MeetingProcessBirth.read(pid: pid))
        let identity = MeetingApplicationIdentity(bundleID: "io.retrace.tests.owned-process", processID: pid,
                                                   processGeneration: UUID())
        let observation = await Task.detached { MeetingCoreAudioInput.observe(application: identity, birth: birth) }.value
        XCTAssertEqual(observation.source, .coreAudioProcessInput)
        XCTAssertEqual(observation.application, identity)
        XCTAssertTrue([.idleInput, .runningInput, .unavailable].contains(observation.signal))
        if observation.signal == .unavailable {
            throw XCTSkip("Native process-input property unavailable: \(String(describing: observation.uncertainty)); no device was opened")
        }
        XCTAssertLessThanOrEqual(observation.interval.startedUptime, observation.interval.endedUptime)
        XCTAssertNil(observation.windowID)
        XCTAssertEqual(MeetingProcessBirth.read(pid: pid), birth)
    }

    func testCoreAudioRefusesARealEndedOwnedProcess() async throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe(); process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            await Task.detached { process.waitUntilExit() }.value
        }
        let pid = process.processIdentifier
        let birth = try XCTUnwrap(MeetingProcessBirth.read(pid: pid))
        try input.fileHandleForWriting.close()
        await Task.detached { process.waitUntilExit() }.value
        XCTAssertNil(MeetingProcessBirth.read(pid: pid))
        XCTAssertTrue(MeetingProcessBirth.hasExited(pid: pid))
        let identity = MeetingApplicationIdentity(bundleID: "io.retrace.tests.owned-process", processID: pid,
                                                   processGeneration: UUID())
        let refused = await Task.detached { MeetingCoreAudioInput.observe(application: identity, birth: birth) }.value
        XCTAssertEqual(refused.signal, .unavailable)
        XCTAssertEqual(refused.uncertainty, .identityUnproved)
    }

    func testOwnedNativeControlsRecognizeCallAndDoNotReadProfileOrSecureText() async throws {
        let fixture = try await makeFixture()
        let read = await fixture.read()
        try requireNativeCapability(read)
        XCTAssertEqual(read.observation.signal, .inCallControls)
        XCTAssertEqual(read.observation.application?.processID, fixture.process.processIdentifier)
        XCTAssertNotNil(read.observation.windowID)
        XCTAssertEqual(read.observation.capturePolicySHA256, try ScreenEvidenceAccessPolicy(config: .default).fingerprintSHA256())
        try await fixture.command("profile")
        let profile = await fixture.read()
        XCTAssertEqual(profile.observation.signal, .unavailable)
        XCTAssertFalse(profile.observation.signal == .inCallControls)
        let secureReads = try await fixture.command("secure-reads")
        XCTAssertEqual(secureReads, "0", "Secure fields must never supply control labels")
    }

    func testOwnedHiddenOccludedAndUnknownContainersNeverSupplyCallControls() async throws {
        let fixture = try await makeFixture()
        try requireNativeCapability(await fixture.read())
        for command in ["hidden", "occluded", "unknown", "secure", "secure-ancestor"] {
            try await fixture.command(command)
            let result = await fixture.read()
            XCTAssertEqual(result.observation.signal, .unavailable, command)
            XCTAssertNil(result.observation.windowID, "Unproved controls retain no window claim")
            try await fixture.command("call")
        }
        let secureReads = try await fixture.command("secure-reads")
        XCTAssertEqual(secureReads, "0")
    }

    func testOwnedNativeControlAndAncestorABANotificationsInvalidateRead() async throws {
        let fixture = try await makeFixture()
        try requireNativeCapability(await fixture.read())
        for command in ["aba", "ancestor-aba"] {
            let pair = AsyncStream<MeetingControlMutationEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
            let target: MeetingControlMutationEvent = command == "aba" ? .buttonTitleChanged : .ancestorValueChanged
            let result = await fixture.read(onMutation: { pair.continuation.yield($0) }, between: {
                _ = try? await fixture.command(command)
                let received = await waitForMeetingMutation(pair.stream, matching: target)
                XCTAssertTrue(received, "Require the targeted native observer; unrelated window layout is insufficient")
            })
            pair.continuation.finish()
            XCTAssertEqual(result.observation.signal, .unavailable)
            XCTAssertEqual(result.observation.uncertainty, .sourceChanged)
        }
        XCTAssertEqual(MeetingCallControlReader.activeReaderCount, 0)
    }

    func testOwnedNodeBudgetAndCancellationJoinTheNativeReader() async throws {
        let fixture = try await makeFixture()
        try requireNativeCapability(await fixture.read())
        try await fixture.command("large")
        let bounded = await fixture.read()
        XCTAssertEqual(bounded.observation.signal, .unavailable)
        XCTAssertEqual(bounded.observation.uncertainty, .budgetExceeded)
        XCTAssertLessThanOrEqual(bounded.visitedNodes, 128)
        try await fixture.command("call")
        let entered = expectation(description: "native bracket")
        let cancelled = Task {
            await fixture.read(between: {
                entered.fulfill()
                try? await Task.sleep(for: .seconds(30), clock: .continuous)
            })
        }
        await fulfillment(of: [entered], timeout: 5)
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertEqual(result.observation.signal, .unavailable)
        XCTAssertEqual(result.observation.uncertainty, .cancelled)
        XCTAssertEqual(MeetingCallControlReader.activeReaderCount, 0)
    }

    func testExcludedAppDeniedBeforeNativeAXRead() async throws {
        let fixture = try await makeFixture()
        let result = await fixture.read(config: CaptureConfig(excludedAppBundleIDs: [NativeMeetingFixture.bundleID]))
        XCTAssertEqual(result.observation.uncertainty, .privacyExcluded)
        XCTAssertEqual(result.visitedNodes, 0)
        XCTAssertEqual(MeetingCallControlReader.activeReaderCount, 0)
    }

    func testNativeSupportedLifetimeSurvivesInventoryFailureUntilObservedProcessExit() async throws {
        let fixture = try await makeFixture()
        let failure = MeetingInventoryFailureSwitch()
        let source = MeetingNativeObservationSource(captureConfig: {
            MeetingCapturePolicySnapshot(configuration: .default, revision: 1)
        }, applications: { bundle in
            failure.enabled ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        })
        let present = await source.sample(bundleIDs: [NativeMeetingFixture.bundleID], comparisonEnabled: false, previous: nil)
        let identity = try XCTUnwrap(present.observations.first { $0.signal == .present }?.application)
        let birth = try XCTUnwrap(MeetingProcessBirth.read(pid: fixture.process.processIdentifier))
        let controls = await MeetingCallControlReader.read(application: identity, birth: birth, config: .default)
        try requireNativeCapability(controls)
        // Controlled positive IO observation is the external HAL fault boundary;
        // real process identity, AX controls, inventory and exit are production APIs.
        let input = MeetingObservation(interval: controls.observation.interval, source: .coreAudioProcessInput,
                                       signal: .runningInput, application: identity)
        var reducer = MeetingAssessmentReducer(sessionID: UUID())
        let active = reducer.consume(MeetingSample(observations: present.observations + [controls.observation, input],
            observedAt: Date(), observedUptime: ProcessInfo.processInfo.systemUptime, candidateCount: 1,
            controlsVisited: controls.visitedNodes), comparisonEnabled: true, speech: nil)
        XCTAssertEqual(active.phase, .supportedActive)
        failure.set(true)
        let missed = await source.sample(bundleIDs: [NativeMeetingFixture.bundleID], comparisonEnabled: false,
                                         previous: reducer.terminationTarget)
        let unknown = reducer.consume(missed, comparisonEnabled: true, speech: nil)
        XCTAssertEqual(unknown.phase, .unknown)
        XCTAssertNil(unknown.application)
        XCTAssertEqual(reducer.terminationTarget, identity)
        await fixture.stop()
        failure.set(false)
        var ended = unknown
        for _ in 0..<40 {
            let next = await source.sample(bundleIDs: [NativeMeetingFixture.bundleID], comparisonEnabled: false,
                                          previous: reducer.terminationTarget)
            ended = reducer.consume(next, comparisonEnabled: true, speech: nil)
            if ended.phase == .ended { break }
            try await Task.sleep(for: .milliseconds(50), clock: .continuous)
        }
        XCTAssertEqual(ended.phase, .ended)
        XCTAssertEqual(ended.application, identity)
        XCTAssertEqual(ended.supportedSince, active.supportedSince)
        XCTAssertNotNil(ended.endedAt)
        await source.reset()
    }

    func testPartialNativeInventoryDoesNotRetainUnpublishedProcessIdentities() async throws {
        let fixture = try await makeFixture()
        let failingBundle = "zz.retrace.tests.unavailable-inventory"
        let source = MeetingNativeObservationSource(captureConfig: {
            MeetingCapturePolicySnapshot(configuration: .default, revision: 1)
        }, applications: { bundle in
            bundle == failingBundle ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
        })
        for _ in 0..<4 {
            let failed = await source.sample(bundleIDs: [NativeMeetingFixture.bundleID, failingBundle],
                                            comparisonEnabled: false, previous: nil)
            XCTAssertTrue(failed.observations.contains { $0.uncertainty == .nativeUnavailable })
            let retained = await source.retainedIdentityCount()
            XCTAssertEqual(retained, 0, "Incomplete native inventories must not accumulate process handles")
        }
        let complete = await source.sample(bundleIDs: [NativeMeetingFixture.bundleID], comparisonEnabled: false, previous: nil)
        XCTAssertEqual(complete.observations.first { $0.signal == .present }?.application?.processID,
                       fixture.process.processIdentifier)
        let retained = await source.retainedIdentityCount()
        XCTAssertEqual(retained, 1)
        await source.reset()
        let resetCount = await source.retainedIdentityCount()
        XCTAssertEqual(resetCount, 0)
    }

    private func makeFixture() async throws -> NativeMeetingFixture {
        let fixture = try await NativeMeetingFixture.launch()
        addTeardownBlock { await fixture.stop() }
        return fixture
    }
    private func requireNativeCapability(_ result: MeetingControlRead) throws {
        if result.observation.signal == .unavailable, let uncertainty = result.observation.uncertainty,
           [MeetingUncertainty.permissionUnavailable, .observerUnavailable, .controlsUnavailable, .identityUnproved].contains(uncertainty) {
            throw XCTSkip("Owned native AX provider lacks required capability: \(String(describing: result.observation.uncertainty))")
        }
        XCTAssertEqual(result.observation.signal, .inCallControls,
                       "Visibility/budget/mutation failures are failures after a supported fixture has launched")
    }
}

private final class MeetingInventoryFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var enabled: Bool { lock.withLock { value } }
    func set(_ enabled: Bool) { lock.withLock { value = enabled } }
}

private func waitForMeetingMutation(_ stream: AsyncStream<MeetingControlMutationEvent>,
                                    matching target: MeetingControlMutationEvent) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in stream { if event == target { return true } }
            return false
        }
        group.addTask { try? await Task.sleep(for: .seconds(2), clock: .continuous); return false }
        let matched = await group.next() ?? false; group.cancelAll(); return matched
    }
}

private final class NativeMeetingFixture: @unchecked Sendable {
    static let bundleID = "io.retrace.tests.meeting-controls"
    let process: Process
    private let directory: URL
    private let input: FileHandle
    private let output: FileHandle
    private let queue = DispatchQueue(label: "retrace.tests.meeting-fixture")
    private let identity: MeetingApplicationIdentity
    private let birth: MeetingProcessBirth
    private init(process: Process, directory: URL, input: FileHandle, output: FileHandle, birth: MeetingProcessBirth) {
        self.process = process; self.directory = directory; self.input = input; self.output = output; self.birth = birth
        identity = MeetingApplicationIdentity(bundleID: Self.bundleID, processID: process.processIdentifier, processGeneration: UUID())
    }
    static func launch() async throws -> NativeMeetingFixture {
        guard ProcessInfo.processInfo.environment["RETRACE_MEETING_AX_FIXTURE"] == "1" else {
            throw XCTSkip("Owned visible AX fixture is opt-in; no user application is inspected")
        }
        guard AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Already-granted Accessibility and Screen Recording required; no permission prompt")
        }
        return try await Task.detached {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-meeting-native-\(UUID())")
            var handedOff = false
            defer { if !handedOff { try? FileManager.default.removeItem(at: directory) } }
            let contents = directory.appendingPathComponent("MeetingFixture.app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("MeetingFixture.m")
            try nativeMeetingFixtureSource.write(to: source, atomically: true, encoding: .utf8)
            let executable = contents.appendingPathComponent("MacOS/MeetingFixture")
            try """
                <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
                <key>CFBundleIdentifier</key><string>\(bundleID)</string>
                <key>CFBundleExecutable</key><string>MeetingFixture</string><key>LSUIElement</key><true/>
                </dict></plist>
                """.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = ["-fobjc-arc", "-framework", "AppKit", source.path, "-o", executable.path]
            try compiler.run(); compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw CocoaError(.executableNotLoadable) }
            let process = Process(); process.executableURL = executable
            let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output
            try process.run()
            guard let birth = MeetingProcessBirth.read(pid: process.processIdentifier) else {
                process.terminate(); process.waitUntilExit(); throw CocoaError(.executableLoad)
            }
            let fixture = NativeMeetingFixture(process: process, directory: directory,
                input: input.fileHandleForWriting, output: output.fileHandleForReading, birth: birth)
            do { _ = try fixture.reply() } catch { await fixture.stop(); throw error }
            handedOff = true; return fixture
        }.value
    }
    @discardableResult func command(_ command: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.input.write(contentsOf: Data((command + "\n").utf8))
                    continuation.resume(returning: try self.reply())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func reply() throws -> String {
        var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5_000) > 0, descriptor.revents & Int16(POLLIN) != 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let data = try output.read(upToCount: 1024) ?? Data()
        guard !data.isEmpty else { throw CocoaError(.fileReadUnknown) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func read(config: CaptureConfig = .default, onMutation: (@Sendable (MeetingControlMutationEvent) -> Void)? = nil,
              between: @escaping @Sendable () async -> Void = {}) async -> MeetingControlRead {
        await MeetingCallControlReader.read(application: identity, birth: birth, config: config,
                                            onMutation: onMutation, between: between)
    }
    func stop() async {
        try? input.write(contentsOf: Data("stop\n".utf8))
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50), clock: .continuous)
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(50), clock: .continuous)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await Task.detached { [self] in
            process.waitUntilExit(); try? input.close(); try? output.close()
            try? FileManager.default.removeItem(at: directory)
        }.value
    }
}

private let nativeMeetingFixtureSource = #"""
#import <AppKit/AppKit.h>
#include <stdio.h>
static int secureReads = 0;
@interface FixtureSecure : NSSecureTextField @end
@implementation FixtureSecure
- (NSString *)accessibilityTitle { secureReads++; return @"Leave"; }
- (NSString *)accessibilityValue { secureReads++; return @"Mute microphone"; }
@end
@interface FixtureGroup : NSView
@property BOOL unknownRole;
@property BOOL secureRole;
@property NSInteger viewportRevision;
@end
@implementation FixtureGroup
- (BOOL)isAccessibilityElement { return YES; }
- (NSString *)accessibilityRole {
    if (self.secureRole) return NSAccessibilityTextFieldRole;
    return self.unknownRole ? @"AXUnknown" : NSAccessibilityGroupRole;
}
- (NSString *)accessibilitySubrole { return self.secureRole ? NSAccessibilitySecureTextFieldSubrole : nil; }
- (id)accessibilityValue { return @(self.viewportRevision); }
- (NSArray *)accessibilityChildren { return self.subviews; }
@end
@interface Fixture : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property FixtureGroup *group;
@property NSButton *leave;
@property NSButton *microphone;
@property NSWindow *cover;
@end
@implementation Fixture
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 140, 480, 300)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Retrace owned meeting fixture";
    [self populate]; [self.window makeKeyAndOrderFront:nil];
    puts("READY"); fflush(stdout);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        char line[64];
        while (fgets(line, sizeof line, stdin)) {
            NSString *command = [[NSString stringWithUTF8String:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ [self command:command]; });
        }
    });
}
- (void)populate {
    [self.cover orderOut:nil]; self.cover = nil;
    self.group = [[FixtureGroup alloc] initWithFrame:NSMakeRect(20, 30, 440, 220)];
    self.leave = [NSButton buttonWithTitle:@"Leave" target:self action:@selector(noop:)];
    self.leave.frame = NSMakeRect(20, 30, 140, 40);
    self.microphone = [NSButton buttonWithTitle:@"Mute microphone" target:self action:@selector(noop:)];
    self.microphone.frame = NSMakeRect(180, 30, 220, 40);
    [self.group addSubview:self.leave]; [self.group addSubview:self.microphone];
    self.window.contentView.subviews = @[self.group];
    NSAccessibilityPostNotification(self.window, NSAccessibilityLayoutChangedNotification);
}
- (void)noop:(id)sender {}
- (void)command:(NSString *)command {
    if ([command isEqualToString:@"stop"]) { [NSApp terminate:nil]; return; }
    if ([command isEqualToString:@"secure-reads"]) { printf("%d\n", secureReads); fflush(stdout); return; }
    if ([command isEqualToString:@"call"]) [self populate];
    if ([command isEqualToString:@"profile"]) {
        self.leave.title = @"Profile"; self.microphone.title = @"Settings";
    }
    if ([command isEqualToString:@"hidden"]) self.leave.hidden = YES;
    if ([command isEqualToString:@"unknown"]) self.group.unknownRole = YES;
    if ([command isEqualToString:@"secure-ancestor"]) self.group.secureRole = YES;
    if ([command isEqualToString:@"secure"]) {
        FixtureSecure *secure = [[FixtureSecure alloc] initWithFrame:self.leave.frame];
        [self.leave removeFromSuperview]; [self.group addSubview:secure];
    }
    if ([command isEqualToString:@"occluded"]) {
        self.cover = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 140, 480, 300)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        self.cover.backgroundColor = NSColor.blackColor; [self.cover orderFrontRegardless];
    }
    if ([command isEqualToString:@"large"]) {
        for (int n = 0; n < 130; n++) {
            NSButton *button = [NSButton buttonWithTitle:@"irrelevant" target:self action:@selector(noop:)];
            button.frame = NSMakeRect(0, 150, 10, 10); [self.group addSubview:button];
        }
    }
    if ([command isEqualToString:@"aba"]) {
        self.leave.title = @"Join now"; NSAccessibilityPostNotification(self.leave, NSAccessibilityTitleChangedNotification);
        self.leave.title = @"Leave"; NSAccessibilityPostNotification(self.leave, NSAccessibilityTitleChangedNotification);
    }
    if ([command isEqualToString:@"ancestor-aba"]) {
        self.group.viewportRevision = 1;
        NSAccessibilityPostNotification(self.group, NSAccessibilityValueChangedNotification);
        self.group.viewportRevision = 0;
        NSAccessibilityPostNotification(self.group, NSAccessibilityValueChangedNotification);
    }
    if (![command isEqualToString:@"aba"] && ![command isEqualToString:@"ancestor-aba"])
        NSAccessibilityPostNotification(self.window, NSAccessibilityLayoutChangedNotification);
    puts("OK"); fflush(stdout);
}
@end
int main(void) { @autoreleasepool {
    NSApplication *application = NSApplication.sharedApplication;
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    Fixture *fixture = [Fixture new]; application.delegate = fixture; [application run];
} return 0; }
"""#
