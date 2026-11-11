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
    /// Only a privacy-masked all-display source may grant display-only admission.
    /// Nil context without this explicit display receipt continues to deny pixels.
    let displayOnlyID: UInt32?
    init(context: ActivityContext?, observedAt: Date = Date(),
         monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime, privacySignature: String? = nil,
         displayOnlyID: UInt32? = nil) {
        self.context = context; self.observedAt = observedAt; self.monotonicTime = monotonicTime
        self.privacySignature = privacySignature
        self.displayOnlyID = displayOnlyID
    }
}

enum CaptureSnapshotSequencer {
    static func capture(displayID: UInt32,
                        allowDisplayOnly: Bool = false,
                        capturePolicySHA256: String? = nil,
                        readContext: @Sendable () async -> CapturedWindowSample,
                        capturePixels: @Sendable () async throws -> CapturedFrame?) async rethrows -> CapturedFrame? {
        try await captureAttributed(displayID: displayID, allowDisplayOnly: allowDisplayOnly,
            capturePolicySHA256: capturePolicySHA256, readContext: readContext) { _ in
                guard let frame = try await capturePixels() else { return nil }
                return CaptureAttributedPixelRead(frame: frame)
            }
    }

    static func captureAttributed(displayID: UInt32,
                        allowDisplayOnly: Bool = false,
                        capturePolicySHA256: String? = nil,
                        readContext: @Sendable () async -> CapturedWindowSample,
                        capturePixels: @Sendable (ActivityContext?) async throws -> CaptureAttributedPixelRead?) async rethrows -> CapturedFrame? {
        guard displayID > 0, !Task.isCancelled else { return nil }
        // Durable window identity survives title/move noise. Keep a separate
        // notification receipt across metadata AND pixels so A -> B -> A cannot
        // pass merely because the final context and window inventory match.
        let notificationRevision = ObservedWindowGenerations.shared.notificationRevision
        let before = await readContext()
        let sampled = before.context
        let focusedWindowIsProven = sampled.map {
            $0.windowID.map({ $0 > 0 }) == true && $0.windowGeneration?.isEmpty == false &&
                $0.processID > 0 && !$0.processGeneration.isEmpty && $0.displayID == displayID
        } ?? false
        let displayIsProven = allowDisplayOnly && sampled == nil && before.displayOnlyID == displayID
        guard !Task.isCancelled, focusedWindowIsProven || displayIsProven, before.privacySignature != nil,
              notificationRevision == ObservedWindowGenerations.shared.notificationRevision else { return nil }
        let capturedAt = Date()
        let captureMonotonic = ProcessInfo.processInfo.systemUptime
        guard let read = try await capturePixels(sampled), !Task.isCancelled,
              !allowDisplayOnly || read.frame.metadata.displayID == displayID else { return nil }
        let pixels = read.frame
        let after = await readContext()
        guard !Task.isCancelled, sampled == after.context,
              before.displayOnlyID == after.displayOnlyID,
              notificationRevision == ObservedWindowGenerations.shared.notificationRevision,
              before.privacySignature == after.privacySignature,
              before.monotonicTime.isFinite, after.monotonicTime.isFinite,
              after.monotonicTime >= before.monotonicTime,
              after.monotonicTime - before.monotonicTime <= 2 else { return nil }
        let context = pixels.metadata.redactionReason == nil ? sampled : nil
        let receipt = read.pixelReceipt
        if let receipt {
            let span = receipt.interval
            guard span.startedAt.timeIntervalSince1970.isFinite, span.endedAt.timeIntervalSince1970.isFinite,
                  span.endedAt >= span.startedAt, span.startedUptime.isFinite, span.endedUptime.isFinite,
                  span.startedUptime >= before.monotonicTime, span.endedUptime >= span.startedUptime,
                  span.endedUptime <= after.monotonicTime else { return nil }
        }
        let timestamp = receipt?.interval.startedAt ?? capturedAt
        let monotonic = receipt?.interval.startedUptime ?? captureMonotonic
        var text = read.captureText
        if let retained = text {
            do {
                guard pixels.metadata.redactionReason == nil else { throw CaptureTextObservation.ValidationError.malformedObservation }
                _ = try retained.retainedTextEncoding(frameWidth: pixels.width, frameHeight: pixels.height,
                    displayID: displayID, frameTimestamp: timestamp, frameMonotonicTime: monotonic,
                    pixelReceipt: receipt, sourceContext: context)
            } catch {
                let unavailable = CaptureTextObservation(captureAttemptID: receipt?.attemptID, sourceContext: nil,
                    preRead: nil, pixelRead: nil, postRead: nil, availability: .unavailable,
                    reasons: [pixels.metadata.redactionReason == nil ? .sourceChanged : .privacyMasked],
                    consistency: nil, runs: [])
                text = (try? unavailable.retainedTextEncoding(frameWidth: pixels.width, frameHeight: pixels.height,
                    displayID: displayID, frameTimestamp: timestamp, frameMonotonicTime: monotonic,
                    pixelReceipt: receipt, sourceContext: context)) == nil ? nil : unavailable
            }
        }
        let metadata = FrameMetadata(appBundleID: context?.appBundleID, appName: context?.appName,
            windowName: context?.windowTitle, browserURL: context?.safeURL,
            redactionReason: pixels.metadata.redactionReason, displayID: displayID,
            captureContext: context, captureMonotonicTime: monotonic,
            capturePolicySHA256: capturePolicySHA256, pixelReceipt: receipt, captureText: text)
        return CapturedFrame(timestamp: timestamp, imageData: pixels.imageData,
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
        guard let initialInventory = visibleWindowSignature(displayID: displayID),
              let app = await frontmost(), let base = await window(app, true, config) else {
            return CapturedWindowSample(context: nil)
        }
        let context = await document(base, app) ?? base
        guard app == (await frontmost()), context.displayID == displayID,
              let finalInventory = visibleWindowSignature(displayID: displayID),
              initialInventory == finalInventory else {
            return CapturedWindowSample(context: nil)
        }
        return CapturedWindowSample(context: context, privacySignature: finalInventory)
    }

    /// Nonfocused displays never inherit the frontmost window's identity. The
    /// candidate's strict full-window privacy masks are mandatory for this path.
    func sampleCandidateCapture(config: CaptureConfig, displayID: UInt32) async -> CapturedWindowSample {
        guard let initialInventory = visibleWindowSignature(displayID: displayID) else {
            return CapturedWindowSample(context: nil)
        }
        var sampled: ActivityContext?
        if let app = await frontmost(), ObservedWindowGenerations.shared.hasCaptureObservation(processID: app.pid),
           let base = await window(app, true, config), base.displayID == displayID {
            let enriched = await document(base, app) ?? base
            guard app == (await frontmost()),
                  ObservedWindowGenerations.shared.hasCaptureObservation(processID: app.pid) else {
                return CapturedWindowSample(context: nil)
            }
            sampled = enriched
        }
        guard let finalInventory = visibleWindowSignature(displayID: displayID),
              initialInventory == finalInventory else { return CapturedWindowSample(context: nil) }
        return CapturedWindowSample(context: sampled, privacySignature: finalInventory,
                                    displayOnlyID: sampled == nil ? displayID : nil)
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
    private var captureObservationToken: UUID?
    private var captureObservedProcessID: Int32?

    /// Ephemeral, process-local admission state; never part of a durable context.
    var notificationRevision: UInt64 { lock.withLock { revision } }

    func beginCaptureObservation(token: UUID) {
        lock.withLock {
            captureObservationToken = token; captureObservedProcessID = nil
            session = UUID(); windows.removeAll()
            revision &+= 1
        }
    }

    func endCaptureObservation(token: UUID) {
        lock.withLock {
            guard captureObservationToken == token else { return }
            captureObservationToken = nil; captureObservedProcessID = nil
            session = UUID(); windows.removeAll()
            revision &+= 1
        }
    }

    func suspendCaptureObservation(token: UUID) {
        lock.withLock {
            guard captureObservationToken == token else { return }
            captureObservedProcessID = nil
            revision &+= 1
        }
    }

    func confirmCaptureObservation(token: UUID, processID: Int32, revision expected: UInt64) -> Bool {
        lock.withLock {
            guard captureObservationToken == token, processID > 0, revision == expected else { return false }
            captureObservedProcessID = processID
            return true
        }
    }

    func hasCaptureObservation(processID: Int32) -> Bool {
        lock.withLock { captureObservationToken != nil && captureObservedProcessID == processID && processID > 0 }
    }

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
