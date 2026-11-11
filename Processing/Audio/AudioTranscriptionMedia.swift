import Database
import Foundation
import Shared
import Storage

enum AudioTranscriptionMediaError: Error, Sendable {
    case unavailable
    case changed
    case wordTimingRequired
    case invalidWordTiming
    case noOwnedWords
}

/// Both legacy batches and new logical windows enter the model through one
/// loader. New-format leases remain held until the caller's publication finishes.
struct AudioTranscriptionInput: Sendable {
    let data: Data
    let sampleRate: Int
    let duration: TimeInterval
    let startTime: Date
    let window: StoredAudioWindow?
    let lease: AudioWindowReadLease?

    var ownedStartTime: Date { window?.manifest.ownedStartTime ?? startTime }
    var endTime: Date { window?.manifest.endTime ?? startTime.addingTimeInterval(duration) }

    func checkValidity() throws {
        try BackgroundProcessingContext.checkCancellation()
        guard lease?.validity.isValid != false else { throw AudioTranscriptionMediaError.changed }
    }

    func validateForPublication(queries: AudioTranscriptionQueries, path: String) async throws {
        try checkValidity()
        if let window {
            guard try await queries.storedAudioWindow(forPath: path) == window else {
                throw AudioTranscriptionMediaError.changed
            }
        }
        try checkValidity()
    }

    /// A word belongs to the half-open sample interval containing its start.
    /// This rule is independent of processing order or earlier model output.
    /// Unaligned full text is never used as a substitute for context attribution.
    func ownedTranscript(_ result: DetailedTranscriptionResult) throws -> (words: [TranscriptionWord], text: String) {
        guard let manifest = window?.manifest else { return (result.words, result.text) }
        let lower = Double(manifest.ownedStartFrame) / Double(AudioWindowManifest.sampleRate)
        let upper = Double(manifest.frameCount) / Double(AudioWindowManifest.sampleRate)
        if result.words.isEmpty {
            guard lower == 0 || result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AudioTranscriptionMediaError.wordTimingRequired
            }
            return ([], result.text)
        }
        var owned: [TranscriptionWord] = []
        var previousStart = -Double.infinity
        for word in result.words {
            guard word.start.isFinite, word.end.isFinite, word.end >= word.start,
                  word.start >= previousStart else { throw AudioTranscriptionMediaError.invalidWordTiming }
            previousStart = word.start
            guard word.start >= lower, word.start < upper else { continue }
            let end = min(word.end, upper)
            guard end > word.start else { continue }
            owned.append(TranscriptionWord(word: word.word, start: word.start, end: end, confidence: word.confidence))
        }
        guard !owned.isEmpty || result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AudioTranscriptionMediaError.noOwnedWords
        }
        return (owned, owned.map(\.word).joined(separator: " "))
    }
}

enum AudioTranscriptionMedia {
    static func withInput<Value: Sendable>(
        path: String,
        legacyStartTime: Date?,
        storageRoot: URL,
        queries: AudioTranscriptionQueries,
        mediaStore: (any AudioChunkMediaStoreProtocol)?,
        operation: @escaping @Sendable (AudioTranscriptionInput) async throws -> Value
    ) async throws -> Value {
        try BackgroundProcessingContext.checkCancellation()
        if let window = try await queries.storedAudioWindow(forPath: path) {
            guard let mediaStore else { throw AudioTranscriptionMediaError.unavailable }
            let lease = try await mediaStore.readWindow(window)
            do {
                guard lease.window == window,
                      lease.pcmData.count == Int(window.manifest.frameCount) * 2 else {
                    throw AudioTranscriptionMediaError.changed
                }
                let input = AudioTranscriptionInput(data: lease.pcmData, sampleRate: AudioWindowManifest.sampleRate,
                    duration: Double(window.manifest.frameCount) / Double(AudioWindowManifest.sampleRate),
                    startTime: window.manifest.startTime, window: window, lease: lease)
                try input.checkValidity()
                let value = try await operation(input)
                await mediaStore.release(lease)
                return value
            } catch {
                await mediaStore.release(lease)
                throw error
            }
        }
        guard let legacyStartTime else { throw AudioTranscriptionMediaError.unavailable }
        let decoded = try AudioFileDecoder.decodeToPCM(fileURL: storageRoot.appendingPathComponent(path))
        let input = AudioTranscriptionInput(data: decoded.data, sampleRate: decoded.sampleRate,
            duration: decoded.duration, startTime: legacyStartTime, window: nil, lease: nil)
        try input.checkValidity()
        return try await operation(input)
    }
}
