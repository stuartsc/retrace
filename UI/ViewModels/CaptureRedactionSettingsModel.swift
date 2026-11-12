import App
import Combine
import Foundation
import Shared

struct CaptureRedactionSettingsClient: Sendable {
    let read: @Sendable () async throws -> NativeCaptureState
    let update: @Sendable (CaptureConfig, UUID) async throws -> Void

    static func live(_ coordinator: AppCoordinator) -> Self {
        .init(read: { try await coordinator.captureCommandState() }, update: { config, revision in
            try await coordinator.updateCaptureConfig(config, expectedRevision: revision)
        })
    }
}

enum CaptureSettingsResetScope: Equatable {
    case capture, privacy, all
    var includesCapture: Bool { self != .privacy }
    var includesPrivacy: Bool { self != .capture }
}

/// Draft text belongs to the editor, independently of accepted capture settings.
/// Only explicit Apply or Reload actions cross the App-owned configuration boundary.
@MainActor
final class CaptureRedactionSettingsModel: ObservableObject {
    @Published private(set) var windowDraft = ""
    @Published private(set) var urlDraft = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var requiresReload = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private var accepted: NativeCaptureState?
    private var editGeneration: UInt64 = 0

    var isLoaded: Bool { accepted != nil }
    var canApply: Bool { isLoaded && !isLoading && !isSaving && !requiresReload && hasUnappliedChanges }
    var hasUnappliedChanges: Bool {
        guard let accepted else { return false }
        return Self.patterns(windowDraft) != accepted.config.redactWindowTitlePatterns ||
            Self.patterns(urlDraft) != accepted.config.redactBrowserURLPatterns
    }

    func editWindow(_ value: String) {
        guard windowDraft != value else { return }
        windowDraft = value; edited()
    }

    func editURLs(_ value: String) {
        guard urlDraft != value else { return }
        urlDraft = value; edited()
    }

    private func edited() {
        editGeneration &+= 1
        statusMessage = nil
        // A conflict remains visible until an explicit reload, including while typing.
        if !requiresReload { errorMessage = nil }
    }

    func loadIfNeeded(using client: CaptureRedactionSettingsClient) async {
        guard !isLoaded else { return }
        await reload(using: client)
    }

    /// The Reload button explicitly replaces the draft. Text entered after the
    /// request begins still belongs to the user and cannot be replaced by its reply.
    func reload(using client: CaptureRedactionSettingsClient) async {
        guard !isLoading, !isSaving else { return }
        let generation = editGeneration
        isLoading = true; errorMessage = nil; statusMessage = nil
        defer { isLoading = false }
        do {
            let state = try await client.read()
            try Task.checkCancellation()
            accepted = state; requiresReload = false
            if editGeneration == generation {
                windowDraft = state.config.redactWindowTitlePatterns.joined(separator: "\n")
                urlDraft = state.config.redactBrowserURLPatterns.joined(separator: "\n")
            } else {
                statusMessage = "Current settings loaded. Your newer edits are unchanged."
            }
        } catch {
            requiresReload = true
            errorMessage = "Could not load current redaction rules. Your draft is unchanged."
        }
    }

    func apply(using client: CaptureRedactionSettingsClient) async -> (window: Int, url: Int)? {
        guard canApply, let accepted else { return nil }
        let windows = Self.patterns(windowDraft), urls = Self.patterns(urlDraft)
        let config = replacing(accepted.config, windows: windows, urls: urls)
        guard await submit(config, revision: accepted.revision, using: client) else { return nil }
        return (windows.count, urls.count)
    }

    /// All three Settings reset routes make one CAS against a fresh owner snapshot.
    /// Local preferences and reset drafts are published only after that write is
    /// accepted; typing during either the read or the write remains independent.
    func reset(_ scope: CaptureSettingsResetScope, using client: CaptureRedactionSettingsClient,
               onAccepted: @MainActor () -> Void = {}) async -> Bool {
        guard !isLoading, !isSaving else { return false }
        let generation = editGeneration
        isSaving = true; errorMessage = nil; statusMessage = nil
        defer { isSaving = false }
        let state: NativeCaptureState
        do {
            state = try await client.read()
            try Task.checkCancellation()
        } catch {
            errorMessage = "Could not read capture settings. Nothing was reset. Your draft is unchanged."
            return false
        }
        let old = state.config
        let config = CaptureConfig(
            captureIntervalSeconds: scope.includesCapture ? SettingsDefaults.captureIntervalSeconds : old.captureIntervalSeconds,
            adaptiveCaptureEnabled: scope.includesCapture ? SettingsDefaults.deleteDuplicateFrames : old.adaptiveCaptureEnabled,
            deduplicationThreshold: scope.includesCapture ? SettingsDefaults.deduplicationThreshold : old.deduplicationThreshold,
            maxResolution: old.maxResolution,
            excludedAppBundleIDs: scope.includesPrivacy ? ["com.apple.loginwindow"] : old.excludedAppBundleIDs,
            excludePrivateWindows: scope.includesPrivacy ? SettingsDefaults.excludePrivateWindows : old.excludePrivateWindows,
            customPrivateWindowPatterns: old.customPrivateWindowPatterns, showCursor: old.showCursor,
            redactWindowTitlePatterns: scope.includesPrivacy ? [] : old.redactWindowTitlePatterns,
            redactBrowserURLPatterns: scope.includesPrivacy ? [] : old.redactBrowserURLPatterns,
            idleThresholdSeconds: old.idleThresholdSeconds,
            captureOnWindowChange: scope.includesCapture ? SettingsDefaults.captureOnWindowChange : old.captureOnWindowChange)
        return await submit(config, revision: state.revision, using: client, resetting: true) {
            if scope.includesPrivacy, self.editGeneration == generation {
                self.windowDraft = ""; self.urlDraft = ""
            }
            onAccepted()
        }
    }

    private func submit(_ config: CaptureConfig, revision: UUID,
                        using client: CaptureRedactionSettingsClient, resetting: Bool = false,
                        onAccepted: @MainActor () -> Void = {}) async -> Bool {
        let generation = editGeneration
        isSaving = true; errorMessage = nil; statusMessage = nil
        defer { isSaving = false }
        do {
            try await client.update(config, revision)
        } catch {
            if case .revisionConflict? = error as? RetraceCommandError {
                requiresReload = true
                errorMessage = "Capture settings changed elsewhere. Reload saved rules before applying. Your draft is unchanged."
            } else {
                errorMessage = resetting ? "Could not reset capture settings. Your draft is unchanged."
                    : "Could not apply redaction rules. Your draft is unchanged."
            }
            return false
        }
        onAccepted()

        // The write is accepted. Failure to refresh cannot turn it into a failed
        // save or silently retry it with a newer revision.
        do {
            let state = try await client.read()
            guard state.config.redactWindowTitlePatterns == config.redactWindowTitlePatterns,
                  state.config.redactBrowserURLPatterns == config.redactBrowserURLPatterns else {
                requiresReload = true
                errorMessage = "Rules were applied, then changed elsewhere. Reload saved rules to see the current settings. Your draft is unchanged."
                return true
            }
            accepted = state
            requiresReload = false
            statusMessage = editGeneration == generation
                ? (resetting ? "Settings reset." : "Rules applied.")
                : "Earlier rules applied. Your newer edits have not been applied."
            if resetting, hasUnappliedChanges {
                statusMessage = "Settings reset. Your draft has not been applied."
            }
        } catch {
            requiresReload = true
            errorMessage = "Rules were applied, but their current state could not be refreshed. Reload saved rules. Your draft is unchanged."
        }
        return true
    }

    /// Newlines separate rules; commas and spaces are literal pattern characters.
    /// Empty lines do not create a rule, but remain in the independent draft text.
    private static func patterns(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func replacing(_ old: CaptureConfig, windows: [String], urls: [String]) -> CaptureConfig {
        CaptureConfig(captureIntervalSeconds: old.captureIntervalSeconds,
            adaptiveCaptureEnabled: old.adaptiveCaptureEnabled, deduplicationThreshold: old.deduplicationThreshold,
            maxResolution: old.maxResolution,
            excludedAppBundleIDs: old.excludedAppBundleIDs,
            excludePrivateWindows: old.excludePrivateWindows,
            customPrivateWindowPatterns: old.customPrivateWindowPatterns, showCursor: old.showCursor,
            redactWindowTitlePatterns: windows, redactBrowserURLPatterns: urls,
            idleThresholdSeconds: old.idleThresholdSeconds, captureOnWindowChange: old.captureOnWindowChange)
    }
}
