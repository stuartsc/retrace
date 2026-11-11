# PROCESSING Agent Instructions

You are responsible for the **Processing** module of Retrace. Your job is to implement text extraction from captured frames using Vision framework OCR and the Accessibility API, plus local audio transcription/refinement.

**Status**: Vision OCR processes recorded frames. A separate live Accessibility helper exists but is not integrated into capture-time text evidence; see the [capture/text quality audit](../docs/capture-text-quality-plan.md). Audio transcription is implemented with whisper.cpp integration, buffering, sentence segmentation, recall-first quality policy, enhancement retry, backfill, and contextual refinement.

## Your Directory

```
Processing/
├── Accessibility/
│   └── AccessibilityService.swift
├── Audio/
│   ├── AudioBackfillManager.swift
│   ├── AudioBufferManager.swift
│   ├── AudioContextualRefinementManager.swift
│   ├── AudioEnhancer.swift
│   ├── AudioProcessingManager.swift
│   ├── AudioRefinementManager.swift
│   ├── AudioSpeechActivityPolicy.swift
│   ├── AudioStoragePolicy.swift
│   ├── AudioTranscriptQualityPolicy.swift
│   ├── AudioTranscriptionRetryPipeline.swift
│   ├── MockTranscriptionService.swift
│   ├── NativeSpeechTranscriptionService.swift
│   ├── SentenceSegmenter.swift
│   └── WhisperCppTranscriptionService.swift
├── OCR/
│   ├── FullFrameOCRCache.swift
│   ├── OCRTileCache.swift
│   ├── RegionOCRMerger.swift
│   ├── RegionOCRResult.swift
│   ├── TileChangeDetector.swift
│   ├── TileGridConfig.swift
│   ├── TileOCRProcessor.swift
│   └── VisionOCR.swift
├── Tests/
│   ├── Fixtures/
│   │   └── WhisperTimedWords/
│   │       ├── authored.wav
│   │       ├── provenance.json
│   │       └── reference.txt
│   ├── _future/
│   │   ├── AccessibilityTests.swift
│   │   └── VisionOCRTests.swift
│   ├── AudioEnhancementPolicyTests.swift
│   ├── AudioBufferTimingTests.swift # Real PCM/AAC/SQLite batch endpoints and overlap intervals
│   ├── AudioProcessingBackpressureTests.swift
│   ├── AudioProcessingLifecycleTests.swift # Real PCM/AAC/SQLite cancellation, callback joins, restart and pending-backlog preservation
│   ├── AudioRefinementSourceTests.swift # Real AAC/SQLite source lineage, cancellation and stale publication
│   ├── AudioRefinementSchedulingPolicyTests.swift
│   ├── AudioSpeechActivityPolicyTests.swift
│   ├── AudioStoragePolicyTests.swift
│   ├── AudioTranscriptionCompletenessPolicyTests.swift
│   ├── FrameProcessingWakeSignalTests.swift
│   ├── FrameProcessingSourceReadinessTests.swift
│   ├── HistoricalOCREvidenceTests.swift
│   ├── NativeSpeechTranscriptionServiceTests.swift
│   ├── ScreenTextQualityBenchmarkTests.swift # Authored OCR and codec comparison; explicit export path required
│   ├── TestLogger.swift
│   ├── VisionOCRIncrementalTests.swift
│   └── WhisperModelResidencyTests.swift
├── TextMerger/
│   └── TextMerger.swift
├── FrameProcessingQueue.swift
├── FrameProcessingWakeSignal.swift
├── ProcessingManager.swift
└── URLExtractor.swift
```

## Protocols You Must Implement

### 1. `ProcessingProtocol` (from `Shared/Protocols/ProcessingProtocol.swift`)
- Retained-frame OCR with saved metadata; separately requested live Accessibility extraction
- Processing queue management
- Configuration

### 2. `OCRProtocol` (from `Shared/Protocols/ProcessingProtocol.swift`)
- Vision framework text recognition

### 3. `AccessibilityProtocol` (from `Shared/Protocols/ProcessingProtocol.swift`)
- Permission checking
- Text extraction from AX tree

## Current Implementation

- `ProcessingManager` routes saved/captured-frame extraction through a private `RetainedFrameTextExtractor` actor whose only input is retained pixels, saved metadata and OCR configuration. It cannot query live Accessibility; the separately named live-AX APIs remain explicit. Flattened OCR and chrome text are derived from the same ordered regions used for geometry and offsets.
- Complete retained extractions are ordered through cancellation-aware task chaining. Actor reentrancy must not mix previous pixels with a concurrently updated OCR cache or saturate cooperative threads with parallel synchronous Vision waits. Parallel-worker regression fixtures change separate amounts and decisions on real rasterised screens.
- `VisionOCR` uses Apple's Vision framework, an accurate full-frame cache and bounded region crops. Accurate mode keeps native pixels; fast mode retains its existing adaptive scaling. Large accurate images combine native full-image discovery with overlapping native crops: at most 128 inspected grid cells, 12 grid requests/12 MP of grid input, and four seam requests of at most 1.75 MP each. Solid-colour crops skip Vision. This is at most 17 requests including the initial pass, not a latency guarantee. Preserve complete detected lines when crops omit content, order split words left to right, and keep geometry in original pixel coordinates. Expand changed crops to cover complete cached text regions before invalidation; preserve the actual row stride.
- Full-frame and incremental OCR both disable language correction to preserve identifiers. The incremental crop pixel fraction is a work-area estimate, not a measured energy saving.
- `FrameProcessingQueue` is the existing cross-module integration boundary. Database claims are atomic. Automatic priorities 1–10 are current only for captures made within 60 seconds; older automatic work joins priority 0, negative and NULL-priority work in historical enqueue order. One historical claim follows three current automatic claims when available. Manual priorities above 10 take precedence without consuming or resetting that fairness counter. Displayed positions use the same schedule and count distinct pending frames. The wake signal prevents idle polling latency without losing enqueues during registration.
- Publish OCR text, highlight nodes and completed status through `DatabaseManager.commitFrameOCR` in one transaction. Return deferred/cancelled claims through `releaseFrameProcessingClaim`. Never split those writes into separate awaits.
- After durable OCR completion, the queue awaits an optional `extractionCommitted` callback owned by App. This signals a coalesced semantic-index wake; it never embeds on the OCR worker or launches one inference task per frame. Joined worker shutdown includes callback completion. Real WAL/SQLite source-readiness tests prove success observes completed status and an empty queue, while missing media emits no successful wake.
- Media repair failures publish a durable unavailable reason and failed status through `recordFrameMediaUnavailable`; no repair branch deletes frames, existing OCR/FTS, highlight nodes or extraction revisions. Missing/empty media and integrity failures remain distinct; only explicit deletion or retention owns evidence removal. Finalized missing media counts as failed work, never successful OCR.
- Prefer store-qualified original pixels through `StorageProtocol.readOriginalFrameForProcessing`, including when recovery has changed the archive path. Never fall back to a raw ordinal or an unrelated store's numeric frame ID. A conflicting retained identity fails closed; cancellation releases the claim, and an in-progress original read defers without consuming retries. Missing originals may use finalized exact archive pixels, while live/nonfinalized sources defer at automatic priority 10 with the existing age expiry and 0.5-second backoff. Missing finalized media reaches the bounded failure path without deleting retained originals. Source-readiness tests use real WAL pixels, SQLite claims and archive remapping.
- Finalized-video OCR uses the root-coordinated `StorageProtocol.readFrameForProcessing` contract to obtain exact decoded BGRA pixels with saved frame identity/metadata. Do not use the presentation JPEG API for OCR. Storage retains originals until durable extraction, verified archive mapping and reader completion; App reconciles those proofs after recovery, finalization and during periodic maintenance. See the [unified history ledger](../docs/unified-history-plan.md).
- `AudioProcessingManager.startProcessing` joins a single owned session of ingestion, live worker and post-commit callbacks. Duplicate starts join that session; starts during cancellation wait for its retirement. `stopProcessing` synchronously requests cancellation through the session handle and awaits all owned tasks/callbacks before returning. Never await this stop from inside its own callback; enqueue lifecycle requests outside delivery. Worker/session IDs fence slot cleanup. Cancelled partial PCM and overlap words are cleared only after the worker joins; completed raw files and SQLite pending rows survive for recovery. Natural input completion still flushes/drains. Service shutdown must await this stop before closing transcription resources or SQLite. `AudioProcessingLifecycleTests` exercises real PCM/native AAC writer-decoder/private SQLite with held model/callback boundaries; it does not measure ASR quality or installed latency.
- `AudioStoragePolicy` preserves canonical batch recordings and prevents duplicate sentence files. Whisper remains the production transcription backend.
- `AudioBufferManager` treats each captured chunk timestamp as its PCM start and uses timestamp plus duration as the exclusive batch end. The five-second overlap starts relative to that actual end. `AudioBufferTimingTests` checks microphone/system single chunks, natural flush and overlap through native AAC decoding and durable SQLite original-source receipts; it preserves the V28 nonempty-interval guard and pending-backlog semantics.
- Whisper timed-word extraction flushes each segment's pending lexical word after control-token filtering. Contextual transcription shares that parser and retains its existing prefix-based prompt limit. `WhisperModelResidencyTests` includes an opt-in real CPU inference regression using the versioned, unplayed authored audio in `Tests/Fixtures/WhisperTimedWords`; only `RETRACE_WHISPER_WORD_TEST_MODEL_PATH` is required. It compares each returned full text with its own timed words and checks complete PCM reads and timestamp bounds/order, rather than requiring perfect speech recognition. The fixtures are resources of the test target only.
- `NativeSpeechTranscriptionService` is an opt-in macOS 26 batch comparison backend, not a production routing change. Exact module asset readiness must be checked in the calling app; locale support alone is insufficient. Tests may explicitly prepare assets for comparison.
- Its explicit `compareStreaming` developer API feeds supplied, bounded PCM through a pull-based timed chunk sequence and reports genuine volatile/final spans. Chunk conversion preserves resampler tails and source timestamps; only final spans form the completed transcript. The paced comparison measures real first-result latency when explicitly enabled on authored audio. It never captures audio, installs assets implicitly or changes Whisper routing; locale/name/overlap/silence quality and installed latency acceptance remain separate.
- `TranscriptionProtocol.cleanup` is asynchronous so a service can cancel and join owned analyzer work before cleanup completes. The native comparison uses this contract; existing actor-isolated synchronous implementations can still satisfy it.
- Root-owned capture freshness metrics use `Log.recordLatency` for OCR processing and recent/backlog capture-to-search latency. `ocr_source_processing` records only `source` (`wal_bgra`/`archive_bgra`) and `outcome` (`started`/`completed`/`failed`/`cancelled`); completed follows atomic OCR publication. Never include extracted text, paths, identifiers or app names. New product actions must also emit `daily_metrics` as required by the root guide.
- Use continuous-clock duration sleeps, actors for mutable state and background execution for expensive I/O/OCR. Preserve cancellation and drain worker tasks before service teardown.

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw ProcessingError.ocrFailed(underlying: error.localizedDescription)
throw ProcessingError.accessibilityPermissionDenied
throw ProcessingError.imageConversionFailed
```

## Testing Strategy

1. Test OCR with sample images containing text
2. Test OCR with various languages
3. Test Accessibility extraction (mock AX APIs)
4. Test text merging with overlapping content
5. Test queue processing under load
6. Test with empty/blank frames

## Dependencies

- **Input from**: CAPTURE module (CapturedFrame)
- **Output to**: DATABASE (atomic OCR text, nodes and queue completion)
- **Uses types**: `CapturedFrame`, `ExtractedText`, `TextRegion`, `ProcessingConfig`, `AppInfo`

## DO NOT

- Modify any files outside `Processing/`
- Introduce new cross-module imports outside the existing queue integration boundary without root coordination
- Handle storage (that's STORAGE's job)
- Handle search indexing (that's SEARCH's job)
- Handle screen capture (that's CAPTURE's job)

## Performance Targets

- OCR: <500ms per frame on Apple Silicon
- Accessibility extraction: <50ms
- Memory: <200MB during OCR (Vision manages its own memory)
- Queue: Process frames without falling behind at 0.5fps

## Validation

Run `swift test --filter 'VisionOCRIncrementalTests|HistoricalOCRIsolationTests|OCRRepairEvidencePreservationTests|FrameProcessingSourceReadinessTests|FrameProcessingWakeSignalTests|NativeSpeechTranscriptionServiceTests'`. Vision tests render actual CoreText images and exercise the real Vision API. Historical isolation tests inject unrelated live AX while recognizing retained pixels. Repair tests use real SQLite and actual empty-video/decode-all out-of-range errors, including media-disappearance and explicit-deletion races. Native audio comparison requires explicit local fixture/model paths; the normal test run skips those cases.

`ScreenTextQualityBenchmarkTests` requires an explicit new `RETRACE_OCR_QUALITY_EXPORT` JSON path and otherwise skips. It compares a test-only frozen `d1b367f` OCR baseline, production native crops, macOS 26 document recognition, LZFSE round trips and real HEVC encode/decode on four authored sparse 4K scenes. The sample is not a representative accuracy, foreground-latency or compression acceptance result. See the quality plan for reproduction and measured limits. Run tests with `RETRACE_TEST_DISABLE_FILE_LOGGING=1` to keep test diagnostics out of the installed app's log files.

`Audio/AudioProcessingManager.swift` has an optional awaited `committedTranscriptionCallback` after the actual sentence transaction. It passes `AudioTranscriptCommitReceipt` with the original audio occurrence and a true accepted flag only for `transcribed`; this is not physical speech proof. `Tests/AudioTranscriptionCommitTests.swift` uses authored PCM, the real audio writer/quality gate and SQLite success/failure to ensure unreliable or uncommitted text cannot become an accepted receipt. No transcript contents are sent through this receipt.

### Changed-tile comparison candidate

`ScreenTextQualityBenchmarkTests` now includes an ordinary 4K authored changed-tile test: LZFSE tiles replay digit/status changes and reversions byte-for-byte, while wrong bases and truncated files are rejected. The explicitly exported comparison separately measures HEVC 0.5/0.7/0.9 and changed tiles on different declared workloads. This is test-only; HEVC remains production storage. It establishes no energy, monthly storage, capture or production recovery acceptance.

Audio refinement obtains `AudioOriginalSourceReceipt` before decoding/model work and revalidates it during guarded publication. V28 retains the original raw-insert source after intentional placeholder retirement. A reset pass number, latest refined source or nearby screen is not original-source proof. Unavailable/conflicting/stale source leaves the existing history unchanged and emits categorical diagnostics/awaited metrics. An indexed row-ID seek and a 256-row inspection cursor retained across manager cycles advance past legacy source gaps before the model-work limit, including filtered rows and bounded per-cycle path deduplication; unavailable pre-model candidates do not consume that limit or trigger model throttling. This cursor is ephemeral, and restart safely begins another sweep. Check cancellation immediately after model return, before empty-output status branches. Both refiners depend on `TranscriptionProtocol`; authored model output plus real PCM/AAC/SQLite tests verify pipeline ownership, not ASR quality. Live/backfill use the explicit raw retirement operation; ordinary deletion invalidates the source lineage. This receipt grants no consent/app attribution or exact audio-evidence admission.

Explicit native speech comparisons can emit hypotheses, timed spans and volatile updates only with `RETRACE_SPEECH_BENCHMARK_INCLUDE_TEXT=1`; use authored intended inputs. The initialization contract reports separate batch/streaming asset statuses without preparing assets. Authored PCM/AAC and provenance are retained under `docs/fixtures/unified-history/speech/`; zero-byte reference means declared silence, while absent reference remains unscored.


### Quiet-time audio candidate (September 28)

Successfully persisted batches are scheduled from bounded SQLite pending pages rather than a growing in-memory metadata queue. Startup recovery is independent of optional refinement. The optional Shared governor wraps decode/inference; renewed interaction cancels the native permit and preserves pending work. First-pass sentence publication and raw retirement share one original-source-guarded transaction. Whisper's synchronous native callbacks read a retained cancellation token; never call an actor from the C callback or release the permit before native return. Explicit dictation bypasses quiet-time admission.

`WhisperHardwareComparisonTests.swift` is developer-only measurement scaffolding. Its ordinary fixture test drains the real bundled authored WAV and checks exact PCM bytes. CPU/Metal comparisons and the native cancellation-boundary/reuse case require `RETRACE_WHISPER_COMPARISON_MODEL` pointing to an existing local model; `RETRACE_WHISPER_COMPARISON_REPEATS` is bounded to 1–3. Run with `RETRACE_TEST_DISABLE_FILE_LOGGING=1`. The comparison hashes the supplied model and fixed authored PCM, holds thread count at two, and emits authored words, timestamp checks, CPU time, elapsed time and system pressure metadata. GPU selection is reported as requested, not independently verified hardware execution. RSS is the cumulative test-process high-water mark, not isolated backend allocation; whole-system energy and helper-process memory are explicitly unmeasured. Core ML, quantisation comparisons and Apple Speech remain untested by this case; no assets/models are downloaded and no production backend is changed. The cancellation seam establishes an installed handler immediately before the native call, not the exact native sampling phase at cancellation. This single authored Australian TTS fixture is not names/numbers/quiet/overlap quality or installed acceptance.

### Non-overlapping audio candidate (September 28)

`AudioProcessingConfig.chunkedAudioEnabled` is independently default-off. `AudioChunkBuffer` admits fixed 16 kHz mono Int16 callbacks of at most sixty seconds, emits at most ten seconds per immutable chunk, retains exact source labels and starts a new stream at timestamp discontinuities. It never emits overlap PCM. Accepted partials are durably flushed by joined uncancelled writes on stop; inference cancellation still preserves pending work. Failed writes retain only the bounded accepted callback and final source partials, visibly stop capture, and retry with the same chunk identities.

App calls `prepareCapturedInput` before creating each producer/consumer pair. After stopping the producer and finishing its stream, `finishCapturedInput` cancels inference and joins ingestion while it persists every queued capture and final partial. A finish request preceding consumer registration applies to that next session only; preparation clears stale requests between producers. This graceful path requires a finished source stream. Explicit `stopProcessing` and caller cancellation remain hard stops. The real AAC/SQLite regression holds the first native write while another twenty-and-a-half seconds queues, then checks all thirty-and-a-half seconds reach distinct original PCM hashes without starting inference.

`AudioTranscriptionMedia` loads legacy batches or registered logical windows for live, backfill, pass-2 and pass-3. Exact window leases remain held through model work and guarded publication. Window timestamps come from the manifest, not filenames. Timed words belong to the half-open current-chunk interval containing their start; preceding context words cannot become current text, and context-only or untimed full-text output remains deferred for repair. This deterministic ownership rule is not speech-boundary accuracy acceptance.

Live and backfill explicitly require native timed words for registered windows through `AudioTranscriptionRetryPipeline.requireWordTimings`, including enhanced retries. Legacy first-pass decoding retains its text-only setting. Processing fixtures mirror native Whisper by returning no words when that request is false; caller intent alone is not proof that native timing was requested. The boundary comparison uses the candidate retry policy with required words and a separately labelled legacy direct native timed-word geometry baseline. It bypasses SQLite publication/segmentation, so it is not an end-to-end first-pass comparison.

New chunk receipts declare the versioned `nativeAACPCM16V1` decode contract. Encoded-byte identity, native timing, finite bounded decode and exact sample ranges remain authoritative; the initial decoded PCM hash is diagnostic because repeated native AAC decodes can differ at PCM16 least-significant bits. Receipts without the marker keep strict decoded-hash validation. Processing's reordered recovery test checks exact ranges/frame counts, admitted window IDs and byte-exact propagation from each actual read lease into the model; it makes no independent-read PCM equality claim. Lossless in-memory chunk assembly and original PCM hashes remain byte-exact.

Startup registers at most sixteen pending media journals; the existing owned session ticker resumes another bounded page while capture proceeds. An exact canonical deletion proof permits journal acknowledgement only, preserving AAC and never recreating deleted history. `AudioChunkBufferTests` and `AudioChunkProcessingTests` exercise authored PCM, real native AAC/SQLite, partial-stop durability, reordered recovery, journal failure/deletion, leases and all four processing routes. These source tests do not promote the candidate or establish installed performance/storage acceptance.


### Measured OCR admission candidate (September 30)

`FrameProcessingQueue` accepts the shared App governor. It tries manual/fresh/historical admission before claiming SQLite work, so deferred history cannot occupy the OCR worker while fresh pixels are eligible. Cancelled permits release durable claims without failure or retry-count penalties. Original WAL/archive selection and atomic OCR/FTS commits remain unchanged. `FrameProcessingSourceReadinessTests` exercises cancellation/retry and fresh-versus-history routing with actual WAL files and SQLite. Vision checks the owned cancellation token between bounded native requests; an individual native Vision call must return before its permit is released.
