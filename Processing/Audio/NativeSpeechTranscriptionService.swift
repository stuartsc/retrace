import AVFoundation
import CoreMedia
import Foundation
import Shared
import Speech

/// Opt-in, bounded batch comparison backend. Production continues to use CPU Whisper.
/// Requires installed on-device assets; never downloads models or records audio.
@available(macOS 26.0, *)
public actor NativeSpeechTranscriptionService: TranscriptionProtocol {
    private let localeIdentifier: String
    private var installedLocale: Locale?
    private var activeOperation: Task<DetailedTranscriptionResult, Error>?

    public init(localeIdentifier: String = "en-AU") {
        self.localeIdentifier = localeIdentifier
    }

    // Use the same configuration for readiness, preparation, and analysis. Asset readiness
    // is per app/module configuration, so installedLocales alone is insufficient.
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    public func initialize() async throws {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw NativeSpeechError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw NativeSpeechError.unsupportedLocale(localeIdentifier)
        }
        let transcriber = Self.makeTranscriber(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw NativeSpeechError.assetsNotInstalled(locale.identifier)
        }
        try Task.checkCancellation()
        installedLocale = locale
    }

    public func cleanup() {
        installedLocale = nil
        activeOperation?.cancel()
    }

    public func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        let result = try await transcribeWithTimestamps(audioData, wordLevel: false, initialPrompt: nil)
        return TranscriptionResult(text: result.text, language: result.language, duration: result.duration)
    }

    public func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?
    ) async throws -> DetailedTranscriptionResult {
        try await transcribeWithTimestamps(
            audioData, wordLevel: wordLevel, initialPrompt: initialPrompt, languageHint: nil
        )
    }

    public func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?,
        languageHint: String?
    ) async throws -> DetailedTranscriptionResult {
        try Task.checkCancellation()
        guard let locale = installedLocale else { throw TranscriptionError.notInitialized }
        guard activeOperation == nil else { throw NativeSpeechError.alreadyTranscribing }
        guard initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw NativeSpeechError.unsupportedPrompt
        }
        if let hint = languageHint?.lowercased(), !hint.isEmpty, hint != "auto" {
            let requestedLanguage = Locale(identifier: hint).language.languageCode?.identifier
            guard requestedLanguage == locale.language.languageCode?.identifier else {
                throw NativeSpeechError.unsupportedLocale(hint)
            }
        }
        // Validate before scheduling work; a batch is at most 120 seconds of 16 kHz mono Int16.
        try NativeSpeechPCMConverter.validate(audioData)
        let operation = Task {
            try await Self.analyze(audioData, locale: locale, wordLevel: wordLevel)
        }
        activeOperation = operation
        defer { activeOperation = nil }
        return try await withTaskCancellationHandler {
            let result = try await operation.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            operation.cancel()
        }
    }

    private static func analyze(
        _ audioData: Data,
        locale: Locale,
        wordLevel: Bool
    ) async throws -> DetailedTranscriptionResult {
        try Task.checkCancellation()
        let transcriber = makeTranscriber(locale: locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw NativeSpeechError.assetsNotInstalled(locale.identifier)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.audioFormatError
        }
        let input = try NativeSpeechPCMConverter.makeBuffer(audioData)
        let converted = try NativeSpeechPCMConverter.convert(input, to: format)
        let duration = Double(audioData.count) / 32_000
        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse)
        )
        let results = Task {
            var text = ""
            var words: [TranscriptionWord] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                text += String(result.text.characters)
                if wordLevel {
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange else { continue }
                        let word = String(result.text[run.range].characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let start = CMTimeGetSeconds(range.start)
                        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                        // Keep Apple's timed spans; do not invent word boundaries or timing.
                        guard !word.isEmpty, start.isFinite, end.isFinite,
                              start >= 0, end >= start, end <= duration + 0.1 else { continue }
                        words.append(TranscriptionWord(
                            word: word, start: start, end: end, confidence: run.transcriptionConfidence
                        ))
                    }
                }
            }
            return DetailedTranscriptionResult(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                words: words, language: locale.language.languageCode?.identifier, duration: duration
            )
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await analyzer.prepareToAnalyze(in: format)
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                // Offsets remain relative to the original PCM sample zero. The caller owns its wall-clock anchor.
                continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: .zero))
                continuation.finish()
                let lastSample = try await analyzer.analyzeSequence(stream)
                try Task.checkCancellation() // analyzeSequence can return early without throwing on cancellation.
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let result = try await results.value
                try Task.checkCancellation()
                return result
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

public enum NativeSpeechError: Error, Sendable {
    case unavailable
    case unsupportedLocale(String)
    case assetsNotInstalled(String)
    case unsupportedPrompt
    case alreadyTranscribing
}

/// Finite-buffer conversion for the opt-in comparison, independent of the live capture resampler.
/// Uses AVAudioConverter for sample rates, channel layouts and PCM representation.
enum NativeSpeechPCMConverter {
    static let maximumDuration: Double = 120

    static func validate(_ data: Data) throws {
        guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Int16>.size),
              Double(data.count) / 32_000 <= maximumDuration else {
            throw TranscriptionError.audioFormatError
        }
    }

    static func makeBuffer(_ data: Data) throws -> AVAudioPCMBuffer {
        try validate(data)
        let format = try pcm16Format()
        let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = buffer.int16ChannelData?[0] else {
            throw TranscriptionError.audioFormatError
        }
        buffer.frameLength = frames
        _ = data.withUnsafeBytes { bytes in
            memcpy(destination, bytes.baseAddress!, data.count)
        }
        return buffer
    }

    static func pcm16Data(from input: AVAudioPCMBuffer) throws -> Data {
        let output = try convert(input, to: pcm16Format())
        guard let samples = output.int16ChannelData?[0] else { throw TranscriptionError.audioFormatError }
        let data = Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
        try validate(data)
        return data
    }

    static func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let duration = Double(input.frameLength) / input.format.sampleRate
        guard input.frameLength > 0, duration.isFinite, duration <= maximumDuration,
              format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw TranscriptionError.audioFormatError
        }
        if input.format == format { return input }
        let capacity = ceil(duration * format.sampleRate) + 4_096
        guard capacity <= Double(UInt32.max),
              let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw TranscriptionError.audioFormatError
        }
        converter.downmix = format.channelCount < input.format.channelCount
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !consumed else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else {
            throw TranscriptionError.audioFormatError
        }
        return output
    }

    private static func pcm16Format() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
        ) else { throw TranscriptionError.audioFormatError }
        return format
    }
}
