import Foundation

/// Only an explicit application-code invocation can produce this source. This
/// categorical evidence contains no executable, argv, cwd, output, or job title.
public enum JobProducer {
    public static let ownedCommand = UUID(uuidString: "C96D880F-5B03-468B-9D63-389CA90B633C")!
    public static let maximumOutstanding = 8
}

public enum JobKind: String, Codable, Sendable, CaseIterable { case build, test, command }
public enum JobEventPhase: String, Codable, Sendable { case started, terminal, gap }
public enum JobOutcome: String, Codable, Sendable { case succeeded, failed, signalled, launchFailed, interrupted }
public enum JobGapReason: String, Codable, Sendable {
    case observationCancelled, recordingPaused, serviceStopped, admissionChanged, producerRestarted, persistenceUnavailable, observerCapacityExceeded
}
public enum JobEventError: Error, Equatable, Sendable {
    case inactive, unavailable, invalidRequest, conflict, deleted, capacityExceeded, staleRead, integrityFailure, stopped, callbackReentry
}
public enum JobUnavailableReason: String, Codable, Sendable {
    case notPermitted, deleted, missing, unsupportedReference, integrityFailure
}

/// An App-owned master recording generation and the exact live V23 policy token.
/// Persisting this value does not preserve authority; the database also requires
/// its own in-memory V23 capability and a newly minted in-memory job writer.
public struct JobAdmission: Codable, Equatable, Sendable {
    public let masterGeneration: UUID
    public let policy: ScreenEvidencePolicyTransition
    public init(masterGeneration: UUID, policy: ScreenEvidencePolicyTransition) {
        self.masterGeneration = masterGeneration; self.policy = policy
    }
}

/// Deliberately not Codable. Only an exactly matching token held by the current
/// canonical database actor can write. A caller-constructed value is not a grant.
public struct JobWriterSession: Equatable, Sendable {
    public let id: UUID
    public let admission: JobAdmission
    public var producerID: UUID { JobProducer.ownedCommand }
    public init(id: UUID, admission: JobAdmission) { self.id = id; self.admission = admission }
}

/// Exact categorical job identity carried by EvidenceRef.job for local navigation.
public struct JobEvidenceRef: Codable, Hashable, Sendable {
    public let storeID: UUID
    public let producerID: UUID
    public let eventID: UUID
    public let revision: Int64
    public init(storeID: UUID, producerID: UUID, eventID: UUID, revision: Int64 = 1) {
        self.storeID = storeID; self.producerID = producerID; self.eventID = eventID; self.revision = revision
    }
}

/// `observedAt` is when the producer observed a lifecycle fact, not an inferred
/// completion time. Uptime is comparable only within one observerSessionID.
/// A started receipt acknowledges observation admission before Process.run; it
/// does not assert the child launched or that a user was working on the job.
public struct JobObservation: Codable, Equatable, Sendable {
    public let id: UUID
    public let runID: UUID
    public let kind: JobKind
    public let phase: JobEventPhase
    public let outcome: JobOutcome?
    public let terminationStatus: Int32?
    public let gapReason: JobGapReason?
    public let observedAt: Date
    public let observedUptime: TimeInterval

    public init(id: UUID = UUID(), runID: UUID, kind: JobKind, phase: JobEventPhase,
                outcome: JobOutcome? = nil, terminationStatus: Int32? = nil, gapReason: JobGapReason? = nil,
                observedAt: Date = Date(), observedUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.id = id; self.runID = runID; self.kind = kind; self.phase = phase; self.outcome = outcome
        self.terminationStatus = terminationStatus; self.gapReason = gapReason
        self.observedAt = observedAt; self.observedUptime = observedUptime
    }

    /// Bounded producer admission and durable read validation share these rules.
    /// Native termination is observed, never guessed from process disappearance.
    public func validate(receivedAt: Date, maximumUptime: TimeInterval? = nil) throws {
        let wall = observedAt.timeIntervalSince1970, received = receivedAt.timeIntervalSince1970
        guard wall.isFinite, received.isFinite, wall >= 0, received >= wall,
              observedUptime.isFinite, observedUptime >= 0 else { throw JobEventError.invalidRequest }
        if let maximumUptime {
            guard maximumUptime.isFinite, observedUptime <= maximumUptime else { throw JobEventError.invalidRequest }
        }
        switch phase {
        case .started:
            guard outcome == nil, terminationStatus == nil, gapReason == nil else { throw JobEventError.invalidRequest }
        case .terminal:
            guard gapReason == nil else { throw JobEventError.invalidRequest }
            switch outcome {
            case .succeeded: guard terminationStatus == 0 else { throw JobEventError.invalidRequest }
            case .failed: guard let status = terminationStatus, (1...255).contains(status) else { throw JobEventError.invalidRequest }
            case .signalled: guard let signal = terminationStatus, (1...127).contains(signal) else { throw JobEventError.invalidRequest }
            case .launchFailed: guard terminationStatus == nil else { throw JobEventError.invalidRequest }
            default: throw JobEventError.invalidRequest
            }
        case .gap:
            guard outcome == .interrupted, gapReason != nil, terminationStatus == nil else { throw JobEventError.invalidRequest }
        }
    }
}

public struct JobEventSnapshot: Codable, Equatable, Sendable {
    public let reference: JobEvidenceRef
    public let observation: JobObservation
    public let observerSessionID: UUID
    public let receivedAt: Date
    public let sequence: Int64
    public let policySHA256: String
    public init(reference: JobEvidenceRef, observation: JobObservation, observerSessionID: UUID,
                receivedAt: Date, sequence: Int64, policySHA256: String) {
        self.reference = reference; self.observation = observation; self.observerSessionID = observerSessionID
        self.receivedAt = receivedAt; self.sequence = sequence; self.policySHA256 = policySHA256
    }
}
public struct JobBeginReceipt: Equatable, Sendable {
    public let event: JobEventSnapshot
    public let inserted: Bool
    public init(event: JobEventSnapshot, inserted: Bool) { self.event = event; self.inserted = inserted }
}
/// Retained durable state only: even `.active` does not establish a live writer.
/// Local user history can be read while recording is paused. App still brackets
/// current user privacy configuration and its own presentation generation.
public enum JobRetainedPolicyPhase: String, Codable, Sendable { case active, revoked }
public struct JobReadStamp: Codable, Equatable, Sendable {
    public let storeID: UUID
    public let policy: ScreenEvidencePolicyTransition
    public let policyPhase: JobRetainedPolicyPhase
    public let revision: Int64
    public init(storeID: UUID, policy: ScreenEvidencePolicyTransition, policyPhase: JobRetainedPolicyPhase, revision: Int64) {
        self.storeID = storeID; self.policy = policy; self.policyPhase = policyPhase; self.revision = revision
    }
}
public enum JobEvidenceResolution: Equatable, Sendable {
    case available(JobEventSnapshot, JobReadStamp)
    case unavailable(JobUnavailableReason)
}

/// No arbitrary-description lexical claims: this first adapter supports only
/// exact time and categorical kind/outcome chronology, using immutable receipts.
public struct JobChronologyQuery: Codable, Equatable, Sendable {
    public let from: Date?
    public let through: Date?
    public let kind: JobKind?
    public let outcome: JobOutcome?
    public let limit: Int
    public init(from: Date? = nil, through: Date? = nil, kind: JobKind? = nil, outcome: JobOutcome? = nil, limit: Int = 64) {
        self.from = from; self.through = through; self.kind = kind; self.outcome = outcome; self.limit = limit
    }
}
public struct JobEventCursor: Codable, Equatable, Sendable {
    public let stamp: JobReadStamp
    public let query: JobChronologyQuery
    public let lastObservedAt: Date
    public let lastSequence: Int64
    public init(stamp: JobReadStamp, query: JobChronologyQuery, lastObservedAt: Date, lastSequence: Int64) {
        self.stamp = stamp; self.query = query; self.lastObservedAt = lastObservedAt; self.lastSequence = lastSequence
    }
}
public struct JobEventPage: Equatable, Sendable {
    public let events: [JobEventSnapshot]
    public let stamp: JobReadStamp
    public let next: JobEventCursor?
    public init(events: [JobEventSnapshot], stamp: JobReadStamp, next: JobEventCursor?) {
        self.events = events; self.stamp = stamp; self.next = next
    }
}
/// Closed, content-free action diagnostics. Receipt metrics are committed in the
/// same transaction as their event; failures/rejections use these separate facts.
public enum JobDiagnostic: String, Codable, Sendable {
    case rejected, capacityExceeded, persistenceFailed, stopped
}
