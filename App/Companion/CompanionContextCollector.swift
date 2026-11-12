import Foundation
import Shared

public enum CompanionContextCollector {
    public typealias PageReader = @Sendable (_ cursor: String?, _ limit: Int) async throws -> CompanionEvidencePage
    /// Reader supplies relevance-ordered current native evidence, not a fixed before/after slice.
    /// Hitting a bound retains an explicit incomplete flag; it cannot claim exhaustive context.
    public static func collect(marker: TimelineMarker, query: String, verbatimExplanation: String,
                               maximumItems: Int = 256, pageSize: Int = 32, read: PageReader) async throws -> CompanionJobRequest {
        guard marker.deletedAt == nil, (1...256).contains(maximumItems), (1...64).contains(pageSize) else { throw CompanionError.invalidPayload }
        var items: [CompanionEvidenceItem] = [], cursor: String?, snapshot: UUID?
        var cursors = Set<String>(), seen = Set<String>()
        var developing = false, incomplete = false
        repeat {
            try Task.checkCancellation()
            let count = min(pageSize, maximumItems - items.count)
            let page = try await read(cursor, count)
            try Task.checkCancellation()
            guard page.items.count <= count else { throw CompanionError.invalidPayload }
            if let snapshot, snapshot != page.snapshotID { throw CompanionError.staleEvidence }
            snapshot = page.snapshotID; developing = developing || page.developing; incomplete = incomplete || page.incomplete
            for item in page.items {
                guard seen.insert(item.id).inserted else { throw CompanionError.invalidPayload }
                items.append(item)
            }
            cursor = page.nextCursor
            if let cursor {
                try CompanionBounds.text(cursor, max: 4096)
                guard cursors.insert(cursor).inserted, !page.items.isEmpty else { throw CompanionError.invalidPayload }
            }
        } while cursor != nil && items.count < maximumItems
        incomplete = incomplete || cursor != nil
        guard let snapshot else { throw CompanionError.invalidPayload }
        let request = CompanionJobRequest(sourceStoreID: marker.nativeStoreID, observedAt: marker.anchoredAt,
            context: .init(markerID: marker.id, markerRevision: marker.revision, snapshotID: snapshot,
                query: query, verbatimExplanation: verbatimExplanation, developing: developing,
                incomplete: incomplete, evidence: items))
        try request.validate(); return request
    }
}

/// Imports one exact immutable wire result atomically. Raw storage is never a disclosure API.
public actor CompanionContextImporter {
    private let markers: TimelineMarkerService
    public init(markers: TimelineMarkerService) { self.markers = markers }
    public func apply(request: CompanionJobRequest, result: CompanionResult, requestData: Data, resultData: Data) async throws {
        let canonicalRequest = try CompanionWire.decode(CompanionJobRequest.self, data: requestData, limit: 768 * 1024)
        let canonicalResult = try CompanionWire.decode(CompanionResult.self, data: resultData, limit: 2 * 1024 * 1024)
        guard try CompanionWire.encode(request) == CompanionWire.encode(canonicalRequest),
              try CompanionWire.encode(result) == CompanionWire.encode(canonicalResult),
              let context = canonicalRequest.context else { throw CompanionError.invalidPayload }
        let id = CompanionWire.digest(requestData)
        try canonicalRequest.validate(); try CompanionWire.validate(canonicalResult, request: canonicalRequest, id: id)
        _ = try await markers.applyContextProposal(.init(jobID: id, proposalRevision: context.snapshotID,
            expectedMarkerRevision: context.markerRevision, expectedProposalHead: context.expectedProposalHead,
            requestPayload: requestData, resultPayload: resultData))
    }
}
