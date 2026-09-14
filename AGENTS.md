# Retrace - Agent Guide

> **Standard**: This file follows the [AGENTS.md](https://agents.md) specification - a vendor-agnostic standard for AI agent guidance. For human-readable project information, see [README.md](README.md).

Retrace is a local-first screen recording and search application for macOS, inspired by Rewind AI. It captures screens, extracts text via OCR, and makes everything searchable—all locally on-device.

**Status**: Core screen capture (CGWindowListCapture), OCR (Vision), full-text search (FTS5), HEVC encoding, Rewind import, audio transcription, and push-to-dictate are working. Vector search is planned for a future release.

---

## Quick Reference

- **Module-Specific Instructions**: Each module has its own `AGENTS.md` file in its directory
- **Human Documentation**: [README.md](README.md) and [CONTRIBUTING.md](CONTRIBUTING.md)
- **Updates and Release Status**: [CHANGELOG.md](CHANGELOG.md)
- **Product Roadmap**: [docs/roadmap.md](docs/roadmap.md)
- **Progressive Recall Plan**: [docs/progressive-recall-plan.md](docs/progressive-recall-plan.md) (Phase 0/1 implementation authorised; acceptance tracked separately)
- **Progressive Recall Validation**: [docs/progressive-recall-validation.md](docs/progressive-recall-validation.md) (baseline, fixed questions and matched Mac/Timely acceptance)
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
│   ├── progressive-recall-plan.md # Authorised contextual recall plan; Phase 0/1 in progress
│   ├── progressive-recall-validation.md # Baseline, fixtures and acceptance ledger
│   ├── fixtures/progressive-recall/ # Reviewed Cedar JPEGs/oracle and same-title Word RTF fixtures
│   └── roadmap.md               # Product thesis, differentiation, and roadmap
├── scripts/                     # Build/release/validation scripts
│   ├── release.sh               # End-to-end release automation
│   ├── create-release.sh        # Release build + packaging helper
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
│   │   ├── Activity.swift       # Immutable focus events, coverage, corrections and feed contracts
│   │   ├── Evidence.swift       # Source-qualified references, snapshots and typed exact resolution
│   │   ├── Text.swift           # ExtractedText, OCRTextRegion
│   │   ├── TextRegion.swift     # OCR text region types
│   │   ├── Search.swift         # SearchQuery, SearchResult
│   │   ├── Segment.swift        # Segment data model
│   │   ├── Config.swift         # Configuration types
│   │   ├── Errors.swift         # Error types
│   │   ├── Audio.swift          # Audio capture and transcription model types
│   │   ├── Dictation.swift      # Push-to-dictate config/session model types
│   │   ├── FilterCriteria.swift # Timeline/search filter criteria
│   │   ├── Source.swift         # Data source enum (native, rewind, etc.)
│   │   ├── Tag.swift            # Tag model types
│   │   └── Comment.swift        # Segment comment and attachment models
│   └── Protocols/               # Module interfaces
│       ├── DatabaseProtocol.swift
│       ├── ActivityStoreProtocol.swift # Canonical activity/feed/correction writer interface
│       ├── EvidenceStoreProtocol.swift # Immutable screen snapshot/store registry interface
│       ├── StorageProtocol.swift
│       ├── CaptureProtocol.swift
│       ├── ProcessingProtocol.swift
│       ├── AudioCaptureProtocol.swift
│       ├── TranscriptionProtocol.swift
│       ├── SearchProtocol.swift
│       └── MigrationProtocol.swift
│
├── Database/                    # SQLite + FTS5 storage
│   ├── AGENTS.md                # Module-specific agent instructions
│   ├── DatabaseManager.swift    # Main database coordinator
│   ├── DatabaseConnection.swift # SQLite connection helpers
│   ├── FramePipelinePersistence.swift # Atomic OCR, claims and recovery
│   ├── ActivityPersistence.swift # Durable context, feed/checkpoints and corrections
│   ├── ActivityScreenLinkPersistence.swift # Proven capture-to-activity associations
│   ├── ScreenEvidencePersistence.swift # Immutable screen/extraction snapshots and receipts
│   ├── LegacyOCRBackfillPersistence.swift # Bounded, resumable OCR node-text maintenance
│   ├── RetentionPersistence.swift # Bounded frame cleanup and guarded video deletion
│   ├── FTSManager.swift         # Full-text search management
│   ├── RecallSearchRevisionHooks.swift # Connection-local FTS revision tracking for compatible readers
│   ├── Schema.swift             # Current schema definition
│   ├── Migrations/              # Schema migration scripts (including audio/dictation)
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
│   ├── QueryParser/             # Query parsing (app:, date:, -exclude)
│   ├── Ranking/                 # Result ranking implementation
│   ├── VectorSearchTODO/        # Planned for Release 2 (excluded from build)
│   └── Tests/
│
├── Migration/                   # Import from other apps
│   ├── AGENTS.md
│   ├── MigrationManager.swift
│   └── Importers/               # Source-specific importers (Rewind)
│
├── App/                         # Main application coordinator
│   ├── AppCoordinator.swift     # Central coordinator (orchestrates all modules)
│   ├── RecordingLifecycle.swift # Coalesced startup and cancellation/teardown ownership
│   ├── ProgressiveRecallService.swift # Local activity/evidence access with current privacy checks
│   ├── ActivityTimelineProjection.swift # Derived episodes and timed document/coverage intervals
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
    │   ├── Audio/               # Transcript window views
    │   ├── FullscreenTimeline/  # Timeline scrubbing & playback (10 views)
    │   ├── Timeline/            # Activity episodes, exact evidence and window controller
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

`App/Tests/ProgressiveRecallSearchTests.swift`, `EvidenceResolutionTests.swift`, `RecallCoordinatorRoutingTests.swift`, `ActivityTimelineProjectionTests.swift` and `RecordingLifecycleTests.swift` cover constrained/source-aware search, exact navigation, source failure propagation, timed organisation and cancelled device startup. Database, Capture, Processing, Storage and UI inventories list their module regressions. `Database/Tests/RenderedRecallFixture.swift` supplies native-rendered JPEGs to real Vision/HEVC/SQLite pipeline tests; the reviewed on-disk copies and oracle are under `docs/fixtures/progressive-recall/`.

Activity context is independently opt-in (`activityContextEnabled`, default false) in the activity timeline and obeys master recording pause. Source-backed search hits must retain their immutable evidence reference or selection proof; never resolve a legacy hit by bare numeric ID. Local corrections can be confirmed but remain pending until the companion writer acknowledges them. Implementation and automated evidence do not establish installed Mac/Timely acceptance; see the validation ledger.

## Module Ownership & Responsibilities

| Module         | Directory     | Agent File             | Responsibility                                                     |
| -------------- | ------------- | ---------------------- | ------------------------------------------------------------------ |
| **DATABASE**   | `Database/`   | `Database/AGENTS.md`   | SQLite schema, FTS5, CRUD operations, migrations                   |
| **STORAGE**    | `Storage/`    | `Storage/AGENTS.md`    | File I/O, HEVC video encoding (working, not optimized), encryption |
| **CAPTURE**    | `Capture/`    | `Capture/AGENTS.md`    | CGWindowListCapture API, frame deduplication, metadata/audio capture |
| **PROCESSING** | `Processing/` | `Processing/AGENTS.md` | Vision OCR, Accessibility API, audio transcription/refinement      |
| **SEARCH**     | `Search/`     | `Search/AGENTS.md`     | Query parsing, FTS5 queries, result ranking (no vector search yet) |
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
| Vector Search       | llama.cpp               | Planned (prepared but not active)      |

---

## System Requirements

- **macOS**: 13.0+ (Ventura or later)
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

_This file follows the AGENTS.md standard for AI agent guidance. Last updated: 2026-09-12_


<claude-mem-context>
# Memory Context

# [backintime] recent context, 2026-08-26 3:26pm GMT+10

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision 🚨security_alert 🔐security_note
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 20 obs (4,412t read) | 563,302t work | 99% savings

### Jun 15, 2026
S1236 Live Audio UI fixes + Sync/Refining button clarification + repaired audio visibility in Retrace app (Jun 15 at 3:22 AM)
S806 Understanding the purpose of pretool hooks in the project — do we need all of them? (Jun 15 at 3:22 AM)
### Jun 22, 2026
S1237 Live Audio UI fixes — scrollable history, Sync/Refining button clarification, repaired audio row labels — shipped to Retrace.app (Jun 22 at 8:18 AM)
### Jul 2, 2026
S1741 Dictation UX / OCR repair product-shape fix — hide legacy backfill from user-facing UI (Jul 2 at 5:00 AM)
### Aug 26, 2026
49834 2:15p 🔵 Audio audit partial results: 701K filesystem files, 879K DB paths, 177K missing files
49837 2:16p 🔵 Multiple analysis commands launched: word source code search, audio queries, unreferenced file details, duplicate detection, dbstat
49844 2:18p 🔵 User questioned pretool hook system purpose and necessity
49848 2:19p 🔵 Audio file storage analysis for Retrace application
49853 2:20p 🔵 User questions purpose and necessity of pretool hooks
49857 2:21p 🔵 User inquiry about pretool hooks purpose and necessity
49859 " 🔵 Investigation of audio segment writing and transcript rendering code paths
49860 2:22p 🔵 Audio processing pipeline uses writeAudioSegment across 5 managers with consistent pattern
49862 " 🔵 Primary session investigating Retrace app storage and git diffs for audio pipeline
49865 2:24p 🔵 User inquiring about pretool hooks purpose and necessity
49871 2:25p 🔵 Audio transcription system architecture and data scale discovered
49878 2:26p 🔵 Multi-pass audio transcription pipeline architecture with version tracking
49879 " 🔵 Audio storage and repair policy tests executing
49881 2:27p 🔵 Audio storage and repair policy tests compiling
49882 " 🔵 Waiting for audio policy tests compilation to complete
49884 " 🔵 Audio policy tests fail compilation - missing AudioStoragePolicy type
49886 2:28p 🔵 User inquiring about pretool hooks purpose and necessity
49888 2:29p 🔴 Running audio policy tests after patch application
49889 " 🔵 Waiting for audio policy tests compilation after patch
49891 2:30p 🔵 Audio policy tests compilation in progress

Access 563k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>
