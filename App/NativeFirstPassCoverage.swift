import Foundation
import Shared

/// Ordered native-result ledger. Only explicit native finalization advances
/// coverage; a result's text range, wall time or absence of words never does.
struct NativeFirstPassCoverage {
    private var source: LiveAudioSampleIdentity?
    private var lowerBound: Int64 = 0
    private var finalizedThrough: Int64 = 0
    private var spans: [VoiceRecognitionUpdate] = []

    mutating func reset() { self = .init() }
    mutating func receive(_ event: VoiceRecognitionEvent) throws {
        switch event {
        case .ready: return
        case .discontinuity: reset(); throw VoiceRecognitionError.discontinuity
        case .update(let update):
            guard update.source.isValid, update.startSample >= update.source.startSample,
                  update.endSample > update.startSample, update.text.utf8.count <= 8_192 else {
                reset(); throw VoiceRecognitionError.invalidInput
            }
            if let source {
                guard sameSource(source, update.source) else { reset(); throw VoiceRecognitionError.discontinuity }
            } else {
                source = update.source; lowerBound = update.source.startSample; finalizedThrough = lowerBound
            }
            // Even a partially settled span (or a previously silent interval)
            // cannot be rewritten after a covered batch may have consumed it.
            if update.startSample < finalizedThrough {
                guard spans.contains(where: { $0.startSample == update.startSample &&
                    $0.endSample == update.endSample && $0.text == update.text && $0.tokens == update.tokens }) else {
                    reset(); throw VoiceRecognitionError.invalidInput
                }
            }
            spans.removeAll { Self.overlaps($0, update) }
            spans.append(update); spans.sort { $0.startSample < $1.startSample }
            while spans.count > 128 { lowerBound = max(lowerBound, spans.removeFirst().endSample) }
        case .finalized(let generation, let continuity, let through):
            guard let source, source.recordingGeneration == generation, source.continuityID == continuity,
                  through >= finalizedThrough else { return }
            finalizedThrough = through
            lowerBound = max(lowerBound, through - 16_000 * 60)
            spans.removeAll { $0.endSample < lowerBound }
        }
    }

    func result(for batch: NativeFirstPassBatch) -> NativeFirstPassText? {
        let request = batch.range.source, start = request.startSample, end = start + request.sampleCount
        guard let source, sameSource(source, request), start >= lowerBound, end <= finalizedThrough else { return nil }
        var pieces: [String] = []
        for span in spans where span.startSample < end && span.endSample > start {
            if span.startSample >= start && span.endSample <= end {
                pieces.append(span.text)
            } else {
                // Cross-window text is usable only when the native token runs
                // account for all its text and no token is cut at either edge.
                guard !span.tokens.isEmpty, span.tokens.map(\.text).joined() == span.text,
                      span.tokens.allSatisfy({ $0.hasStartBoundary && $0.hasEndBoundary &&
                          $0.startSample >= span.startSample && $0.endSample <= span.endSample && $0.endSample > $0.startSample }) else { return nil }
                for token in span.tokens where token.startSample < end && token.endSample > start {
                    guard token.startSample >= start, token.endSample <= end else { return nil }
                    pieces.append(token.text)
                }
            }
        }
        let text = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 32_768 else { return nil }
        return .init(batch: batch, text: text)
    }

    private func sameSource(_ lhs: LiveAudioSampleIdentity, _ rhs: LiveAudioSampleIdentity) -> Bool {
        lhs.recordingGeneration == rhs.recordingGeneration && lhs.continuityID == rhs.continuityID &&
        lhs.sampleRate == rhs.sampleRate && lhs.approximateOrigin == rhs.approximateOrigin
    }
    private static func overlaps(_ a: VoiceRecognitionUpdate, _ b: VoiceRecognitionUpdate) -> Bool {
        a.startSample < b.endSample && b.startSample < a.endSample
    }
}
