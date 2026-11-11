# Retrace - Agent Guide

> **Standard**: This file follows the [AGENTS.md](https://agents.md) specification - a vendor-agnostic standard for AI agent guidance. For human-readable project information, see [README.md](README.md).

Retrace is a local-first screen recording and search application for macOS, inspired by Rewind AI. It captures screens, extracts text via OCR, and makes everything searchable—all locally on-device.

**Status**: Core screen capture (CGWindowListCapture), OCR (Vision), full-text search (FTS5), HEVC encoding, Rewind import, audio transcription, and push-to-dictate are working. Default-disabled native MiniLM indexing and hybrid moment search are implemented as a source candidate; integrated validation and installed acceptance remain separate.

**Installed local repair (2026-10-01):** build **2610.1.1** from source `f1551be` in `/Users/stuartbond/backintime-hotfix-cpu-guard` adds CPU monitoring and quiet-time audio admission to the V23-compatible masked-recording fix. Installed UI, recording advancement and preserved settings/schema are verified. OCR is unchanged; matched performance and the 20% CPU target remain open. This workspace's larger V24–V32 candidate remains uninstalled. See the [CPU repair ledger](docs/installed-cpu-protection.md) for measurements, disclosed restart gaps and recovery material.

---

## Quick Reference

- **Module-Specific Instructions**: Each module has its own `AGENTS.md` file in its directory
- **Human Documentation**: [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md)
- **Updates and Release Status**: [CHANGELOG.md](CHANGELOG.md)
- **Source checkpoint (11 November)**: [GitHub checkpoint journal](docs/session-20261111-github-checkpoint.md) records the prototype README link, retained native candidate and verification limits.
- **Product Roadmap**: [docs/roadmap.md](docs/roadmap.md)
- **Unified History**: [docs/unified-history-plan.md](docs/unified-history-plan.md) (September 24 accepted direction, implementation and acceptance ledger)
- **Progressive Recall Plan**: [docs/progressive-recall-plan.md](docs/progressive-recall-plan.md) (Phase 2A/2B, 2C feed/bootstrap and 2D question/native-admission checkpoints installed in local trial 2609.18.1; index/worker integration and acceptance tracked separately)
- **Progressive Recall Validation**: [docs/progressive-recall-validation.md](docs/progressive-recall-validation.md) (baseline, fixed questions, implementation and scoped Mac acceptance)
- **Capture/Text Quality Priority**: [docs/capture-text-quality-plan.md](docs/capture-text-quality-plan.md) (native OCR/pixel-path checkpoint; original retention, direct text and compression acceptance precede index/worker integration)
- **Capture Audit and Validation**: [docs/capture-improvements-validation.md](docs/capture-improvements-validation.md) (implementation, performance measurements and local-trial evidence)

---

## Project Commands

### Build & Test

```bash
# Build all targets
swift build

# Run all tests
swift test

# Run specific module tests
swift test --filter DatabaseTests

# Run specific test
swift test --filter testSpecificMethod

# Clean build artifacts
rm -rf .build/
```

After changing Swift actor/protocol method layouts, use `swift package clean` before final test validation and clean any separate release scratch build. September 20 validation found an incrementally retained test caller using an obsolete async dispatch slot after a private queue-method change. Recompiling unchanged source corrected the linked caller; source hashes alone do not prove generated objects are compatible. Keep failing build/test receipts when diagnosing this condition.

For debug test runs beside an installed app, set `RETRACE_TEST_DISABLE_FILE_LOGGING=1` at process launch to keep diagnostic file reads/writes out of the live log directory. Console and unified logging remain available. Release builds ignore this test switch. An inherited `sandbox-exec` profile can remove native helper bundle metadata even when it only denies log writes; use the process-local switch for native identity tests.

---

## Project Structure

```
retrace/
├── AGENTS.md                    # This file - main agent coordination
├── .env.example                 # Template for local release credentials (copy to .env)
├── README.md                    # Human-readable project overview
├── CHANGELOG.md                 # Maintained fixes, improvements and release status
├── CONTRIBUTING.md              # Contribution guidelines
├── Package.swift                # Swift Package Manager configuration
├── docs/                        # Product and data-access documentation
│   ├── DATA_ACCESS.md           # Local database/audio/screen data access notes
│   ├── capture-improvements-validation.md # Phase-one implementation, benchmark and rollout evidence
│   ├── capture-text-quality-plan.md # OCR fidelity implementation, measurement limits and remaining delivery order
│   ├── unified-history-plan.md # macOS 26 capture, unified workspace, semantic recall and live assistance delivery gates
│   ├── progressive-recall-plan.md # Phase 2 checkpoints in local trial 2609.18.1; index/worker integration pending
│   ├── progressive-recall-validation.md # Baseline, fixtures and acceptance ledger
│   ├── fixtures/progressive-recall/ # Reviewed Cedar JPEGs/oracle, Word RTFs and phase2d authored ranking corpus
│   ├── fixtures/screen-text-quality/ # Authored native OCR/codec comparison JSON and validation receipts
│   ├── fixtures/unified-history/speech/ # Authored PCM/AAC, original synthesis/codec receipts and separate oracles
│   ├── fixtures/unified-history/validation/ # Completed command/source receipts and retained native failure diagnostics
│   └── roadmap.md               # Product thesis, differentiation, and roadmap
├── prototypes/retrace-clickthrough/ # Independent offline HTML replica, full spec and issues journal
├── scripts/                     # Build/release/validation scripts
│   ├── release.sh               # End-to-end release automation
│   ├── create-release.sh        # Release build + packaging helper
│   ├── recall_benchmark/        # Offline authored-corpus evaluator, pins, tests and reproduction guide
│   ├── check_no_nanoseconds_sleep.sh # Guardrail for Task.sleep(nanoseconds:)
│   ├── validate_sleep_wake_stability.sh # Sleep/wake soak validation workflow
│   └── validate_darkwake_watchdog.sh # Automated darkwake watchdog regression validation
│
├── Shared/                      # CRITICAL: Shared types and protocols
│   ├── Logging.swift            # Central log utility (Log.debug/info/warning/error)
│   ├── AppPaths.swift           # Application path configuration
│   ├── CapturedURLPolicy.swift  # Shared metadata URL/label scrubbing and opaque navigation identity
│   ├── Models/                  # Data types used across modules
│   │   ├── Frame.swift          # FrameID, CapturedFrame, VideoSegment
│   │   ├── OriginalSpool.swift  # Durable extraction/archive cleanup dispositions and bounded original-pixel pressure
│   │   ├── Job.swift            # Typed categorical job receipts, independent exact references and policy/read stamps
│   │   ├── Activity.swift       # Immutable focus events, coverage, corrections and feed contracts
│   │   ├── Evidence.swift       # Source-qualified references, snapshots and typed exact resolution
│   │   ├── CaptureGroup.swift   # Durable per-display sampling identities and categorical outcomes
│   │   ├── CapturedMoment.swift # Current-policy companion display snapshots and read stamps
│   │   ├── CaptureText.swift    # Bounded visible AX runs, native pixel receipts and structural validation
│   │   ├── StructuredScreenObservation.swift # Immutable OCR blocks, channels, ranges and unknown ownership
│   │   ├── ScreenEvidenceExpansion.swift # Bounded exact text fragments and opaque revision-bound continuation
│   │   ├── ScreenEvidenceFeed.swift # Native feed identity, leased bootstrap and blocked lexical/vector work
│   │   ├── ScreenEvidenceAdmission.swift # Native writer/policy fences, bounded attempts and unpublished artifact receipts
│   │   ├── SemanticRecall.swift # Typed local vectors, exact spans, coverage and current read fences
│   │   ├── LocalContext.swift # Bounded canonical local context cards, exact supports and explicit model opt-in
│   │   ├── LocalEmbedding.swift # Pinned local runtime, semantic questions/results and content-free lifecycle metrics
│   │   ├── Text.swift           # ExtractedText, OCRTextRegion
│   │   ├── TextRegion.swift     # OCR text region types
│   │   ├── Search.swift         # SearchQuery, SearchResult
│   │   ├── HistorySearch.swift  # Typed exact screen/transcript hits, bounded source coverage and ephemeral read stamps
│   │   ├── Segment.swift        # Segment data model
│   │   ├── Config.swift         # Configuration types
│   │   ├── Errors.swift         # Error types
│   │   ├── BackgroundProcessingContext.swift # Task-scoped permits and joined release
│   │   ├── ResourceUsage.swift # Monotonic one-core CPU windows, sample coverage and bounded minute metrics
│   │   ├── StorageUsage.swift # Categorized logical/allocated file reports, partial scans and volume free space
│   │   ├── FrameProcessingLane.swift # Manual, fresh and historical OCR admission before durable claim
│   │   ├── Audio.swift          # Audio capture and transcription model types
│   │   ├── AudioEvidence.swift  # Exact native transcript snapshots, bounded coverage and read-only search contracts
│   │   ├── AudioChunkMedia.swift # Immutable sample ranges, native AAC receipts and revocable reader leases
│   │   ├── AudioChunkMediaValidation.swift # Bounded canonical chunk/window identity and range validation
│   │   ├── Dictation.swift      # Push-to-dictate config/session model types
│   │   ├── FilterCriteria.swift # Timeline/search filter criteria
│   │   ├── Source.swift         # Data source enum (native, rewind, etc.)
│   │   ├── Tag.swift            # Tag model types
│   │   └── Comment.swift        # Segment comment and attachment models
│   └── Protocols/               # Module interfaces
│       ├── DatabaseProtocol.swift
│       ├── JobEventStoreProtocol.swift # Bounded admitted job writer, exact resolve/chronology and tombstones
│       ├── ActivityStoreProtocol.swift # Canonical activity/feed/correction writer interface
│       ├── EvidenceStoreProtocol.swift # Immutable screen snapshot/store registry interface
│       ├── ScreenEvidenceFeedStoreProtocol.swift # Atomic bounded native feed consumption; no result acceptance
│       ├── ScreenEvidenceAdmissionStoreProtocol.swift # Native admission transactions and Capture configuration bracket
│       ├── SemanticRecallStoreProtocol.swift # Native semantic input, typed publication and bounded current-policy reads
│       ├── LocalEmbeddingRuntimeProtocol.swift # Explicit optional local runtime with complete windows and joined close
│       ├── StorageProtocol.swift
│       ├── CaptureGroupJournalProtocol.swift # Awaited capture journal, before native reads
│       ├── CaptureGroupStoreProtocol.swift # Exact current-policy display group access
│       ├── CaptureProtocol.swift
│       ├── ProcessingProtocol.swift
│       ├── AudioCaptureProtocol.swift
│       ├── AudioEvidenceStoreProtocol.swift # Committed read-only transcript identity, deletion and reader lifetime
│       ├── AudioChunkMediaStoreProtocol.swift # Durable chunk publication, exact window reads and joined media leases
│       ├── BackgroundProcessingProtocol.swift # Bounded automatic-work permits, native cancellation and optional admission
│       ├── ResourceUsageProviding.swift # Cheap cached App resource snapshot
│       ├── StorageUsageReportingProtocol.swift # Coalesced periodic/manual storage accounting
│       ├── TranscriptionProtocol.swift
│       ├── SearchProtocol.swift
│       └── MigrationProtocol.swift
│
├── Database/                    # SQLite + FTS5 storage
│   ├── AGENTS.md                # Module-specific agent instructions
│   ├── DatabaseManager.swift    # Main database coordinator
│   ├── DatabaseConnection.swift # SQLite connection helpers
│   ├── CaptureGroupPersistence.swift # V26 durable attempts, exact frame admission, recovery and deletion
│   ├── FramePipelinePersistence.swift # Atomic OCR, claims and recovery
│   ├── LocalContextVisibility.swift # Atomic local context source/policy/revision fence and indexed hide checks
│   ├── ActivityPersistence.swift # Durable context, feed/checkpoints and corrections
│   ├── ActivityScreenLinkPersistence.swift # Proven capture-to-activity associations
│   ├── ScreenEvidencePersistence.swift # Immutable screen/extraction snapshots and receipts
│   ├── ScreenEvidenceFeedPublication.swift # V22 reference/state feed publication and status
│   ├── ScreenEvidenceAdmissionPersistence.swift # Native writer/policy admission and bounded unpublished artifacts
│   ├── SemanticRecallPersistence.swift # Independent fresh/backfill cursors and typed native vector publication
│   ├── ScreenEvidenceFeedConsumerPersistence.swift # Leased keyset bootstrap, atomic work/checkpoints and bounded compaction
│   ├── LegacyOCRBackfillPersistence.swift # Bounded, resumable OCR node-text maintenance
│   ├── RetentionPersistence.swift # Bounded frame cleanup and guarded video deletion
│   ├── FTSManager.swift         # Full-text search management
│   ├── RecallSearchRevisionHooks.swift # Connection-local FTS revision tracking for compatible readers
│   ├── Schema.swift             # Current schema definition
│   ├── Migrations/              # V24 original pixels; V25 semantic index; V26 display groups; V27 context; V28 original audio; V29 jobs; V30 exact transcripts; V31 pending audio index; V32 chunk media
│   ├── Queries/                 # Query implementations (including audio transcripts/dictation sessions)
│   ├── TestSupport/             # Test-only typed C bridge for defensive SQLite reader checks
│   └── Tests/                  # App integration, dictation, and refinement policy tests
│
├── Storage/                     # File I/O, HEVC encoding
│   ├── AGENTS.md
│   ├── StorageManager.swift
│   ├── ExactFrameReader.swift   # Identity-checked encoded-frame evidence reads
│   ├── ImageExtractor.swift     # Extract frames from video files
│   ├── IncrementalSegmentWriter.swift
│   ├── SegmentWriterImpl.swift
│   ├── Audio/                   # Legacy AAC and candidate exact chunk media writers/readers
│   ├── FileManager/             # File system utilities
│   ├── VideoEncoder/            # HEVC video encoding
│   ├── WAL/                     # WALManager, RecoveryManager, WALRecoveryReader
│   └── Tests/
│
├── Capture/                     # CGWindowListCapture integration
│   ├── AGENTS.md
│   ├── CaptureManager.swift
│   ├── ActivityMonitor.swift    # Independent bounded activity observer/persistence lifecycle
│   ├── ScreenCapture/           # Screen capture implementation
│   ├── LegacyBridge/            # C boundary for existing public CoreGraphics comparison APIs
│   ├── Deduplication/           # Perceptual hash deduplication
│   ├── Metadata/                # AppInfoProvider, BrowserURLExtractor
│   ├── Audio/                   # Microphone/system audio capture
│   └── Tests/
│
├── Processing/                  # OCR and text extraction
│   ├── AGENTS.md
│   ├── ProcessingManager.swift
│   ├── FrameProcessingQueue.swift # Async frame processing queue
│   ├── FrameProcessingWakeSignal.swift # Cancellation-safe worker notifications
│   ├── URLExtractor.swift       # URL extraction from OCR text
│   ├── OCR/                     # Vision framework OCR
│   ├── Accessibility/           # Accessibility API integration
│   ├── TextMerger/              # Text merging utilities
│   ├── Audio/                   # Whisper pipeline; opt-in NativeSpeechTranscriptionService
│   └── Tests/
│
├── Search/                      # Full-text search
│   ├── AGENTS.md
│   ├── SearchManager.swift
│   ├── IngestionManager.swift   # Search index ingestion
│   ├── SemanticRecallEngine.swift # Optional native worker, bounded semantic queries and foreground priority
│   ├── Embedding/              # Pinned native MiniLM runtime and bundled tokenizer lookup
│   ├── Resources/MiniLM/       # Verified tokenizer and license; model package remains explicitly selected
│   ├── QueryParser/             # Query parsing (app:, date:, -exclude)
│   ├── Ranking/                 # Result ranking implementation
│   ├── VectorSearchTODO/        # Planned for Release 2 (excluded from build)
│   └── Tests/                  # Includes upstream tokenizer/vector oracle and explicit native model checks
│
├── Migration/                   # Import from other apps
│   ├── AGENTS.md
│   ├── MigrationManager.swift
│   └── Importers/               # Source-specific importers (Rewind)
│
├── App/                         # Main application coordinator
│   ├── JobEventService.swift    # Explicit owned-command observation, joined callbacks and inert detached child ownership
│   ├── JobIntegration.swift     # Recording/policy owner, immediate invocation cancellation and joined callbacks
│   ├── AudioHistoryOwner.swift  # Lazy separate exact transcript reader and terminal joined close
│   ├── AudioMediaPlaybackOwner.swift # Exact transcript/media revalidation and joined PCM playback leases
│   ├── BackgroundProcessingGovernor.swift # App-owned quiet-time/native scheduler, pressure and joined cancellation
│   ├── ResourceProcessingPolicy.swift # Measured active-use budget and continuous recovery hysteresis
│   ├── ResourceUsageMonitor.swift # Owned monotonic CPU/host/footprint sampler and joined minute delivery
│   ├── StorageUsageService.swift # Periodic storage owner independent of views and recording writers
│   ├── BackgroundTranscriptionService.swift # Refinement admission adapter; dictation keeps direct service
│   ├── AppCoordinator.swift     # Central coordinator (orchestrates all modules)
│   ├── TimelineLiveCapture.swift # Joined background live-preview compatibility capture; unavailable runtime APIs fail closed
│   ├── CaptureHealth.swift      # Content-free capture gaps, original-spool pressure and cheap UI snapshots
│   ├── CapturedMomentNavigation.swift # Fresh exact display links while history stays pinned
│   ├── CaptureTextMetrics.swift # Bounded joined delivery of categorical AX outcomes and timings
│   ├── LocalRecallController.swift # Explicit local model activation, index/query lifecycle and joined shutdown
│   ├── LocalRecallMetrics.swift # Bounded content-free runtime/index metric delivery
│   ├── RecordingLifecycle.swift # Coalesced startup and cancellation/teardown ownership
│   ├── ScreenEvidenceAdmissionCoordinator.swift # App-owned native policy/configuration bridge and categorical metrics
│   ├── ProgressiveRecallService.swift # Local exact evidence, bounded expansion and mutation/privacy presentation stamps
│   ├── ActivityTimelineProjection.swift # Legacy episode projection retained for compatibility; no assignment UI
│   ├── LocalContextService.swift # Coalesced expiring local cards, optional on-device topics and joined teardown
│   ├── LocalContextIntegration.swift # Independent topic setting and categorical SQLite metrics
│   ├── LocalContextEvidenceReader.swift # Exact native screen/activity visibility, policy and provider fences
│   ├── FoundationModelsLocalContextModel.swift # Lazy optional on-device structured topic adapter; no tools
│   ├── HybridMomentSearch.swift # Explicit bounded lexical/native-semantic moments, exact identifiers and factual excerpts
│   ├── HistoryMomentSearch.swift # One explicit screen/transcript query and optimistic canonical batch revalidation
│   ├── DataAdapter.swift        # Data layer adapter (DB queries, transformations)
│   ├── ServiceContainer.swift   # Dependency injection container
│   ├── AppLifecycle.swift       # App lifecycle management
│   ├── ModelManager.swift       # Model management
│   ├── OnboardingManager.swift  # First-run onboarding flow
│   ├── RetentionManager.swift   # Data retention policies
│   ├── Dictation/               # Push-to-dictate buffer, manager, target context, insertion service
│   └── Tests/
│
└── UI/                          # SwiftUI interface
    ├── AGENTS.md
    ├── RetraceApp.swift         # App entry point
    ├── ContentView.swift        # Root content view
    ├── Components/              # Reusable UI components (MenuBarManager, HotkeyManager, etc.)
    ├── ViewModels/              # View models (Dashboard, Search, Timeline, Feedback)
    ├── Views/
    │   ├── Dashboard/           # App usage analytics and dictation history views
    │   ├── Audio/               # Transcript panel and cancellable per-entry audio playback
    │   ├── FullscreenTimeline/  # Timeline scrubbing & playback (10 views)
    │   ├── Timeline/            # Shared exact evidence image/context and bounded text views
    │   ├── Search/              # Search UI (SearchView, ResultRow, FrameViewer)
    │   ├── Settings/            # Settings panel
    │   ├── Onboarding/          # Onboarding flow
    │   └── Feedback/            # Feedback form & submission
    └── Tests/
```

---

### Capture improvement validation files

- Database: `FramePipelinePersistenceTests.swift`, `RetentionPersistenceTests.swift`, `LegacyOCRBackfillPagingTests.swift`; `Migrations/V19_ProcessingQueueFrameIndex.swift` adds queue/document/video lookup indexes, and `Migrations/V20_OCRBackfillState.swift` stores the per-database maintenance cursor.
- Storage: `WALRecoveryTests.swift` exercises large WAL, retries, damaged tails and live-session exclusion.
- Processing: `VisionOCRIncrementalTests.swift`, `FrameProcessingWakeSignalTests.swift`, `NativeSpeechTranscriptionServiceTests.swift`.
- Capture: `AudioFormatConverterTests.swift` exercises actual AVFoundation/CoreMedia conversion and stream draining; `CaptureStreamLifecycleTests.swift` covers stream ownership, cancellation, restart and display-switch ordering using real AsyncStreams.
- App: `RetentionPathValidationTests.swift` exercises real filesystem path/symlink guards; `FrameDeletionRoutingTests.swift` verifies native timeline deletion and rollback through the database API; `StartupRecoverySequencingTests.swift` covers recovery-before-worker startup, shutdown, journal preservation, bounded orphan snapshots, live placeholder ownership and cancellable bounded OCR maintenance using real SQLite and filesystem journals.

### Progressive recall implementation and validation

`App/Tests/ScreenEvidenceExpansionTests.swift`, `ScreenEvidenceFeedIntegrationTests.swift`, `ProgressiveRecallSearchTests.swift`, `EvidenceResolutionTests.swift`, `RecallCoordinatorRoutingTests.swift`, `ActivityTimelineProjectionTests.swift` and `RecordingLifecycleTests.swift` cover bounded exact text, local-only feed bookkeeping/disclosure denial, constrained/source-aware search, exact navigation, source failure propagation, legacy projection compatibility and cancelled device startup. `DiagnosticFileLoggingTests.swift` exercises the real file backend in private temporary directories, including disabled creation/append/read/rotation and debug process-launch admission. Database, Capture, Processing, Storage and UI inventories list their module regressions. `Database/Tests/RenderedRecallFixture.swift` supplies native-rendered JPEGs to real Vision/HEVC/SQLite pipeline tests; the reviewed on-disk copies and oracle are under `docs/fixtures/progressive-recall/`.

`App/Tests/ProgressiveRecallBenchmarkTests.swift` binds eight reviewed JPEGs and twelve fixed questions to actual Vision/SQLite exact references. It uses private in-memory storage, refuses media lookup and can exclusively export an authored snapshot beneath `/tmp`. Run with `RETRACE_TEST_DISABLE_FILE_LOGGING=1`. `scripts/recall_benchmark/{benchmark.py,test_benchmark.py,model-pins.json,README.md}` evaluate that snapshot with pinned offline CPU models; they are developer tools, never a production index/worker or an agent disclosure grant. The dataset, reviewed images, `vision-export.json` and retained `measurement-20260916/` artifacts live in `docs/fixtures/progressive-recall/phase2d/`. The raw v1 run is immutable; a documented Q11 oracle ambiguity leaves eleven questions for interpretation. Root owns benchmark/Shared coordination; UI owns complete-question dispatch and its isolated native-input regressions.

`Processing/Tests/ScreenTextQualityBenchmarkTests.swift` renders authored 4K images and compares the frozen scaled OCR baseline, native crops, macOS 26 document recognition, lossless LZFSE and real HEVC round trips. It requires an explicit `RETRACE_OCR_QUALITY_EXPORT` path; ordinary suites skip that comparison. Real Vision/SQLite/HEVC regressions separately cover complete lines, crop geometry, cache invalidation, exact decoded pixels and source/outcome metrics. Root coordinates the Shared processing-pixel and original-retention contracts across Processing/Storage/Database. Original retention is being verified in the [unified history ledger](docs/unified-history-plan.md); direct capture-time Accessibility text and installed accuracy/performance acceptance remain open.

`App/CaptureHealth.swift` and `App/Tests/CaptureHealthTests.swift` own bounded, joined coverage delivery and content-free `capture_coverage` metrics. Storage pressure, native capture gaps and event overflow remain independent. New callback delivery must finish before the canonical database writer closes. UI polls a cheap cached snapshot; file scans and archive verification never run in a view body.

`App/Tests/ScreenEvidenceAdmissionIntegrationTests.swift` exercises the native policy bridge, local-only unpublished-artifact endpoints, cancellation/metric-delayed reads and coalesced owning-service initialization/cleanup against private SQLite. Its debug initialization boundary skips unrelated native/audio/storage setup; it never substitutes the policy owner or database. Capture and Database own their lifecycle/mutation/rollback regressions. The admission contract grants no model scheduling, agent disclosure or index readiness.

`App/Tests/AudioHistoryOwnerTests.swift` exercises coalesced reader acquisition and joined terminal close. `CrossSourceEvidenceResolutionTests.swift` uses real private SQLite stores for exact transcript/job revisions, policy changes, deletion during reads, paused history and agent denial. These sources resolve through their own immutable references without manufacturing a screen frame or verified media mapping. The candidate workspace can pin and revisit them; exact standalone audio playback remains unverified.

`App/Tests/HistoryMomentSearchTests.swift` exercises the one-field screen/transcript route with real SQLite/FTS and separate V30 readers. Screen semantic scope and transcript text/row-order matching remain distinct. Bounded exact source excerpts, unsupported audio syntax/filters, partial scans and omitted candidates remain explicit. Whole-batch revalidation is optimistic across separate stores; it is not a lasting permission or a single cross-store transaction. The UI clears changed results and coverage before refresh. V30 historical preparation has a bounded database API, but its App maintenance owner is not yet integrated; search starts no model or bootstrap worker.

`App/JobIntegration.swift` owns independent default-off `JobObservationConfig`, the master recording generation and activated V23 policy for explicit application-code commands. Every invalidating change synchronously cancels its bounded, request-coalesced invocation tasks; reconciliation joins those tasks and callbacks before replacing the observer. The policy bridge drains the old owner before policy mutation, and `ServiceContainer` joins shutdown before SQLite closes. `App/Tests/JobIntegrationTests.swift` uses real SQLite/native processes, held native launch/resolve boundaries, policy changes, restart, duplicate/conflicting requests and close ordering. This is an owner prerequisite for explicit producers; external build/agent adapters and their user controls remain separate work.

`App/Tests/LocalRecallControllerTests.swift`, `LocalRecallMetricsTests.swift` and `LocalRecallServiceLifecycleTests.swift` exercise default-disabled behavior, failed artifacts, private cache creation, bounded content-free SQLite metric delivery and joined native shutdown. The service-boundary fixture holds an actual native embedding and a real V25 claim, vetoes cancellation commits on a private writer, and proves failed shutdown preserves the capability/database until cleanup retry drains metrics. Native model cases require an explicit `RETRACE_MINILM_MODEL_PACKAGE`; ordinary skips are not native runtime acceptance.

Capture context is independently opt-in (`activityContextEnabled`, default false), exposed in Capture settings, and obeys master recording pause. Source-backed search hits must retain their immutable evidence reference or selection proof; never resolve a hit by bare numeric ID. Screenshots/OCR and timeline selection use exact evidence without project assignment or visit grouping. Existing correction records remain for compatibility; the assignment workflow is outside the active scope. Implementation and automated evidence do not establish installed Mac acceptance; see the validation ledger.

Capture-time direct text is independently opt-in (`captureVisibleTextEnabled`, default false). `Shared/Models/CaptureText.swift` binds exact native UTF-16 runs to an immutable source context and independently retained pixel receipt. The label is a checked same-window bracket, not an atomic AX/pixel snapshot. Database snapshot admission and WAL V2 reads/writes reject conflicting receipts, ranges, geometry or provenance; old metadata decodes without inventing direct text. `CaptureTextPersistenceTests`, `CaptureTextWALTests` and `CaptureTextMetricsTests` cover private SQLite/files and bounded joined delivery. Native acquisition tests belong to Capture. UI validates direct text off main and keeps it separate from OCR, including OCR-scoped references. Staged source and native fixture checks do not establish installed accuracy/performance acceptance.

`CapturedMomentNavigationTests` covers private SQLite navigation refresh, WAL retention across revoked admission, native HEVC recovery and deletion. `MixedDisplayPipelineTests` feeds interleaved native-rendered 640x360/960x540 frames through the real App writer path, SQLite, original WAL, Vision and HEVC readers. It checks display identity, per-writer archive indices, exact original pixels and release only after durable extraction plus verified archive mapping. Its debug-only stream entry does not start capture/audio devices or modify live preferences; it does not establish physical multi-display or installed acceptance.

## Module Ownership & Responsibilities

| Module         | Directory     | Agent File             | Responsibility                                                     |
| -------------- | ------------- | ---------------------- | ------------------------------------------------------------------ |
| **DATABASE**   | `Database/`   | `Database/AGENTS.md`   | SQLite schema, FTS5, CRUD operations, migrations                   |
| **STORAGE**    | `Storage/`    | `Storage/AGENTS.md`    | File I/O, HEVC video encoding (working, not optimized), encryption |
| **CAPTURE**    | `Capture/`    | `Capture/AGENTS.md`    | CGWindowListCapture API, frame deduplication, metadata/audio capture |
| **PROCESSING** | `Processing/` | `Processing/AGENTS.md` | Vision OCR, Accessibility API, audio transcription/refinement      |
| **SEARCH**     | `Search/`     | `Search/AGENTS.md`     | Query parsing, FTS5 ranking and default-disabled native semantic recall candidate |
| **MIGRATION**  | `Migration/`  | `Migration/AGENTS.md`  | Import from Rewind AI (Rewind only, others planned)                |
| **APP**        | `App/`        | —                      | Coordinator, DI container, data adapter, lifecycle, dictation      |
| **UI**         | `UI/`         | `UI/AGENTS.md`         | SwiftUI interface (timeline, dashboard, settings, search, audio)   |

**Rule**: Each agent should **ONLY** modify files in their assigned module directory. Cross-module changes require explicit coordination.

---

## Coding Conventions

### Language & Style

- **Language**: Swift 5.9+
- **Async/Await**: Required for all I/O operations
- **Actors**: Use for stateful classes needing synchronization
- **Sendable**: All public APIs must be `Sendable`
- **Value Types**: Prefer structs/enums over classes

### Module Boundaries

1. **Depend only on protocols** - Import from `Shared/Protocols/` only
2. **Use shared types** - All cross-module data uses `Shared/Models/`
3. **No direct imports** - Never import from another module's directory
4. **Protocol conformance** - Each module implements its protocol from `Shared/`

### Error Handling

- Use error types from `Shared/Models/Errors.swift`
- Throw specific errors, not generic ones
- Add new error cases to your module's directory only

### Testing

- **Write tests first** - Follow TDD: RED → GREEN → REFACTOR
- **Test locations**: `{Module}/Tests/`
- **Test against protocols** - Not implementations
- **Mock dependencies** - Using protocol conformance

### ⚠️ CRITICAL: Test with REAL Input Data, Not Fake Structures

Many tests "play cop and thief" - creating fake data structures and validating the fake data they created. This provides **zero confidence** about real system behavior.

**USELESS** — tests that Swift can assign struct fields:

```swift
let appInfo = AppInfo(bundleID: "com.apple.Safari", ...)
let result = AccessibilityResult(appInfo: appInfo, ...)
XCTAssertEqual(result.appInfo.bundleID, "com.apple.Safari")  // circular
```

**USEFUL** — tests that exercise real system APIs:

```swift
let tables = try await database.getTables()
XCTAssertTrue(tables.contains("segment"))  // validates real SQLite schema
```

**What makes a test useful:**

- ✅ Tests real system APIs (SQLite, FileManager, Vision OCR)
- ✅ Uses real production input (real screenshots, real OCR output)
- ✅ Validates end-to-end workflows (screenshot → OCR → database → search)
- ❌ NOT testing struct field assignment or string concatenation

---

## Architecture & Data Flow

### Data Flow by Module

```
CAPTURE Module:
  Input:  CGWindowListCapture API (every 2 seconds)
  Output: CGImage + AppInfo metadata → deduplication (~95% filtered)

STORAGE Module (Video Path):
  Input:  CGImage stream
  Output: .mp4 file (HEVC encoded) → {AppPaths.storageRoot}/videos/

PROCESSING Module (OCR Path):
  Input:  CGImage
  Output: ExtractedText with OCRRegion[] (bounds + text)

DATABASE Module:
  Input:  AppInfo + ExtractedText + Video metadata
  Output: Core tables:
    • segment (app/window context)
    • frame (screenshot metadata)
    • node (OCR bounding boxes)
    • searchRanking (FTS5 full-text index)
    • doc_segment (linking table)
    • video (file metadata)

SEARCH Module:
  Input:  Query string (with filters: app:, date:, -exclude)
  Output: SearchResult[] with frameId + snippet + highlighting
```

### Database Relationships

```sql
segment (1) ──< (N) frame (N) >── (1) video
                    │
                    └──< (N) node

frame (1) ──< (1) doc_segment >── (1) searchRanking_content
```

### Architecture Diagram

```
                +---------------------------+
                |        App Layer          |
                |  (Integration + UI)       |
                +------------+--------------+
                             |
     +-----------------------+-----------------------+
     |                       |                       |
     v                       v                       v
+----------------+     +------------------+     +----------------+
|    Capture     |     |   Processing     |     |     Search     |
|    Module      |     |     Module       |     |     Module     |
+-------+--------+     +--------+---------+     +-------+--------+
        |                       |                       |
        v                       v                       v
+----------------+     +------------------+     +----------------+
|    Storage     |     |    Database      |     |    Database    |
|    Module      |     |     (FTS)        |     |   (Vectors)    |
+----------------+     +------------------+     +----------------+
```

---

## Tech Stack

| Component           | Technology              | Notes                                  |
| ------------------- | ----------------------- | -------------------------------------- |
| Language            | Swift 5.9+              | Actors, async/await, Sendable required |
| UI Framework        | SwiftUI                 | Fully implemented                      |
| Screen Capture      | CGWindowListCapture     | Legacy API, no privacy indicator       |
| Video Encoding      | VideoToolbox (HEVC)     | Hardware encoding on Apple Silicon     |
| OCR                 | Vision framework        | macOS native OCR                       |
| Database            | SQLite + FTS5           | Full-text search built-in              |
| Encryption          | CryptoKit (AES-256-GCM) | Optional on-device encryption          |
| Audio Transcription | whisper.cpp             | Local transcription pipeline           |
| Vector Search       | Pinned local MiniLM / Core ML | Default-disabled native screen-text candidate; exact canonical evidence and bounded coverage |

---

## System Requirements

- **macOS**: 26.0+ (Tahoe or later); retain existing archive/import compatibility
- **Hardware**: **Apple Silicon required** (M1/M2/M3) - Intel not supported
- **Permissions**:
  - Screen Recording permission (required)
  - Microphone permission (required for dictation/audio capture)
  - Accessibility permission (required for app context extraction)

---

## Performance Targets

- **CPU**: <20% of single core during capture
- **Memory**: <1GB total app usage
- **Storage**: ~15-20GB per month of continuous use
- **Search**: <100ms for keyword search
- **OCR**: <500ms per frame on Apple Silicon

---

## Debug Logging

Use `Shared/Logging.swift` (`Log.debug`, `Log.info`, `Log.warning`, `Log.error`) with the correct category.

### Writing Debug Logs

```swift
Log.debug("[TIMELINE] Play button tapped", category: .ui)
Log.info("[TIMELINE] Playback started at \(position)", category: .ui)
```

### Best Practice: Scope Logs to User Actions

Prefer event-scoped logging over high-frequency frame-by-frame logging during normal debugging.

### Debugging Philosophy: Trace Execution First

**When debugging, add logging to trace the actual execution path BEFORE making assumptions.**

Don't assume you know which code is running. Add logs at each layer to verify:

```swift
Log.debug("[VM] Calling coordinator", category: .ui)
Log.debug("[COORDINATOR] Calling adapter", category: .app)
Log.debug("[ADAPTER] Taking FILTERED path", category: .database)  // Reveals which path
```

Then check which path actually executes and fix the right code.

---

## Critical Rules for All Agents

### 1. Stay In Your Lane

- **ONLY** modify files in your assigned directory
- **NEVER** modify files in `Shared/` without explicit coordination
- **NEVER** modify another agent's directory

### 2. Depend Only on Protocols

- Import from `Shared/` only
- Never import from another module's directory
- Your implementation must conform to protocols in `Shared/Protocols/`

### 3. Use Shared Types

- All data passed between modules uses types from `Shared/Models/`
- Don't create duplicate types - use what exists
- If you need a new shared type, document the need (don't create it)

### 4. Testing is Mandatory

- Write tests BEFORE implementation (TDD)
- Test against protocols, not implementations
- Cover edge cases thoroughly
- All tests must pass before submitting changes

### 5. Keep AGENTS.md Up-to-Date

- **Whenever you add, rename, move, or delete files/directories**, update the relevant `AGENTS.md` (root or module-level) in the **same commit**
- This includes: new Swift files, new subdirectories, new model/protocol types in `Shared/`, and changes to module structure
- If you notice AGENTS.md is out of date while working, fix it immediately — don't leave it for later
- The project structure tree, module ownership table, and shared type listings must always reflect reality

### 6. Main Thread & Hang Prevention (Mandatory)

- Treat the main thread as **UI-only**: state publication, view updates, input handling, and presentation.
- **Never** do blocking work on main for timeline/search open paths, startup checks, or settings pickers.
- Move heavy work off main (`Task.detached`, actors, background queues): SQLite/file validation, OCR, screenshot capture, metadata/icon lookup, image decode, and large layout calculations.
- **Do not use blocking primitives on UI paths**: `DispatchSemaphore.wait()`, `DispatchQueue.sync`, `Thread.sleep`, or equivalent blocking waits.
- For duplicate triggers (`onAppear` + controller calls), **coalesce** with an in-flight task/join pattern; do not silently skip important loads.
- In SwiftUI render paths (`body`, cell builders), avoid synchronous system/file APIs (`NSWorkspace`, `FileManager`, SQLite, image decoding). Use async caches/view models.
- Keep list/grid identity stable (`result.id`, model IDs). Avoid index-based IDs and avoid forcing full subtree recreation via generation `.id(...)` on large containers.
- Guard geometry/preference-driven state writes with an epsilon to prevent layout/preference feedback loops.
- Cache expensive derived layout data (timeline/treemap block geometry) with explicit invalidation keys (snapshot revision, frame count, zoom, etc.).
- Prefer natural `@Published` updates; avoid manual broad invalidation (`objectWillChange.send()`) unless there is a documented, minimal-scope reason.
- Instrument critical UX paths with `Log.recordLatency` and watch p50/p95 (timeline open, search open, live screenshot/OCR, picker validation). Regressions should block merge.
- Required smoke checks before merge for UI/perf-sensitive changes:
  - Timeline close → reopen (prerendered path): no stale tape, no hitching.
  - Search overlay open and navigate: no full-grid teardown thrash.
  - Settings/storage picker validation: no UI freeze while verifying paths.

### 7. Daily Metrics Instrumentation (Mandatory)

- **Any newly added feature or user action must add `daily_metrics` instrumentation in the same change**.
- Add a new `DailyMetricsQueries.MetricType` (and metadata schema) when no existing metric accurately represents the action.
- Wire the metric emission at the action entry/outcome points (for example: opened, submitted, succeeded, failed/no-results where applicable).

### 8. Keep the Changelog Current

- Update `CHANGELOG.md` in the same change as every meaningful bug fix or improvement. Describe the resulting behavior and include relevant validation or a link to its evidence.
- Add dated entries under **Unreleased** while changes are in development. A passing build or test suite does not establish installation or release.
- Record a **Local trial** only after verifying the installed build and launch; include the build identifier, date and comparison/rollback notes when available. Local trials remain under Unreleased until an actual release.
- Move shipped entries into a dated, versioned **Released** section only after verifying the release. Preserve the distinction between implemented, installed for local assessment, and released.
- Keep the changelog and linked validation notes available to Git; do not place release history only in ignored local notes.

---

## Additional Resources

- **AGENTS.md Specification**: https://agents.md
- **Contribution Guide**: [CONTRIBUTING.md](CONTRIBUTING.md)
- **Human README**: [README.md](README.md)

---

_This file follows the AGENTS.md standard for AI agent guidance. Last updated: 2026-09-20_


<claude-mem-context>
# Memory Context

# [backintime] recent context, 2026-11-11 3:08pm GMT+10

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 20 obs (5,697t read) | 528,549t work | 99% savings

### Jun 15, 2026
S1236 Live Audio UI fixes + Sync/Refining button clarification + repaired audio visibility in Retrace app (Jun 15 at 3:22 AM)
S806 Understanding the purpose of pretool hooks in the project — do we need all of them? (Jun 15 at 3:22 AM)
### Jun 22, 2026
S1237 Live Audio UI fixes — scrollable history, Sync/Refining button clarification, repaired audio row labels — shipped to Retrace.app (Jun 22 at 8:18 AM)
### Jul 2, 2026
S1741 Dictation UX / OCR repair product-shape fix — hide legacy backfill from user-facing UI (Jul 2 at 5:00 AM)
### Nov 11, 2026
83176 12:44p 🔵 Full offline QA run passes all 66 checks from a copied portable folder, with no page errors or external requests
83177 " 🔵 Retrace prototype monitor screenshot viewed; no visual defects recorded
83178 12:46p ✅ Session log and validation records written for the Retrace click-through prototype
83179 " 🔵 Validation record links to files this step did not create, and git status is stated inconsistently
83180 12:47p 🔵 Documentation browser check passed 21 offline checks with no errors or external requests
83181 " ✅ Documentation browser check script written to /tmp and run against the prototype
83182 " 🔵 Prototype folder is still untracked in git, contrary to the session log
83183 12:48p ✅ Package checks and bundle manifest written; validation record now links the 21-check receipt
83184 " 🔵 Static link check passes across 31 HTML pages, with two exemptions that rely on other checks
83185 " ✅ Retrace click-through prototype staged in git, not yet committed
83186 " 🔵 Staged file count (51) differs from the manifest file count (54 plus itself)
83187 " 🔵 Git ignores the Markdown documentation files, so they are not in the staged set
83188 12:49p 🔵 Standalone copy of the Retrace prototype matches the deliverable byte-for-byte, and seven pages open offline
83189 " ✅ Retrace prototype committed as aa0bed4 on the feature/push-to-dictate branch
83190 " 🔵 Prototype commit sits on an unrelated feature branch, not a dedicated one
83191 " 🔵 Prototype folder is clean in git and its 54 manifest hashes match
83192 " ✅ Commit aa0bed4 pushed to the shared remote branch feature/push-to-dictate
83194 3:07p ✅ README update and GitHub commit requested
83195 " 🔵 Retrace working tree holds a large uncommitted change set on feature/push-to-dictate
83196 " 🔵 Live-context recovery lives in a separate worktree from the V24–V32 candidate

Access 529k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>

`App/HybridMomentSearch.swift` is the explicit workspace moments route. It preserves the existing paged/chronological adapter route, applies supported app/date/hidden filters before candidate budgets, reserves only source-verified whole identifiers and fuses lexical/semantic ranks with exact evidence references. Source text is read without image decoding, supporting spans are bounded and validated, and final source/policy/semantic stamps follow awaited metrics. Optional `SearchResult.matchExplanation` and `SearchResults.momentCoverage` default to nil for existing routes; semantic coverage is native-screen-text-only and exposes partial scans. `App/Tests/HybridMomentSearchTests.swift` uses private real SQLite/FTS, canonical evidence and authored pinned vector goldens for ranking, source/visibility fences, imported/native equal IDs, cancellation and backwards-compatible result decoding. Source review, automated execution and installed semantic quality remain distinct.

`App/LocalContextService.swift` admits bounded selected native screen/activity references for local cards, with a separate explicit Foundation Models opt-in that defaults off. Model output is only a bounded topic interpretation with validated supplied supports; deterministic excerpts remain available. External source items require provider-owned full-snapshot revalidation and retain separate provenance. Canonical V23 writer/policy identity, exact extraction/activity visibility, source identity and wall/monotonic expiry are rechecked after generation and metrics. Replacements and stop join owned work; no audio or significant-job claims are supported by this slice. `App/Tests/LocalContextServiceTests.swift` uses private real SQLite/evidence inputs and controlled external model/provider boundaries. Native generation and installed energy/quality acceptance remain separate gates.

`App/LocalContextIntegration.swift` records categorical local-context metrics and defines the independent Foundation Models opt-in. `App/Tests/LocalContextOwnershipTests.swift` verifies one lazy service owner and joined metric cleanup before private SQLite closes. `TimelineLiveCapture` keeps legacy live-preview capture off main and joins cancelled native reads; availability does not establish installed capture acceptance.

`LocalContextServiceTests/testExplicitNativeTopicUsesPrivateCanonicalEvidenceAndRetainsExactSupports` is separately opt-in via `RETRACE_LOCAL_CONTEXT_NATIVE=1`. It uses authored private SQLite and the actual on-device topic adapter, retains exact references and rejects post-generation deletion. Unavailable runtime/locale skips are not native model acceptance; ordinary suites load no Foundation Models model.

`App/JobEventService.swift` accepts only explicit application-code command invocations; it never starts work on init and exposes no external ingress or global hooks. Native exit reason/status becomes categorical job evidence after canonical SQLite admission. Pause/stop joins App/database callbacks and records interruption without killing or waiting for an already-launched command; at most eight native child lifetimes remain retained with inert callbacks. A fresh service instance owns restart after joined stop. Command paths/arguments/output are never persisted or interpreted as authority, and process presence makes no user-engagement claim. `App/Tests/JobEventServiceTests.swift` uses actual authored true/false/signal/FIFO commands and private SQLite. V29 integration/source checks do not establish installed acceptance or arbitrary job-description search.


### Automatic processing responsiveness candidate (September 28)

The separate default-off audio storage trial writes unique ten-second AAC chunks and ordered overlapping manifests. V32 binds normalized ranges to V28 source lineage; V30 text alone remains no proof of media. `AudioMediaPlaybackOwner` independently checks registered manifests, native decoded bytes, current transcript identity and policy. Native sample-clock continuity is supplied through `CapturedAudio.continuityID`; receipt-time wall-clock anchoring remains approximate. Startup recovery is bounded to 16 journals before recording and continues through the owned periodic task. Shared/Storage/Database/Processing/Capture/App/UI changes require coordinated clean debug and separate optimized builds. `docs/responsiveness-storage-validation.md` records the staged candidate, passing integrity/lifecycle tests and failed authored recognition/storage comparison; it is not accepted for rollout. Pending-recording playback and installed acceptance remain open. Never infer speech accuracy from deterministic word ownership or reclaimable disk space from logical AAC size.

App owns `BackgroundProcessingGovernor` through the Shared permit protocol. Automatic ambient audio, refinement model calls, optional semantic background pages and optional topic generation share one permit; direct dictation and explicit queries do not acquire automatic permits. Fresh OCR now acquires a separate automatic lane after measured CPU/host admission; manual and historical lanes cannot claim its work. This source policy still requires installed active-use acceptance. Native Whisper uses owned cancellation flags in both encoder-start and abort callbacks and uses two threads in Low Power Mode, four otherwise. Quiet-time admission requires five minutes without input plus native scheduler and pressure permission; input inactivity is only a scheduling hint.

`BackgroundProcessingGovernorTests` covers bounded admission, cancellation/release, pressure, fairness and native observer lifetime. `BackgroundProcessingContext` joins release on every exit. The System Monitor displays recording, text preparation and indexing separately and exposes a cancellable Process now override. See `docs/responsiveness-storage-validation.md` for measured evidence and remaining plan scope; source implementation is not installed performance acceptance.


### Measured performance candidate (September 30)

`ResourceUsageMonitor` samples only this process and host counters once per second with a monotonic clock. One core is 100%; host utilization uses all cores. Unknown/reset/sleep intervals stay unknown. `ResourceProcessingPolicy` defers automatic fresh OCR above the active-use 20% rolling app target or 80% five-second host utilization, recovering after 15 continuous seconds below 15%/70%. This is admission control, not a hard CPU cap. Historical audio/OCR/model work still waits for five quiet minutes and macOS permission; capture, durable writes and explicit work retain priority. `ResourceUsageMonitorTests`, `ResourceProcessingPolicyTests`, `StorageUsageServiceTests` and real SQLite/queue regressions cover the new owners and admission boundaries.

The App storage owner scans metadata every 15 minutes and coalesces manual refreshes independently of visible views. Logical bytes, allocated file blocks and volume free space are separate; APFS shared blocks are not reclaimable-space promises. Partial or inaccessible locations stay visible and cannot replace a last complete measurement with an apparent zero. `ResourceUsagePersistence` stores bounded content-free minute aggregates for 30 days. The offline `scripts/performance_benchmark/` scorecard measures quality, speed, cost and recall with complete denominators and pinned run metadata; see `docs/performance-measurement.md`. No installed CPU, codec or capture acceptance follows from source tests alone.

For each performance-sensitive change, retain a matched baseline and candidate receipt covering the affected quality, speed, cost and recall measures. Include capture/audio coverage and pending-work denominators so lost or deferred work cannot be presented as a resource saving. Preserve failed runs and explicitly unavailable measurements. Before promoting a backend, codec or governor, apply the representative three-run gates in `docs/performance-measurement.md`; a build, authored fixture or runner self-test is insufficient. Keep source validation, installation and installed acceptance separate in the delivery ledger.
