import Database
import Foundation
import Shared

extension AppCoordinator {
    func preparedAudioSearchPage(original: AudioSearchPage, query: SearchQuery) async throws -> AudioSearchPage {
        guard original.notice == nil, let match = DataAdapter.audioMatchExpression(query.text) else { return original }
        let ranges = query.filters.effectiveDateRanges
        let lower = ranges.count == 1 ? ranges.first?.start : nil
        let upper = ranges.count == 1 ? ranges.first?.end : nil
        do {
            let enriched = try await companion().searchSpeakerPresentations(query: query.text, from: lower, to: upper,
                limit: min(100, max(1, query.limit)), matchExpression: match, oldestFirst: query.sortOrder == .oldestFirst)
            let reader = try await liveContextSearch()
            var extras: [AudioSearchHit] = [], covered = Set<Int64>(), omitted = enriched.incomplete
            for value in enriched.items {
                try Task.checkCancellation()
                guard let proof = value.firstPassReferences.first else { omitted = true; continue }
                do {
                    let record = try await reader.resolveTranscript(proof)
                    let source = value.enhancement.sourceIdentity
                    let start = source.approximateOrigin.addingTimeInterval(Double(source.startSample) / Double(source.sampleRate))
                    let end = start.addingTimeInterval(Double(source.sampleCount) / Double(source.sampleRate))
                    guard ranges.isEmpty || ranges.contains(where: {
                        ($0.start == nil || start >= $0.start!) && ($0.end == nil || end <= $0.end!)
                    }) else { continue }
                    extras.append(try AudioSearchHit(record: record, owner: value.nativeStoreID, enrichment: value))
                    if PreparedTranscriptProjection.coversOriginal(value) {
                        covered.formUnion(value.firstPassReferences.map(\.rowID))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { omitted = true }
            }
            var hits = original.hits.filter { !covered.contains($0.record.id) } + extras
            hits.sort {
                if $0.displayStartTime != $1.displayStartTime {
                    return query.sortOrder == .oldestFirst ? $0.displayStartTime < $1.displayStartTime : $0.displayStartTime > $1.displayStartTime
                }
                return $0.id < $1.id
            }
            let limit = min(100, max(1, query.limit))
            return AudioSearchPage(hits: Array(hits.prefix(limit)),
                isTruncated: original.isTruncated || enriched.nextCursor != nil || hits.count > limit || omitted,
                notice: omitted ? "Some refined transcripts remain unchecked; original text is still searched." : nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return AudioSearchPage(hits: original.hits, isTruncated: original.isTruncated,
                notice: "Refined transcript search is unavailable; showing original transcript matches.")
        }
    }

    public func resolvePreparedAudioSearchSelection(_ hit: AudioSearchHit) async throws -> (hit: AudioSearchHit, recordings: [AudioTranscription]) {
        let current = try await resolvePreparedAudioSearchHit(hit)
        guard let enrichment = current.enrichment else { return (current, [current.record]) }
        let reader = try await liveContextSearch()
        var records: [AudioTranscription] = [], seen = Set<Int64>()
        for reference in enrichment.firstPassReferences {
            try Task.checkCancellation()
            if seen.insert(reference.rowID).inserted {
                records.append(try await reader.resolveTranscript(reference))
            }
        }
        try await reader.validate(.speaker(enrichment))
        return (current, records)
    }

    public func resolvePreparedAudioSearchHit(_ hit: AudioSearchHit) async throws -> AudioSearchHit {
        guard let expected = hit.enrichment else {
            _ = try await resolveAudioSearchHit(hit)
            return hit
        }
        guard let current = try await companion().speakerPresentation(jobID: expected.jobID),
              current.nativeStoreID == expected.nativeStoreID,
              current.enhancement == expected.enhancement, current.corrections == expected.corrections,
              current.firstPassReferences == expected.firstPassReferences,
              current.firstPassSourceIdentity == expected.firstPassSourceIdentity,
              let proof = current.firstPassReferences.first else { throw AudioSearchError.changed }
        let reader = try await liveContextSearch()
        let record = try await reader.resolveTranscript(proof)
        let resolved = try AudioSearchHit(record: record, owner: current.nativeStoreID, enrichment: current)
        guard resolved.id == hit.id else { throw AudioSearchError.changed }
        // Repeat current-policy validation after the original-row read yielded.
        try await reader.validate(.speaker(current))
        return resolved
    }
}
