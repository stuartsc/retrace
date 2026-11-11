import CoreGraphics
import Foundation

/// One observed display attachment/mode lifetime within a capture source session.
/// Attachment IDs change on removal, reconfiguration, mode change or restart;
/// the WindowServer numeric ID and monitor UUID alone do not prove that lifetime.
public struct CaptureDisplayAttachment: Codable, Equatable, Sendable {
    public let attachmentID: UUID
    public let displayID: UInt32
    public let monitorUUID: UUID
    public let bounds: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let rotationDegrees: Double
    public let refreshRateHz: Double
    public let modeID: UInt32

    public init(attachmentID: UUID, displayID: UInt32, monitorUUID: UUID, bounds: CGRect,
                pixelWidth: Int, pixelHeight: Int, rotationDegrees: Double,
                refreshRateHz: Double, modeID: UInt32) {
        self.attachmentID = attachmentID; self.displayID = displayID; self.monitorUUID = monitorUUID
        self.bounds = bounds; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.rotationDegrees = rotationDegrees; self.refreshRateHz = refreshRateHz; self.modeID = modeID
    }
}

/// Reserved before any native pixel request. Beginning a group durably creates
/// a pending member for every target, including targets that later become lost.
public struct CaptureSamplingTarget: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let attachment: CaptureDisplayAttachment
    public init(attemptID: UUID, attachment: CaptureDisplayAttachment) {
        self.attemptID = attemptID; self.attachment = attachment
    }
}

public struct CaptureSamplingGroup: Codable, Equatable, Sendable {
    public static let maximumTargets = 64
    public let formatVersion: Int
    public let groupID: UUID
    public let sessionID: UUID
    public let configurationGeneration: UInt64
    public let backend: CaptureBackend
    public let displayPolicy: CaptureDisplayPolicy
    public let capturePolicySHA256: String
    public let enumeration: CaptureReadInterval
    public let targets: [CaptureSamplingTarget]

    public init(groupID: UUID, sessionID: UUID, configurationGeneration: UInt64,
                backend: CaptureBackend, displayPolicy: CaptureDisplayPolicy,
                capturePolicySHA256: String, enumeration: CaptureReadInterval,
                targets: [CaptureSamplingTarget]) {
        formatVersion = 1
        self.groupID = groupID; self.sessionID = sessionID
        self.configurationGeneration = configurationGeneration; self.backend = backend
        self.displayPolicy = displayPolicy; self.capturePolicySHA256 = capturePolicySHA256
        self.enumeration = enumeration; self.targets = targets
    }
}

/// Optional frame metadata. This reference never changes an earlier sample's
/// timestamp. A grouped frame also retains its own exact CapturePixelReceipt.
public struct CaptureGroupFrameReceipt: Codable, Equatable, Sendable {
    public let groupID: UUID
    public let sessionID: UUID
    public let configurationGeneration: UInt64
    public let attemptID: UUID
    public let attachmentID: UUID
    public let displayID: UInt32

    public init(groupID: UUID, sessionID: UUID, configurationGeneration: UInt64,
                attemptID: UUID, attachmentID: UUID, displayID: UInt32) {
        self.groupID = groupID; self.sessionID = sessionID
        self.configurationGeneration = configurationGeneration; self.attemptID = attemptID
        self.attachmentID = attachmentID; self.displayID = displayID
    }

    public init(group: CaptureSamplingGroup, target: CaptureSamplingTarget) {
        self.init(groupID: group.groupID, sessionID: group.sessionID,
            configurationGeneration: group.configurationGeneration, attemptID: target.attemptID,
            attachmentID: target.attachment.attachmentID, displayID: target.attachment.displayID)
    }
}

/// Identifies a genuinely cached earlier candidate, not necessarily a durably
/// stored frame. The journal resolves its later admission/deletion separately.
public struct CaptureAttemptReference: Codable, Equatable, Sendable {
    public let member: CaptureGroupFrameReceipt
    public let pixelReceipt: CapturePixelReceipt
    public init(member: CaptureGroupFrameReceipt, pixelReceipt: CapturePixelReceipt) {
        self.member = member; self.pixelReceipt = pixelReceipt
    }
}

public enum CaptureAttemptDisposition: String, Codable, Sendable {
    case retainedCandidate, suppressedSimilar, unavailable, dropped, cancelled
}

public enum CaptureGroupOutcomeReason: String, Codable, Sendable {
    case displayUnavailable, displayAsleep, displayReconfigured, unstableContext
    case captureFailed, pixelReceiptUnavailable, rawBufferBackpressure, outputBufferBackpressure
    case sourceStopped, configurationChanged, streamCancelled, journalUnavailable
    case screenLocked, historyViewing, pipelineStopped
}

/// Legacy sampled similarity and exact equality are distinct receipts. Exact
/// reuse is admitted only after full BGRA equality and compatible provenance.
public struct CaptureSimilarityComparison: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable { case captureAdaptiveV1, exactPixelsV1 }
    public let method: Method
    public let pixelThreshold: Double
    public let directTextEnabled: Bool
    public let exactPixelSHA256: String?
    public init(pixelThreshold: Double, directTextEnabled: Bool) {
        method = .captureAdaptiveV1
        self.pixelThreshold = pixelThreshold; self.directTextEnabled = directTextEnabled
        exactPixelSHA256 = nil
    }
    public init(exactPixelSHA256: String, directTextEnabled: Bool) {
        method = .exactPixelsV1; pixelThreshold = 0
        self.directTextEnabled = directTextEnabled; self.exactPixelSHA256 = exactPixelSHA256
    }
}

/// Sampling and forwarding outcomes are not durable-media admission. A candidate
/// may later become similar/dropped/cancelled while downstream work drains.
public struct CaptureAttemptOutcome: Codable, Equatable, Sendable {
    public let member: CaptureGroupFrameReceipt
    public let disposition: CaptureAttemptDisposition
    public let reason: CaptureGroupOutcomeReason?
    public let pixelReceipt: CapturePixelReceipt?
    public let similarReference: CaptureAttemptReference?
    public let comparison: CaptureSimilarityComparison?

    public init(member: CaptureGroupFrameReceipt, disposition: CaptureAttemptDisposition,
                reason: CaptureGroupOutcomeReason? = nil, pixelReceipt: CapturePixelReceipt? = nil,
                similarReference: CaptureAttemptReference? = nil, comparison: CaptureSimilarityComparison? = nil) {
        self.member = member; self.disposition = disposition; self.reason = reason
        self.pixelReceipt = pixelReceipt; self.similarReference = similarReference; self.comparison = comparison
    }
}

public enum CaptureSamplingEndReason: String, Codable, Sendable {
    case completed, cancelled, configurationChanged, journalUnavailable
}

public struct CaptureSamplingEnd: Codable, Equatable, Sendable {
    public let groupID: UUID
    public let sessionID: UUID
    public let reason: CaptureSamplingEndReason
    public init(groupID: UUID, sessionID: UUID, reason: CaptureSamplingEndReason) {
        self.groupID = groupID; self.sessionID = sessionID; self.reason = reason
    }
}

/// Idempotent journal envelopes contain identities, timing and categorical state
/// only. No window/app text, AX payload, screenshot bytes or privacy rules.
public struct CaptureGroupEvent: Codable, Equatable, Sendable {
    public static let maximumJSONBytes = 64 * 1_024
    public enum Payload: Codable, Equatable, Sendable {
        case began(CaptureSamplingGroup)
        case attemptOutcome(CaptureAttemptOutcome)
        case samplingEnded(CaptureSamplingEnd)
    }
    public let formatVersion: Int
    public let eventID: UUID
    public let occurredAt: Date
    public let monotonicTime: TimeInterval
    public let payload: Payload

    public init(eventID: UUID = UUID(), occurredAt: Date = Date(),
                monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime, payload: Payload) {
        formatVersion = 1; self.eventID = eventID; self.occurredAt = occurredAt
        self.monotonicTime = monotonicTime; self.payload = payload
    }

    public enum ValidationError: Error, Sendable { case malformedEvent, mismatchedMember, sizeLimit }

    /// Structural validation before write/read. For member/end events, the
    /// journal additionally requires their exact persisted group descriptor.
    public func validatedEncoding(group: CaptureSamplingGroup? = nil) throws -> Data {
        guard formatVersion == 1, occurredAt.timeIntervalSince1970.isFinite,
              monotonicTime.isFinite, monotonicTime >= 0 else { throw ValidationError.malformedEvent }
        switch payload {
        case .began(let descriptor):
            try Self.validate(descriptor)
            guard descriptor.enumeration.endedUptime <= monotonicTime,
                  descriptor.enumeration.endedAt <= occurredAt else { throw ValidationError.malformedEvent }
        case .attemptOutcome(let outcome):
            guard let group else { throw ValidationError.mismatchedMember }
            try Self.validate(group)
            try Self.validate(outcome, group: group, eventDate: occurredAt, eventUptime: monotonicTime)
        case .samplingEnded(let end):
            guard let group, end.groupID == group.groupID, end.sessionID == group.sessionID,
                  monotonicTime >= group.enumeration.endedUptime,
                  occurredAt >= group.enumeration.endedAt else { throw ValidationError.mismatchedMember }
            try Self.validate(group)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumJSONBytes else { throw ValidationError.sizeLimit }
        return data
    }

    private static func valid(_ interval: CaptureReadInterval) -> Bool {
        interval.startedAt.timeIntervalSince1970.isFinite && interval.endedAt.timeIntervalSince1970.isFinite &&
        interval.endedAt >= interval.startedAt && interval.startedUptime.isFinite && interval.endedUptime.isFinite &&
        interval.startedUptime >= 0 && interval.endedUptime >= interval.startedUptime
    }

    private static func validate(_ group: CaptureSamplingGroup) throws {
        guard group.formatVersion == 1, group.backend == .screenCaptureKitCandidate,
              group.configurationGeneration <= UInt64(Int64.max), valid(group.enumeration),
              (1...CaptureSamplingGroup.maximumTargets).contains(group.targets.count),
              group.displayPolicy != .activeDisplay || group.targets.count == 1,
              Set(group.targets.map(\.attemptID)).count == group.targets.count,
              Set(group.targets.map { $0.attachment.displayID }).count == group.targets.count,
              Set(group.targets.map { $0.attachment.attachmentID }).count == group.targets.count,
              group.capturePolicySHA256.utf8.count == 64,
              group.capturePolicySHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ValidationError.malformedEvent
        }
        for target in group.targets {
            let attachment = target.attachment, bounds = attachment.bounds
            guard attachment.displayID > 0, (1...16_384).contains(attachment.pixelWidth),
                  (1...16_384).contains(attachment.pixelHeight),
                  attachment.pixelWidth * attachment.pixelHeight <= 33_554_432,
                  !bounds.isNull, !bounds.isInfinite, bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                  bounds.maxX.isFinite, bounds.maxY.isFinite,
                  attachment.rotationDegrees.isFinite, (0..<360).contains(attachment.rotationDegrees),
                  attachment.refreshRateHz.isFinite, (0...1_000).contains(attachment.refreshRateHz) else {
                throw ValidationError.malformedEvent
            }
        }
    }

    private static func validate(_ outcome: CaptureAttemptOutcome, group: CaptureSamplingGroup,
                                 eventDate: Date, eventUptime: TimeInterval) throws {
        let member = outcome.member
        guard member.groupID == group.groupID, member.sessionID == group.sessionID,
              member.configurationGeneration == group.configurationGeneration,
              let target = group.targets.first(where: { $0.attemptID == member.attemptID }),
              target.attachment.attachmentID == member.attachmentID,
              target.attachment.displayID == member.displayID else { throw ValidationError.mismatchedMember }
        guard eventUptime >= group.enumeration.endedUptime,
              eventDate >= group.enumeration.endedAt else { throw ValidationError.malformedEvent }
        if let receipt = outcome.pixelReceipt {
            guard receipt.attemptID == member.attemptID, valid(receipt.interval),
                  receipt.interval.startedUptime >= group.enumeration.endedUptime,
                  receipt.interval.endedUptime <= eventUptime,
                  receipt.interval.startedAt >= group.enumeration.endedAt,
                  receipt.interval.endedAt <= eventDate else { throw ValidationError.malformedEvent }
        }
        switch outcome.disposition {
        case .retainedCandidate:
            guard outcome.pixelReceipt != nil, outcome.reason == nil,
                  outcome.similarReference == nil, outcome.comparison == nil else { throw ValidationError.malformedEvent }
        case .suppressedSimilar:
            guard let receipt = outcome.pixelReceipt, outcome.reason == nil, let comparison = outcome.comparison,
                  let previous = outcome.similarReference,
                  comparison.pixelThreshold.isFinite, (0...1).contains(comparison.pixelThreshold) else {
                throw ValidationError.malformedEvent
            }
            switch comparison.method {
            case .captureAdaptiveV1:
                guard comparison.exactPixelSHA256 == nil else { throw ValidationError.malformedEvent }
            case .exactPixelsV1:
                guard comparison.pixelThreshold == 0, let hash = comparison.exactPixelSHA256,
                      hash.utf8.count == 64,
                      hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw ValidationError.malformedEvent
                }
            }
            guard previous.member.groupID != member.groupID, previous.member.attemptID != member.attemptID,
                      previous.member.sessionID == member.sessionID,
                      previous.member.configurationGeneration == member.configurationGeneration,
                      previous.member.attachmentID == member.attachmentID,
                      previous.member.displayID == member.displayID,
                      previous.pixelReceipt.attemptID == previous.member.attemptID,
                      valid(previous.pixelReceipt.interval),
                      previous.pixelReceipt.interval.endedUptime <= receipt.interval.startedUptime else {
                throw ValidationError.malformedEvent
            }
        case .unavailable, .dropped, .cancelled:
            guard outcome.reason != nil, outcome.similarReference == nil,
                  outcome.comparison == nil else { throw ValidationError.malformedEvent }
        }
    }
}
