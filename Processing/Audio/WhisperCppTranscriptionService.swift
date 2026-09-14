import Foundation
import AVFoundation
import Shared
import CWhisper

/// Whisper.cpp-based local transcription service
/// Uses whisper.cpp C library for on-device speech-to-text
/// Owner: PROCESSING agent
public actor WhisperCppTranscriptionService: TranscriptionProtocol {
    internal static let defaultUseGPU = false
    internal static let recallFirstNoSpeechThreshold: Float = 1.0
    internal static let recallFirstLogprobThreshold: Float = -10.0
    internal static let recallFirstEntropyThreshold: Float = 8.0
    internal static let recallFirstTemperatureIncrement: Float = 0.2
    internal static let recallFirstMaxInitialTimestamp: Float = 1.0

    /// Controls whisper.cpp decoding strategy
    public enum SamplingStrategy: Sendable {
        case greedy
        case beamSearch(beamSize: Int)
    }

    /// Controls whether model weights remain resident between transcription jobs.
    public enum ModelResidency: Sendable {
        case resident
        case onDemand(idleTimeout: Duration)
    }

    private var whisperContext: OpaquePointer?
    private let modelPath: String
    private let coreMLModelPath: String?
    private let samplingStrategy: SamplingStrategy
    private let modelResidency: ModelResidency
    internal nonisolated let useGPU: Bool
    private var isInitialized = false
    private var idleUnloadTask: Task<Void, Never>?

    public init(
        modelPath: String,
        coreMLModelPath: String? = nil,
        samplingStrategy: SamplingStrategy = .greedy,
        useGPU: Bool = false,
        modelResidency: ModelResidency = .resident
    ) {
        self.modelPath = modelPath
        self.coreMLModelPath = coreMLModelPath
        self.samplingStrategy = samplingStrategy
        self.useGPU = useGPU
        self.modelResidency = modelResidency
    }

    // MARK: - Initialization

    /// Initialize whisper.cpp with the specified model
    public func initialize() async throws {
        cancelScheduledUnload()
        guard !isInitialized else { return }

        let expandedPath = NSString(string: modelPath).expandingTildeInPath

        var params = whisper_context_default_params()
        params.use_gpu = useGPU

        whisperContext = whisper_init_from_file_with_params(expandedPath, params)

        guard whisperContext != nil else {
            throw TranscriptionError.modelLoadFailed("Failed to load model at: \(expandedPath)")
        }

        isInitialized = true
        Log.info(
            "[WhisperCppTranscriptionService] Initialized with model: \(expandedPath), backend=\(useGPU ? "gpu" : "cpu")",
            category: .processing
        )
    }

    /// Cleanup
    public func cleanup() {
        cancelScheduledUnload()
        unloadModel()
    }

    private func unloadModel() {
        if let ctx = whisperContext {
            whisper_free(ctx)
            whisperContext = nil
        }
        isInitialized = false
    }

    // MARK: - Transcription

    /// Transcribe audio data (must be 16kHz mono Float32 or PCM Int16)
    public func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        let ctx = try await prepareForTranscription()
        defer { scheduleIdleUnloadIfNeeded() }

        // Convert PCM Int16 to Float32 for whisper.cpp
        let samples = convertToFloat32(audioData)

        // Call whisper.cpp with configured sampling strategy
        var params = makeWhisperParams()
        Self.configureRecallFirstDecoding(&params)
        params.suppress_blank = true
        params.suppress_nst = false
        let result = runWhisper(ctx: ctx, params: &params, samples: samples, initialPrompt: nil, languageHint: nil)

        guard result == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        // Get transcription text
        let numSegments = whisper_full_n_segments(ctx)
        var fullText = ""

        for i in 0..<numSegments {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                fullText += String(cString: segmentText)
            }
        }

        // Get detected language
        let langId = whisper_full_lang_id(ctx)
        let language = String(cString: whisper_lang_str(langId))

        return TranscriptionResult(
            text: Self.stripControlTokens(fullText),
            confidence: 0.0,  // whisper.cpp doesn't provide overall confidence
            language: language,
            duration: Double(samples.count) / 16000.0
        )
    }

    /// Transcribe with word-level timestamps
    public func transcribeWithTimestamps(_ audioData: Data, wordLevel: Bool = false, initialPrompt: String? = nil) async throws -> DetailedTranscriptionResult {
        try await transcribeWithTimestamps(
            audioData,
            wordLevel: wordLevel,
            initialPrompt: initialPrompt,
            languageHint: nil
        )
    }

    /// Transcribe with word-level timestamps and an optional language hint.
    /// nil / "auto" uses multilingual auto-detection explicitly.
    public func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool = false,
        initialPrompt: String? = nil,
        languageHint: String?
    ) async throws -> DetailedTranscriptionResult {
        let ctx = try await prepareForTranscription()
        defer { scheduleIdleUnloadIfNeeded() }

        let samples = convertToFloat32(audioData)

        // Configure whisper.cpp for word-level timestamps
        var params = makeWhisperParams()
        Self.configureRecallFirstDecoding(&params)
        params.print_timestamps = wordLevel
        params.token_timestamps = wordLevel
        params.max_len = 0  // Don't limit segment length
        // Keep suppress_blank (prevents blank token spam) but disable suppress_nst
        // which was dropping valid short words in fast speech.
        params.suppress_blank = true
        params.suppress_nst = false

        // Run transcription — helper keeps prompt/language C strings alive during whisper_full.
        let result = runWhisper(
            ctx: ctx,
            params: &params,
            samples: samples,
            initialPrompt: initialPrompt,
            languageHint: languageHint
        )

        guard result == 0 else {
            throw TranscriptionError.transcriptionFailed
        }

        var words: [TranscriptionWord] = []
        var fullText = ""

        // Extract word-level timestamps from tokens within each segment
        let numSegments = whisper_full_n_segments(ctx)
        for segmentIdx in 0..<numSegments {
            guard let segmentText = whisper_full_get_segment_text(ctx, segmentIdx) else {
                continue
            }
            fullText += String(cString: segmentText)

            if wordLevel {
                // Get tokens for this segment
                let numTokens = whisper_full_n_tokens(ctx, segmentIdx)

                var currentWord = ""
                var wordStartTime: Double? = nil
                var wordEndTime: Double? = nil
                var lastTokenConfidence: Double? = nil

                for tokenIdx in 0..<numTokens {
                    let tokenData = whisper_full_get_token_data(ctx, segmentIdx, tokenIdx)

                    // Get token text
                    guard let tokenTextPtr = whisper_full_get_token_text(ctx, segmentIdx, tokenIdx) else {
                        continue
                    }
                    let tokenText = String(cString: tokenTextPtr)

                    // Get token timestamps (in centiseconds)
                    let t0 = Double(tokenData.t0) / 100.0
                    let t1 = Double(tokenData.t1) / 100.0

                    // Skip control tokens entirely ([_BEG_], [_TT_nnn], [BLANK_AUDIO], etc.)
                    if tokenText.hasPrefix("[") && tokenText.hasSuffix("]") {
                        continue
                    }

                    // Word boundary detection: whisper tokens starting with space indicate new word
                    if tokenText.hasPrefix(" ") || tokenText.hasPrefix("\n") {
                        // Save previous word if exists
                        if !currentWord.isEmpty, let startTime = wordStartTime {
                            let cleanWord = Self.stripControlTokens(currentWord.trimmingCharacters(in: .whitespacesAndNewlines))
                            if !cleanWord.isEmpty {
                                words.append(TranscriptionWord(
                                    word: cleanWord,
                                    start: startTime,
                                    end: t0,
                                    confidence: Double(tokenData.p)
                                ))
                            }
                        }
                        // Start new word
                        currentWord = tokenText.trimmingCharacters(in: .whitespaces)
                        wordStartTime = t0
                    } else {
                        // Continue current word
                        currentWord += tokenText
                        if wordStartTime == nil {
                            wordStartTime = t0
                        }
                    }

                    wordEndTime = t1
                    lastTokenConfidence = Double(tokenData.p)
                }

                // Whisper normally ends a segment with a skipped control token.
                // Flush the pending word after visiting every token, using the
                // last lexical token's timing rather than the control token's.
                if !currentWord.isEmpty, let startTime = wordStartTime, let endTime = wordEndTime {
                    let cleanWord = Self.stripControlTokens(currentWord.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !cleanWord.isEmpty {
                        words.append(TranscriptionWord(
                            word: cleanWord,
                            start: startTime,
                            end: endTime,
                            confidence: lastTokenConfidence
                        ))
                    }
                }
            }
        }

        // Get detected language
        let langId = whisper_full_lang_id(ctx)
        let language = String(cString: whisper_lang_str(langId))

        return DetailedTranscriptionResult(
            text: Self.stripControlTokens(fullText),
            words: words,
            language: language,
            duration: Double(samples.count) / 16000.0
        )
    }

    /// Transcribe with word-level timestamps and contextual initial prompt
    /// The initial prompt conditions the decoder on surrounding context, improving coherence
    public func transcribeWithContext(
        _ audioData: Data,
        wordLevel: Bool = true,
        initialPrompt: String
    ) async throws -> DetailedTranscriptionResult {
        // Preserve this entry point's prefix-based prompt limit while sharing
        // decoding, word extraction and model cleanup with the timestamp API.
        try await transcribeWithTimestamps(
            audioData,
            wordLevel: wordLevel,
            initialPrompt: String(initialPrompt.prefix(800)),
            languageHint: nil
        )
    }

    // MARK: - Helper Methods

    /// Strip whisper.cpp control tokens like [_BEG_], [BLANK_AUDIO], [_TT_500], [no audio] etc.
    private static func stripControlTokens(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "\\[.*?\\]",
            with: "",
            options: .regularExpression
        )
        // Collapse multiple spaces and trim
        let collapsed = stripped.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create whisper params based on the configured sampling strategy
    private func makeWhisperParams() -> whisper_full_params {
        switch samplingStrategy {
        case .greedy:
            return whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        case .beamSearch(let beamSize):
            var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
            params.beam_search.beam_size = Int32(beamSize)
            return params
        }
    }

    private func prepareForTranscription() async throws -> OpaquePointer {
        cancelScheduledUnload()

        if !isInitialized {
            switch modelResidency {
            case .resident:
                throw TranscriptionError.notInitialized
            case .onDemand:
                try await initialize()
            }
        }

        guard let whisperContext else {
            throw TranscriptionError.notInitialized
        }
        return whisperContext
    }

    private func cancelScheduledUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
    }

    private func scheduleIdleUnloadIfNeeded() {
        guard case .onDemand(let idleTimeout) = modelResidency else { return }

        cancelScheduledUnload()
        idleUnloadTask = Task { [weak self] in
            do {
                try await Task.sleep(for: idleTimeout, clock: .continuous)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.unloadAfterIdle()
        }
    }

    private func unloadAfterIdle() {
        idleUnloadTask = nil
        guard isInitialized else { return }
        unloadModel()
        Log.info(
            "[WhisperCppTranscriptionService] Released on-demand model after refinement became idle",
            category: .processing
        )
    }

    /// The outer audio pipeline decides whether a batch is silence after decoding.
    /// Keep whisper.cpp from internally skipping quiet/foreign speech before we can inspect it.
    internal static func configureRecallFirstDecoding(_ params: inout whisper_full_params) {
        params.no_context = true
        params.no_speech_thold = recallFirstNoSpeechThreshold
        params.logprob_thold = recallFirstLogprobThreshold
        params.entropy_thold = recallFirstEntropyThreshold
        params.temperature_inc = recallFirstTemperatureIncrement
        params.max_initial_ts = recallFirstMaxInitialTimestamp
    }

    private func runWhisper(
        ctx: OpaquePointer,
        params: inout whisper_full_params,
        samples: [Float],
        initialPrompt: String?,
        languageHint: String?
    ) -> Int32 {
        let language = Self.normalizedLanguageHint(languageHint)
        params.detect_language = false
        params.translate = false

        func runWithPrompt() -> Int32 {
            if let initialPrompt, !initialPrompt.isEmpty {
                let truncated = String(initialPrompt.suffix(800))
                return truncated.withCString { promptCStr in
                    params.initial_prompt = promptCStr
                    params.carry_initial_prompt = false
                    return samples.withUnsafeBufferPointer { samplesPtr in
                        whisper_full(ctx, params, samplesPtr.baseAddress, Int32(samples.count))
                    }
                }
            }

            return samples.withUnsafeBufferPointer { samplesPtr in
                whisper_full(ctx, params, samplesPtr.baseAddress, Int32(samples.count))
            }
        }

        guard let language else {
            params.language = nil
            return runWithPrompt()
        }

        return language.withCString { languageCStr in
            params.language = languageCStr
            return runWithPrompt()
        }
    }

    /// nil tells whisper.cpp to auto-select the language while still transcribing.
    /// Do not set `detect_language` for normal transcription; that mode can return language only.
    internal static func normalizedLanguageHint(_ languageHint: String?) -> String? {
        let trimmed = languageHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let trimmed, !trimmed.isEmpty, trimmed != "auto" else {
            return nil
        }
        return trimmed
    }

    /// Convert PCM Int16 to Float32 for whisper.cpp
    private func convertToFloat32(_ audioData: Data) -> [Float] {
        let int16Count = audioData.count / 2
        var samples = [Float](repeating: 0, count: int16Count)

        audioData.withUnsafeBytes { bufferPointer in
            let int16Buffer = bufferPointer.bindMemory(to: Int16.self)
            for i in 0..<int16Count {
                samples[i] = Float(int16Buffer[i]) / 32768.0
            }
        }

        return samples
    }
}
