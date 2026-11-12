import App
import AppKit
import Database
import Foundation
import Shared
import SwiftUI
import XCTest
@testable import Retrace

#if DEBUG
/// Opt-in visible native settings fixture. The real cards retain their production
/// polling and native controls; only their App-owned service acquisition is injected.
/// It never constructs SettingsView, AppCoordinator, capture, or an application lock.
/// The installed crash's originating sleep is unproven. Passing this diagnostic
/// establishes only this private interaction run, not a crash fix or installed acceptance.
@MainActor
final class LiveContextSettingsNativeTests: XCTestCase {
    func testActualAudioAndCommandSettingsSurviveNativePopupAndNavigation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RETRACE_TEST_NATIVE_SETTINGS"] == "1" else {
            throw XCTSkip("Set RETRACE_TEST_NATIVE_SETTINGS=1 for the visible 90-second native settings fixture")
        }
        guard environment["RETRACE_TEST_DISABLE_FILE_LOGGING"] == "1" else {
            throw XCTSkip("Native settings validation requires process-local file logging to be disabled")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("retrace-native-settings-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let database = ContextDatabase(databasePath: root.appendingPathComponent("context.db").path, nativeStoreID: UUID())
        try await database.initialize()
        let probe = SettingsNativeOwnerProbe()
        let audio = AudioSessionOwner(store: database,
            baseConfig: .init(microphoneEnabled: true, systemAudioEnabled: false),
            pipeline: .init(start: { _ in await probe.recordUnexpectedStart(); throw AudioSessionError.closed },
                stopAndDrain: {}, runtime: { .init(microphone: .init(.paused), systemAudio: .init(.paused)) },
                revokeMarkers: {}, setMicrophoneAllowed: { _ in }))
        let access = RetraceCommandAccessService(storageRoot: root) {
            await probe.recordUnexpectedListenerRequest()
            throw RetraceCommandError.unavailable
        }
        do {
            try await audio.initialize()
            try await render(audio: audio, access: access, probe: probe)
            try await audio.close()
            await access.close()
            try await database.close()
        } catch {
            try? await audio.close()
            await access.close()
            try? await database.close()
            throw error
        }
    }

    private func render(audio: AudioSessionOwner, access: RetraceCommandAccessService,
                        probe: SettingsNativeOwnerProbe) async throws {
        _ = NSApplication.shared
        let focusRequested = ProcessInfo.processInfo.environment["RETRACE_TEST_NATIVE_SETTINGS_FOCUS"] == "1"
        NSApp.setActivationPolicy(focusRequested ? .regular : .accessory)
        NSApp.finishLaunching()
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        let size = NSSize(width: 860, height: 760)
        let panel = SettingsNativeTestWindow(contentRect: NSRect(x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Retrace Settings — AUTHORED VALIDATION"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let navigation = SettingsNativeNavigation()
        let workspace = LiveContextWorkspaceModel(loadAudio: { _, _, _ in
            await probe.recordLiveRead()
            return .init(entries: [], nextCursor: nil)
        }, loadScreens: { _ in .init(rows: [], hasMore: false) })
        let evidence = EvidenceViewModel(client: .live(service: { throw ContextStoreError.notInitialized }))
        let playback = TranscriptAudioPlayback(resolve: { _ in
            await probe.recordUnexpectedPlayback()
            throw TranscriptAudioError.unavailable
        }, isMuted: true, playbackGate: RetracePlaybackGate())
        let companion = CompanionWorkspaceModel(service: {
            await probe.recordCompanionRead()
            throw ContextStoreError.notInitialized
        })
        let voice = VoiceMarkerStatusModel(readStatus: {
            await probe.recordVoiceRead()
            return VoiceMarkerStatus()
        })
        let live = LiveContextWorkspaceView(model: workspace, evidence: evidence, playback: playback,
            isActive: true, isRecording: false, validateScreen: { _ in false },
            openEvidence: { _ in XCTFail("Empty authored Live must not open evidence") },
            voice: voice, companion: companion)
        let view = SettingsNativeHarness(navigation: navigation, live: live,
            audio: {
                await probe.recordAudioRead()
                return audio
            }, access: {
                await probe.recordAccessRead()
                return access
            })
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        if focusRequested {
            // Explicit additional opt-in permits this private diagnostic window
            // to take focus for native text input and popup-menu tracking.
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeMain()
        } else {
            panel.orderFront(nil)
        }
        defer {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            workspace.setActive(false)
            evidence.closeEvidence()
            playback.stop(reason: .closed)
            companion.hide()
        }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) })
        print("Native Settings AX probe ready: PID \(ProcessInfo.processInfo.processIdentifier), 90 seconds. Keep Live visible for at least 10 seconds, then use Audio → Advanced → Audio → Advanced; edit the authored client name, check capabilities, and leave the expiry popup open across 60 seconds. Do not create a client.")

        // No fixture Task.sleep caller is added to the runtime investigation.
        // The focus run needs NSApplication's actual NSEvent dispatch loop;
        // XCTest's CFRunLoop alone services AX/dispatch but not native input.
        // Live and both cards retain their unchanged production polling loops.
        let finished = expectation(description: "Native settings observation interval elapsed")
        if focusRequested {
            let wake = try XCTUnwrap(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: 0, data1: 0, data2: 0))
            let loop = NativeAppKitObservationLoop(wake: wake, activate: {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeMain()
            }, verifyReadiness: {
                XCTAssertTrue(NSApp.isActive, "Explicit native-input opt-in must activate the fixture application")
                XCTAssertTrue(panel.isKeyWindow, "The fixture must initially receive native keyboard input")
                XCTAssertTrue(panel.isMainWindow)
            }, finished: { finished.fulfill() })
            loop.schedule()
            await fulfillment(of: [finished], timeout: 100)
            loop.invalidateTimers()
            XCTAssertTrue(loop.checkedReadiness)
            XCTAssertTrue(loop.deadlineReached, "The real AppKit event loop must run for the full observation interval")
            XCTAssertTrue(loop.returnedFromRun)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 90) { finished.fulfill() }
            await fulfillment(of: [finished], timeout: 100)
        }

        XCTAssertTrue(panel.isVisible, "The native fixture must remain open through the observation interval")
        XCTAssertTrue(NSApp.windows.contains { $0 === panel })
        let counts = await probe.snapshot()
        XCTAssertGreaterThanOrEqual(counts.audioReads, 2, "Exercise the real Audio card before and after tab cancellation")
        XCTAssertGreaterThanOrEqual(counts.accessReads, 2, "Exercise the real Advanced card and its polling")
        XCTAssertGreaterThanOrEqual(counts.liveReads, 2, "Keep the actual empty Live view active through its eight-second refresh")
        XCTAssertGreaterThanOrEqual(counts.companionReads, 2, "Live must exercise its actual companion status loop")
        XCTAssertGreaterThanOrEqual(counts.voiceReads, 2, "Live must exercise its actual voice status loop")
        XCTAssertGreaterThanOrEqual(navigation.transitions, 4, "Use Live → Audio → Advanced → Audio → Advanced to cancel and resume view tasks")
        XCTAssertEqual(counts.nativeStarts, 0)
        XCTAssertEqual(counts.listenerRequests, 0)
        XCTAssertEqual(counts.playbackAttempts, 0)
        XCTAssertNil(playback.player)
        let audioState = await audio.snapshot()
        XCTAssertEqual(audioState.phase, .paused)
        XCTAssertFalse(audioState.recordingRequested)
        let accessState = await access.state()
        XCTAssertTrue(accessState.clients.isEmpty, "This fixture edits a draft only; do not create a client")
        XCTAssertFalse(accessState.enabled)
        XCTAssertFalse(accessState.listening)
        print("Native Settings AX probe finished: Live reads \(counts.liveReads), companion reads \(counts.companionReads), voice reads \(counts.voiceReads), audio reads \(counts.audioReads), access reads \(counts.accessReads), tab transitions \(navigation.transitions), native starts \(counts.nativeStarts), listener requests \(counts.listenerRequests), playback attempts \(counts.playbackAttempts). Draft text and capability choices are not logged.")
    }
}

/// The normal fixture only orders this window front. The separate FOCUS opt-in
/// permits explicit activation for native text input and popup-menu tracking.
private final class SettingsNativeTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class SettingsNativeNavigation: ObservableObject {
    enum Tab { case live, audio, advanced }
    @Published var selected: Tab = .live {
        didSet { if selected != oldValue { transitions += 1 } }
    }
    private(set) var transitions = 0
}

@MainActor
private struct SettingsNativeHarness: View {
    @ObservedObject var navigation: SettingsNativeNavigation
    let live: LiveContextWorkspaceView
    let audio: @Sendable () async throws -> AudioSessionOwner
    let access: @Sendable () async throws -> RetraceCommandAccessService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AUTHORED NATIVE SETTINGS VALIDATION").font(.headline)
            Text("Private temporary data · recording paused · access disabled · do not create a client")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Live") { navigation.selected = .live }
                Button("Audio") { navigation.selected = .audio }
                Button("Advanced") { navigation.selected = .advanced }
                Spacer()
            }
            Divider()
            ScrollView {
                switch navigation.selected {
                case .live:
                    // Only polling/lifecycle is under observation here. In particular,
                    // prevent Live's global Voice markers navigation from opening the
                    // application's real Settings owner in this isolated test process.
                    live.disabled(true).frame(height: 560)
                case .audio:
                    AudioSessionSettingsView(session: audio)
                case .advanced:
                    CommandAccessSettingsView(service: access)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 740, minHeight: 650, alignment: .topLeading)
        .background(Color.retraceBackground)
    }
}

private actor SettingsNativeOwnerProbe {
    struct Counts: Sendable {
        var audioReads = 0
        var accessReads = 0
        var liveReads = 0
        var companionReads = 0
        var voiceReads = 0
        var nativeStarts = 0
        var listenerRequests = 0
        var playbackAttempts = 0
    }
    private var counts = Counts()
    func recordAudioRead() { counts.audioReads += 1 }
    func recordAccessRead() { counts.accessReads += 1 }
    func recordLiveRead() { counts.liveReads += 1 }
    func recordCompanionRead() { counts.companionReads += 1 }
    func recordVoiceRead() { counts.voiceReads += 1 }
    func recordUnexpectedStart() { counts.nativeStarts += 1 }
    func recordUnexpectedListenerRequest() { counts.listenerRequests += 1 }
    func recordUnexpectedPlayback() { counts.playbackAttempts += 1 }
    func snapshot() -> Counts { counts }
}
#endif
