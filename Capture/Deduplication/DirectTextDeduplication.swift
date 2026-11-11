import CoreGraphics
import Foundation
import Shared

/// Additional retention evidence for the opt-in direct-text path. This helper
/// never changes pixel sensitivity or grants privacy/visibility permission. It
/// accepts only a complete exact-frame validation of the producer's observation.
enum DirectTextDeduplication {
    static func hasNewEvidence(_ frame: CapturedFrame, comparedTo reference: CapturedFrame?) -> Bool {
        guard let reference, let observation = frame.metadata.captureText,
              observation.availability != .unavailable else { return false }
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            Log.recordLatency("capture.dedup_direct_text",
                valueMs: (ProcessInfo.processInfo.systemUptime - started) * 1_000, category: .capture)
        }
        guard let candidate = signature(frame) else { return false }
        guard let previous = signature(reference) else { return true }
        return candidate != previous
    }

    private struct Signature: Equatable {
        let source: SourceIdentity
        let runs: [Run]
    }

    private struct SourceIdentity: Equatable {
        // Compare exact code units, including opaque generation/document IDs.
        // Swift String equality alone applies Unicode canonical equivalence.
        let app: [UInt16]
        let processID: Int32
        let processGeneration: [UInt16]
        let windowID: UInt32
        let windowGeneration: [UInt16]
        let displayID: UInt32
        let documentID: [UInt16]?

        init(_ context: ActivityContext, windowID: UInt32, windowGeneration: String, displayID: UInt32) {
            app = Array(context.appBundleID.utf16)
            processID = context.processID
            processGeneration = Array(context.processGeneration.utf16)
            self.windowID = windowID
            self.windowGeneration = Array(windowGeneration.utf16)
            self.displayID = displayID
            documentID = context.documentID.map { Array($0.utf16) }
        }
    }

    private struct Run: Equatable {
        let text: [UInt16]
        let bounds: CGRect
        let range: EvidenceUTF16Range
        let role: CaptureTextRole
        let ancestors: [CaptureTextAncestorRole]

        init(_ run: CaptureTextRun) {
            text = Array(run.text.utf16)
            bounds = run.boundsInFramePixels
            range = run.elementUTF16Range
            role = run.role
            ancestors = run.ancestors
        }

        /// Order a multiset without using per-attempt traversal ordinals/IDs.
        /// Geometry and ranges are finite and bounded by validation before sort.
        static func precedes(_ lhs: Run, _ rhs: Run) -> Bool {
            if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
            if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
            if lhs.bounds.width != rhs.bounds.width { return lhs.bounds.width < rhs.bounds.width }
            if lhs.bounds.height != rhs.bounds.height { return lhs.bounds.height < rhs.bounds.height }
            if lhs.range.location != rhs.range.location { return lhs.range.location < rhs.range.location }
            if lhs.range.length != rhs.range.length { return lhs.range.length < rhs.range.length }
            if lhs.role != rhs.role { return lhs.role.rawValue < rhs.role.rawValue }
            if lhs.ancestors != rhs.ancestors {
                return lhs.ancestors.map(\.rawValue).lexicographicallyPrecedes(rhs.ancestors.map(\.rawValue))
            }
            return lhs.text.lexicographicallyPrecedes(rhs.text)
        }
    }

    private static func signature(_ frame: CapturedFrame) -> Signature? {
        // Use the same canonical admission as WAL and SQLite, including the
        // policy digest and metadata app/context binding, not only run encoding.
        guard let observation = try? frame.metadata.validatedCaptureText(frameWidth: frame.width,
                frameHeight: frame.height, timestamp: frame.timestamp), observation.availability != .unavailable,
              let context = observation.sourceContext, let windowID = context.windowID,
              let windowGeneration = context.windowGeneration, let displayID = context.displayID else {
            return nil
        }
        // At most 128 runs / 8192 UTF16 units / 32 KiB per validated observation.
        // A separate signature cache would need its own eviction/privacy fence;
        // derive it from the manager's bounded per-display last-kept frame instead.
        return Signature(source: SourceIdentity(context, windowID: windowID,
            windowGeneration: windowGeneration, displayID: displayID),
            runs: observation.runs.map(Run.init).sorted(by: Run.precedes))
    }
}
