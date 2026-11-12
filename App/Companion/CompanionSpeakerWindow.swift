import Shared

enum CompanionSpeakerWindow {
    /// Subtract the union of exact accepted source intervals. Arrival order cannot
    /// change coverage, and uncovered gaps are never joined across submitted PCM.
    static func uncovered(_ source: LiveAudioSampleIdentity, covered: [LiveAudioSampleIdentity],
                          limit: Int = 32) throws -> [LiveAudioSampleIdentity] {
        guard source.isValid, covered.count <= 256, covered.allSatisfy(\.isValid),
              (1...256).contains(limit) else { throw CompanionError.invalidPayload }
        let end = source.startSample + source.sampleCount
        let same = covered.filter { item in
            guard item.recordingGeneration == source.recordingGeneration, item.continuityID == source.continuityID,
                  item.sampleRate == source.sampleRate, item.startSample < end,
                  item.startSample + item.sampleCount > source.startSample else { return false }
            return CompanionWire.sameWireDate(item.approximateOrigin, source.approximateOrigin)
        }.sorted { $0.startSample < $1.startSample }
        var cursor = source.startSample
        var result: [LiveAudioSampleIdentity] = []
        func append(_ start: Int64, _ end: Int64) throws {
            guard start < end else { return }
            guard result.count < limit else { throw CompanionError.capacityExceeded }
            result.append(.init(recordingGeneration: source.recordingGeneration, continuityID: source.continuityID,
                startSample: start, sampleCount: end - start, sampleRate: source.sampleRate,
                approximateOrigin: source.approximateOrigin))
        }
        for interval in same {
            try append(cursor, min(end, interval.startSample))
            cursor = max(cursor, min(end, interval.startSample + interval.sampleCount))
            if cursor == end { break }
        }
        try append(cursor, end)
        return result
    }

    /// Compatibility for a caller that can publish only one interval. It must not
    /// silently drop a second interval or reprocess a covered gap.
    static func fresh(_ source: LiveAudioSampleIdentity, covered: [LiveAudioSampleIdentity]) throws -> LiveAudioSampleIdentity? {
        try uncovered(source, covered: covered, limit: 1).first
    }
}
