import AVFoundation
import CoreMedia
import Foundation
import Shared
import Speech

/// One on-device recognizer for a shared microphone subscription. No microphone,
/// model download, file write or recording iterator is created here.
@available(macOS 26.0, *)
public actor NativeStreamingSpeechService: VoiceRecognitionProtocol {
    private let localeIdentifier: String
    private var running = false
    private var session: (id: UUID, analyzer: SpeechAnalyzer, identity: VoiceStreamIdentity)?
    private var finalizationTask: Task<Void, Never>?
    private var requestedThrough: Int64?

    /// Coalesces requests while capture keeps feeding the independent input task.
    /// The ordered result consumer, never this return, acknowledges coverage.
    public func requestFinalization(source: LiveAudioSampleIdentity, throughSample: Int64) async throws {
        try Task.checkCancellation()
        guard let session, let original = session.identity.get(),
              original.recordingGeneration == source.recordingGeneration,
              original.continuityID == source.continuityID,
              original.approximateOrigin == source.approximateOrigin,
              source.isValid, throughSample > source.startSample,
              throughSample <= (session.identity.lastEnd() ?? -1) else {
            throw VoiceRecognitionError.invalidInput
        }
        requestedThrough = max(requestedThrough ?? throughSample, throughSample)
        guard finalizationTask == nil else { return }
        let id = session.id
        finalizationTask = Task { await self.finalizeRequested(id: id) }
    }

    private func finalizeRequested(id: UUID) async {
        while !Task.isCancelled, let session, session.id == id, let through = requestedThrough {
            requestedThrough = nil
            do { try await session.analyzer.finalize(through: CMTime(value: through, timescale: 16_000)) }
            catch { break } // No acknowledgement: the durable worker retains CPU fallback.
        }
        if session?.id == id { finalizationTask = nil; requestedThrough = nil }
    }

    private func joinFinalization(id: UUID) async {
        guard session?.id == id else { return }
        let task = finalizationTask
        task?.cancel()
        await task?.value
        if session?.id == id { session = nil; finalizationTask = nil; requestedThrough = nil }
    }
    public init(localeIdentifier: String = "en-AU") { self.localeIdentifier = localeIdentifier }

    /// Explicit Settings action only. Recognition never initiates a download.
    public static func prepareAssets(localeIdentifier: String = "en-AU") async throws {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw VoiceRecognitionError.unavailable
        }
        _ = try await AssetInventory.reserve(locale: locale)
        let transcriber = makeTranscriber(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw VoiceRecognitionError.missingAssets
        }
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    public func run(input: AsyncStream<CapturedAudio>,
                    receive: @escaping @Sendable (VoiceRecognitionEvent) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !running else { throw VoiceRecognitionError.alreadyRunning }
        running = true
        defer { running = false }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw VoiceRecognitionError.unavailable
        }
        let transcriber = Self.makeTranscriber(locale)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw VoiceRecognitionError.missingAssets
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceRecognitionError.unavailable
        }
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .utility, modelRetention: .whileInUse))
        let (nativeInput, nativeContinuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(16))
        let (events, eventContinuation) = AsyncThrowingStream<VoiceRecognitionEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let identity = VoiceStreamIdentity()
        let sessionID = UUID()
        session = (sessionID, analyzer, identity)
        // Finalization is read from the same ordered result consumer below.
        // Analyzer callbacks can race that consumer and must never confirm text.
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
            try await receive(.ready)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in events { try await receive(event) }
                }
                group.addTask {
                    do {
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            guard let source = identity.get() else { throw VoiceRecognitionError.invalidInput }
                            let update = try Self.convertResult(result, source: source)
                            if case .dropped = eventContinuation.yield(.update(update)) {
                                throw VoiceRecognitionError.droppedInput
                            }
                            if result.resultsFinalizationTime.isNumeric {
                                let through = CMTimeConvertScale(result.resultsFinalizationTime,
                                    timescale: 16_000, method: .roundTowardZero).value
                                guard through <= (identity.lastEnd() ?? -1) else { throw VoiceRecognitionError.invalidInput }
                                if through >= source.startSample, case .dropped = eventContinuation.yield(.finalized(
                                    recordingGeneration: source.recordingGeneration,
                                    continuityID: source.continuityID, throughSample: through)) {
                                    throw VoiceRecognitionError.droppedInput
                                }
                            }
                        }
                        eventContinuation.finish()
                    } catch {
                        eventContinuation.finish(throwing: error)
                        throw error
                    }
                }
                group.addTask {
                    do {
                        let last = try await analyzer.analyzeSequence(nativeInput)
                        try Task.checkCancellation()
                        if let last {
                            try await analyzer.finalizeAndFinish(through: last)
                            if last.isNumeric, let end = identity.lastEnd() {
                                identity.setCompletedThrough(min(end, CMTimeConvertScale(last,
                                    timescale: 16_000, method: .roundTowardZero).value))
                            }
                        }
                        else { await analyzer.cancelAndFinishNow() }
                    } catch {
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                }
                group.addTask {
                    let converter = try LiveSpeechPCMConverter(format: format)
                    var expected: Int64?
                    for await audio in input {
                        try Task.checkCancellation()
                        guard audio.source == .microphone, let source = audio.sampleIdentity, source.isValid,
                              audio.sampleRate == 16_000, audio.channels == 1,
                              source.sampleCount * 2 == audio.audioData.count else {
                            throw VoiceRecognitionError.invalidInput
                        }
                        if let original = identity.get() {
                            guard original.recordingGeneration == source.recordingGeneration,
                                  original.continuityID == source.continuityID,
                                  original.approximateOrigin == source.approximateOrigin,
                                  expected == source.startSample else { throw VoiceRecognitionError.discontinuity }
                        } else { identity.set(source) }
                        expected = source.startSample + source.sampleCount
                        identity.setEnd(expected!)
                        for value in try converter.append(audio.audioData, sourceStart: source.startSample) {
                            if case .dropped = nativeContinuation.yield(value) { throw VoiceRecognitionError.droppedInput }
                        }
                    }
                    try Task.checkCancellation()
                    for value in try converter.finish() {
                        if case .dropped = nativeContinuation.yield(value) { throw VoiceRecognitionError.droppedInput }
                    }
                    nativeContinuation.finish()
                }
                do { while try await group.next() != nil {} }
                catch {
                    nativeContinuation.finish()
                    eventContinuation.finish(throwing: error)
                    group.cancelAll()
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            }
            await joinFinalization(id: sessionID)
            try Task.checkCancellation()
            // Only successful, joined analyzer completion may settle the tail.
            // Result-stream termination alone can also follow native failure.
            if let source = identity.get(), let through = identity.completedThrough(), through >= source.startSample {
                try await receive(.finalized(recordingGeneration: source.recordingGeneration,
                    continuityID: source.continuityID, throughSample: through))
            }
        } catch {
            nativeContinuation.finish()
            eventContinuation.finish(throwing: error)
            await analyzer.cancelAndFinishNow()
            await joinFinalization(id: sessionID)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private static func convertResult(_ result: SpeechTranscriber.Result,
                                      source: LiveAudioSampleIdentity) throws -> VoiceRecognitionUpdate {
        func sample(_ time: CMTime) throws -> Int64 {
            guard time.isNumeric, time.timescale > 0 else { throw VoiceRecognitionError.invalidInput }
            let value = CMTimeConvertScale(time, timescale: 16_000, method: .roundHalfAwayFromZero).value
            guard value >= 0 else { throw VoiceRecognitionError.invalidInput }
            return value
        }
        let start = try sample(result.range.start)
        let end = try sample(CMTimeRangeGetEnd(result.range))
        var tokens: [VoiceTimedToken] = []
        for run in result.text.runs {
            let text = String(result.text[run.range].characters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if let range = run.audioTimeRange {
                tokens.append(.init(text: text, startSample: try sample(range.start),
                    endSample: try sample(CMTimeRangeGetEnd(range)), hasStartBoundary: true, hasEndBoundary: true))
            } else {
                // This span has only enclosing utterance timing; it cannot supply
                // phrase edges even when its text happens to equal the trigger.
                tokens.append(.init(text: text, startSample: start, endSample: end,
                    hasStartBoundary: false, hasEndBoundary: false))
            }
        }
        return .init(source: source, startSample: start, endSample: end,
            text: String(result.text.characters), tokens: tokens, isFinal: result.isFinal)
    }
}

private final class VoiceStreamIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var source: LiveAudioSampleIdentity?
    private var end: Int64?
    private var completed: Int64?
    func completedThrough() -> Int64? { lock.lock(); defer { lock.unlock() }; return completed }
    func setCompletedThrough(_ value: Int64) { lock.lock(); completed = value; lock.unlock() }
    func get() -> LiveAudioSampleIdentity? { lock.lock(); defer { lock.unlock() }; return source }
    func set(_ value: LiveAudioSampleIdentity) { lock.lock(); source = value; lock.unlock() }
    func lastEnd() -> Int64? { lock.lock(); defer { lock.unlock() }; return end }
    func setEnd(_ value: Int64) { lock.lock(); end = value; lock.unlock() }
}

/// A single stateful native converter survives all packets in one continuity.
/// Output offsets use produced frame counts, avoiding packet-rounding drift.
@available(macOS 26.0, *)
private final class LiveSpeechPCMConverter {
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private var sourceStart: Int64?
    private var produced: Int64 = 0
    init(format: AVAudioFormat) throws {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format) else { throw VoiceRecognitionError.invalidInput }
        self.format = format; self.converter = converter
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        converter.primeMethod = .none
    }
    func append(_ data: Data, sourceStart: Int64) throws -> [AnalyzerInput] {
        if self.sourceStart == nil { self.sourceStart = sourceStart }
        return try convert(try NativeSpeechPCMConverter.makeBuffer(data), final: false)
    }
    func finish() throws -> [AnalyzerInput] { try convert(nil, final: true) }
    private func convert(_ buffer: AVAudioPCMBuffer?, final: Bool) throws -> [AnalyzerInput] {
        guard let sourceStart else { return [] }
        var delivered = false
        var values: [AnalyzerInput] = []
        // A capture packet is bounded at 60 seconds; 64K output frames per turn
        // bounds native allocation while preserving converter state and tails.
        for _ in 0..<512 {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
                throw VoiceRecognitionError.invalidInput
            }
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in
                if !delivered, let buffer { delivered = true; status.pointee = .haveData; return buffer }
                status.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            guard result != .error, error == nil else { throw VoiceRecognitionError.invalidInput }
            if output.frameLength > 0 {
                let offset = CMTimeAdd(CMTime(value: sourceStart, timescale: 16_000),
                    CMTime(value: produced, timescale: CMTimeScale(format.sampleRate)))
                values.append(AnalyzerInput(buffer: output, bufferStartTime: offset))
                produced += Int64(output.frameLength)
            }
            if result == .inputRanDry || result == .endOfStream { return values }
            guard output.frameLength > 0 else { throw VoiceRecognitionError.invalidInput }
        }
        throw VoiceRecognitionError.invalidInput
    }
}
