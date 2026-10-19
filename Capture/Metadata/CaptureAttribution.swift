import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import Shared

struct CapturedWindowSample: Sendable {
    let context: ActivityContext?
    let observedAt: Date
    let monotonicTime: TimeInterval
    let privacySignature: String?
    let failure: CaptureSamplingOutcome?
    init(context: ActivityContext?, observedAt: Date = Date(),
         monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime, privacySignature: String? = nil,
         failure: CaptureSamplingOutcome? = nil) {
        self.context = context; self.observedAt = observedAt; self.monotonicTime = monotonicTime
        self.privacySignature = privacySignature
        self.failure = failure
    }
}

enum CaptureSnapshotSequencer {
    static func capture(displayID: UInt32,
                        readContext: @Sendable () async -> CapturedWindowSample,
                        capturePixels: @Sendable () async throws -> CapturedFrame?,
                        recordOutcome: @Sendable (CaptureSamplingOutcome) -> Void = { _ in }) async rethrows -> CapturedFrame? {
        var outcome = CaptureSamplingOutcome.cancelled
        defer { recordOutcome(outcome) }
        guard !Task.isCancelled else { return nil }
        outcome = .invalidDisplay
        guard displayID > 0 else { return nil }
        // Durable window identity survives title/move noise. Keep a separate
        // notification receipt across metadata AND pixels so A -> B -> A cannot
        // pass merely because the final context and window inventory match.
        let notificationRevision = ObservedWindowGenerations.shared.notificationRevision
        let before = await readContext()
        outcome = .cancelled
        guard !Task.isCancelled else { return nil }
        outcome = before.failure ?? .contextUnavailable
        guard let sampled = before.context else { return nil }
        outcome = .windowIdentityUnavailable
        guard sampled.windowID.map({ $0 > 0 }) == true,
              sampled.windowGeneration?.isEmpty == false, sampled.processID > 0,
              !sampled.processGeneration.isEmpty else { return nil }
        outcome = .displayMismatch
        guard sampled.displayID == displayID else { return nil }
        outcome = .inventoryUnavailable
        guard before.privacySignature != nil else { return nil }
        outcome = .notificationChangedBeforePixels
        guard notificationRevision == ObservedWindowGenerations.shared.notificationRevision else { return nil }
        let capturedAt = Date()
        let captureMonotonic = ProcessInfo.processInfo.systemUptime
        outcome = .pixelsUnavailable
        let capturedPixels: CapturedFrame?
        do { capturedPixels = try await capturePixels() }
        catch {
            if Task.isCancelled || error is CancellationError { outcome = .cancelled }
            throw error
        }
        outcome = .cancelled
        guard !Task.isCancelled else { return nil }
        outcome = .pixelsUnavailable
        guard let pixels = capturedPixels else { return nil }
        outcome = .cancelled
        let after = await readContext()
        guard !Task.isCancelled else { return nil }
        outcome = after.failure ?? .contextChanged
        guard sampled == after.context else { return nil }
        outcome = .notificationChangedDuringPixels
        guard notificationRevision == ObservedWindowGenerations.shared.notificationRevision else { return nil }
        outcome = .inventoryChanged
        guard before.privacySignature == after.privacySignature else { return nil }
        outcome = .invalidClock
        guard before.monotonicTime.isFinite, after.monotonicTime.isFinite,
              after.monotonicTime >= before.monotonicTime else { return nil }
        outcome = .samplingTooSlow
        guard after.monotonicTime - before.monotonicTime <= 2 else { return nil }
        let context = pixels.metadata.redactionReason == nil ? sampled : nil
        let metadata = FrameMetadata(appBundleID: context?.appBundleID, appName: context?.appName,
            windowName: context?.windowTitle, browserURL: context?.safeURL,
            redactionReason: pixels.metadata.redactionReason, displayID: displayID,
            captureContext: context, captureMonotonicTime: captureMonotonic)
        outcome = .accepted
        return CapturedFrame(timestamp: capturedAt, imageData: pixels.imageData,
            width: pixels.width, height: pixels.height, bytesPerRow: pixels.bytesPerRow, metadata: metadata)
    }
}

/// Only external workspace/window/AX reads are replaceable; observation ordering,
/// privacy admission and persistence remain in the production monitor.
struct ActivityContextSource: Sendable {
    let frontmost: @Sendable () async -> ActivityApplicationSnapshot?
    let window: @Sendable (ActivityApplicationSnapshot, Bool, CaptureConfig) async -> ActivityContext?
    let document: @Sendable (ActivityContext, ActivityApplicationSnapshot) async -> ActivityContext?
    let permission: @Sendable () -> Bool

    static let live = ActivityContextSource(
        frontmost: { await MainActor.run { ActivityApplicationSnapshot(NSWorkspace.shared.frontmostApplication) } },
        window: { app, focused, config in AppInfoProvider().activityContext(for: app, isStillFocused: focused, config: config) },
        document: { context, app in AppInfoProvider().activityDocumentContext(context, app: app) },
        permission: { AXIsProcessTrusted() }
    )

    func sampleCapture(config: CaptureConfig, displayID: UInt32) async -> CapturedWindowSample {
        guard let initialInventory = visibleWindowSignature(displayID: displayID) else {
            return CapturedWindowSample(context: nil, failure: .inventoryUnavailable)
        }
        guard let app = await frontmost() else {
            return CapturedWindowSample(context: nil, failure: .applicationUnavailable)
        }
        guard let base = await window(app, true, config) else {
            return CapturedWindowSample(context: nil, failure: .windowUnavailable)
        }
        let context = await document(base, app) ?? base
        guard app == (await frontmost()) else {
            return CapturedWindowSample(context: nil, failure: .focusedApplicationChanged)
        }
        guard context.displayID == displayID else {
            return CapturedWindowSample(context: nil, failure: .displayMismatch)
        }
        guard let finalInventory = visibleWindowSignature(displayID: displayID) else {
            return CapturedWindowSample(context: nil, failure: .inventoryUnavailable)
        }
        guard initialInventory == finalInventory else {
            return CapturedWindowSample(context: nil, failure: .inventoryChangedDuringMetadata)
        }
        return CapturedWindowSample(context: context, privacySignature: finalInventory)
    }

    /// An opaque inventory receipt protects exclusion masks from background-window
    /// changes. Raw titles exist only within this call and never enter logs or caches.
    private func visibleWindowSignature(displayID: UInt32) -> String? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              windows.count <= 4096,
              windows.allSatisfy({ ($0[kCGWindowName as String] as? String ?? "").utf8.count <= 4096 }) else { return nil }
        let display = CGDisplayBounds(displayID)
        var entries: [String] = []
        for window in windows {
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            guard bounds.intersects(display) else { continue }
            let title = window[kCGWindowName as String] as? String ?? ""
            let titleDigest = SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            entries.append("\(id)|\(pid)|\(layer)|\(bounds)|\(alpha)|\(titleDigest)")
        }
        return SHA256.hash(data: Data(entries.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A process/session-scoped observation identity, shared by activity and pixels.
/// Missing windows, process restarts, lifecycle gaps and focus notifications
/// invalidate previous generations. No title or URL is retained in this registry.
final class ObservedWindowGenerations: @unchecked Sendable {
    static let shared = ObservedWindowGenerations()
    private struct Process: Hashable { let pid: Int32; let generation: String }
    private let lock = NSLock()
    private var session = UUID()
    private var windows: [Process: [UInt32: UUID]] = [:]
    private var revision: UInt64 = 0

    /// Ephemeral, process-local admission state; never part of a durable context.
    var notificationRevision: UInt64 { lock.withLock { revision } }

    func noteNotification(resettingWindows: Bool) {
        lock.withLock {
            revision += 1
            if resettingWindows { session = UUID(); windows.removeAll() }
        }
    }

    func generation(processID: Int32, processGeneration: String, windowID: UInt32,
                    visibleWindowIDs: Set<UInt32>) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard processID > 0, !processGeneration.isEmpty, windowID > 0 else { return nil }
        let process = Process(pid: processID, generation: processGeneration)
        windows = windows.filter { $0.key.pid != processID || $0.key == process }
        if windows.count >= 256 && windows[process] == nil { windows.removeAll(); session = UUID() }
        var observed = windows[process, default: [:]].filter { visibleWindowIDs.contains($0.key) }
        guard visibleWindowIDs.contains(windowID) else { windows[process] = observed; return nil }
        let generation = observed[windowID] ?? UUID()
        observed[windowID] = generation
        windows[process] = observed
        return "\(session.uuidString):\(processGeneration):\(windowID):\(generation.uuidString)"
    }

    func reset() { noteNotification(resettingWindows: true) }
}
