import CoreGraphics
import Foundation

/// Public AX and screenshot APIs do not supply one atomic snapshot. These
/// intervals describe a checked same-window bracket, never pixel/text equality.
public struct CaptureReadInterval: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let startedUptime: TimeInterval
    public let endedUptime: TimeInterval

    public init(startedAt: Date, endedAt: Date, startedUptime: TimeInterval, endedUptime: TimeInterval) {
        self.startedAt = startedAt; self.endedAt = endedAt
        self.startedUptime = startedUptime; self.endedUptime = endedUptime
    }

    fileprivate var isValid: Bool {
        startedAt.timeIntervalSince1970.isFinite && endedAt.timeIntervalSince1970.isFinite &&
        endedAt >= startedAt && startedUptime.isFinite && endedUptime.isFinite &&
        startedUptime >= 0 && endedUptime >= startedUptime
    }
}

public enum CaptureTextAvailability: String, Codable, Sendable { case available, partial, unavailable }

/// Issued once around an actual native pixel request. The frame retains this
/// receipt independently of optional direct text; IDs are never recycled.
public struct CapturePixelReceipt: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let interval: CaptureReadInterval
    public init(attemptID: UUID, interval: CaptureReadInterval) {
        self.attemptID = attemptID; self.interval = interval
    }
}

public enum CaptureTextConsistency: String, Codable, Sendable { case sameWindowBracketed }
public enum CaptureTextReason: String, Codable, Sendable {
    case disabled, permissionUnavailable, focusedWindowUnavailable, windowIdentityUnproved
    case sourceChanged, visibilityUnverified, privacyMasked, occluded, unsupportedRole, unsupportedRange
    case mutationObserverUnavailable, invalidGeometry, budgetExceeded, textChanged, cancelled, captureFailed, noVisibleText
}

/// Initial direct-text admission excludes text fields, including secure fields.
/// A decoded known role is a retained producer claim, not a new visibility grant.
public enum CaptureTextRole: String, Codable, Sendable { case textArea, staticText }
public enum CaptureTextAncestorRole: String, Codable, Sendable {
    case window, group, splitGroup, scrollArea, webArea, sheet, tabGroup
}

public struct CaptureTextRun: Codable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let elementOrdinal: Int
    public let text: String
    /// UTF-16 coordinates in the source AX element, never an OCR channel or a
    /// concatenation of runs. The exact native range is retained without trimming.
    public let elementUTF16Range: EvidenceUTF16Range
    /// Whole-run bounds in original frame pixels, with top-left origin.
    public let boundsInFramePixels: CGRect
    public let role: CaptureTextRole
    /// Window first, leaf's parent last. Unknown/secure ancestry is inadmissible.
    public let ancestors: [CaptureTextAncestorRole]

    public init(id: Int, elementOrdinal: Int, text: String, elementUTF16Range: EvidenceUTF16Range,
                boundsInFramePixels: CGRect, role: CaptureTextRole, ancestors: [CaptureTextAncestorRole]) {
        self.id = id; self.elementOrdinal = elementOrdinal; self.text = text
        self.elementUTF16Range = elementUTF16Range; self.boundsInFramePixels = boundsInFramePixels
        self.role = role; self.ancestors = ancestors
    }
}

/// Immutable direct text is kept separate from OCR and interpreted descriptions.
/// Every consumer must validate decoded observations against its exact frame.
public struct CaptureTextObservation: Codable, Equatable, Sendable, Identifiable {
    public static let maximumJSONBytes = 32 * 1_024
    public static let maximumRuns = 128
    public static let maximumUTF16Units = 8_192
    public let formatVersion: Int
    public let id: UUID
    public let extractorIdentifier: String
    public let extractorVersion: Int
    public let sourceContext: ActivityContext?
    public let captureAttemptID: UUID?
    public let preRead: CaptureReadInterval?
    public let pixelRead: CaptureReadInterval?
    public let postRead: CaptureReadInterval?
    public let availability: CaptureTextAvailability
    public let reasons: [CaptureTextReason]
    public let consistency: CaptureTextConsistency?
    public let runs: [CaptureTextRun]

    public init(id: UUID = UUID(), captureAttemptID: UUID?, sourceContext: ActivityContext?, preRead: CaptureReadInterval?,
                pixelRead: CaptureReadInterval?, postRead: CaptureReadInterval?, availability: CaptureTextAvailability,
                reasons: [CaptureTextReason], consistency: CaptureTextConsistency?, runs: [CaptureTextRun]) {
        self.formatVersion = 1; self.id = id
        self.extractorIdentifier = "retrace.visible-ax"; self.extractorVersion = 1
        self.captureAttemptID = captureAttemptID
        self.sourceContext = sourceContext; self.preRead = preRead; self.pixelRead = pixelRead; self.postRead = postRead
        self.availability = availability; self.reasons = reasons; self.consistency = consistency; self.runs = runs
    }

    public enum ValidationError: Error, Sendable { case malformedObservation, sizeLimit }

    /// Canonical encoding is also the read-side validator. No trimming, clipping,
    /// unknown-role upgrade or repair of malformed retained content is permitted.
    public func retainedTextEncoding(frameWidth: Int, frameHeight: Int, displayID: UInt32,
                                     frameTimestamp: Date, frameMonotonicTime: TimeInterval?,
                                     pixelReceipt: CapturePixelReceipt?,
                                     sourceContext expectedContext: ActivityContext?) throws -> Data {
        guard formatVersion == 1, extractorIdentifier == "retrace.visible-ax", extractorVersion == 1,
              (1...32_768).contains(frameWidth), (1...32_768).contains(frameHeight), displayID > 0,
              reasons.count <= 16, Set(reasons.map(\.rawValue)).count == reasons.count,
              runs.count <= Self.maximumRuns,
              [preRead, pixelRead, postRead].compactMap({ $0 }).allSatisfy(\.isValid) else {
            throw ValidationError.malformedObservation
        }
        if let sourceContext {
            guard sourceContext == expectedContext, sourceContext.processID > 0,
                  !sourceContext.processGeneration.isEmpty, !sourceContext.appBundleID.isEmpty,
                  sourceContext.windowID.map({ $0 > 0 }) == true,
                  sourceContext.windowGeneration?.isEmpty == false, sourceContext.displayID == displayID else {
                throw ValidationError.malformedObservation
            }
        }
        if let captureAttemptID {
            guard captureAttemptID == pixelReceipt?.attemptID else { throw ValidationError.malformedObservation }
        }
        if let pixelRead {
            guard pixelRead == pixelReceipt?.interval else { throw ValidationError.malformedObservation }
        }
        switch availability {
        case .unavailable:
            guard runs.isEmpty, consistency == nil, sourceContext == nil, !reasons.isEmpty else {
                throw ValidationError.malformedObservation
            }
        case .available, .partial:
            guard sourceContext != nil, !runs.isEmpty, consistency == .sameWindowBracketed,
                  availability == .available ? reasons.isEmpty : !reasons.isEmpty,
                  let preRead, let pixelRead, let postRead,
                  let pixelReceipt, captureAttemptID == pixelReceipt.attemptID,
                  pixelRead == pixelReceipt.interval,
                  frameTimestamp.timeIntervalSince1970.isFinite,
                  // WAL serializes Unix seconds; exact comparison in that same
                  // representation tolerates only its epoch-conversion rounding.
                  frameTimestamp.timeIntervalSince1970 == pixelRead.startedAt.timeIntervalSince1970,
                  frameMonotonicTime == pixelRead.startedUptime,
                  preRead.endedUptime <= pixelRead.startedUptime,
                  pixelRead.endedUptime <= postRead.startedUptime,
                  preRead.endedAt <= pixelRead.startedAt, pixelRead.endedAt <= postRead.startedAt,
                  postRead.endedUptime - preRead.startedUptime <= 2,
                  !reasons.contains(where: { ![.privacyMasked, .occluded, .unsupportedRole, .unsupportedRange,
                                               .visibilityUnverified, .invalidGeometry, .budgetExceeded].contains($0) }) else {
                throw ValidationError.malformedObservation
            }
        }
        var identifiers = Set<Int>()
        var units = 0
        for run in runs {
            let range = run.elementUTF16Range, bounds = run.boundsInFramePixels
            let length = run.text.utf16.count
            guard run.id >= 0, identifiers.insert(run.id).inserted, (0..<256).contains(run.elementOrdinal),
                  length > 0, length <= Self.maximumUTF16Units - units,
                  range.location >= 0, range.length == length,
                  !range.location.addingReportingOverflow(range.length).overflow,
                  !run.ancestors.isEmpty, run.ancestors.count <= 12, run.ancestors.first == .window,
                  !bounds.isNull, !bounds.isInfinite,
                  bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.minX >= 0, bounds.minY >= 0, bounds.width > 0, bounds.height > 0,
                  bounds.maxX <= CGFloat(frameWidth), bounds.maxY <= CGFloat(frameHeight) else {
                throw ValidationError.malformedObservation
            }
            units += length
        }
        for elementRuns in Dictionary(grouping: runs, by: \.elementOrdinal).values {
            guard let first = elementRuns.first,
                  elementRuns.allSatisfy({ $0.role == first.role && $0.ancestors == first.ancestors }) else {
                throw ValidationError.malformedObservation
            }
            let ordered = elementRuns.sorted { $0.elementUTF16Range.location < $1.elementUTF16Range.location }
            for (previous, next) in zip(ordered, ordered.dropFirst()) {
                guard previous.elementUTF16Range.location + previous.elementUTF16Range.length <= next.elementUTF16Range.location else {
                    throw ValidationError.malformedObservation
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumJSONBytes else { throw ValidationError.sizeLimit }
        return data
    }
}

/// Content-free producer measurements; no native IDs, text, URLs or titles.
public struct CaptureTextOutcome: Sendable {
    public let backend: CaptureBackend
    public let availability: CaptureTextAvailability
    public let reasons: [CaptureTextReason]
    public let visitedNodes: Int
    public let retainedRuns: Int
    public let retainedUTF16Units: Int
    public let preReadMilliseconds: Double?
    public let postReadMilliseconds: Double?

    public init(backend: CaptureBackend, availability: CaptureTextAvailability, reasons: [CaptureTextReason],
                visitedNodes: Int, retainedRuns: Int, retainedUTF16Units: Int,
                preReadMilliseconds: Double?, postReadMilliseconds: Double?) {
        self.backend = backend; self.availability = availability; self.reasons = reasons
        self.visitedNodes = visitedNodes; self.retainedRuns = retainedRuns; self.retainedUTF16Units = retainedUTF16Units
        self.preReadMilliseconds = preReadMilliseconds; self.postReadMilliseconds = postReadMilliseconds
    }
}


extension FrameMetadata {
    /// Structural validation for persistence/readback. This does not authorize
    /// current privacy access or disclosure, and must use the original capture
    /// timestamp rather than the millisecond-quantized compatible frame table.
    @discardableResult
    public func validatedCaptureText(frameWidth: Int, frameHeight: Int,
                                     timestamp: Date) throws -> CaptureTextObservation? {
        if let receipt = pixelReceipt {
            guard receipt.interval.isValid, timestamp.timeIntervalSince1970.isFinite,
                  timestamp.timeIntervalSince1970 == receipt.interval.startedAt.timeIntervalSince1970,
                  captureMonotonicTime == receipt.interval.startedUptime else {
                throw CaptureTextObservation.ValidationError.malformedObservation
            }
        }
        if let group = captureGroup {
            guard let pixels = pixelReceipt, group.attemptID == pixels.attemptID,
                  group.configurationGeneration <= UInt64(Int64.max), group.displayID > 0,
                  group.displayID == displayID, let digest = capturePolicySHA256,
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw CaptureTextObservation.ValidationError.malformedObservation
            }
        }
        guard let text = captureText else { return nil }
        guard let digest = capturePolicySHA256, digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              text.runs.isEmpty || (redactionReason == nil && appBundleID == captureContext?.appBundleID) else {
            throw CaptureTextObservation.ValidationError.malformedObservation
        }
        _ = try text.retainedTextEncoding(frameWidth: frameWidth, frameHeight: frameHeight, displayID: displayID,
            frameTimestamp: timestamp, frameMonotonicTime: captureMonotonicTime, pixelReceipt: pixelReceipt,
            sourceContext: captureContext)
        return text
    }
}

extension ScreenEvidenceSnapshot {
    /// Validate away from SwiftUI render paths, after current evidence admission.
    /// OCR-scoped references do not automatically expand into another channel.
    public var validatedCaptureText: CaptureTextObservation? {
        guard ref.source == .native, frame.source == .native, !legacyContext, ref.blockIDs.isEmpty else { return nil }
        return try? frame.metadata.validatedCaptureText(frameWidth: width, frameHeight: height,
                                                       timestamp: frame.timestamp)
    }
}
