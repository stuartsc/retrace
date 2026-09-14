import Foundation
import CoreGraphics

public struct ActivityEvidenceRef: Hashable, Codable, Sendable {
    public let storeID: UUID
    public let source: FrameSource
    public let eventID: UUID
    public init(storeID: UUID, source: FrameSource = .native, eventID: UUID) {
        self.storeID = storeID; self.source = source; self.eventID = eventID
    }
}

public struct ScreenEvidenceRef: Hashable, Codable, Sendable {
    public let storeID: UUID
    public let source: FrameSource
    public let observationID: UUID
    public let frameID: FrameID
    public let extractionRevision: Int64
    public let blockIDs: [Int]
    public init(storeID: UUID, source: FrameSource, observationID: UUID, frameID: FrameID,
                extractionRevision: Int64, blockIDs: [Int] = []) {
        self.storeID = storeID; self.source = source; self.observationID = observationID
        self.frameID = frameID; self.extractionRevision = extractionRevision; self.blockIDs = blockIDs
    }
}

public struct AudioEvidenceRef: Hashable, Codable, Sendable {
    public let storeID: UUID
    public let source: FrameSource
    public let segmentID: String
    public let transcriptRevision: Int64
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public init(storeID: UUID, source: FrameSource, segmentID: String, transcriptRevision: Int64,
                startTime: TimeInterval, endTime: TimeInterval) {
        self.storeID = storeID; self.source = source; self.segmentID = segmentID
        self.transcriptRevision = transcriptRevision; self.startTime = startTime; self.endTime = endTime
    }
}

public enum EvidenceRef: Hashable, Codable, Sendable {
    case activity(ActivityEvidenceRef)
    case screen(ScreenEvidenceRef)
    case audio(AudioEvidenceRef)

    public var deepLink: URL? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        var components = URLComponents()
        components.scheme = "retrace"; components.host = "evidence"
        components.queryItems = [URLQueryItem(name: "ref", value: data.base64EncodedString())]
        return components.url
    }

    public init?(deepLink: URL) {
        guard deepLink.scheme == "retrace", deepLink.host == "evidence",
              let raw = URLComponents(url: deepLink, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "ref" })?.value,
              raw.utf8.count <= 16_384, let data = Data(base64Encoded: raw),
              let ref = try? JSONDecoder().decode(EvidenceRef.self, from: data) else { return nil }
        self = ref
    }
}

/// Immutable capture metadata and extraction. Legacy imports explicitly lack highlight proof.
public struct ScreenEvidenceSnapshot: Codable, Sendable {
    public let ref: ScreenEvidenceRef
    public let frame: FrameReference
    public let width: Int
    public let height: Int
    public let text: ExtractedText?
    public let legacyContext: Bool
    public let highlightsVerified: Bool
    public init(ref: ScreenEvidenceRef, frame: FrameReference, width: Int, height: Int,
                text: ExtractedText?, legacyContext: Bool, highlightsVerified: Bool) {
        self.ref = ref; self.frame = frame; self.width = width; self.height = height
        self.text = text; self.legacyContext = legacyContext; self.highlightsVerified = highlightsVerified
    }
}

public enum EvidenceUnavailableReason: String, Codable, Sendable, Error {
    case notPermitted, sourceDisconnected, recordingMissing, frameFinalising, evidenceDeleted
    case extractionUnavailable, integrityFailure, unsupported
}

public enum EvidenceResolution: Sendable {
    case activity(PersistedActivityEvent)
    case screen(ScreenEvidenceSnapshot, image: CGImage)
    case unavailable(EvidenceUnavailableReason)
}

/// Local presentation is distinct from permission to disclose through an agent/broker.
public enum EvidenceAudience: Sendable { case localUser, agent(clientID: String) }

public protocol EvidenceResolverProtocol: Sendable {
    func resolve(_ reference: EvidenceRef, for audience: EvidenceAudience) async -> EvidenceResolution
}
