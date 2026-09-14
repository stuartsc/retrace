import Foundation

/// Metadata describes observed focus, never document contents or user engagement.
public struct ActivityContext: Codable, Sendable, Equatable {
    public let appBundleID: String
    public let appName: String
    public let processID: Int32
    public let processGeneration: String
    public let windowID: UInt32?
    public let windowGeneration: String?
    public let windowTitle: String?
    public let displayID: UInt32?
    public let documentID: String?
    public let paneID: String?
    public let safeURL: String?
    public let adapter: String
    public let uncertainty: [String]

    public init(appBundleID: String, appName: String, processID: Int32,
                processGeneration: String, windowID: UInt32? = nil, windowGeneration: String? = nil, windowTitle: String? = nil,
                displayID: UInt32? = nil, documentID: String? = nil, paneID: String? = nil,
                safeURL: String? = nil, adapter: String = "window-metadata-v1", uncertainty: [String] = []) {
        self.appBundleID = appBundleID; self.appName = appName
        self.processID = processID; self.processGeneration = processGeneration
        self.windowID = windowID; self.windowGeneration = windowGeneration
        self.windowTitle = CapturedURLPolicy.sanitizeLabel(windowTitle); self.displayID = displayID
        self.documentID = documentID; self.paneID = paneID; self.safeURL = CapturedURLPolicy.sanitize(safeURL)
        self.adapter = adapter; self.uncertainty = uncertainty
    }

    /// A title alone is deliberately insufficient to join documents or conversations.
    public var stableDocumentKey: String? {
        guard let documentID else { return nil }
        return "\(appBundleID)|\(documentID)|\(paneID ?? "")"
    }
}

/// Present only when the independently observed activity and captured surface have proven identity.
public struct ActivityCaptureIdentity: Codable, Sendable, Equatable {
    public let activityEventID: UUID
    public let sessionID: UUID
    public let processID: Int32
    public let processGeneration: String
    public let windowID: UInt32
    public let windowGeneration: String
    public let captureMonotonicTime: TimeInterval
    public let documentID: String?
    public let paneID: String?
    public init(activityEventID: UUID, sessionID: UUID, processID: Int32, processGeneration: String,
                windowID: UInt32, windowGeneration: String, captureMonotonicTime: TimeInterval,
                documentID: String? = nil, paneID: String? = nil) {
        self.activityEventID = activityEventID; self.sessionID = sessionID; self.processID = processID
        self.processGeneration = processGeneration; self.windowID = windowID; self.windowGeneration = windowGeneration
        self.captureMonotonicTime = captureMonotonicTime; self.documentID = documentID; self.paneID = paneID
    }
}

public enum ActivityEventKind: String, Codable, Sendable {
    case startup, focus, reconciliation, heartbeat, enrichment
    case pause, resume, sleep, wake, shutdown, gap, excluded, permissionLost, observerFailure, clockChange
}

public enum ActivityCoverage: String, Codable, Sendable {
    case observed, uncertain, unknown, paused, sleeping, excluded, stopped
}

public struct ActivityEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let sequence: Int64
    public let observedAt: Date
    public let monotonicTime: TimeInterval
    public let kind: ActivityEventKind
    public let coverage: ActivityCoverage
    public let context: ActivityContext?
    public let relatedEventID: UUID?
    public let method: String

    public init(id: UUID = UUID(), sessionID: UUID, sequence: Int64, observedAt: Date = Date(),
                monotonicTime: TimeInterval, kind: ActivityEventKind, coverage: ActivityCoverage,
                context: ActivityContext? = nil, relatedEventID: UUID? = nil, method: String) {
        self.id = id; self.sessionID = sessionID; self.sequence = sequence
        self.observedAt = observedAt; self.monotonicTime = monotonicTime
        self.kind = kind; self.coverage = coverage; self.context = context
        self.relatedEventID = relatedEventID; self.method = method
    }
}

public struct PersistedActivityEvent: Codable, Sendable, Identifiable {
    public let storeID: UUID
    public let commitSequence: Int64
    public let persistedAt: Date
    public let event: ActivityEvent
    public var id: UUID { event.id }

    public init(storeID: UUID, commitSequence: Int64, persistedAt: Date, event: ActivityEvent) {
        self.storeID = storeID; self.commitSequence = commitSequence
        self.persistedAt = persistedAt; self.event = event
    }
}

public struct ActivityQuery: Sendable {
    public let text: String
    public let from: Date?
    public let to: Date?
    public let appBundleIDs: [String]?
    public let afterSequence: Int64
    public let limit: Int

    public init(text: String = "", from: Date? = nil, to: Date? = nil,
                appBundleIDs: [String]? = nil, afterSequence: Int64 = 0, limit: Int = 200) {
        self.text = text; self.from = from; self.to = to; self.appBundleIDs = appBundleIDs
        self.afterSequence = afterSequence; self.limit = min(500, max(1, limit))
    }
}

public struct ActivityPage: Sendable {
    public let events: [PersistedActivityEvent]
    public let nextSequence: Int64?
    public init(events: [PersistedActivityEvent], nextSequence: Int64?) {
        self.events = events; self.nextSequence = nextSequence
    }
}

public enum ActivityCorrectionAction: String, Codable, Sendable {
    case rename, assignProject, group, separate, hide, revoke
}

public enum ActivityCorrectionScope: String, Codable, Sendable { case selection, document }
public enum ActivityCorrectionStatus: String, Codable, Sendable { case draft, pending, applied, conflict, revoked }

/// Confirmation and application status are separate. Commands are append-only and idempotent.
public struct ActivityCorrection: Codable, Sendable, Identifiable {
    public let id: UUID
    public let targetEventIDs: [UUID]
    public let expectedRevision: Int64
    public let action: ActivityCorrectionAction
    public let scope: ActivityCorrectionScope
    public let label: String?
    public let documentKey: String?
    public let confirmed: Bool
    public let author: String
    public let createdAt: Date
    public let revokesCommandID: UUID?

    public init(id: UUID = UUID(), targetEventIDs: [UUID], expectedRevision: Int64,
                action: ActivityCorrectionAction, scope: ActivityCorrectionScope = .selection,
                label: String? = nil, documentKey: String? = nil, confirmed: Bool,
                author: String = "local-user", createdAt: Date = Date(), revokesCommandID: UUID? = nil) {
        self.id = id; self.targetEventIDs = targetEventIDs; self.expectedRevision = expectedRevision
        self.action = action; self.scope = scope; self.label = label; self.documentKey = documentKey
        self.confirmed = confirmed; self.author = author; self.createdAt = createdAt
        self.revokesCommandID = revokesCommandID
    }
}

public struct ActivityCorrectionReceipt: Codable, Sendable {
    public let command: ActivityCorrection
    public let revision: Int64
    public let status: ActivityCorrectionStatus
    public init(command: ActivityCorrection, revision: Int64, status: ActivityCorrectionStatus) {
        self.command = command; self.revision = revision; self.status = status
    }
}

public struct ActivityFeedEntry: Codable, Sendable, Identifiable {
    public let id: Int64
    public let kind: String
    public let entityID: UUID
    public let payload: Data
    public init(id: Int64, kind: String, entityID: UUID, payload: Data) {
        self.id = id; self.kind = kind; self.entityID = entityID; self.payload = payload
    }
}

public struct ActivityStoreHealth: Codable, Sendable {
    public let lastObservedAt: Date?
    public let lastPersistedAt: Date?
    public let latestSequence: Int64
    public let gapCount: Int
    public let correctionRevision: Int64
    public init(lastObservedAt: Date?, lastPersistedAt: Date?, latestSequence: Int64,
                gapCount: Int, correctionRevision: Int64) {
        self.lastObservedAt = lastObservedAt; self.lastPersistedAt = lastPersistedAt
        self.latestSequence = latestSequence; self.gapCount = gapCount
        self.correctionRevision = correctionRevision
    }
}

public struct ActivityInterval: Sendable, Identifiable {
    public let id: UUID
    public let storeID: UUID
    public let eventIDs: [UUID]
    public let context: ActivityContext?
    public let coverage: ActivityCoverage
    public let startedAt: Date
    public let endedAt: Date
    public let focusDuration: TimeInterval
    public let evidence: [ScreenEvidenceRef]

    public init(id: UUID, storeID: UUID, eventIDs: [UUID], context: ActivityContext?, coverage: ActivityCoverage,
                startedAt: Date, endedAt: Date, focusDuration: TimeInterval, evidence: [ScreenEvidenceRef] = []) {
        self.id = id; self.storeID = storeID; self.eventIDs = eventIDs; self.context = context
        self.coverage = coverage; self.startedAt = startedAt; self.endedAt = endedAt
        self.focusDuration = focusDuration; self.evidence = evidence
    }
}

public struct ActivityEpisode: Sendable, Identifiable {
    public let id: UUID
    public let revision: Int64
    public let title: String
    public let intervals: [ActivityInterval]
    public let classification: String
    public let pendingCorrectionIDs: [UUID]
    public let hidden: Bool
    public var focusDuration: TimeInterval { intervals.reduce(0) { $0 + $1.focusDuration } }
    public var spanDuration: TimeInterval {
        guard let start = intervals.first?.startedAt, let end = intervals.last?.endedAt else { return 0 }
        return max(0, end.timeIntervalSince(start))
    }
    public init(id: UUID, revision: Int64, title: String, intervals: [ActivityInterval], classification: String,
                pendingCorrectionIDs: [UUID] = [], hidden: Bool = false) {
        self.id = id; self.revision = revision; self.title = title; self.intervals = intervals
        self.classification = classification; self.pendingCorrectionIDs = pendingCorrectionIDs; self.hidden = hidden
    }
}

/// An append-only, source-qualified link established from capture identity proof.
/// Capture time remains the image's time, distinct from the earlier focus event.
public struct ActivityScreenLink: Codable, Sendable, Identifiable {
    public let id: UUID
    public let commitSequence: Int64
    public let eventID: UUID
    public let screen: ScreenEvidenceRef
    public let capturedAt: Date
    public let method: String
    public init(id: UUID, commitSequence: Int64, eventID: UUID, screen: ScreenEvidenceRef,
                capturedAt: Date, method: String) {
        self.id = id; self.commitSequence = commitSequence; self.eventID = eventID
        self.screen = screen; self.capturedAt = capturedAt; self.method = method
    }
}
