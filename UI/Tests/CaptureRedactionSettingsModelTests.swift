import AppKit
import Shared
import SwiftUI
import XCTest
@testable import App
@testable import Retrace

@MainActor
final class CaptureRedactionSettingsModelTests: XCTestCase {
    func testCanonicalCommasAndWhitespaceSurviveEditingAnotherField() async throws {
        let windows = ["Client, Confidential", " edge spaces ", "   "]
        let store = RedactionSettingsFixture(config: .init(captureIntervalSeconds: 11,
            redactWindowTitlePatterns: windows, redactBrowserURLPatterns: ["private.example"], idleThresholdSeconds: 321))
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        XCTAssertEqual(model.windowDraft, windows.joined(separator: "\n"))
        XCTAssertFalse(model.canApply)
        model.editURLs("private.example\n second, literal ")
        let result = await model.apply(using: store.client)
        XCTAssertNotNil(result)
        let state = await store.snapshot()
        XCTAssertEqual(state.config.redactWindowTitlePatterns, windows)
        XCTAssertEqual(state.config.redactBrowserURLPatterns, ["private.example", " second, literal "])
        XCTAssertEqual(state.config.captureIntervalSeconds, 11)
        XCTAssertEqual(state.config.idleThresholdSeconds, 321)
        XCTAssertFalse(model.hasUnappliedChanges)
    }

    func testNativeEditorEnterAndNextLineRemainDraftUntilExplicitApply() async throws {
        let store = RedactionSettingsFixture(config: .init(redactWindowTitlePatterns: ["Authored first"]))
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 420, height: 160),
            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: SettingsView.redactionRuleEditor(
            text: Binding(get: { model.windowDraft }, set: { model.editWindow($0) }), placeholder: "Authored placeholder"))
        panel.contentView = hosting
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.close() }
        hosting.layoutSubtreeIfNeeded()
        var editor: NSTextView?
        for _ in 0..<100 {
            editor = textEditor(in: hosting)
            if editor != nil { break }
            await Task.yield()
            hosting.layoutSubtreeIfNeeded()
        }
        let native = try XCTUnwrap(editor, "Render the actual Settings TextEditor without capture devices or preference writes")
        XCTAssertEqual(native.string, "Authored first")
        native.setSelectedRange(NSRange(location: native.string.utf16.count, length: 0))
        native.insertNewline(nil)
        for _ in 0..<100 where model.windowDraft != "Authored first\n" { await Task.yield() }
        XCTAssertEqual(model.windowDraft, "Authored first\n")
        await model.loadIfNeeded(using: store.client)
        XCTAssertEqual(model.windowDraft, "Authored first\n", "Reappearing must not reload a live draft")
        native.insertText("Authored second, literal", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<100 where model.windowDraft != "Authored first\nAuthored second, literal" { await Task.yield() }
        XCTAssertEqual(model.windowDraft, "Authored first\nAuthored second, literal")
        let before = await store.snapshot(), attempts = await store.attemptCount()
        XCTAssertEqual(before.config.redactWindowTitlePatterns, ["Authored first"])
        XCTAssertEqual(attempts, 0, "Typing cannot invoke capture configuration")
        _ = await model.apply(using: store.client)
        let after = await store.snapshot()
        XCTAssertEqual(after.config.redactWindowTitlePatterns, ["Authored first", "Authored second, literal"])
    }

    func testHeldSaveKeepsNewerDraftAndUsesAcceptedRevisionForNextApply() async throws {
        let store = RedactionSettingsFixture(), gate = RedactionSettingsGate()
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        model.editWindow("Submitted")
        await store.holdNextWrite(gate)
        let saving = Task { await model.apply(using: store.client) }
        await fulfillment(of: [gate.entered], timeout: 2)
        model.editWindow("Newer\nStill editing\n")
        await gate.release()
        let first = await saving.value
        XCTAssertNotNil(first)
        XCTAssertEqual(model.windowDraft, "Newer\nStill editing\n")
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.statusMessage, "Earlier rules applied. Your newer edits have not been applied.")
        let saved = await store.snapshot()
        XCTAssertEqual(saved.config.redactWindowTitlePatterns, ["Submitted"])
        _ = await model.apply(using: store.client)
        let latest = await store.snapshot()
        XCTAssertEqual(latest.config.redactWindowTitlePatterns, ["Newer", "Still editing"])
        XCTAssertEqual(model.windowDraft, "Newer\nStill editing\n", "Apply never normalizes editor text")
    }

    func testExternalConfigurationConflictPreservesNewerDraftAndShowsFreshError() async throws {
        let store = RedactionSettingsFixture(), gate = RedactionSettingsGate()
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        model.editWindow("Submitted")
        await store.holdNextWrite(gate)
        let saving = Task { await model.apply(using: store.client) }
        await fulfillment(of: [gate.entered], timeout: 2)
        model.editWindow("Newer draft")
        await store.replaceExternally(.init(captureIntervalSeconds: 22, redactWindowTitlePatterns: ["External, literal"]))
        await gate.release()
        let result = await saving.value
        XCTAssertNil(result)
        XCTAssertEqual(model.windowDraft, "Newer draft")
        XCTAssertFalse(model.isSaving)
        XCTAssertTrue(model.requiresReload)
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.errorMessage?.contains("changed elsewhere") == true)
        let state = await store.snapshot()
        XCTAssertEqual(state.config.captureIntervalSeconds, 22)
        XCTAssertEqual(state.config.redactWindowTitlePatterns, ["External, literal"])
        await model.reload(using: store.client)
        XCTAssertEqual(model.windowDraft, "External, literal")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.requiresReload)
    }

    func testDelayedReloadCannotOverwriteTextEnteredAfterReloadBegan() async throws {
        let store = RedactionSettingsFixture(), gate = RedactionSettingsGate()
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        await store.replaceExternally(.init(redactWindowTitlePatterns: ["External rule"]))
        await store.holdNextRead(gate)
        let loading = Task { await model.reload(using: store.client) }
        await fulfillment(of: [gate.entered], timeout: 2)
        model.editWindow("Typed during reload\n")
        await gate.release(); await loading.value
        XCTAssertEqual(model.windowDraft, "Typed during reload\n")
        XCTAssertTrue(model.canApply)
    }

    func testPrivacyResetPreservesTypingAfterItsAcceptedSubmission() async throws {
        let store = RedactionSettingsFixture(config: .init(excludedAppBundleIDs: ["test.authored"],
            redactWindowTitlePatterns: ["Before reset"], redactBrowserURLPatterns: ["before.example"], idleThresholdSeconds: 321))
        let gate = RedactionSettingsGate(), model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        await store.holdNextWrite(gate)
        let resetting = Task { await model.reset(.privacy, using: store.client) }
        await fulfillment(of: [gate.entered], timeout: 2)
        model.editWindow("After reset draft")
        await gate.release(); await resetting.value
        let state = await store.snapshot()
        XCTAssertEqual(state.config.excludedAppBundleIDs, ["com.apple.loginwindow"])
        XCTAssertFalse(state.config.excludePrivateWindows)
        XCTAssertTrue(state.config.redactWindowTitlePatterns.isEmpty)
        XCTAssertTrue(state.config.redactBrowserURLPatterns.isEmpty)
        XCTAssertEqual(state.config.idleThresholdSeconds, 321)
        XCTAssertEqual(model.windowDraft, "After reset draft")
        XCTAssertTrue(model.canApply)
    }

    func testCombinedResetMakesOneWriteAndPublishesPreferencesOnlyAfterAcceptance() async throws {
        let store = RedactionSettingsFixture(config: .init(captureIntervalSeconds: 17,
            adaptiveCaptureEnabled: false, excludedAppBundleIDs: ["test.authored"],
            redactWindowTitlePatterns: ["Saved rule"], idleThresholdSeconds: 321, captureOnWindowChange: false))
        let gate = RedactionSettingsGate(), model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        model.editWindow("Unsaved draft")
        var published = 0
        await store.holdNextWrite(gate)
        let resetting = Task { await model.reset(.all, using: store.client) { published += 1 } }
        await fulfillment(of: [gate.entered], timeout: 2)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(model.windowDraft, "Unsaved draft", "Pending reset cannot discard a draft")
        let overlapping = await model.reset(.privacy, using: store.client) { published += 1 }
        XCTAssertFalse(overlapping)
        let before = await store.snapshot()
        XCTAssertEqual(before.config.captureIntervalSeconds, 17)
        XCTAssertEqual(before.config.redactWindowTitlePatterns, ["Saved rule"])
        await gate.release()
        let accepted = await resetting.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(published, 1)
        let after = await store.snapshot(), attempts = await store.attemptCount()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(after.config.captureIntervalSeconds, SettingsDefaults.captureIntervalSeconds)
        XCTAssertEqual(after.config.adaptiveCaptureEnabled, SettingsDefaults.deleteDuplicateFrames)
        XCTAssertEqual(after.config.captureOnWindowChange, SettingsDefaults.captureOnWindowChange)
        XCTAssertEqual(after.config.excludedAppBundleIDs, ["com.apple.loginwindow"])
        XCTAssertTrue(after.config.redactWindowTitlePatterns.isEmpty)
        XCTAssertEqual(after.config.idleThresholdSeconds, 321)
        XCTAssertEqual(model.windowDraft, "")
    }

    func testResetConflictPublishesNoPreferencesAndPreservesDraft() async throws {
        let store = RedactionSettingsFixture(), gate = RedactionSettingsGate()
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        model.editWindow("Draft before reset")
        var published = false
        await store.holdNextWrite(gate)
        let resetting = Task { await model.reset(.all, using: store.client) { published = true } }
        await fulfillment(of: [gate.entered], timeout: 2)
        model.editWindow("Newer draft")
        await store.replaceExternally(.init(captureIntervalSeconds: 19, redactWindowTitlePatterns: ["External, exact"]))
        await gate.release()
        let accepted = await resetting.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(published)
        XCTAssertEqual(model.windowDraft, "Newer draft")
        XCTAssertTrue(model.requiresReload)
        XCTAssertTrue(model.errorMessage?.contains("changed elsewhere") == true)
        let after = await store.snapshot()
        XCTAssertEqual(after.config.captureIntervalSeconds, 19)
        XCTAssertEqual(after.config.redactWindowTitlePatterns, ["External, exact"])
    }

    func testCaptureOnlyResetReadsFreshConfigurationAndPreservesIndependentDraft() async throws {
        let store = RedactionSettingsFixture(config: .init(redactWindowTitlePatterns: ["Old saved"]))
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        model.editWindow("Unapplied editor draft")
        await store.replaceExternally(.init(captureIntervalSeconds: 19, excludedAppBundleIDs: ["test.external"],
            redactWindowTitlePatterns: ["External, literal", " edge spaces "], idleThresholdSeconds: 321))
        let accepted = await model.reset(.capture, using: store.client)
        XCTAssertTrue(accepted)
        let after = await store.snapshot()
        XCTAssertEqual(after.config.captureIntervalSeconds, SettingsDefaults.captureIntervalSeconds)
        XCTAssertEqual(after.config.redactWindowTitlePatterns, ["External, literal", " edge spaces "])
        XCTAssertEqual(after.config.excludedAppBundleIDs, ["test.external"])
        XCTAssertEqual(after.config.idleThresholdSeconds, 321)
        XCTAssertEqual(model.windowDraft, "Unapplied editor draft")
        XCTAssertTrue(model.canApply)
    }

    func testResetPreservesTypingWhileItsFreshReadIsHeld() async throws {
        let store = RedactionSettingsFixture(config: .init(redactWindowTitlePatterns: ["Saved"])), gate = RedactionSettingsGate()
        let model = CaptureRedactionSettingsModel()
        await model.loadIfNeeded(using: store.client)
        await store.holdNextRead(gate)
        let resetting = Task { await model.reset(.privacy, using: store.client) }
        await fulfillment(of: [gate.entered], timeout: 2)
        model.editWindow("Typed during reset read\n")
        await gate.release()
        let accepted = await resetting.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.windowDraft, "Typed during reset read\n")
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(model.statusMessage, "Settings reset. Your draft has not been applied.")
    }

    private func textEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.isEditable { return editor }
        for child in view.subviews { if let editor = textEditor(in: child) { return editor } }
        return nil
    }
}

/// Controlled owner boundary for editor concurrency tests. Native configuration
/// persistence/admission is covered separately by App/Capture tests.
private actor RedactionSettingsFixture {
    private var state: NativeCaptureState
    private var writes = 0
    private var writeGate: RedactionSettingsGate?
    private var readGate: RedactionSettingsGate?
    init(config: CaptureConfig = .init()) { state = .init(config: config, revision: UUID()) }
    nonisolated var client: CaptureRedactionSettingsClient {
        .init(read: { await self.read() }, update: { try await self.update($0, revision: $1) })
    }
    func snapshot() -> NativeCaptureState { state }
    func attemptCount() -> Int { writes }
    func holdNextWrite(_ gate: RedactionSettingsGate) { writeGate = gate }
    func holdNextRead(_ gate: RedactionSettingsGate) { readGate = gate }
    func replaceExternally(_ config: CaptureConfig) { state = .init(config: config, revision: UUID()) }
    private func read() async -> NativeCaptureState {
        let gate = readGate; readGate = nil
        await gate?.hold()
        return state
    }
    private func update(_ config: CaptureConfig, revision: UUID) async throws {
        writes += 1
        let gate = writeGate; writeGate = nil
        await gate?.hold()
        guard state.revision == revision else { throw RetraceCommandError.revisionConflict }
        state = .init(config: config, revision: UUID())
    }
}

private actor RedactionSettingsGate {
    nonisolated let entered = XCTestExpectation(description: "Configuration boundary held")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold() async {
        entered.fulfill()
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
