# PROCESSING Agent Instructions

You are responsible for the **Processing** module of Retrace. Your job is to implement text extraction from captured frames using Vision framework OCR and the Accessibility API, plus local audio transcription/refinement.

**Status**: ✅ Vision OCR and Accessibility API fully implemented. Audio transcription is implemented with whisper.cpp integration, buffering, sentence segmentation, recall-first quality policy, enhancement retry, backfill, and contextual refinement.

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
│   ├── AudioProcessingBackpressureTests.swift
│   ├── AudioProcessingFreshnessTests.swift
│   ├── AudioRefinementSchedulingPolicyTests.swift
│   ├── AudioSpeechActivityPolicyTests.swift
│   ├── AudioStoragePolicyTests.swift
│   ├── AudioTranscriptionCompletenessPolicyTests.swift
│   ├── FrameProcessingWakeSignalTests.swift
│   ├── FrameProcessingSourceReadinessTests.swift
│   ├── HistoricalOCREvidenceTests.swift
│   ├── NativeSpeechTranscriptionServiceTests.swift
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
- `VisionOCR` uses Apple's Vision framework, an accurate full-frame cache and bounded native-pixel region crops. Expand changed crops to cover complete cached text regions before invalidation. Preserve coordinate transforms and the actual row stride for each frame.
- Full-frame and incremental OCR both disable language correction to preserve identifiers. The incremental crop pixel fraction is a work-area estimate, not a measured energy saving.
- `FrameProcessingQueue` is the existing cross-module integration boundary. Database claims are atomic. Automatic priorities 1–10 are current only for captures made within 60 seconds; older automatic work joins priority 0, negative and NULL-priority work in historical enqueue order. One historical claim follows three current automatic claims when available. Manual priorities above 10 take precedence without consuming or resetting that fairness counter. Displayed positions use the same schedule and count distinct pending frames. The wake signal prevents idle polling latency without losing enqueues during registration.
- Publish OCR text, highlight nodes and completed status through `DatabaseManager.commitFrameOCR` in one transaction. Return deferred/cancelled claims through `releaseFrameProcessingClaim`. Never split those writes into separate awaits.
- Media repair failures publish a durable unavailable reason and failed status through `recordFrameMediaUnavailable`; no repair branch deletes frames, existing OCR/FTS, highlight nodes or extraction revisions. Missing/empty media and integrity failures remain distinct; only explicit deletion or retention owns evidence removal. Finalized missing media counts as failed work, never successful OCR.
- Prefer a readable exact-frame-ID WAL over encoded video even when database metadata says finalized: an active container can still be empty or return an earlier frame. Missing/incomplete live WAL or nonfinalized sources defer at automatic priority 10 without consuming error retries, retaining the 0.5-second backoff; capture-age expiry still sends old work to historical FIFO. An unreadable retained WAL from a prior process falls back to strict encoded reads when metadata is finalized, so damaged evidence cannot cause endless retries. Missing finalized media still reaches the existing terminal failure path without deleting the retained WAL. The source-readiness tests exercise real WAL pixels, SQLite claims, fresh-retry precedence over backlog, restart ownership and completion through the production worker.
- `AudioStoragePolicy` preserves canonical batch recordings and prevents duplicate sentence files. Whisper remains the production transcription backend.
- Whisper timed-word extraction flushes each segment's pending lexical word after control-token filtering. Contextual transcription shares that parser and retains its existing prefix-based prompt limit. `WhisperModelResidencyTests` includes an opt-in real CPU inference regression using the versioned, unplayed authored audio in `Tests/Fixtures/WhisperTimedWords`; only `RETRACE_WHISPER_WORD_TEST_MODEL_PATH` is required. It compares each returned full text with its own timed words and checks complete PCM reads and timestamp bounds/order, rather than requiring perfect speech recognition. The fixtures are resources of the test target only.
- `NativeSpeechTranscriptionService` is an opt-in macOS 26 batch comparison backend, not a production routing change. Exact module asset readiness must be checked in the calling app; locale support alone is insufficient. Tests may explicitly prepare assets for comparison.
- Root-owned capture freshness metrics use `Log.recordLatency` for OCR processing and recent/backlog capture-to-search latency. New product actions must also emit `daily_metrics` as required by the root guide.
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

### V23 CPU governor repair (2026-10-01 source candidate)

`AudioProcessingManager` accepts the App-owned `BackgroundProcessingProtocol`. With a governor, completed AAC recordings and legacy pending rows are durable before model admission; deferred PCM/metadata are not accumulated in a live array. One pending row is loaded after admission. Startup recovery refuses the missing-model mock, and replacing it with a real service wakes retained work. Native initialization is deferred to admitted work. Cancellation leaves rows pending, and repeated model/database errors back off for five seconds.

The manager owns and joins ingestion, admission and inference. Stop flushes accepted partial audio using a joined uncancelled write before cancelling inference; a natural governed stream end does not wait for the next idle period. Native Whisper uses an owned abort token and the permit's thread count (two under Low Power Mode, four otherwise). Pending completion validates the original row and atomically inserts sentence rows/deletes its placeholder; deletion or another completion invalidates a stale result. Backfill uses the same completion/outcome transaction. Interrupted pass-2/pass-3 work exits as deferred without permanently retiring its candidate.

This repair preserves the previous immediate in-memory fallback when AAC or raw-row persistence fails and exposes `hasPersistenceFailure`; it does not claim a new bounded disk-failure retention protocol. Existing low-rate OCR is unchanged by this narrow repair.

`AudioProcessingGovernorTests`, `PendingAudioCommitTests` and `WhisperModelResidencyTests` cover private AAC/SQLite admission, restart, cancellation, exact completion, partial-tail shutdown and model recovery. The opt-in native cancellation/reuse case requires `RETRACE_WHISPER_WORD_TEST_MODEL_PATH` and uses only the bundled authored fixture. Source tests and installed CPU acceptance remain separate receipts.

### October 6 automatic audio freshness repair (source candidate)

The governed first-pass worker gives up to three admitted attempts to the newest
`pending` recordings captured within the previous 24 hours, then one attempt to
the oldest retained `pending`/`needs_repair` recording. When no recent pending row
exists it immediately selects oldest work. Failures and cancelled inference
consume their selected turn; existing error backoff and the same governor permit
remain in force. The in-memory fairness budget lasts for the manager lifetime,
while restart discovers the same durable pending rows and starts with recent work.
Manual backfill, model/thread admission, codecs, exact transactional completion
and recording persistence are unchanged.

`AudioProcessingFreshnessTests` uses private SQLite, the pinned bundled authored
WAV through the production native decoder, and controlled inference/admission
protocol boundaries. It checks recent/old fairness, ongoing interaction deferral,
failed/cancelled oldest work, deletion, joined stop and restart without duplicate
completion. Timed-word regression input also checks complete sentence text,
canonical media and timestamps across reverse recent windows and an old-lane hop,
with no first-pass prompt carryover; this does not measure recognition accuracy.
`RETRACE_AUDIO_FRESHNESS_FIXTURE_AAC` explicitly runs the same cases with the pinned
authored AAC from the audio-visibility validation. An enabled AAC decode failure
is a failure, never a skip; native AAC acceptance remains distinct from the WAV
scheduling regression.
