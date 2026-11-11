# DATABASE Agent Instructions

You are responsible for the **Database** module of Retrace. Your job is to implement SQLite database operations including schema, migrations, CRUD operations, and full-text search indexing.

**Status**: ✅ Core tables fully implemented (segments, frames, searchRanking FTS5). Uses SQLCipher for optional encryption and Rewind database import compatibility. Audio capture/transcription tables, contextual refinement tracking, daily metrics, and dictation session history are active. **Advanced tables not yet implemented** (app_sessions, encoding_queue, junction tables - planned for future release).

## Your Directory

```
Database/
├── ResourceUsagePersistence.swift # Content-free resource minute writes, bounded 30-day expiry and row cap
├── Migrations/
│   ├── MigrationRunner.swift
│   ├── V10_SegmentCommentSearchIndex.swift
│   ├── V11_SegmentCommentLinkCompositeIndex.swift
│   ├── V12_AudioCaptures.swift
│   ├── V13_TranscriptionPass.swift
│   ├── V14_ContextualRefinement.swift
│   ├── V15_PipelineVersion.swift
│   ├── V16_DictationSessions.swift
│   ├── V17_AudioTranscriptMetadata.swift
│   ├── V18_NodeText.swift
│   ├── V19_ProcessingQueueFrameIndex.swift
│   ├── V20_OCRBackfillState.swift
│   ├── V21_ProgressiveRecall.swift
│   ├── V22_ScreenEvidenceFeed.swift
│   ├── V23_ScreenEvidenceAdmission.swift
│   ├── V24_OriginalFrameSources.swift # Store-qualified source aliases and deletion tombstones
│   ├── V25_SemanticRecall.swift # Typed native vectors, source invalidation and independent fresh/backfill checkpoints
│   ├── V26_CaptureGroups.swift # Additive group/attachment/member journal and revision/deletion guards
│   ├── V28_AudioOriginalSources.swift # Immutable declared source and deletion/path fences
│   ├── V27_LocalContextVisibility.swift # Indexed document hides and canonical revocation lookups
│   ├── V29_JobEvents.swift # Additive exact categorical job receipts, tombstones and read revision
│   ├── V30_AudioEvidence.swift # Exact transcript revisions, lineage deletion and bounded historical registration
│   ├── V1_InitialSchema.swift
│   ├── V2_UnfinalisedVideoTracking.swift
│   ├── V3_TagSystem.swift
│   ├── V4_DailyMetrics.swift
│   ├── V5_FTSUnicode61.swift
│   ├── V6_FrameProcessedAt.swift
│   ├── V7_FrameRedactionReason.swift
│   ├── V8_SegmentComments.swift
│   └── V9_SegmentCommentFrameAnchor.swift
├── Queries/
│   ├── AppSegmentQueries.swift
│   ├── AudioTranscriptionQueries.swift
│   ├── DailyMetricsQueries.swift
│   ├── DictationSessionQueries.swift
│   ├── DocumentQueries.swift
│   ├── FTSQueries.swift
│   ├── FrameQueries.swift
│   ├── NodeQueries.swift
│   └── SegmentQueries.swift
├── TestSupport/                  # Test-only C bridge for SQLite defensive configuration
│   ├── DatabaseTestSupport.c
│   └── include/DatabaseTestSupport.h
├── Tests/
│   ├── _future/
│   │   └── AudioTranscriptionQueriesTests.swift
│   ├── AsyncQueuePipelineTests.swift
│   ├── ActivityPersistenceTests.swift
│   ├── JobEventPersistenceTests.swift # Real SQLite live admission, exact replay/deletion, chronology, corruption and recovery
│   ├── LocalContextVisibilityTests.swift # Real SQLite visibility, policy capability, correction acknowledgement and query-plan gates
│   ├── ActivityScreenLinkTests.swift
│   ├── AudioOriginalSourceTests.swift # Real SQLite receipts, retirement, rollback, reset and reopen
│   ├── AudioEvidencePersistenceTests.swift # Separate committed SQLite readers, exact revisions, deletion, filters and bootstrap
│   ├── AudioRepairPolicyTests.swift
│   ├── AudioTranscriptionPaginationTests.swift
│   ├── DatabaseManagerTests.swift
│   ├── DictationSessionQueriesTests.swift
│   ├── EdgeCaseTests.swift
│   ├── FTSManagerTests.swift
│   ├── FramePipelinePersistenceTests.swift
│   ├── ResourceUsagePersistenceTests.swift # Real SQLite telemetry expiry, row cap and invalid metric rejection
│   ├── IntegrationTests.swift
│   ├── LegacyOCRBackfillPagingTests.swift
│   ├── OCRPipelineTests.swift
│   ├── CaptureGroupPersistenceTests.swift # Real SQLite begin, retries, membership, policy, rollback and deletion
│   ├── OriginalFrameAliasTests.swift # Atomic capture identity, rollback and deletion-before-map recovery
│   ├── CaptureTextPersistenceTests.swift # Real SQLite direct-text receipt admission, immutable OCR revisions and rollback
│   ├── QueryBuilderTests.swift
│   ├── ProgressivePersistenceTestAssertions.swift
│   ├── RecallReadConnectionTests.swift
│   ├── RecallSearchRevisionTests.swift
│   ├── RenderedRecallFixture.swift
│   ├── RetentionPersistenceTests.swift
│   ├── StructuredScreenObservationTests.swift # Real SQLite/Vision publication, geometry and legacy payloads
│   ├── ScreenEvidencePersistenceTests.swift
│   ├── ScreenEvidenceFeedPublicationTests.swift
│   ├── ScreenEvidenceFeedConsumerTests.swift
│   ├── ScreenEvidenceAdmissionTests.swift
│   ├── SemanticRecallPersistenceTests.swift
│   ├── SearchRevisionCompatibilityTests.swift
│   └── TestLogger.swift
├── DatabaseConfig.swift
├── AudioEvidencePersistence.swift # Owned read-only native transcript store, exact stamps and fixed-boundary bootstrap
├── ActivityPersistence.swift
├── JobEventPersistence.swift # Canonical bounded job writer, exact receipt resolution and policy-stamped chronology
├── LocalContextVisibility.swift # Bounded current hide predicates, activity feed mutation fence and live policy identity
├── ActivityScreenLinkPersistence.swift
├── DatabaseConnection.swift
├── DatabaseManager.swift
├── FTSManager.swift
├── CaptureGroupPersistence.swift  # Durable per-display attempts, exact admission and current-policy group reads
├── FramePipelinePersistence.swift
├── IDMappingService.swift
├── LegacyOCRBackfillPersistence.swift
├── RecallSearchRevisionHooks.swift
├── RetentionPersistence.swift
├── ScreenEvidencePersistence.swift
├── ScreenEvidenceFeedPublication.swift
├── ScreenEvidenceFeedConsumerPersistence.swift
├── ScreenEvidenceAdmissionPersistence.swift
├── SemanticRecallPersistence.swift
└── Schema.swift
```

## Protocols You Must Implement

### 1. `DatabaseProtocol` (from `Shared/Protocols/DatabaseProtocol.swift`)
- Frame CRUD operations
- Segment CRUD operations
- Document CRUD operations
- Statistics

### 2. `FTSProtocol` (from `Shared/Protocols/DatabaseProtocol.swift`)
- Full-text search queries
- Match counting
- Index maintenance

### 3. `ActivityStoreProtocol` and `EvidenceStoreProtocol` (from `Shared/Protocols/`)
- Independent metadata events, bounded feed pages and durable consumer checkpoints
- Confirmed correction outbox, revision conflicts, acknowledgement and append-only revoke
- Durable source/store UUIDs, immutable capture metadata and extraction revisions
- Source-qualified screen snapshot resolution and retained media-unavailable receipts

### 4. `ScreenEvidenceFeedStoreProtocol` (from `Shared/Protocols/`)
- V22 publishes native materialized observation revisions/tombstones and media/redaction state in existing writer transactions through ordinary-table triggers, including retained V21 writer paths.
- Stable feed/store identity and a retained floor fence durable leased cursors; bootstrap scans only materialized native keys through a fixed maximum, then replays intervening events.
- The database chooses and applies each bounded page, atomically recording event identities, separate lexical/vector work and checkpoint progress. Clients cannot acknowledge arbitrary sequences.
- Work contains only references/state and is blocked, invalidated or deleted; never ready. V23 adds a durable policy/source admission fence and quarantined result receipts, while index publication and readiness remain deferred.
- Rebootstrap changes the lease generation so old work is inaccessible immediately; compaction and expiry cleanup remain bounded. A compacted gap requires explicit rebootstrap.

### 5. `ScreenEvidenceAdmissionStoreProtocol` (Phase 2D gate 2)
- V23 adds an initially inactive feed/store-bound policy singleton and bounded derivation receipts without scanning retained evidence. Admission additionally requires the current DatabaseManager incarnation's local capability; persisted active state alone never authorizes a new writer.
- Begin/prepare create a fresh policy epoch. Activation requires the exact prepared token. Matching revoke/end closes local authority before SQL and stays closed on COMMIT failure; stale cleanup cannot close a newer owner or epoch. Admission requires a fully initialized writer and is fenced throughout asynchronous close/checkpoint retries. Duplicate close is refused before acquiring the fence; the owning close clears capability on every exit. Repeated end/revoke after close is harmless.
- Claim/stage/read use synchronous writer transactions to recheck exact native ref/preferred revision, V22 source sequence, leased consumer/channel work, retained and current metadata permissions, and a constant-size metadata epoch. Segment app/title/URL or frame-segment changes fence A→B→A; routine captures and initial dimension establishment do not increment that epoch. Native retained payload/preference guards preserve append-only extraction and tombstone deletion.
- Claims bind a writer-computed SHA256 manifest of the exact bounded Unicode expansion, retained payloads, block scope, ranges and provenance. They deliver no model input. One live attempt is allowed per consumer/observation/channel, with both wall and same-incarnation monotonic execution deadlines capped at 30 seconds. Platform clocks are sampled after the writer lock and again after canonical validation, before publication and after the bounded write; reads/retries recheck current consumer/retention expiry before returning. This is a logical admission check, not a physical fsync deadline guarantee.
- At most 256 attempt/receipt rows, 256 KiB per opaque artifact and 16 MiB total artifact bytes are retained. Policy/claim/receipt JSON is capped at 64 KiB. Completed identical retries may outlive execution deadlines, but receipt retention is at most 24 hours and every read still checks policy, source and consumer fences. Explicit cleanup removes at most 100 stale rows; native deletion erases associated artifact bytes in the same transaction.
- `ScreenEvidenceAdmissionTests.swift` exercises private SQLCipher files, real retained Vision input, policy/source/metadata ABA, forged handles, Unicode bounds, cancellation, deadline and COMMIT failures, capacity, defensive reopen, actor close/reinitialize and independent WAL checkpoint release. The initial 31 cases passed; two independent review regressions then reproduced stale clocks across real writer contention/canonical reads and admission during an actual checkpoint retry. After both fixes, all 33 admission tests passed in the integrated 82-test selection on 2026-09-17; full-suite validation remains separate. The DEBUG-only private-memory checkpoint switch exercises retry reentrancy without on-disk encryption preferences; it does not measure disk checkpoint timing.
- Quarantined bytes remain `stagedUnpublished`. They do not establish semantic correctness, resource/model scheduling permission or production index readiness; V22 channel states remain unready. Supported older native data writers are fenced by persistent ordinary-table triggers, but concurrent older processes cannot supply capture-policy ownership.

## Progressive recall persistence

`ActivityScreenLinkPersistence.swift` admits native image links only with matching captured session, process/window generations, display/document/pane identity and actual capture time. Timestamp proximity alone is insufficient. Reads page by feed sequence. A later committed activity boundary whose monotonic time predates the pixels invalidates an earlier association in the same transaction, redacts its old feed payload and appends a link tombstone while retaining the screen. Explicit activity/frame deletion uses the same append-only link deletion receipt.

`SQLiteConnection(readOnlyDatabasePath:)` owns an independent read-only handle with bounded busy timeout; `init(db:)` borrows its handle and never closes it. Search must use the owned reader in production so another actor cannot expose a partially committed extraction. V21 `recall_search_revision` triggers track identity and filtering changes within their original transactions. `RecallSearchRevisionHooks` installs TEMP FTS-content triggers on the canonical `DatabaseManager` connection through `MigrationRunner`, and on `FTSManager.initialize`; no FTS shadow trigger is persisted in the database schema. This preserves defensive SQLite reader compatibility and atomic revision updates for direct SQL through supported native writers. Arbitrary external native SQL writers are outside that contract. Activity, metrics, materialization and OCR status-only updates do not advance the stamp. Paged search checks it to detect concurrent changes explicitly.

`SearchRevisionCompatibilityTests` uses real disk databases to exercise defensive read-only reopen, two managed writer transactions, same-length edits, rollback and connection reopening. Its test-only `DatabaseTestSupport` C shim enables defensive mode through SQLite's variadic configuration API; Swift cannot safely call that API directly. Standalone pre-V21/empty FTS initialization remains supported, while a V21 writer missing its revision table fails initialization.

`commitFrameOCR` binds Processing's unassigned `FrameID(0)` text and regions to the requested persisted frame, and rejects a conflicting positive frame ID. Immutable snapshots retain the original capture metadata and every extraction revision. Actual Vision/queue integration validates this boundary, in addition to the focused SQLite tests.

Compatibility `insertDocument`, `updateDocument` and `indexFrameText` also publish a new immutable extraction inside the FTS transaction. Their flat text does not claim replacement geometry; old citations retain their original text. Canonical `deleteFrames(ids:)` keeps a selected native batch and all dependent cleanup in one transaction. The App adapter's separate reader cannot write, and imported stores must not be mutated through it.

`ActivityPersistence.swift` and additive V21 own native activity events, the resumable feed, consumer checkpoints and correction commands on the existing database actor. Event/feed/metrics and command/feed/metrics publication share synchronous short transactions. A repeated UUID is idempotent only for identical content. Session sequences are contiguous except explicit gap markers; monotonic session time cannot regress. Administrative markers omit captured context. Search applies time/app/text constraints before its bounded page and lookahead. Confirmation remains distinct from application: drafts are drafts, confirmed commands remain pending until an explicit acknowledgement, and stale targets/revisions produce conflicts. Annotation revisions refer to the local command projection until a companion writer is connected. Explicit activity deletion sanitizes dependent command and feed payloads and retains opaque tombstones.

`ScreenEvidencePersistence.swift` creates a durable native store UUID and capture-time observation UUIDs. Imported source identities are registered by bounded caller-supplied identity hashes; imported databases remain read-only. Native insertion stores original frame metadata, and `commitFrameOCR` appends an extraction in the same transaction as FTS, nodes and processing completion. Earlier revisions remain resolvable and never borrow newer text. Pixel dimensions are established from the linked video or the first verified materialization/OCR; they cannot later change. Block IDs are zero-based ordinals in main regions followed by chrome regions, not `TextRegion.id` hashes. Highlight proof requires coherent text and finite in-image pixel bounds; legacy materialization never claims highlight proof. V21 does not scan old frames or OCR at startup.

Frame deletion triggers remove all native snapshots and media receipts and create opaque tombstones inside the caller's deletion transaction, covering direct, retention and video-cascade routes without colliding with imported frame IDs. Missing/damaged media is a retained typed receipt plus failed processing status, not evidence deletion. Successful OCR clears that receipt. `ActivityPersistenceTests` and `ScreenEvidencePersistenceTests` exercise real SQLite commits, rollbacks, paging, revision retention, identity rejection, corrections, receipts and deletion.

## Capture and retention persistence

`FramePipelinePersistence.swift` owns atomic OCR publication, claim release and idempotent WAL recovery. `RetentionPersistence.swift` deletes bounded expired-frame batches and rechecks finalized, unreferenced video identity inside the same transaction as a guarded unlink callback. Never pass the SQLite pointer to App for deletion. No awaits are allowed inside these transactions.

`originalFrameDisposition` is a single-transaction, native-store-qualified release proof for retained original pixels. Completed status alone does not prove extraction: require a committed OCR snapshot (including durable blank OCR), current finalized archive identity and dimensions, or a canonical deletion tombstone. Unknown/mismatched stores remain pending. `getFrameWithVideoInfoByID` restores immutable capture display/context identity from the observation while retaining current archive links and current privacy metadata. `FramePipelinePersistenceTests` covers skip-versus-extraction, rollback, blank OCR, deletion and recovery remapping.

V24 records `(storeID, originalVideoPathID, sourceIndex)` aliases in the same transaction as new native capture. `insertCapturedFrame` owns that admission; do not split it into a generic insert plus an alias write. The deletion trigger retains a content-free tombstone even if a crash prevented filesystem frame-ID registration. `commitRecoveredFrames` rechecks and publishes aliases atomically so deletion during encoding cannot resurrect a source. Existing data is not backfilled or rewritten, and unqualified legacy journals are not automatically adopted.

V19 adds non-unique indexes for queue frame IDs, document IDs and video paths. Preserve existing records; duplicates are consolidated on enqueue/claim, not silently discarded by migration. Runtime retention does not vacuum the database. Frame IDs, app-segment IDs, database video IDs and storage path IDs are distinct.

`LegacyOCRBackfillPersistence.swift` performs bounded, resumable node-text maintenance. V20 creates only a one-row cursor/watermark table, without scanning/indexing OCR text. Check capacity first using at most the configured number of pending/claimed rows from the status index. Then read at most 1,000 nodes by `node.id` keyset before filtering and enqueue at most 100 frames. Freeze each sweep's upper node ID with a one-row primary-key endpoint lookup, so ongoing captures cannot indefinitely postpone earlier revisits. Persist only the last inspected node when a batch fills. Cursor, watermark, queue and status changes share one synchronous cancellable transaction; old nodes and FTS remain until OCR replacement. An empty batch means no work enqueued this tick, not global completion. Never restore exact whole-library candidate counts or a filtered/sorted full-table query with a final LIMIT. `LegacyOCRBackfillPagingTests` checks real SQLite VM steps, query plans, sparse pages, restart, growing-tail revisits, capacity, rollback and readable text preservation.

OCR selection has three lanes: manual priorities above 10 always lead; automatic priorities 1–10 are current only while their frame capture is no older than 60 seconds; expired automatic, zero, negative and legacy NULL priorities share historical FIFO by enqueue time and queue ID. After three current claims, give history a turn when available. Manual claims preserve the fairness counter; historical claims reset it even when their stored priority is positive. Aging affects selection only and must not rewrite timestamps or recorded priority. A released/deferred claim rejoins the FIFO tail with its retry metadata.

Keep claim selection inside its atomic transaction and mutate the fairness counter only after commit. Use the existing priority index for manual/current selection and enqueue-time index for history, with queue-driven frame primary-key lookups; do not add a migration or scan/sort the full frame table. `FramePipelinePersistenceTests` traces actual claim SQL and validates its SQLite plans. Queue-position estimates use the same lanes and fairness budget, count distinct pending frames and exclude claimed/completed rows; new arrivals and age changes can alter the displayed estimate.

## Active schema and access rules

- `video` stores encoded container paths; `segment` stores app/window sessions; `frame` links both. IDs are integer database keys, distinct from numeric storage filenames.
- `node` stores OCR bounds and raw text. `doc_segment` links frame/session IDs to the `searchRanking` FTS5 table. `processing_queue` holds durable OCR work.
- `DocumentQueries` implements legacy document CRUD against these canonical FTS/link tables; there is no separate `documents` table. Metadata comes from the source frame/session, and duplicate insertion requires an explicit update instead.
- Explicit frame deletion cleans OCR nodes, queue work and search links atomically, preserving documents with surviving frame/session links and detaching user-comment frame anchors. Public video deletion includes its associated frames in the same transaction. Storage filename IDs must never be passed as database video IDs.
- Audio/transcript, tags, comments, daily metrics and dictation tables are already active. Inspect `Schema.swift` and ordered migrations for column definitions rather than copying historical schema sketches.
- `DatabaseManager` owns its SQLite connection on an actor. Use prepared statements and bound parameters. Concrete transaction helpers must not suspend while owning a write transaction.
- Dates in frame/session records use `Schema.dateToTimestamp` (milliseconds). Queue enqueue timestamps remain the existing seconds representation; do not mix units.
- Keep `DatabaseProtocol` and Shared types authoritative for cross-module operations. Test migrations and queries against real temporary SQLCipher databases.

## Error Handling

Use errors from `Shared/Models/Errors.swift`:
```swift
throw DatabaseError.queryFailed(query: sql, underlying: errorMessage)
throw DatabaseError.connectionFailed(underlying: errorMessage)
```

## Testing Strategy (TDD Philosophy)

### Core Principles

**Test-Driven Development (TDD)** is mandatory for this module. The goal is to have such comprehensive tests that you can confidently deploy based solely on tests passing—no manual inspection needed.

**The TDD Cycle:**
```
1. Write failing test (RED)
2. Write minimum code to pass (GREEN)
3. Refactor (REFACTOR)
4. Repeat
```

### Test Categories

We maintain 6 categories of tests, each serving a specific purpose:

#### 1. Schema Validation Tests (`SchemaValidationTests.swift`)
**Purpose:** Verify all SQL statements in `Schema.swift` compile correctly.
**What they catch:** Typos, syntax errors, missing commas, invalid SQL.

```swift
func testCreateFramesTable_IsValidSQL() {
    assertValidSQL(Schema.createSegmentsTable)
    assertValidSQL(Schema.createAppSessionsTable)
    assertValidSQL(Schema.createFramesTable)  // Depends on above
}
```

#### 2. Migration Tests (`MigrationTests.swift`)
**Purpose:** Verify migrations run correctly and create expected schema.
**What they catch:** Migration ordering issues, missing tables/indexes/triggers.

```swift
func testV1Migration_CreatesAllCoreTables() async throws {
    let runner = MigrationRunner(db: db!)
    try runner.runMigrations()
    XCTAssertTrue(tableExists("frames"))
}
```

#### 3. Query Builder Tests (`QueryBuilderTests.swift`)
**Purpose:** Unit test individual query builder methods in isolation.
**What they catch:** SQL bugs, parameter binding errors, parsing issues.

#### 4. Edge Case Tests (`EdgeCaseTests.swift`)
**Purpose:** Test boundary conditions, null handling, special characters.
**What they catch:** Bugs that only appear with unusual inputs.

- Empty database queries (should return nil/empty, not crash)
- Null/optional fields stored and retrieved correctly
- Unicode, emoji, special characters
- SQL injection attempts (should be stored literally, not executed)
- Very long content
- Boundary timestamps (exact start/end, 1ms outside)
- Zero limits, huge offsets
- Duplicate ID handling

#### 5. Integration Tests (`IntegrationTests.swift`)
**Purpose:** Test complete workflows end-to-end.
**What they catch:** Module interaction bugs, cascade issues.

```swift
func testFullCaptureToSearchFlow() async throws {
    // 1. Create segment (simulate capture)
    // 2. Create frame with metadata
    // 3. Index document (simulate OCR)
    // 4. Search and find content
}
```

#### 6. FTS Manager Tests (`FTSManagerTests.swift`)
**Purpose:** Test full-text search functionality.
**What they catch:** Search bugs, ranking issues, filter problems.

### Writing New Tests

When adding any new feature, ALWAYS write the test first:

```swift
// 1. Write test (will fail - method doesn't exist)
func testNewFeature() async throws {
    let result = try await database.newMethod()
    XCTAssertEqual(result, expectedValue)
}

// 2. Run test → RED (fails)
// 3. Write minimum code to pass
// 4. Run test → GREEN (passes)
// 5. Refactor if needed
```

### Test File Structure

```
Database/Tests/
├── AudioTranscriptionPaginationTests.swift # Audio transcript paging queries
├── SchemaValidationTests.swift    # SQL syntax validation
├── MigrationTests.swift           # Migration execution
├── QueryBuilderTests.swift        # Query builder unit tests
├── EdgeCaseTests.swift            # Boundaries, nulls, errors
├── IntegrationTests.swift         # End-to-end workflows
├── DatabaseManagerTests.swift     # Manager-level tests
└── FTSManagerTests.swift          # Search tests
```

### Running Tests

```bash
swift test                                    # All tests
swift test --filter SchemaValidationTests    # Specific file
swift test --filter testFullCaptureToSearchFlow  # Specific test
```

### Test Checklist Before Deploying

- [ ] All schema SQL compiles
- [ ] Migration creates all tables/indexes/triggers
- [ ] Foreign keys enforced, cascades work
- [ ] Null fields handled correctly
- [ ] Unicode/special chars work
- [ ] SQL injection prevented
- [ ] Empty database queries don't crash
- [ ] Search finds correct content
- [ ] Search filters work
- [ ] Statistics accurate
- [ ] Concurrent access safe

## Dependencies

- **Input from**: PROCESSING module (ExtractedText to index)
- **Output to**: SEARCH module (FTSMatch results)
- **Uses types**: `FrameID`, `SegmentID`, `FrameReference`, `VideoSegment`, `IndexedDocument`, `FTSMatch`, `SearchFilters`

## DO NOT

- Modify any files outside `Database/`
- Import from other module directories (only `Shared/`)
- Create custom types that duplicate `Shared/Models/`
- Use Core Data or other ORMs—use SQLite directly
- Store binary data (images/video) in the database

## Performance Targets

- Insert: <5ms per frame
- Search: <100ms for typical queries
- Database size: <500MB per month of metadata
- Support 1M+ documents efficiently

## Historical schema proposal (not the active schema)

The following is retained as design history only. Active audio tables are already implemented; use `Schema.swift` and V1–V20 migrations as the source of truth. These proposed table names, size forecasts and Intel assumptions do not describe the current product.

### Original V3 proposal

### New Tables

#### 1. `app_sessions` - Application Focus Tracking

Tracks periods where a specific application had focus, similar to Rewind's "segment" concept.

```sql
CREATE TABLE app_sessions (
    id TEXT PRIMARY KEY,
    app_bundle_id TEXT NOT NULL,
    app_name TEXT,
    window_title TEXT,
    browser_url TEXT,
    display_id INTEGER,
    start_time INTEGER NOT NULL,
    end_time INTEGER,                    -- NULL = still active
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);
```

**Why?**: UI needs to group frames by app session for timeline visualization. Without this, you'd have to scan all frames to determine session boundaries.

**Usage**: When app focus changes, close current session and create new one. Link frames to sessions for efficient queries like "show all Chrome usage today."

#### 2. `encoding_queue` - Async Encoding Jobs

Manages asynchronous frame encoding pipeline for both Intel (CPU) and Apple Silicon (hardware).

```sql
CREATE TABLE encoding_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id TEXT NOT NULL UNIQUE,
    priority INTEGER DEFAULT 0,
    retry_count INTEGER DEFAULT 0,
    error_message TEXT,
    status TEXT DEFAULT 'pending',       -- pending, encoding, success, failed, cancelled
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000),
    updated_at INTEGER DEFAULT (strftime('%s', 'now') * 1000),
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);
```

**Why?**: Encoding can be slow on Intel Macs. Async processing prevents blocking capture thread.

**Workflow**:
1. Frame captured → insert into `frames` with `encoding_status='pending'`
2. Add job to `encoding_queue` with priority
3. Background worker picks up job, encodes, updates status to 'success'
4. On failure, increment `retry_count` and requeue

#### 3. `deletion_queue` - Async Cleanup

Implements deferred deletion for responsive UI (inspired by Rewind's `purge` table).

```sql
CREATE TABLE deletion_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entity_type TEXT NOT NULL,            -- 'frame', 'segment', 'document', 'app_session'
    entity_id TEXT NOT NULL,
    file_path TEXT,                       -- Video file to delete (if applicable)
    created_at INTEGER DEFAULT (strftime('%s', 'now') * 1000)
);
```

**Why?**: Deleting large video files blocks UI. Queue deletions for background processing.

**Workflow**:
1. User clicks delete → queue entity in `deletion_queue`
2. UI immediately hides entity (responds instantly)
3. Background job on next app launch:
   - Delete SQLite rows
   - Delete video files from disk
   - Remove from queue

### Updated Tables

#### `segments` - Added Dimensions

```sql
ALTER TABLE segments ADD COLUMN width INTEGER NOT NULL;
ALTER TABLE segments ADD COLUMN height INTEGER NOT NULL;
ALTER TABLE segments ADD COLUMN source TEXT DEFAULT 'native';
```

**Why?**: Multi-monitor setups have different resolutions. Need to know dimensions for proper video playback and timeline scrubbing.

#### `frames` - Added Encoding Status and Session Link

```sql
ALTER TABLE frames ADD COLUMN encoding_status TEXT DEFAULT 'pending';
ALTER TABLE frames ADD COLUMN session_id TEXT REFERENCES app_sessions(id) ON DELETE SET NULL;
ALTER TABLE frames ADD COLUMN source TEXT DEFAULT 'native';
```

- `encoding_status`: Track async encoding pipeline state
- `session_id`: Link frame to app session for efficient grouping
- `source`: Distinguish native captures from imported data (`'native'`, `'rewind'`, `'screen_memory'`, etc.)

**Note**: Removed `duration_ms` - it was always 2000ms (fixed capture rate). Can derive from timestamp gaps if needed.

### Migration Strategy

Existing databases (V1/V2) will automatically upgrade via migrations:
- V2: Add `source` column (for third-party import support)
- V3: Add dimensions, encoding_status, session_id, new tables

New installations get V3 schema immediately (no migrations needed).

### Indexes

Critical indexes for performance:

```sql
-- App sessions
CREATE INDEX idx_app_sessions_time ON app_sessions(start_time, end_time);
CREATE INDEX idx_app_sessions_app ON app_sessions(app_bundle_id);

-- Encoding queue
CREATE INDEX idx_encoding_queue_status ON encoding_queue(status, priority DESC);

-- Deletion queue
CREATE INDEX idx_deletion_queue_type ON deletion_queue(entity_type);

-- Frames (updated)
CREATE INDEX idx_frames_session ON frames(session_id);
CREATE INDEX idx_frames_encoding_status ON frames(encoding_status);
CREATE INDEX idx_frames_source ON frames(source);
```

### Junction Tables - Critical at 40GB+ Scale

#### `document_sessions` - Fast Search Filtering

**The Problem**:
```sql
-- Slow query (3 JOINs on millions of rows)
SELECT d.*, f.*, s.*
FROM documents_fts
JOIN documents d ON d.id = documents_fts.rowid
JOIN frames f ON f.id = d.frame_id
JOIN app_sessions s ON s.id = f.session_id
WHERE documents_fts MATCH 'error'
  AND s.app_bundle_id = 'com.google.Chrome';
```

At Rewind's 26 MB/hour text growth rate, you'd have **~18 million documents** after a year. Those JOINs are brutal.

**The Solution**:
```sql
CREATE TABLE document_sessions (
    document_id INTEGER NOT NULL,
    session_id TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    PRIMARY KEY (document_id, session_id),
    FOREIGN KEY (document_id) REFERENCES documents(id) ON DELETE CASCADE,
    FOREIGN KEY (session_id) REFERENCES app_sessions(id) ON DELETE CASCADE
);
```

**Fast Query** (pre-joined, indexed lookup):
```sql
SELECT d.*, s.*
FROM documents_fts
JOIN documents d ON d.id = documents_fts.rowid
JOIN document_sessions ds ON ds.document_id = d.id
JOIN app_sessions s ON s.id = ds.session_id
WHERE documents_fts MATCH 'error'
  AND s.app_bundle_id = 'com.google.Chrome';
```

Avoids scanning `frames` table (largest table) entirely.

**Maintenance**: Populate when indexing documents:
```sql
INSERT INTO document_sessions (document_id, session_id, timestamp)
SELECT d.id, f.session_id, d.timestamp
FROM documents d
JOIN frames f ON f.id = d.frame_id;
```

#### `session_segments` - Efficient Video Retrieval

Links app sessions to video segments for fast playback.

**Why needed**:
- One session can span multiple 5-minute video segments
- One video segment can contain multiple app sessions (e.g., switching apps mid-segment)
- Many-to-many relationship requires junction table

**Usage**: "Play video of all Chrome usage between 2-3pm"
```sql
SELECT DISTINCT seg.*
FROM app_sessions s
JOIN session_segments ss ON ss.session_id = s.id
JOIN segments seg ON seg.id = ss.segment_id
WHERE s.app_bundle_id = 'com.google.Chrome'
  AND s.start_time BETWEEN ? AND ?;
```

Without this, you'd have to:
1. Find all frames in time range + app filter
2. Group by segment_id
3. Load each segment

With junction table: direct segment lookup.

#### `text_regions` - OCR Bounding Boxes

Stores spatial coordinates of detected text (inspired by Rewind's `node` table).

```sql
CREATE TABLE text_regions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    frame_id TEXT NOT NULL,
    text TEXT NOT NULL,
    x INTEGER NOT NULL,
    y INTEGER NOT NULL,
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    confidence REAL,
    FOREIGN KEY (frame_id) REFERENCES frames(id) ON DELETE CASCADE
);
```

**Critical for UI**: Click search result → jump to exact location on frame with highlighting.

**Storage cost**: ~150GB (200 bytes × 50 regions/frame × 15M frames). Worth it for professional UX.

#### `audio_captures` - Speech-to-Text (Future)

Scaffolding for audio transcription (Zoom/Meet/Teams).

```sql
CREATE TABLE audio_captures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT,
    text TEXT NOT NULL,
    start_time INTEGER NOT NULL,
    end_time INTEGER NOT NULL,
    speaker TEXT,
    source TEXT,                    -- 'zoom', 'system', 'microphone'
    confidence REAL,
    FOREIGN KEY (session_id) REFERENCES app_sessions(id) ON DELETE SET NULL
);
```

**Not implemented yet** - schema ready for v2 feature.

### Key Design Decisions

1. **App Sessions separate from Frames**: Cleaner queries, mirrors Rewind's architecture
2. **Junction tables**: **Critical for 40GB+ databases** - avoids expensive JOINs at query time
3. **Text regions**: **150GB storage** but essential for click-to-zoom UI
4. **Audio captures**: Future-proof for speech-to-text (v2)
5. **Async encoding**: Supports both Intel (slow) and Apple Silicon (fast) without blocking
6. **Deferred deletion**: Responsive UI, safe cleanup on next launch
7. **Source column**: Import Rewind/ScreenMemory/TimeScroll data
8. **Dimensions in segments**: Multi-monitor support

### Performance at Scale

With junction tables and proper indexes:
- **Search with app filter**: <100ms (vs 5-10s without junction tables)
- **Video segment lookup**: <10ms (vs 1-2s scanning frames)
- **Database size**: ~500MB metadata/month + ~150GB text regions + ~50MB junctions

Trade-off: Slightly more complex writes (populate junction tables + text regions), but **massive** read speedups and professional UI.

### Structured screen observations (Phase 2)

Canonical OCR commits append immutable optional structured payloads through `ScreenEvidencePersistence`; they retain original main-then-chrome block ordinals, exact flat-text parity, UTF16 channel ranges, frame-pixel geometry and explicit unknown block ownership. Incoherent legacy text remains an unstructured channel with no fabricated highlights. Old JSON decodes without rewriting retained revisions or requiring a schema migration. Chrome-only text must enter FTS just as main text does. `StructuredScreenObservationTests` uses real SQLite publication and rendered JPEG/Vision input; expansion itself remains a currently authorised service read with per-page access checks.

## Capture groups (candidate)

V26 does not group legacy or imported frames by time proximity. A native begin requires the current in-memory writer/active policy before every acknowledgement, including retries. It inserts every target atomically before native pixels. Each display retains its own attachment, attempt and real pixel interval. Sampling completion is separate from media admission; suppressed samples name an exact older attempt and keep that earlier evidence time. Missing, dropped, cancelled, deleted, excluded and interrupted members remain explicit.

Fresh frame/alias admission requires the same active writer and epoch. Recovery may finish a durable exact candidate after writer restart, but can never rebind a member or revive a deletion. Failed fresh admission does not invoke recovery in the live loop. Read stamps include the journal revision, source and privacy/metadata fences; UI refreshes pinned groups before display navigation. The independent SCK-only switch defaults off. Journal bytes/day, physical capture and installed performance acceptance remain unmeasured; source tests do not establish promotion. Private in-memory database initialization no longer probes the user's Rewind archive.

### Typed native semantic persistence (V25)

`SemanticRecallStoreProtocol` is a separate typed local index. V22 work remains blocked and V23 receipts remain unpublished. V25 uses the same canonical input projector and current actor-owned admission capability, with independent durable coalesced source-state and fixed-boundary historical cursors. Fresh work precedes historical page continuation. A page is at most 4096 text bytes and 64 fragments; claim deadlines use wall and monotonic clocks, and publication revalidates source/revision/policy/metadata/input identity in one non-suspending transaction. Window ranges retain exact fragment/channel UTF16 spans and pinned model/projection identity; finite unit Float32 vectors are 384 dimensions. Incomplete observations never enter retrieval. Capture-before-OCR is distinct from an actually empty extraction.

Source changes synchronously remove affected derivatives; context changes reset affected work, policy changes clear derivatives and reset coverage. Segment context invalidation starts from retained semantic documents and uses frame primary-key lookups, so unindexed legacy history is not enumerated; its work still scales with retained semantic documents and needs active-corpus profiling. Durable vectors survive writer restart only behind fresh active authority and current canonical checks. Time/app constraints, app exclusions, hidden-segment filters and current policy precede inspection/output limits; tag/visibility changes invalidate read generations without re-embedding; bounded reads return explicit continuation and a generation stamp that must be revalidated after ranking. Queue caught-up status is not complete coverage when observations were skipped. The index does not cover imports, audio, unmaterialized legacy text or direct AX text independently. App owns content-free worker/query metrics and native runtime lifecycle.

`SemanticRecallPersistenceTests.swift` exercises real private SQLCipher, canonical capture/extraction publication, authored pinned MiniLM vectors, 10k-observation fresh preemption, durable page continuation, empty/pre-OCR distinction, source/policy/metadata invalidation, selective context-byte/claim purge and rollback behind 3,000 unindexed frames, read fences, filters and malformed vector/span rejection. The authored vector oracle is the repository Search fixture; tests never load a model or live history. Swift endpoint execution and installed quality/performance acceptance remain separate from source and isolated SQL-trigger checks.

Local context visibility uses the canonical active V23 capability and policy epoch, current hidden tag name, and confirmed non-revoked selection/document hide semantics. V27 adds only the partial expression indexes needed to avoid scanning correction history. The activity feed sequence fences acknowledgement changes that activity health alone cannot detect. No context summary, model activation, job claim or audio authority is stored here.

V28 records the original declared audio source in the raw-row INSERT statement. Its immutable alias survives only explicit processing retirement; ordinary raw/transcript deletion retains a path tombstone and invalidates refinement. Legacy adoption inspects at most two original raw rows using the partial path index. No old pass-one row is treated as original proof, because pipeline reset/restamping loses that distinction. Guarded publication checks the native store, recording identity and mutation generation while holding the serialized connection's recursive SQLite mutex; it refuses an already-open transaction and never awaits while locked. Guarded publication checks caller cancellation after acquiring connection ownership and again before COMMIT, rolling back rows, receipt generation and success metrics together. Failure metrics remain independently writable by a cancelled owning task. The bounded inspection endpoint seeks the existing pass/row-ID index before LIMIT and returns ineligible rows without candidate paths so the manager always advances. It grants no source proof; a 10,000-row VM-step/query-plan regression guards against regrouping the whole prefix. These new methods do not repair every legacy borrowed-pointer transaction. `AudioOriginalSourceTests` and Processing's `AudioRefinementSourceTests` require actual SQLite/AAC; the receipt establishes no consent, app attribution, canonical transcript revision or searchable audio coverage.

`JobEventPersistence.swift` and V29 retain categorical explicit-command observation receipts, with no command text, arguments, path or output. Starts require the current in-memory V23 and job writer capabilities plus the exact App-owned master-generation admission. Terminal success/failure requires the same current policy; only content-free interruption may drain an already-admitted run after revocation. Eight unfinished runs are bounded; a new owner records pending old runs as interrupted without inventing completion time. Immutable exact references, validated retained policy hash/phase and job-state revision fence local resolve/keyset pages even while recording is paused; retained identity never restores writer capability; deletion tombstones deny replay. Receipt and categorical daily_metrics writes are atomic. `JobEventPersistenceTests.swift` uses private real SQLite; source review and native execution remain distinct.

### Exact native audio evidence

V30 keeps ordinary legacy transcript rows intact and stores at most one current immutable text snapshot per native row. Retained row aliases prevent deleted IDs from being rebound. INSERT/UPDATE/DELETE triggers call one transaction-local materializer; its request row is consumed before the original statement completes. V28 invalidation/tombstones purge every copied transcript in that lineage. An intentional raw-placeholder retirement preserves surviving transcript identity. Preferred-pass changes invalidate prior references without substituting text. Source proof means only the original declared recording source, never capture consent, app ownership, exclusions, ASR accuracy or verified media.

`DatabaseManager.makeAudioEvidenceStore()` owns a separate read-only native connection and preserves the native encryption key policy. It rejects a borrowed writer handle. The reader lifetime is bound to the owning database's generation, which changes before any close suspension. Joined reader close waits for admitted calls/awaited categorical attempt metrics; no later call can emit. After every owner/metric suspension, one final canonical read checks the mutation stamp and exact references before text escapes. App still owns the independent local-history policy/source fence.

Search inspects at most 512 descending native row IDs before filling at most 50 results; exact source/date/provenance checks precede the result limit. It uses safely quoted literal FTS phrases and bounds copied text to 64 KiB per row and 256 KiB per page. Excerpts preserve composed Unicode boundaries within 512 UTF16 units. Cursors bind query/filter identity, reader lifetime and mutation revision. App/window/URL/tag/comment/only-hidden/multiple-date filters and requested capture-policy attestation fail explicitly when unsupported. Coverage describes proven native transcripts and that bounded scan only. Media stays `notVerified`; no path, frame identity or word timing is invented.

`advanceAudioEvidenceBootstrap` inspects at most 128 row IDs toward the fixed migration boundary. Fresh mutations register independently, and gaps/unavailable lineages still advance historical progress. Source-less legacy rows are never relabelled/adopted from a refined pass. Later source adoption alone does not imply a previously unavailable alias has a text snapshot; fresh mutations or explicit historical registration are still required. The source state and current row are always rechecked. VM progress budgets bound new read/write transactions and do not await while holding SQLite's recursive FULLMUTEX. Test and SQL receipts are scoped evidence, not installed playback/privacy/latency acceptance.

### Pending ambient audio (V31)

`audio_pending_raw_id` is a partial ID index for first-pass pending raw recordings. Recovery seeks at most 16 rows per live-worker page through this index; it never sorts the complete backlog. Capture-time `capture_probable_silence` is a scheduling hint only. Within each bounded page, three speech/unknown candidates precede one silence candidate when both are available; this is not global speech ordering or a reason to discard media. A joined 30-second worker wake retries exhausted failed sweeps. First-pass sentence publication and intentional raw retirement share one original-source-guarded, cancellation-checked transaction; no-text outcomes use the same source and pending-row fences. Private SQLite tests cover rollback, replay, stale/cancelled outcomes and a 10,000-row query-plan/VM-step bound.

### Exact chunk audio registration (V32)

`AudioChunkMediaPersistence.swift` registers immutable ten-second AAC chunk receipts and overlapping logical window ranges through `AudioTranscriptionQueries.registerRawAudioWindow`. The explicit `chunkWindowV1` discriminator and `.retraceaudio` namespace never impersonate legacy `batch_*.m4a` media. Native store identity, bounded manifests, source, contiguous ranges, non-overlapping chunk ownership and exact replay are checked before one mutex-guarded transaction publishes the pending row, V28 source lineage, chunk receipts and window references. Chunk descriptors are stored once; normalized ranges reuse them. Replays after raw retirement return the original raw identity without recreating work. Deleted/conflicting identities remain unavailable.

Current window registration is revalidated inside first-pass and source-guarded refinement commits. Sentence rows must reference the registered window and remain within its newly owned interval; predecessor context cannot be published twice. Pending/repair queries admit registered active windows explicitly while retaining legacy files. `AudioTranscription.evidenceReference` is populated for registered media only after all returned transcript evidence fields match a current V30 snapshot. `NativeAudioEvidenceStore.readAudioMedia` returns the exact snapshot, window and read stamp, then rechecks revision and registration after awaited owner/metric callbacks. This is a database mapping, not a claim that AAC bytes have been verified; Storage independently verifies media and owns reader leases.

Existing raw/transcript deletion and original-source tombstones invalidate window access transactionally. Immutable chunk/window/range receipts are retained and no filesystem cleanup or historical conversion occurs. `AudioChunkMediaPersistenceTests.swift` uses actual AAC receipts from Storage plus private SQLite for shared-chunk registration, replay/restart, late-write rollback, ownership bounds, manifest conflicts, stale references, deletion during reads, independent successor visibility and immutable metadata guards.

`isAudioWindowCanonicallyDeleted` compares the exact retained window, chunk descriptors, ranges and manifest digest and requires its committed original-source tombstone. It permits recovery to acknowledge a leftover publication journal after deletion without resurrecting pending work. It grants no filesystem deletion authority; physical media stays retained.
