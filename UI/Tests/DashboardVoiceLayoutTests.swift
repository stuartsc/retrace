import XCTest
@testable import Retrace

final class DashboardVoiceLayoutTests: XCTestCase {
    func testDictationIsDefaultDashboardTab() {
        XCTAssertEqual(DashboardContentTab.defaultTab, .dictation)
    }

    func testDashboardTabsAreVoiceFirst() {
        XCTAssertEqual(DashboardContentTab.allCases, [.dictation, .appUsage, .live, .screenshots])
        XCTAssertEqual(DashboardContentTab.allCases.map(\.title), ["Dictation", "App Usage", "Live", "Screenshots"])
    }

    func testLiveTabHasDedicatedCaptureSurfaces() {
        XCTAssertEqual(DashboardContentTab.live.subtitle, "Live transcript, intelligence feed, and conversation context")
    }

    func testScreenshotsTabOwnsScreenHistory() {
        XCTAssertEqual(DashboardContentTab.screenshots.subtitle, "Screen frames, OCR, and capture metadata")
        XCTAssertEqual(DashboardContentTab.screenshots.icon, "rectangle.stack.fill")
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

    func testLiveTabGivesIntelligenceFeedPrimaryWidth() {
        let columns = DashboardLiveLayoutPolicy.columnWidths(forWidth: DashboardVoiceLayoutPolicy.defaultContentWidth)
        XCTAssertGreaterThan(columns.intelligence, columns.transcript)
        XCTAssertGreaterThan(columns.transcript, columns.context)
    }

    func testLiveIntelligenceFeedHasActionableDefaultCards() {
        let titles = DashboardLiveIntelligencePolicy.defaultCards.map(\.title)

        XCTAssertGreaterThanOrEqual(titles.count, 6)
        XCTAssertTrue(titles.contains("Key people mentioned"))
        XCTAssertTrue(titles.contains("Risks & objections"))
        XCTAssertTrue(titles.contains("Questions to ask now"))
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

    func testLiveAudioHistoryRemainsAvailableWhenNewestPageHasNoReadableRows() {
        XCTAssertTrue(DashboardLiveAudioHistoryPolicy.shouldShowHistory(
            readableRowCount: 0,
            canLoadMoreOlderRows: true,
            isLoadingOlderRows: false
        ))
        XCTAssertTrue(DashboardLiveAudioHistoryPolicy.shouldShowHistory(
            readableRowCount: 0,
            canLoadMoreOlderRows: false,
            isLoadingOlderRows: true
        ))
        XCTAssertFalse(DashboardLiveAudioHistoryPolicy.shouldShowHistory(
            readableRowCount: 0,
            canLoadMoreOlderRows: false,
            isLoadingOlderRows: false
        ))
    }

    func testLiveAudioInitialLoadKeepsPagingUntilReadableRowsAreFilled() {
        XCTAssertTrue(DashboardLiveAudioHistoryPolicy.shouldPrefetchMoreReadableRows(
            readableRowCount: 0,
            targetReadableRowCount: 12,
            fetchedTranscriptRows: 20,
            pageSize: 20,
            canLoadMoreOlderRows: true
        ))
        XCTAssertTrue(DashboardLiveAudioHistoryPolicy.shouldPrefetchMoreReadableRows(
            readableRowCount: 4,
            targetReadableRowCount: 12,
            fetchedTranscriptRows: 20,
            pageSize: 20,
            canLoadMoreOlderRows: true
        ))
        XCTAssertFalse(DashboardLiveAudioHistoryPolicy.shouldPrefetchMoreReadableRows(
            readableRowCount: 12,
            targetReadableRowCount: 12,
            fetchedTranscriptRows: 20,
            pageSize: 20,
            canLoadMoreOlderRows: true
        ))
        XCTAssertFalse(DashboardLiveAudioHistoryPolicy.shouldPrefetchMoreReadableRows(
            readableRowCount: 4,
            targetReadableRowCount: 12,
            fetchedTranscriptRows: 8,
            pageSize: 20,
            canLoadMoreOlderRows: true
        ))
    }

    func testLiveAudioAutoLoadsOlderRowsOnlyAtEndOfReadableList() {
        XCTAssertTrue(DashboardLiveAudioHistoryPolicy.shouldAutoLoadOlderRows(
            currentRowID: 42,
            lastRowID: 42,
            canLoadMoreOlderRows: true,
            isLoadingOlderRows: false
        ))
        XCTAssertFalse(DashboardLiveAudioHistoryPolicy.shouldAutoLoadOlderRows(
            currentRowID: 41,
            lastRowID: 42,
            canLoadMoreOlderRows: true,
            isLoadingOlderRows: false
        ))
        XCTAssertFalse(DashboardLiveAudioHistoryPolicy.shouldAutoLoadOlderRows(
            currentRowID: 42,
            lastRowID: 42,
            canLoadMoreOlderRows: true,
            isLoadingOlderRows: true
        ))
    }

    func testLiveAudioRepairedTranscriptBadgeUsesTranscriptionPass() {
        let pass2 = DashboardLiveAudioRow(
            id: 501,
            text: "This text was repaired.",
            startedAt: Date(timeIntervalSince1970: 1_781_555_000),
            endedAt: Date(timeIntervalSince1970: 1_781_555_006),
            source: .microphone,
            confidence: 0.82,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil,
            transcriptionPass: 2
        )
        let pass3 = DashboardLiveAudioRow(
            id: 502,
            text: "This text was context repaired.",
            startedAt: Date(timeIntervalSince1970: 1_781_555_010),
            endedAt: Date(timeIntervalSince1970: 1_781_555_016),
            source: .microphone,
            confidence: 0.86,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil,
            transcriptionPass: 3
        )

        XCTAssertTrue(pass2.isRepairedTranscript)
        XCTAssertEqual(pass2.repairedBadgeText, "Repaired")
        XCTAssertTrue(pass3.isRepairedTranscript)
        XCTAssertEqual(pass3.repairedBadgeText, "Context repaired")
    }

    func testLiveAudioRowsUseBatchKeyForPassReplacement() {
        let start = Date(timeIntervalSince1970: 1_781_555_000)
        let pass1 = DashboardLiveAudioRow(
            id: 801,
            text: "first pass draft",
            startedAt: start,
            endedAt: start.addingTimeInterval(8),
            source: .microphone,
            confidence: 0.48,
            transcriptStatus: "needs_review",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: "short_text,variant:raw",
            transcriptionPass: 1,
            batchAudioPath: "audio/batch_1781555000_microphone.m4a"
        )
        let pass3 = DashboardLiveAudioRow(
            id: 802,
            text: "third pass final",
            startedAt: start,
            endedAt: start.addingTimeInterval(8),
            source: .microphone,
            confidence: 0.91,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "contextual",
            qualityFlags: nil,
            transcriptionPass: 3,
            batchAudioPath: "audio/batch_1781555000_microphone.m4a"
        )

        let merged = DashboardLiveAudioPresentationPolicy.mergedRowsReplacingOlderPasses(
            existing: [pass1],
            latest: [pass3]
        )

        XCTAssertEqual(merged.map(\.id), [802])
        XCTAssertEqual(merged.first?.text, "third pass final")
        XCTAssertEqual(merged.first?.transcriptionPass, 3)
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

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: pendingRows + [transcript])

        XCTAssertEqual(presentation.transcriptRows.count, 1)
        XCTAssertEqual(presentation.transcriptRows[0].text, "This is a real transcript.")
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isPendingSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 6)
        XCTAssertTrue(presentation.statusRows[0].displayText.contains("6 audio batches captured"))
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

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: noiseRows + [transcript])

        XCTAssertEqual(presentation.transcriptRows.count, 1)
        XCTAssertEqual(presentation.transcriptRows[0].text, "This is the next useful transcript.")
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isLowConfidenceSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 5)
        XCTAssertTrue(presentation.statusRows[0].displayText.contains("5 audio batches grouped for repair"))
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

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: rows)
        let lowConfidenceSummaries = presentation.statusRows.filter { $0.isLowConfidenceSummary }

        XCTAssertEqual(lowConfidenceSummaries.count, 1)
        XCTAssertEqual(lowConfidenceSummaries.first?.pendingBatchCount, 60)
        let pendingSummaries = presentation.statusRows.filter { $0.isPendingSummary }
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

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: repeatedArtifacts + [transcript])

        XCTAssertEqual(presentation.transcriptRows.count, 1)
        XCTAssertEqual(presentation.transcriptRows[0].text, transcript.text)
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isLowConfidenceSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 6)
        XCTAssertFalse(presentation.transcriptRows.contains { $0.text == "(Breathing)" })
        XCTAssertFalse(presentation.transcriptRows.contains { $0.text == "*sound of wind*" })
    }

    func testLiveAudioPresentationMovesHighConfidenceAmbientCaptionsToSpecificStatusSummary() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let rows = [
            "*sound of camera*",
            "*sound of camera*",
            "*typing* *typing* *typing* *typing*",
            "*typing*"
        ].enumerated().map { index, text in
            DashboardLiveAudioRow(
                id: Int64(8_100 + index),
                text: text,
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: 0.84,
                transcriptStatus: "transcribed",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: nil
            )
        }

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: rows)

        XCTAssertTrue(presentation.transcriptRows.isEmpty)
        XCTAssertEqual(presentation.statusRows.count, 2)
        XCTAssertEqual(
            presentation.statusRows.map(\.displayText),
            [
                "Ambient audio: sound of camera (2 entries collapsed).",
                "Ambient audio: typing (2 entries collapsed)."
            ]
        )
    }

    func testLiveAudioPresentationKeepsPlausibleFirstPassRepairTextVisible() {
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

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: repairRows + [cleanTranscript])

        XCTAssertEqual(
            presentation.transcriptRows.map(\.text),
            ["No.", cleanTranscript.text]
        )
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isLowConfidenceSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 4)
        XCTAssertFalse(presentation.transcriptRows.contains { $0.text == "(Breathing)" })
        XCTAssertFalse(presentation.transcriptRows.contains { $0.text == "ʻᵖᵗᵗᵗ" })
        XCTAssertFalse(presentation.transcriptRows.contains { $0.text == "සැහාහින්න්" })
        XCTAssertFalse(presentation.transcriptRows.contains { $0.text == "[Observe the" })
    }

    func testLiveAudioPresentationHidesLaughCaptionsAndLanguageUncertainGarbage() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let rows = [
            DashboardLiveAudioRow(
                id: 7_000,
                text: "(笑)",
                startedAt: now,
                endedAt: now.addingTimeInterval(8),
                source: .microphone,
                confidence: 0.18,
                transcriptStatus: "needs_review",
                detectedLanguage: "nn",
                audioVariant: "raw",
                qualityFlags: "short_text,variant:raw"
            ),
            DashboardLiveAudioRow(
                id: 7_001,
                text: "pomoc ommatechnic Օե ՠ� probably huh orit",
                startedAt: now.addingTimeInterval(-10),
                endedAt: now.addingTimeInterval(-2),
                source: .microphone,
                confidence: 0.18,
                transcriptStatus: "language_uncertain",
                detectedLanguage: "nn",
                audioVariant: "raw",
                qualityFlags: "language_uncertain,variant:raw"
            ),
            DashboardLiveAudioRow(
                id: 7_002,
                text: "No.",
                startedAt: now.addingTimeInterval(-20),
                endedAt: now.addingTimeInterval(-12),
                source: .microphone,
                confidence: 0.72,
                transcriptStatus: "needs_review",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: "short_text,variant:raw"
            )
        ]

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: rows)

        XCTAssertEqual(presentation.transcriptRows.map(\.text), ["No."])
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isLowConfidenceSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 2)
    }

    func testLiveAudioPresentationHidesCommonSoundEffectCaptions() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let rows = [
            "(footsteps)",
            "(footsteps) (bell rings)",
            "(fire crackling)",
            "( Meaning No audio )",
            "[door closes]",
            "*keyboard clicks*"
        ].enumerated().map { index, text in
            DashboardLiveAudioRow(
                id: Int64(7_100 + index),
                text: text,
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: 0.1,
                transcriptStatus: "needs_review",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: "short_text,variant:raw"
            )
        }

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: rows)

        XCTAssertTrue(presentation.transcriptRows.isEmpty)
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isLowConfidenceSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 6)
    }

    func testLiveAudioPresentationHidesPunctuationOnlyDecoderArtifacts() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let rows = ["[", "]", "*"].enumerated().map { index, text in
            DashboardLiveAudioRow(
                id: Int64(7_200 + index),
                text: text,
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: 0.1,
                transcriptStatus: "needs_review",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: "short_text,variant:raw"
            )
        }

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: rows)

        XCTAssertEqual(presentation.transcriptRows, [])
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isLowConfidenceSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 3)
    }

    func testLiveAudioStatusPanelCanUseRecentStatusWindow() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        var statusRows: [DashboardLiveAudioRow] = []
        for index in 0..<30 {
            statusRows.append(DashboardLiveAudioRow(
                id: Int64(7_300 + index),
                text: "",
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: nil,
                transcriptStatus: "probable_silence",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: "empty_text,low_energy"
            ))
        }
        let transcript = DashboardLiveAudioRow(
            id: 7_400,
            text: "Readable transcript remains available.",
            startedAt: now.addingTimeInterval(-400),
            endedAt: now.addingTimeInterval(-392),
            source: .microphone,
            confidence: 0.8,
            transcriptStatus: "transcribed",
            detectedLanguage: "en",
            audioVariant: "raw",
            qualityFlags: nil
        )

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(
            for: statusRows + [transcript],
            statusRowLimit: 8
        )

        XCTAssertEqual(
            presentation.transcriptRows.map { $0.text },
            ["Readable transcript remains available."]
        )
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 8)
    }

    func testLiveAudioPresentationCollapsesConsecutiveDuplicateTranscriptText() {
        let now = Date(timeIntervalSince1970: 1_781_555_000)
        let rows = [
            "The water they use.",
            "The water they use.",
            "Data centers already operating in New South Wales.",
            "Data centers already operating in New South Wales."
        ].enumerated().map { index, text in
            DashboardLiveAudioRow(
                id: Int64(6_000 + index),
                text: text,
                startedAt: now.addingTimeInterval(Double(-index * 10)),
                endedAt: now.addingTimeInterval(Double(-index * 10 + 8)),
                source: .microphone,
                confidence: 0.42,
                transcriptStatus: index < 2 ? "needs_review" : "transcribed",
                detectedLanguage: "en",
                audioVariant: "raw",
                qualityFlags: index < 2 ? "short_text,variant:raw" : nil
            )
        }

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: rows)

        XCTAssertEqual(
            presentation.transcriptRows.map(\.text),
            ["The water they use.", "Data centers already operating in New South Wales."]
        )
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

        let presentation = DashboardLiveAudioPresentationPolicy.presentation(for: failedRows)

        XCTAssertTrue(presentation.transcriptRows.isEmpty)
        XCTAssertEqual(presentation.statusRows.count, 1)
        XCTAssertTrue(presentation.statusRows[0].isStatusSummary)
        XCTAssertEqual(presentation.statusRows[0].pendingBatchCount, 4)
        XCTAssertTrue(presentation.statusRows[0].displayText.contains("4 matching audio status rows"))
        XCTAssertTrue(presentation.statusRows[0].displayText.contains("decoding failed"))
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
