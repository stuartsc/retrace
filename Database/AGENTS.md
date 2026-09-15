# DATABASE Agent Instructions

You are responsible for the **Database** module of Retrace. Your job is to implement SQLite database operations including schema, migrations, CRUD operations, and full-text search indexing.

**Status**: ✅ Core tables fully implemented (segments, frames, searchRanking FTS5). Uses SQLCipher for optional encryption and Rewind database import compatibility. Audio capture/transcription tables, contextual refinement tracking, daily metrics, and dictation session history are active. **Advanced tables not yet implemented** (app_sessions, encoding_queue, junction tables - planned for future release).

## Your Directory

```
Database/
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
│   ├── ActivityScreenLinkTests.swift
│   ├── AudioRepairPolicyTests.swift
│   ├── AudioTranscriptionPaginationTests.swift
│   ├── DatabaseManagerTests.swift
│   ├── DictationSessionQueriesTests.swift
│   ├── EdgeCaseTests.swift
│   ├── FTSManagerTests.swift
│   ├── FramePipelinePersistenceTests.swift
│   ├── IntegrationTests.swift
│   ├── LegacyOCRBackfillPagingTests.swift
│   ├── OCRPipelineTests.swift
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
│   ├── SearchRevisionCompatibilityTests.swift
│   └── TestLogger.swift
├── DatabaseConfig.swift
├── ActivityPersistence.swift
├── ActivityScreenLinkPersistence.swift
├── DatabaseConnection.swift
├── DatabaseManager.swift
├── FTSManager.swift
├── FramePipelinePersistence.swift
├── IDMappingService.swift
├── LegacyOCRBackfillPersistence.swift
├── RecallSearchRevisionHooks.swift
├── RetentionPersistence.swift
├── ScreenEvidencePersistence.swift
├── ScreenEvidenceFeedPublication.swift
├── ScreenEvidenceFeedConsumerPersistence.swift
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
- Work contains only references/state and is blocked, invalidated or deleted; never ready. No OCR copies, worker loop, model, permission grant or index-readiness acceptance is introduced. Future acceptance requires a durable capture-policy/source fence; current configuration reads are not that fence.
- Rebootstrap changes the lease generation so old work is inaccessible immediately; compaction and expiry cleanup remain bounded. A compacted gap requires explicit rebootstrap.

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
