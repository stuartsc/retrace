import XCTest
@testable import Retrace

final class DashboardVoiceLayoutTests: XCTestCase {
    func testDictationIsDefaultDashboardTab() {
        XCTAssertEqual(DashboardContentTab.defaultTab, .dictation)
    }

    func testDashboardTabsAreVoiceFirst() {
        XCTAssertEqual(DashboardContentTab.allCases, [.dictation, .appUsage, .live])
        XCTAssertEqual(DashboardContentTab.allCases.map(\.title), ["Dictation", "App Usage", "Live"])
    }

    func testLiveTabHasDedicatedCaptureSurfaces() {
        XCTAssertEqual(DashboardContentTab.live.subtitle, "Live audio, screenshots, OCR, and capture metadata")
    }

    func testVoiceDeskUsesSplitLayoutAtNormalWidths() {
        XCTAssertEqual(DashboardVoiceLayoutPolicy.contentMode(forWidth: 1_000), .split)
    }

    func testVoiceDeskUsesSplitLayoutAtDefaultWindowContentWidth() {
        XCTAssertEqual(DashboardVoiceLayoutPolicy.contentMode(forWidth: 840), .split)
    }

    func testVoiceDeskStacksLiveAudioAtCompactWidths() {
        XCTAssertEqual(DashboardVoiceLayoutPolicy.contentMode(forWidth: 760), .stacked)
    }

    func testDefaultDashboardWindowIsWideEnoughForAllStatTiles() {
        XCTAssertGreaterThanOrEqual(DashboardVoiceLayoutPolicy.defaultWindowWidth, 1_420)
        XCTAssertTrue(
            DashboardStatsStripLayoutPolicy.canFitAllTiles(
                cardCount: 6,
                availableWidth: DashboardVoiceLayoutPolicy.defaultContentWidth
            )
        )
    }

    func testStatsStripIsTallEnoughForMiniGraphs() {
        XCTAssertGreaterThanOrEqual(DashboardStatsStripLayoutPolicy.tileHeight, 116)
        XCTAssertGreaterThanOrEqual(DashboardStatsStripLayoutPolicy.graphHeight, 34)
    }

    func testLiveTabUsesThreeColumnLayoutAtDefaultWidth() {
        XCTAssertEqual(
            DashboardLiveLayoutPolicy.contentMode(forWidth: DashboardVoiceLayoutPolicy.defaultContentWidth),
            .threeColumn
        )
    }

    func testLiveTabStacksAtCompactWidths() {
        XCTAssertEqual(DashboardLiveLayoutPolicy.contentMode(forWidth: 900), .stacked)
    }

    func testLiveTabGivesAudioMoreHorizontalSpaceThanScreenshotsAndContext() {
        let columns = DashboardLiveLayoutPolicy.columnWidths(forWidth: DashboardVoiceLayoutPolicy.defaultContentWidth)
        XCTAssertGreaterThan(columns.audio, columns.screenshots)
        XCTAssertGreaterThan(columns.screenshots, columns.context)
    }

    func testLiveScreenshotHistoryPageSizeSupportsLazyLoading() {
        XCTAssertGreaterThanOrEqual(DashboardLiveLayoutPolicy.screenshotPageSize, 12)
    }

    func testLivePassiveRefreshKeepsRecentItemsBounded() {
        let latest = [105, 104, 103, 102]
        let existing = Array(stride(from: 110, through: 1, by: -1))

        let merged = DashboardLiveMemoryPolicy.mergedLatest(
            latest,
            into: existing,
            id: { $0 },
            maxCount: 12
        )

        XCTAssertEqual(Array(merged.prefix(4)), latest)
        XCTAssertEqual(merged.count, 12)
        XCTAssertFalse(merged.contains(1))
    }

    func testDashboardRefreshLoopStopsWhenWindowIsHidden() {
        XCTAssertTrue(DashboardRefreshLoopPolicy.shouldContinue(
            loopTab: .dictation,
            selectedTab: .dictation,
            isWindowVisible: true
        ))
        XCTAssertFalse(DashboardRefreshLoopPolicy.shouldContinue(
            loopTab: .dictation,
            selectedTab: .dictation,
            isWindowVisible: false
        ))
        XCTAssertFalse(DashboardRefreshLoopPolicy.shouldContinue(
            loopTab: .dictation,
            selectedTab: .live,
            isWindowVisible: true
        ))
    }

    func testLiveThumbnailCacheKeepsOnlyRecentAndSelectedFrames() {
        let retained = DashboardLiveMemoryPolicy.retainedCacheIDs(
            preferredIDs: Array(1...20),
            selectedID: 17,
            maxCount: 6
        )

        XCTAssertEqual(retained.count, 6)
        XCTAssertTrue(retained.contains(17))
        XCTAssertTrue(retained.contains(1))
        XCTAssertTrue(retained.contains(5))
        XCTAssertFalse(retained.contains(20))
    }

    func testLiveScreenshotThumbnailsHaveSmallPixelBudget() {
        XCTAssertLessThanOrEqual(DashboardLiveMemoryPolicy.thumbnailMaxPixelDimension, 360)
        XCTAssertGreaterThanOrEqual(DashboardLiveMemoryPolicy.thumbnailMaxPixelDimension, 180)
    }

    func testTranscriptRowsExpandFromPreviewToFullText() {
        XCTAssertEqual(DashboardTranscriptDisplayPolicy.lineLimit(isExpanded: false), 3)
        XCTAssertNil(DashboardTranscriptDisplayPolicy.lineLimit(isExpanded: true))
    }

    func testTranscriptCopyTextPreservesFullText() {
        XCTAssertEqual(
            DashboardTranscriptDisplayPolicy.copyText(" first line\nsecond line "),
            "first line\nsecond line"
        )
    }

    func testLiveAudioPreviewTrimsWhitespaceAndCollapsesLines() {
        XCTAssertEqual(
            DashboardLiveAudioRow.previewText(from: "  hello\n\nworld  "),
            "hello world"
        )
    }

    func testLiveAudioPreviewFallsBackForBlankText() {
        XCTAssertEqual(
            DashboardLiveAudioRow.previewText(from: "  \n "),
            "No transcript text"
        )
    }

    func testLiveAudioStatusTextExplainsCapturedEmptyBatch() {
        XCTAssertEqual(
            DashboardLiveAudioRow.statusText(status: "needs_review", qualityFlags: "empty_text,speech_energy"),
            "Audio captured. No words decoded yet; queued for repair."
        )
    }

    func testLiveAudioPresentationGroupsRepeatedPendingRows() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        var pendingRows: [DashboardLiveAudioRow] = []
        for index in 0..<6 {
            pendingRows.append(DashboardLiveAudioRow(
                id: Int64(100 + index),
                text: "",
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 10)),
                source: .microphone,
                confidence: nil,
                transcriptStatus: "pending",
                detectedLanguage: nil,
                audioVariant: "raw",
                qualityFlags: nil
            ))
        }
        let transcript = DashboardLiveAudioRow(
            id: 50,
            text: "This is a real transcript.",
            startedAt: now.addingTimeInterval(-120),
            endedAt: now.addingTimeInterval(-110),
            source: .microphone,
            confidence: 0.8,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil
        )

        let presented = DashboardLiveAudioPresentationPolicy.rowsForDisplay(pendingRows + [transcript])

        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0].isPendingSummary)
        XCTAssertEqual(presented[0].pendingBatchCount, 6)
        XCTAssertTrue(presented[0].displayText.contains("6 audio batches captured"))
        XCTAssertEqual(presented[1].text, "This is a real transcript.")
    }

    func testLiveAudioPresentationGroupsRepeatedLowConfidenceArtifacts() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        var noiseRows: [DashboardLiveAudioRow] = []
        for index in 0..<5 {
            noiseRows.append(DashboardLiveAudioRow(
                id: Int64(200 + index),
                text: "ɔːɔːɔːɔːɔːɔː",
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 10)),
                source: .microphone,
                confidence: nil,
                transcriptStatus: "probable_junk",
                detectedLanguage: "nn",
                audioVariant: "raw",
                qualityFlags: "vocalization_artifact,variant:raw"
            ))
        }
        let transcript = DashboardLiveAudioRow(
            id: 90,
            text: "This is the next useful transcript.",
            startedAt: now.addingTimeInterval(-90),
            endedAt: now.addingTimeInterval(-80),
            source: .microphone,
            confidence: 0.8,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil
        )

        let presented = DashboardLiveAudioPresentationPolicy.rowsForDisplay(noiseRows + [transcript])

        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0].isLowConfidenceSummary)
        XCTAssertEqual(presented[0].pendingBatchCount, 5)
        XCTAssertTrue(presented[0].displayText.contains("5 audio batches grouped for repair"))
        XCTAssertEqual(presented[1].text, "This is the next useful transcript.")
    }

    func testLiveAudioPresentationCoalescesRepeatedSummaryMessages() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        var rows: [DashboardLiveAudioRow] = []

        for group in 0..<3 {
            for index in 0..<20 {
                rows.append(DashboardLiveAudioRow(
                    id: Int64(1_000 + group * 100 + index),
                    text: "ɔːɔːɔːɔːɔːɔː",
                    startedAt: now.addingTimeInterval(Double(-(group * 30 + index))),
                    endedAt: now.addingTimeInterval(Double(-(group * 30 + index - 1))),
                    source: .microphone,
                    confidence: nil,
                    transcriptStatus: "probable_junk",
                    detectedLanguage: "nn",
                    audioVariant: "raw",
                    qualityFlags: "vocalization_artifact,variant:raw"
                ))
            }

            rows.append(DashboardLiveAudioRow(
                id: Int64(2_000 + group),
                text: "",
                startedAt: now.addingTimeInterval(Double(-(group * 30 + 21))),
                endedAt: now.addingTimeInterval(Double(-(group * 30 + 20))),
                source: .microphone,
                confidence: nil,
                transcriptStatus: "pending",
                detectedLanguage: nil,
                audioVariant: "raw",
                qualityFlags: nil
            ))
        }

        let presented = DashboardLiveAudioPresentationPolicy.rowsForDisplay(rows)
        let lowConfidenceSummaries = presented.filter { $0.isLowConfidenceSummary }

        XCTAssertEqual(lowConfidenceSummaries.count, 1)
        XCTAssertEqual(lowConfidenceSummaries.first?.pendingBatchCount, 60)
        let pendingSummaries = presented.filter { $0.isPendingSummary }
        XCTAssertEqual(pendingSummaries.count, 1)
        XCTAssertEqual(pendingSummaries.first?.pendingBatchCount, 3)
    }

    func testLiveAudioPresentationCollapsesRepeatedNonSpeechCaptionArtifacts() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let repeatedArtifacts = [
            "(Breathing)",
            "(Breathing)",
            "(Breathing)",
            "*sound of wind*",
            "*sound of wind*",
            "*sound of wind*"
        ].enumerated().map { index, text in
            DashboardLiveAudioRow(
                id: Int64(3_000 + index),
                text: text,
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: 0.12,
                transcriptStatus: "transcribed",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: nil
            )
        }
        let transcript = DashboardLiveAudioRow(
            id: 3_999,
            text: "This part is actual speech and should stay readable.",
            startedAt: now.addingTimeInterval(-80),
            endedAt: now.addingTimeInterval(-70),
            source: .microphone,
            confidence: 0.88,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil
        )

        let presented = DashboardLiveAudioPresentationPolicy.rowsForDisplay(repeatedArtifacts + [transcript])

        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0].isLowConfidenceSummary)
        XCTAssertEqual(presented[0].pendingBatchCount, 6)
        XCTAssertFalse(presented.contains { $0.text == "(Breathing)" })
        XCTAssertFalse(presented.contains { $0.text == "*sound of wind*" })
        XCTAssertEqual(presented[1].text, transcript.text)
    }

    func testLiveAudioPresentationCollapsesRepairStatusRowsEvenWhenTheyHaveText() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let repairRows = [
            (text: "(Breathing)", status: "probable_junk", language: "nn", flags: "junk_pattern,variant:raw"),
            (text: "No.", status: "needs_review", language: "en", flags: "short_text,variant:raw"),
            (text: "ʻᵖᵗᵗᵗ", status: "needs_review", language: "nn", flags: "short_text,variant:raw"),
            (text: "සැහාහින්න්", status: "needs_review", language: "nn", flags: "short_text,variant:highPassBoosted"),
            (text: "[Observe the", status: "language_uncertain", language: "nn", flags: "language_uncertain,variant:normalized")
        ].enumerated().map { index, item in
            DashboardLiveAudioRow(
                id: Int64(5_000 + index),
                text: item.text,
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: 0.18,
                transcriptStatus: item.status,
                detectedLanguage: item.language,
                audioVariant: "raw",
                qualityFlags: item.flags
            )
        }
        let cleanTranscript = DashboardLiveAudioRow(
            id: 5_999,
            text: "No, keep clean transcribed speech visible.",
            startedAt: now.addingTimeInterval(-70),
            endedAt: now.addingTimeInterval(-62),
            source: .microphone,
            confidence: 0.91,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil
        )

        let presented = DashboardLiveAudioPresentationPolicy.rowsForDisplay(repairRows + [cleanTranscript])

        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented[0].isLowConfidenceSummary)
        XCTAssertEqual(presented[0].pendingBatchCount, 5)
        XCTAssertFalse(presented.contains { $0.text == "(Breathing)" })
        XCTAssertFalse(presented.contains { $0.text == "No." })
        XCTAssertFalse(presented.contains { $0.text == "ʻᵖᵗᵗᵗ" })
        XCTAssertFalse(presented.contains { $0.text == "සැහාහින්න්" })
        XCTAssertEqual(presented[1].text, cleanTranscript.text)
    }

    func testLiveAudioPresentationGroupsRepeatedGenericStatusRows() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        var failedRows: [DashboardLiveAudioRow] = []
        for index in 0..<4 {
            failedRows.append(DashboardLiveAudioRow(
                id: Int64(4_000 + index),
                text: "",
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: nil,
                transcriptStatus: "decode_failed",
                detectedLanguage: nil,
                audioVariant: "raw",
                qualityFlags: "decode_error"
            ))
        }

        let presented = DashboardLiveAudioPresentationPolicy.rowsForDisplay(failedRows)

        XCTAssertEqual(presented.count, 1)
        XCTAssertTrue(presented[0].isStatusSummary)
        XCTAssertEqual(presented[0].pendingBatchCount, 4)
        XCTAssertTrue(presented[0].displayText.contains("4 matching audio status rows"))
        XCTAssertTrue(presented[0].displayText.contains("decoding failed"))
    }

    func testLiveAudioPaginationOffsetTracksRawTranscriptRows() {
        XCTAssertEqual(
            DashboardLiveAudioPaginationPolicy.nextTranscriptOffset(
                currentOffset: 0,
                fetchedTranscriptRows: 20,
                reset: true
            ),
            20
        )
        XCTAssertEqual(
            DashboardLiveAudioPaginationPolicy.nextTranscriptOffset(
                currentOffset: 20,
                fetchedTranscriptRows: 20,
                reset: false
            ),
            40
        )
    }
}
