import CryptoKit
import Foundation
import Shared

enum CompanionWire {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, data: Data, limit: Int) throws -> T {
        guard data.count <= limit else { throw CompanionError.invalidPayload }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
    /// Compare exact canonical wire dates, never a tolerance around unrelated evidence.
    /// Foundation's reference-epoch conversion can move a raw Date by one ULP on decoding.
    static func sameWireDate(_ lhs: Date, _ rhs: Date) -> Bool {
        guard lhs.timeIntervalSince1970.isFinite, rhs.timeIntervalSince1970.isFinite,
              let a = try? decode(Date.self, data: encode(lhs), limit: 128),
              let b = try? decode(Date.self, data: encode(rhs), limit: 128) else { return false }
        return a == b
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validate(_ result: CompanionResult, request: CompanionJobRequest, id: String) throws {
        guard result.version == 1, result.jobID == id, result.sourceStoreID == request.sourceStoreID,
              result.kind == request.kind else { throw CompanionError.invalidPayload }
        if let source = request.context {
            guard let proposal = result.contextProposal, result.speakerEnrichment == nil,
                  proposal.markerID == source.markerID, proposal.markerRevision == source.markerRevision,
                  proposal.snapshotID == source.snapshotID, proposal.verbatimExplanation == source.verbatimExplanation,
                  proposal.developing == source.developing, proposal.incomplete == source.incomplete,
                  proposal.ranges.count <= 16, Set(proposal.ranges.map(\.id)).count == proposal.ranges.count else { throw CompanionError.invalidPayload }
            try CompanionBounds.text(proposal.method, max: 256)
            let evidence = Dictionary(uniqueKeysWithValues: source.evidence.map { ($0.id, $0) })
            var used = Set<String>()
            for range in proposal.ranges {
                guard range.supportIDs.count == 1, let supportID = range.supportIDs.first,
                      let support = evidence[supportID], used.insert(supportID).inserted,
                      range.start == support.start, range.end == support.end,
                      range.explanation == CompanionProposedRange.supportedExplanation(support),
                      range.score.isFinite, (0...1).contains(range.score) else { throw CompanionError.invalidPayload }
                try CompanionBounds.text(range.explanation, max: 4096)
            }
        } else if let source = request.speaker {
            guard let enhanced = result.speakerEnrichment, result.contextProposal == nil,
                  enhanced.sourceIdentity == source.sourceIdentity,
                  enhanced.firstPassSHA256 == digest(Data(source.firstPassText.utf8)),
                  !enhanced.automaticNamesCalibrated, enhanced.turns.count <= 4096 else { throw CompanionError.invalidPayload }
            try CompanionBounds.text(enhanced.enhancedText, max: 128 * 1024, empty: true)
            try CompanionBounds.digest(enhanced.modelFingerprint)
            var previous = -1.0, textBytes = 0
            var inferenceID: String?
            for turn in enhanced.turns {
                guard turn.start.isFinite, turn.end.isFinite, turn.start >= previous, turn.start >= 0,
                      turn.start < turn.end, turn.end <= Double(source.sourceIdentity.sampleCount) / 16_000 else { throw CompanionError.invalidPayload }
                previous = turn.start; textBytes += turn.text.utf8.count
                try CompanionBounds.text(turn.text, max: 128 * 1024)
                guard textBytes <= 128 * 1024 else { throw CompanionError.invalidPayload }
                let components = turn.speakerID.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard components.count == 3 else { throw CompanionError.invalidPayload }
                try CompanionBounds.digest(components[0])
                if let inferenceID, inferenceID != components[0] { throw CompanionError.invalidPayload }
                inferenceID = components[0]
                if components[1] == "cluster" {
                    let cluster = components[2]
                    guard (1...64).contains(cluster.utf8.count), cluster.utf8.allSatisfy({
                        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
                    }), turn.speakerLabel == "Speaker " + cluster, turn.speakerStatus != .overlap else { throw CompanionError.invalidPayload }
                } else {
                    guard components[1] == "state", turn.similarity == nil,
                          (components[2] == "unknown" && turn.speakerLabel == "Unknown speaker" && turn.speakerStatus == .unknown) ||
                          (components[2] == "overlap" && turn.speakerLabel == "Overlapping voices" && turn.speakerStatus == .overlap) else { throw CompanionError.invalidPayload }
                }
                if let similarity = turn.similarity {
                    guard similarity.isFinite, (-1...1).contains(similarity) else { throw CompanionError.invalidPayload }
                }
                if turn.speakerStatus == .suggested {
                    guard components[1] == "cluster", turn.similarity != nil,
                          let name = turn.candidateName, let person = turn.personID else { throw CompanionError.invalidPayload }
                    try CompanionBounds.text(name, max: 256); try CompanionBounds.text(person, max: 128)
                } else if turn.candidateName != nil || turn.personID != nil { throw CompanionError.invalidPayload }
            }
        } else { throw CompanionError.invalidPayload }
    }
}
