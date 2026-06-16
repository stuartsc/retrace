import XCTest
import Shared
@testable import Processing

final class AudioTranscriptionCompletenessPolicyTests: XCTestCase {
    func testShortUtterancesAreReviewableSpeechNotDiscardedJunk() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "Yes",
            language: "en",
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: false,
                fullBatchRMS: 0.02,
                activeWindowRMS: 0.03,
                activeDuration: 0.8
            )
        )

        XCTAssertEqual(assessment.status, .needsReview)
        XCTAssertTrue(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testRepeatedOutroPhraseIsStoredAsProbableJunkForManualReview() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "Thanks for watching thanks for watching thanks for watching thanks for watching",
            language: "en",
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: false,
                fullBatchRMS: 0.02,
                activeWindowRMS: 0.03,
                activeDuration: 2.0
            )
        )

        XCTAssertEqual(assessment.status, .probableJunk)
        XCTAssertTrue(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testNonSpeechSoundCaptionsAreStoredAsProbableJunkForManualReview() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "*sound of wind*",
            language: "en",
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: true,
                fullBatchRMS: 0.003,
                activeWindowRMS: 0.004,
                activeDuration: 1.5
            )
        )

        XCTAssertEqual(assessment.status, .probableJunk)
        XCTAssertTrue(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testRepeatedPhoneticArtifactsAreStoredAsProbableJunkForManualReview() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "ɔːɔːɔːɔːɔːɔː",
            language: "nn",
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: false,
                fullBatchRMS: 0.004,
                activeWindowRMS: 0.006,
                activeDuration: 2.0
            )
        )

        XCTAssertEqual(assessment.status, .probableJunk)
        XCTAssertTrue(assessment.flags.contains("vocalization_artifact"))
        XCTAssertTrue(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testModifierHeavyPhoneticArtifactsAreStoredAsProbableJunkForManualReview() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "ʻɔːɟːɟːɟː",
            language: "nn",
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: false,
                fullBatchRMS: 0.004,
                activeWindowRMS: 0.006,
                activeDuration: 2.0
            )
        )

        XCTAssertEqual(assessment.status, .probableJunk)
        XCTAssertTrue(assessment.flags.contains("vocalization_artifact"))
        XCTAssertTrue(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testEmptyLowEnergyResultIsProbableSilenceAfterTranscriptionNotBefore() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "",
            language: nil,
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: true,
                fullBatchRMS: 0.0001,
                activeWindowRMS: 0.0001,
                activeDuration: 0
            )
        )

        XCTAssertEqual(assessment.status, .probableSilence)
        XCTAssertFalse(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testUnexpectedDetectedLanguageIsQueuedForRepairNotFinalTranscript() {
        let assessment = AudioTranscriptQualityPolicy.assess(
            text: "stainless steel meter screen KAREN tomato",
            language: "nn",
            activity: .init(
                shouldTranscribe: true,
                isProbablySilence: false,
                fullBatchRMS: 0.006,
                activeWindowRMS: 0.008,
                activeDuration: 2.5
            )
        )

        XCTAssertEqual(assessment.status, .languageUncertain)
        XCTAssertTrue(assessment.flags.contains("language_uncertain"))
        XCTAssertTrue(assessment.shouldStoreText)
        XCTAssertTrue(assessment.shouldRetryWithEnhancement)
    }

    func testExpectedLanguageHintsPreferAutoThenEnglishJapaneseAndMongolian() {
        XCTAssertEqual(
            AudioTranscriptionLanguageHint.retryOrder.map(\.rawValue),
            ["auto", "en", "ja", "mn"]
        )
    }

    func testRetryPipelineExhaustsEnhancementsBeforeAcceptingEmptySpeechEnergy() async throws {
        let service = ScriptedTranscriptionService(
            results: Array(
                repeating: DetailedTranscriptionResult(text: "", words: [], language: "nn", duration: 1.0),
                count: 32
            )
        )
        try await service.initialize()

        let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
            audioData: Self.pcmSine(duration: 1.0, sampleRate: 16_000, amplitude: 0.02),
            sampleRate: 16_000,
            channels: 1,
            transcriptionService: service,
            wordLevel: true,
            initialPrompt: nil
        )

        let expectedAttempts = 1 + (AudioEnhancementVariant.retryOrder.count - 1) * AudioTranscriptionLanguageHint.retryOrder.count
        XCTAssertEqual(decision.status, .needsReview)
        XCTAssertEqual(decision.attempts, expectedAttempts)
    }

    func testRetryPipelinePrefersLongerEnhancedCandidateOverShortRawQuietCandidate() async throws {
        let short = Self.result("quiet speech starts")
        let long = Self.result("quiet speech starts and then continues with more words that raw whisper missed")
        let service = ScriptedTranscriptionService(
            results: [short, long] + Array(repeating: short, count: 32)
        )
        try await service.initialize()

        let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
            audioData: Self.pcmSine(duration: 1.0, sampleRate: 16_000, amplitude: 0.02),
            sampleRate: 16_000,
            channels: 1,
            transcriptionService: service,
            wordLevel: true,
            initialPrompt: nil
        )

        XCTAssertEqual(decision.transcription.text, long.text)
        XCTAssertGreaterThan(decision.attempts, 1)
    }

    func testLiveRetryProfileDoesNotRunOfflineRepairBudget() async throws {
        let service = ScriptedTranscriptionService(
            results: Array(
                repeating: DetailedTranscriptionResult(text: "", words: [], language: "nn", duration: 1.0),
                count: 32
            )
        )
        try await service.initialize()

        let decision = try await AudioTranscriptionRetryPipeline.transcribeBest(
            audioData: Self.pcmSine(duration: 1.0, sampleRate: 16_000, amplitude: 0.004),
            sampleRate: 16_000,
            channels: 1,
            transcriptionService: service,
            wordLevel: true,
            initialPrompt: nil,
            profile: .liveFirstPass
        )

        XCTAssertEqual(decision.attempts, 3)
    }

    func testSentenceSegmenterKeepsTextWhenWordTimingsAreMissing() {
        let sentences = SentenceSegmenter.segment(
            words: [],
            fullText: "これは静かな日本語のテストです",
            fallbackDuration: 3.5
        )

        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences[0].text, "これは静かな日本語のテストです")
        XCTAssertEqual(sentences[0].startTime, 0)
        XCTAssertEqual(sentences[0].endTime, 3.5)
    }

    func testWhisperDecoderPolicyDisablesInternalNoSpeechSkip() {
        XCTAssertEqual(WhisperCppTranscriptionService.recallFirstNoSpeechThreshold, 1.0)
        XCTAssertLessThanOrEqual(WhisperCppTranscriptionService.recallFirstLogprobThreshold, -10.0)
        XCTAssertGreaterThanOrEqual(WhisperCppTranscriptionService.recallFirstEntropyThreshold, 8.0)
    }

    func testAutoLanguageHintUsesTranscriptionModeNotDetectionOnlyMode() {
        XCTAssertNil(WhisperCppTranscriptionService.normalizedLanguageHint(nil))
        XCTAssertNil(WhisperCppTranscriptionService.normalizedLanguageHint("auto"))
        XCTAssertEqual(WhisperCppTranscriptionService.normalizedLanguageHint(" ja "), "ja")
    }

    private static func result(_ text: String) -> DetailedTranscriptionResult {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let words = parts.enumerated().map { index, word in
            let start = Double(index) * 0.1
            return TranscriptionWord(word: word, start: start, end: start + 0.08, confidence: 0.85)
        }
        return DetailedTranscriptionResult(text: text, words: words, language: "en", duration: Double(parts.count) * 0.1)
    }

    private static func pcmSine(duration: TimeInterval, sampleRate: Int, amplitude: Double) -> Data {
        let totalSamples = Int(duration * Double(sampleRate))
        var samples: [Int16] = []
        samples.reserveCapacity(totalSamples)

        for index in 0..<totalSamples {
            let wave = sin(2.0 * Double.pi * 220.0 * Double(index) / Double(sampleRate))
            samples.append(Int16(max(-1.0, min(1.0, wave * amplitude)) * 32767.0))
        }

        return Data(bytes: samples, count: samples.count * MemoryLayout<Int16>.size)
    }
}

private actor ScriptedTranscriptionService: TranscriptionProtocol {
    private var isInitialized = false
    private var results: [DetailedTranscriptionResult]
    private var callIndex = 0

    init(results: [DetailedTranscriptionResult]) {
        self.results = results
    }

    func initialize() async throws {
        isInitialized = true
    }

    func cleanup() {
        isInitialized = false
    }

    func transcribe(_ audioData: Data) async throws -> TranscriptionResult {
        let detailed = try await transcribeWithTimestamps(audioData, wordLevel: false, initialPrompt: nil)
        return TranscriptionResult(
            text: detailed.text,
            confidence: 0.8,
            language: detailed.language,
            duration: detailed.duration
        )
    }

    func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?
    ) async throws -> DetailedTranscriptionResult {
        try await transcribeWithTimestamps(
            audioData,
            wordLevel: wordLevel,
            initialPrompt: initialPrompt,
            languageHint: nil
        )
    }

    func transcribeWithTimestamps(
        _ audioData: Data,
        wordLevel: Bool,
        initialPrompt: String?,
        languageHint: String?
    ) async throws -> DetailedTranscriptionResult {
        guard isInitialized else {
            throw TranscriptionError.notInitialized
        }
        let result = results[min(callIndex, results.count - 1)]
        callIndex += 1
        return result
    }
}
