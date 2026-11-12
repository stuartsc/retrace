import Foundation

/// Foreground targets preserve exact native identities across the App/UI boundary.
public enum RetraceNavigationTarget: Sendable {
    case screen(ScreenEvidenceRef)
    case transcript(V23TranscriptReference)
    case speakerTurn(CompanionTurnReference)
    case marker(id: UUID, expectedRevision: UUID)
}

public enum RetracePlaybackRequest: Sendable {
    case playMarker(id: UUID, expectedRevision: UUID)
    case playTurn(CompanionTurnReference)
    case stop
}

/// An allowlisted command vocabulary. Availability is the intersection of a live App handler
/// and a client's explicit grant. Declaring a case does not expose an unimplemented feature.
public enum RetraceOperation: String, Codable, CaseIterable, Sendable {
    case manifest = "capabilities.read"
    case health = "health.read"
    case search = "evidence.search", timeline = "timeline.read", evidence = "evidence.read"
    case screenshot = "screenshot.read", transcript = "transcript.read", speakers = "speakers.read"
    case copyContext = "context.copy"
    case markerList = "marker.list", markerRead = "marker.read", markerCreate = "marker.create"
    case markerUpdate = "marker.update", markerRemove = "marker.remove", markerRestore = "marker.restore"
    case contextRead = "context.read", contextRevise = "context.revise"
    case ruleList = "rule.list", ruleSave = "rule.save"
    case tagsRead = "tags.read", tagsWrite = "tags.write", commentsRead = "comments.read", commentsWrite = "comments.write"
    case tagsRemove = "tags.remove", commentsRemove = "comments.remove"
    case speakerCorrect = "speaker.correct"
    case navigate = "navigation.open", playback = "playback.control"
    case recordingRead = "recording.read", recordingSet = "recording.set"
    case settingsRead = "settings.read", settingsUpdate = "settings.update", sourcesRead = "sources.read", sourcesUpdate = "sources.update"
    case audioSettingsRead = "audio.settings.read", audioSettingsUpdate = "audio.settings.update"
    case processingRepair = "processing.repair", processingOverride = "processing.override", indexRequest = "index.request"
    case jobRead = "job.read", jobCancel = "job.cancel"
    case usage = "usage.read", storage = "storage.read", backlog = "backlog.read"
    case importRequest = "import.request", maintenance = "maintenance.request", retention = "retention.apply"

    public var capability: RetraceCapability {
        switch self {
        case .manifest: return .manifest
        case .health, .usage, .storage, .backlog: return .operationsRead
        case .search, .timeline, .evidence, .screenshot, .transcript, .speakers, .copyContext: return .evidenceRead
        case .markerList, .markerRead, .contextRead: return .markersRead
        case .markerCreate, .markerUpdate, .markerRemove, .markerRestore, .contextRevise: return .markersWrite
        case .ruleList: return .rulesRead
        case .ruleSave: return .rulesWrite
        case .tagsRead, .commentsRead: return .annotationsRead
        case .tagsWrite, .commentsWrite, .tagsRemove, .commentsRemove, .speakerCorrect: return .annotationsWrite
        case .navigate, .playback: return .foregroundControl
        case .recordingRead, .settingsRead, .sourcesRead, .audioSettingsRead: return .settingsRead
        case .recordingSet, .settingsUpdate, .sourcesUpdate, .audioSettingsUpdate: return .settingsWrite
        case .processingRepair, .processingOverride, .indexRequest, .jobRead, .jobCancel: return .processing
        case .importRequest, .maintenance, .retention: return .maintenance
        }
    }
    public var mutates: Bool {
        switch self {
        case .manifest, .health, .search, .timeline, .evidence, .screenshot, .transcript, .speakers,
             .copyContext, .markerList, .markerRead, .contextRead, .ruleList, .tagsRead, .commentsRead,
             .recordingRead, .settingsRead, .sourcesRead, .audioSettingsRead, .jobRead, .usage, .storage, .backlog: return false
        default: return true
        }
    }
    public var requiresPreview: Bool {
        switch self {
        case .markerRemove, .retention, .sourcesUpdate, .tagsRemove, .commentsRemove: return true
        default: return false
        }
    }
}

public enum RetraceCapability: String, Codable, CaseIterable, Sendable {
    case manifest = "manifest"
    case operationsRead = "operations.read", evidenceRead = "evidence.read"
    case markersRead = "markers.read", markersWrite = "markers.write"
    case rulesRead = "rules.read", rulesWrite = "rules.write"
    case annotationsRead = "annotations.read", annotationsWrite = "annotations.write"
    case foregroundControl = "foreground.control", settingsRead = "settings.read", settingsWrite = "settings.write"
    case processing = "processing", maintenance = "maintenance"
}

/// Tokens are generated/provisioned outside the endpoint. Only a SHA-256 token digest is stored.
public struct RetraceClientGrant: Codable, Equatable, Sendable {
    public let clientID: String
    public let tokenSHA256: String
    public let capabilities: Set<RetraceCapability>
    public let expiresAt: Date?
    public init(clientID: String, tokenSHA256: String, capabilities: Set<RetraceCapability>, expiresAt: Date? = nil) {
        self.clientID = clientID; self.tokenSHA256 = tokenSHA256; self.capabilities = capabilities; self.expiresAt = expiresAt
    }
}

/// JSON is only a wire representation: each registered operation decodes a bounded typed payload.
/// No value is evaluated as a path, SQL, shell code, or an instruction extracted from recordings.
public indirect enum RetraceJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), integer(Int64), number(Double), string(String), array([RetraceJSON]), object([String: RetraceJSON])
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([RetraceJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: RetraceJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
    public func decode<T: Decodable>(_ type: T.Type) throws -> T { try RetraceWire.decoder().decode(type, from: RetraceWire.encoder().encode(self)) }
    public static func encode<T: Encodable>(_ value: T) throws -> Self { try RetraceWire.decoder().decode(Self.self, from: RetraceWire.encoder().encode(value)) }
}

public enum RetraceWire {
    /// All wire timestamps are Unix milliseconds; UUIDs are canonical UUID strings.
    public static func encoder() -> JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; value.dateEncodingStrategy = .millisecondsSince1970; return value }
    public static func decoder() -> JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value }
}

public struct RetraceCommandRequest: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case execute, preview }
    public let requestID: UUID
    public let operation: RetraceOperation
    public let arguments: RetraceJSON
    public let mode: Mode
    public let confirmation: RetracePreviewConfirmation?
    public init(requestID: UUID, operation: RetraceOperation, arguments: RetraceJSON = .object([:]), mode: Mode = .execute, confirmation: RetracePreviewConfirmation? = nil) {
        self.requestID = requestID; self.operation = operation; self.arguments = arguments; self.mode = mode; self.confirmation = confirmation
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UUID.self, forKey: .requestID); operation = try c.decode(RetraceOperation.self, forKey: .operation)
        arguments = try c.decodeIfPresent(RetraceJSON.self, forKey: .arguments) ?? .object([:])
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .execute
        confirmation = try c.decodeIfPresent(RetracePreviewConfirmation.self, forKey: .confirmation)
    }
}

public struct RetracePreviewConfirmation: Codable, Equatable, Sendable {
    public let previewID: UUID
    public let digest: String
    public init(previewID: UUID, digest: String) { self.previewID = previewID; self.digest = digest }
}
public struct RetraceDestructivePreview: Codable, Equatable, Sendable {
    public let id: UUID
    public let digest: String
    public let summary: String
    public let revision: String
    public let affectedCount: Int
    public let expiresAt: Date
    /// Typed operation-specific review data, including coverage and opaque paging tokens.
    public let details: RetraceJSON?
    public init(id: UUID, digest: String, summary: String, revision: String, affectedCount: Int, expiresAt: Date,
                details: RetraceJSON? = nil) {
        self.id = id; self.digest = digest; self.summary = summary; self.revision = revision; self.affectedCount = affectedCount; self.expiresAt = expiresAt
        self.details = details
    }
}
public struct RetraceCommandResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case succeeded, preview, denied, unavailable, conflict, failed, indeterminate, cancelled }
    public let requestID: UUID
    public let status: Status
    public let code: String?
    public let observedAt: Date
    public let replayed: Bool
    public let data: RetraceJSON?
    public let preview: RetraceDestructivePreview?
    public let queued: Bool
    public init(requestID: UUID, status: Status, code: String? = nil, observedAt: Date = Date(), replayed: Bool = false, data: RetraceJSON? = nil, preview: RetraceDestructivePreview? = nil) {
        self.requestID = requestID; self.status = status; self.code = code; self.observedAt = observedAt
        self.replayed = replayed; self.data = data; self.preview = preview; queued = false
    }
}
public struct RetraceCapabilityManifest: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let operation: RetraceOperation
        public let capability: RetraceCapability
        public let mutates: Bool
        public let requiresPreview: Bool
        public init(operation: RetraceOperation, capability: RetraceCapability? = nil, requiresPreview: Bool) { self.operation = operation; self.capability = capability ?? operation.capability; mutates = operation.mutates; self.requiresPreview = requiresPreview }
    }
    public let protocolVersion: Int
    public let observedAt: Date
    public let liveLaptop: Bool
    public let operations: [Entry]
    public init(operations: [Entry]) { protocolVersion = 1; observedAt = Date(); liveLaptop = true; self.operations = operations }
}

public struct RetraceCommandJob: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, succeeded, failed, cancelled, interrupted }
    public let id: UUID
    public let operation: RetraceOperation
    public let state: State
    public let requestedAt: Date
    public let updatedAt: Date
    /// Unknown when an underlying native API does not provide measurable progress.
    public let fractionCompleted: Double?
    public let effectsMayBePartial: Bool
    public let repairPhase: ExactOCRRepairPhase?
    public let repairOutcome: ExactOCRRepairOutcome?
    public let retentionPhase: RetentionCommandPhase?
    public let retentionOutcome: RetentionCommandOutcome?
    public init(id: UUID, operation: RetraceOperation, state: State, requestedAt: Date, updatedAt: Date = Date(),
                repairPhase: ExactOCRRepairPhase? = nil, repairOutcome: ExactOCRRepairOutcome? = nil,
                retentionPhase: RetentionCommandPhase? = nil, retentionOutcome: RetentionCommandOutcome? = nil) {
        self.id = id; self.operation = operation; self.state = state; self.requestedAt = requestedAt; self.updatedAt = updatedAt
        self.repairPhase = repairPhase; self.repairOutcome = repairOutcome
        self.retentionPhase = retentionPhase; self.retentionOutcome = retentionOutcome
        fractionCompleted = state == .succeeded ? 1 : nil
        effectsMayBePartial = state == .cancelled || state == .failed || state == .interrupted || retentionOutcome?.partial == true
    }
}
