# Retrace — Data Capture & Access Reference

This document describes what Retrace records and how external agents or scripts can read the captured data.

Schema and release status are separate. On **2026-09-18**, **0.7.6 (2609.18.1)** was installed and launched hidden for an unreleased local trial; read-only inspection verified its native database upgraded from **V21 to V23**, preserved its store identity and resumed capture. The previous app and a verified database copy from before the upgrade are retained for rollback. V22 feed and V23 admission are installed, but no automatic consumer, model worker or semantic index is enabled. See the [local-trial record](progressive-recall-validation.md#local-trial-2609181--2026-09-18) for verification and acceptance limits. Inspect the selected database's schema before using a query; imported sources can have older schemas.

## What the app records

### 1. Screen captures (every 2 seconds)
- **Source**: `CGWindowListCreateImage` (not ScreenCaptureKit)
- **Frame dedup**: ~95% filtered by perceptual hash before storage
- **Storage**: HEVC-encoded MP4 files at `~/Library/Application Support/Retrace/chunks/YYYYMM/DD/<storageID>`; native files have no extension
- **Metadata per frame**: app bundle ID, window title, browser URL (when applicable)
- **OCR text**: extracted via Apple Vision; native V18+ stores region text with bounding boxes in `node`, and searchable document text in FTS5

### 2. Microphone audio (continuous)
- **Source**: `AVCaptureSession` (mic is shared — other apps can use it simultaneously)
- **Raw batches**: 30-second chunks as `batch_*.m4a` files
- **Transcript playback**: sentence timings in SQLite point into canonical batch recordings; retained legacy `sentence_*.m4a` clips remain supported
- **Storage path**: `~/Library/Application Support/Retrace/audio/YYYY/MM/DD/`
- **Transcription**: whisper.cpp with 3-pass refinement pipeline (pass 1 = small/greedy, pass 2 = turbo/beam, pass 3 = contextual with neighboring batch text as `initial_prompt`)

### 3. Metadata / derived data
- **App usage stats** per bundle ID, per day (in `daily_metrics`)
- **Segment boundaries** (when foreground app/window changes)
- **Tags**, comments, recording sessions

---

## Where everything lives

| Data | Path |
|------|------|
| Database | `~/Library/Application Support/Retrace/retrace.db` (SQLite, FTS5-indexed, NOT encrypted by default) |
| SQLite sidecars | Adjacent `retrace.db-wal` and `retrace.db-shm`, and `retrace.db-journal` if present |
| Video files | `~/Library/Application Support/Retrace/chunks/YYYYMM/DD/<storageID>` — extensionless HEVC MP4 files |
| Audio files | `~/Library/Application Support/Retrace/audio/YYYY/MM/DD/` — AAC `.m4a` |
| Capture recovery journals | `~/Library/Application Support/Retrace/wal/`, including `active_segment_*` directories and quarantine |
| Preferences | `~/Library/Preferences/io.retrace.app.plist` (use a defaults export for a retained settings copy) |
| Logs | `~/Library/Logs/Retrace/retrace.log` (tail with `tail -f` for live events) |

These are default native paths. `customRetraceDBLocation` in the `io.retrace.app` preferences can select another root. Resolve the active root before accessing files. Rewind sources use a separate root, by default `~/Library/Application Support/com.memoryvault.MemoryVault`, and remain read-only.

---

## Key tables (read-only SQL access)

### `frame`
One row per captured screenshot.
```
id, createdAt (unix ms), segmentId, videoId, videoFrameIndex, encodingStatus, processingStatus
```
Join to `video` for file path, to `segment` for app/window context.

### `segment`
Groups of frames sharing the same foreground app + window.
```
id, bundleID, windowName, browserUrl, startDate, endDate, type
```
Note: column names are `startDate` / `endDate` (not `startTime` / `endTime`). Values are unix milliseconds.

### `video`
File metadata for HEVC segments.
```
id, path (relative to the native storage root), frameRate, width, height, frameCount, processingState
```
Native `path` already includes `chunks/` and names the media file itself. `processingState = 0` means finalized; `1` means still being written. `videoFrameIndex / frameRate` is a requested sample time, not proof that a decoder returned that sample. The exact-evidence encoded path requires finalized media with matching source/file identity, returned timestamp and dimensions. Native unfinalized captures can instead use an exact journal mapping with verified frame identity, timestamp, dimensions and display. Neither path permits an unavailable or neighbouring image to be substituted.

### `node`
OCR regions per frame. Native migration V18 added nullable `text`; new OCR writes preserve each region's text directly. Older rows can still have null text and offset-based references into a document's current FTS content.
```
id, frameId, nodeOrder, textOffset, textLength, leftX, topY, width, height, windowIndex, text
```
Columns are `leftX` / `topY` (not `x` / `y`). There is no `confidence` column on `node`. Check `PRAGMA table_info(node)` before selecting `text` from an imported or pre-V18 source.

Read retained region text on a native V18+ source:
```sql
SELECT n.id, n.leftX, n.topY, n.width, n.height, n.text
FROM node n
WHERE n.frameId = ?
ORDER BY n.nodeOrder;
```
Null region text is a legacy limitation. The app's compatibility reader joins through `doc_segment.docid` to `searchRanking_content`, combines its `c0` and `c1` text and applies bounded Swift string offsets. A generic SQLite `substr(searchRanking.text, ...)` is not equivalent for all legacy text or Unicode. Current nodes and mutable FTS content do not identify a retained historical extraction revision or establish verified highlights.

### `doc_segment`
Link table between FTS5 docs and frames/segments.
```
docid, segmentId, frameId
```
Use this to map a `searchRanking.rowid` (= `docid`) back to the frame/segment it was indexed from.

### `searchRanking` (FTS5 virtual table)
Screen/document full-text index. Columns: `text`, `otherText`, `title`. Use `MATCH` for search. `rowid` joins to `doc_segment.docid`. Native audio transcription uses the separate `audio_captures_fts` index.

### `audio_captures`
Audio transcription records.
```
id, session_id, text, start_time (unix ms), end_time (unix ms), source,
confidence, audio_path, audio_size, created_at (unix ms),
transcription_pass (1/2/3), batch_audio_path, pipeline_version
```
Legacy observations include `word` (per-word alignments) and `microphone` / `microphone_XXXX` (sentence-level, with the suffix identifying a batch). `source != 'word'` excludes those word alignments; verify the selected source's current values before assuming every remaining row is a sentence. Filtering `text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')` excludes these known placeholders; it does not verify transcription accuracy.

**`session_id` caveat:** An undated legacy observation found NULL in **493,914 of 493,914 rows**. This is not a current count or evidence about every capture path. Do not assume the field is populated. Time-gap or shared-`batch_audio_path` grouping can aid navigation, but must be labelled as derived grouping, not an observed recording session or proof of continuous activity.

### `audio_captures_fts` (FTS5)
Full-text search over audio text.

### V21 progressive recall

V21 adds activity events, correction/feed receipts, source/store identities and immutable screen/extraction snapshots. In-process `ProgressiveRecallService` resolves source-qualified `EvidenceRef` values with current permission, exclusion, deletion and source checks. A search selection must retain its original immutable reference or selection proof; a numeric frame ID and current source are insufficient. Legacy materialization remains labelled as legacy, and unverified geometry must not produce highlights. These APIs do not establish an external agent disclosure endpoint or permission to export captured content.

The durable `recall_search_revision` fence tracks search-affecting transactions. Ordinary-table triggers are persisted. FTS-content triggers are **TEMP triggers**, installed separately on the supported native `DatabaseManager` and `FTSManager` writer connections; they are not persisted on FTS shadow tables, preserving defensive-reader compatibility. Arbitrary external native SQL writers do not receive those hooks and are outside the revision-fence contract. Do not use direct writes to maintain or repair this schema.

### V22 native screen feed (installed local trial)

The separate screen feed covers already-materialized native observations. It does not enumerate all legacy frames or monitor external imported stores. `screen_evidence_feed` contains source-qualified reference/state events; `screen_evidence_feed_state` retains the stable feed identity, durable head and compaction floor. `screen_evidence_source_state` preserves the current revision, ordered availability/redaction facts and absorbing tombstones. These tables do not copy OCR, URLs or titles.

Use `ScreenEvidenceFeedStoreProtocol` through the local-only service for maintenance. Begin/resume a leased consumer, then advance bounded pages chosen by the canonical writer. Bootstrap records a boundary and maximum materialized frame ID, scans current state in short keyset pages, then replays intervening events. The transaction records applied-event identities and separate lexical/vector work before advancing the checkpoint; there is no arbitrary acknowledgement API. Expired or gapped consumers require a new bootstrap generation. Compaction retains the history needed by unexpired cursors. The initial contract allows 32 registered consumer IDs; reuse an existing ID after expiry. Page limits are 1–200 records, compaction limits 1–1,000 events, and leases last at most seven days.

Work contains only identity/state and is blocked, invalidated or deleted; it is never ready. A consumed event or retained extraction is not a ready lexical/vector index, a disclosure grant or a verified media file. No automatic consumer or model is enabled. V23 adds a separate unpublished-artifact boundary below; typed index publication remains future work. Continue using exact resolution for currently permitted evidence access. Do not mutate feed, cursor, work or applied-event tables through direct SQL.

### V23 native admission (installed local trial)

`ScreenEvidenceAdmissionStoreProtocol` requires a fresh live owning session and an active policy epoch. A persisted active row is insufficient to recreate authority. Capture owns the serialized configuration boundary, with App installing its policy bridge after database initialization. Policy changes close admission before configuration application; old claims cannot revive when settings return to earlier values. Ordinary recording pause retains historical policy authority; service shutdown ends it.

The local-only `ProgressiveRecallService` endpoints claim exact native input pages and stage bounded opaque bytes. `screen_evidence_admission_state` holds constant-size policy and metadata fences; `screen_evidence_derivation` holds authoritative claims and their optional artifact/checksum/receipt together. Source/consumer/policy checks are repeated transactionally. A staged receipt is neither semantic validation nor index readiness. Imported derived work and agent access are denied. Do not read these BLOBs as an alternative to the checked service API or mutate admission/source tables directly.

Limits are 256 attempt/receipt rows, 256 KiB per artifact, 16 MiB aggregate artifact bytes and 100 rows per cleanup call. Execution lasts at most 30 seconds under wall and monotonic checks; retained completed results may outlive execution for at most 24 hours only while their consumer and all current fences hold. Source deletion also deletes its staged bytes. V23 guards retained native payloads and tracks app/title/URL/relinking changes, including changes back to earlier values. Concurrent older binaries owning configuration and arbitrary database-file replacement need a separate compatibility design; old source-writer shapes alone do not grant policy authority.

---

## Common access patterns

### Find all frames in a time range
```sql
SELECT f.id, f.createdAt, s.bundleID, s.windowName, s.browserUrl,
       v.path, f.videoFrameIndex, v.frameRate
FROM frame f
JOIN segment s ON f.segmentId = s.id
LEFT JOIN video v ON f.videoId = v.id
WHERE f.createdAt BETWEEN ? AND ?
ORDER BY f.createdAt;
```
Resolve native `video.path` against the verified storage root. A direct decoder seek is useful for diagnostics, but the exact-evidence checks described above are required before presenting it as the selected historical screen. The candidate's search/evidence flow also rechecks the original selection proof and current privacy rules.

### Find OCR text on screen at a timestamp
```sql
SELECT n.text,
       n.leftX, n.topY, n.width, n.height
FROM node n
JOIN frame f         ON n.frameId   = f.id
WHERE f.createdAt = ?
ORDER BY n.nodeOrder;
```
This reads current native V18+ node text; nulls do not prove that no text was captured. Use the retained evidence revision when exact historical text or highlights are required.

### Search screen and audio indexes separately
```sql
-- Screen OCR (searchRanking has no frameId column — join via doc_segment)
SELECT ds.frameId, sr.text
FROM searchRanking sr
JOIN doc_segment ds ON ds.docid = sr.rowid
WHERE sr.text MATCH 'invoice';
-- Audio
SELECT ac.id, ac.text, ac.start_time
FROM audio_captures_fts
JOIN audio_captures ac ON ac.id = audio_captures_fts.rowid
WHERE audio_captures_fts MATCH 'meeting';
```

### Get clean transcript for a time range
```sql
SELECT datetime(start_time/1000, 'unixepoch', 'localtime') AS t, text
FROM audio_captures
WHERE source != 'word'
  AND text NOT IN ('', '[silence]', '[hallucination]', '[decode_error]')
  AND start_time BETWEEN ? AND ?
ORDER BY start_time;
```

### Get app usage for a day
```sql
SELECT bundleID, SUM(endDate - startDate) AS ms_in_app
FROM segment
WHERE startDate BETWEEN ? AND ?
GROUP BY bundleID
ORDER BY ms_in_app DESC;
```

---

## Safety notes for the agent

- **Use bounded read-only access** while the app runs: open the exact selected database with `mode=ro`, enable `query_only`, use indexed constraints and retain source identity. Read-only SQL does not itself enforce the app's disclosure/privacy policy, and a read-only connection can update the shared-memory WAL index. Zero SQL changes does not mean zero filesystem changes. Do not use `immutable=1` on a changing live database or bypass SQLite's locking/security configuration.
- **Use supported app operations for mutations.** Before an authorized offline recovery or installation snapshot, stop recording through the app, allow capture/audio finalization, then Quit and verify the exact app process has exited and no other writer holds the library. Quit or a successful checkpoint log alone does not establish that every pending write was flushed. Do not use broad process-name kills or pause the recorder with `SIGSTOP` as a snapshot method.
- **Retain a coherent recovery set.** With all durable-data writers stopped, preserve the native database, any retained SQLite `-wal`/`-journal`, `chunks/`, `audio/`, capture `wal/` and other durable files, alongside the signed app and preferences. The SQLite `retrace.db-shm` file is a regenerable coordination index with no database content: omit it from a new recovery/validation copy and let SQLite rebuild it there; do not remove it from a live library. Still reject database, WAL, journal or media changes during the copy. [SQLite WAL file documentation](https://www.sqlite.org/walformat.html#the_wal_index_or_shm_file)
- **Keep capture journals with their database and media.** They contain `frames.bin`, `frame_id_map.bin`, metadata and sometimes recovery progress; startup recovery can consume them. An online SQLite backup does not include these journals or media. Validate a separate recovery copy before first candidate launch, and never overlay an older DB onto newer sidecars/journals. Restoring persisted data also reverts post-snapshot captures; preserve that later library separately.
- **Don't delete retained audio files independently of their references.** Refinement re-reads `batch_*.m4a`; sentence files can still be referenced. Use supported retention/deletion paths.
- **Legacy frame, segment and audio timestamps are unix milliseconds.** Divide by 1000 before using `datetime(..., 'unixepoch')`. V21 activity observation/persistence columns use Unix seconds as `REAL`; inspect each table's schema and writer.
- **Native `video.path` is relative to the storage root**, already including `chunks/`; the final component is an extensionless media file.
- **Audio paths in `audio_path` are relative** to the storage root (`~/Library/Application Support/Retrace/`).

---

## Schema gotchas

Things that caught the first ingester author out — verify against live `.schema` output before trusting any prose above.

- **`node` geometry columns are `leftX` / `topY`**, not `x` / `y`.
- **Native V18+ `node` has nullable `text`, but no `confidence` column.** Imported/pre-V18 schemas can differ. Prefer retained region text; offset-only legacy reconstruction is not verified historical geometry.
- **`segment` uses `startDate` / `endDate`**, not `startTime` / `endTime`. Values are still unix milliseconds.
- **`searchRanking` has no `frameId` column.** It's an FTS5 virtual table with `(text, otherText, title)`. Map back to frames via `doc_segment` (`docid` = `searchRanking.rowid`).
- **`audio_captures.session_id` may be absent.** The 493,914-row all-NULL count above is an undated legacy observation, not a refreshed library measurement. Any time-gap/batch grouping is derived, not an observed session.
- **`audio_captures.source` values** in that legacy observation included `word`, `microphone` and `microphone_XXXX`. Verify source-specific values; excluding `word` alone does not prove the remaining rows' granularity.
