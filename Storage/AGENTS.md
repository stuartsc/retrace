# STORAGE Agent Instructions

Storage owns local media I/O, HEVC segment writing, raw screenshot WAL recovery, audio segment files and storage health. Depend on `Shared` protocols and models; database publication remains behind `DatabaseProtocol`.

**Status:** HEVC encoding uses AVAssetWriter/VideoToolbox, interframe compression, default GOP 30, and a synthetic 30 fps encoded timebase. Audio is stored as AAC `.m4a` (16 kHz mono). Encryption is not currently implemented in this module. Performance and monthly storage targets are targets, not measured guarantees.

## Files and ownership

```
Storage/
├── StorageManager.swift                 # StorageProtocol implementation, capture/recovery writer factories
├── StorageModuleError.swift             # Storage-specific errors
├── IncrementalSegmentWriter.swift       # Normal capture writer; raw WAL before encoding
├── SegmentWriterImpl.swift              # Video-only writer; recovery keeps the original WAL
├── ImageExtractor.swift                 # Frame/image extraction
├── ExactFrameReader.swift               # Exact evidence decoding and typed unavailable states
├── ImageExtractor.swift.bak             # Existing backup; not production source
├── Audio/
│   ├── AudioFileDecoder.swift
│   └── AudioSegmentWriter.swift
├── FileManager/
│   ├── DirectoryManager.swift
│   └── StorageHealthMonitor.swift
│   └── StorageUsageMonitor.swift        # Bounded periodic metadata scan, categories, volume free space
├── VideoEncoder/
│   ├── HEVCEncoder.swift
│   └── FrameConverter.swift
├── WAL/
│   ├── WALManager.swift                 # Capture persistence, identity map, active/quarantine lifecycle
│   ├── WALRecoveryReader.swift          # Validated metadata scan and one-frame pixel reads
│   └── RecoveryManager.swift            # Journaled recovery and atomic database publication
└── Tests/
    ├── DirectoryManagerTests.swift
    ├── HEVCEncoderTests.swift
    ├── ExactFrameReaderTests.swift
    ├── ExactWALFrameTests.swift
    ├── StorageManagerTests.swift
    ├── StorageUsageMonitorTests.swift   # Real file, hard-link, symlink, sparse-file and scan lifecycle checks
    ├── WALRecoveryTests.swift
    └── TestLogger.swift
```

The storage root is configurable through `AppPaths`. Screen video lives under `chunks/YYYYMM/DD/{timestampID}` (extensionless MP4); raw recovery files live under `wal/active_segment_{timestampID}/`. The timestamp-based path ID is distinct from the database `video.id`. Never substitute one for the other.

Strict encoded-frame reads retry a stale image generator once, then reject a timestamp mismatch instead of returning a neighboring capture. Explicitly tolerant playback remains available. `StorageManagerTests` covers this with a real HEVC timestamp gap.

Exact screen evidence uses `ExactFrameReader` and `WALManager.readExactFrame`. Encoded reads create fresh image generators, validate finite sample timestamps and expected dimensions, check source-file stability, and propagate cancellation. WAL evidence requires a conflict-free database frame ID map and a validated record boundary; capture index is never a fallback. Timestamp tolerance is at most the native database's one millisecond precision. The dedicated exact-media tests encode real HEVC samples and write real binary WAL records; these fixtures do not establish installed-app latency.

## Recovery invariants

- Normal capture writes `frames.bin` and `metadata.json`; `frame_id_map.bin` records exact database frame ID to byte offset mappings.
- Recovery scans headers and metadata without loading pixel payloads. Encoding reads one validated frame at a time; each output chunk holds at most 150 metadata descriptors. Individual raw frames have a 256 MiB allocation limit (including supported 8K BGRA); unsupported or corrupt input is retained.
- Sessions created by the current WALManager belong to live capture and are excluded from `listRecoverableSessions`; `listActiveSessions` remains inclusive for orphan bookkeeping.
- `isLiveSession` reports current-manager ownership, not filesystem presence. Retained incomplete journals must not be mistaken for writers that will append more pixels.
- Recent or old WAL files above 512 MiB are recoverable; size and age alone must never trigger quarantine or deletion.
- `recovery-progress.json` records output identity before encoding, finalized video metadata before database publication, and completion after atomic database commit and successful OCR enqueue. File and directory synchronization persist journal transitions.
- Recovery uses the video-only `createRecoverySegmentWriter()` path. Creating a second raw WAL would cause duplicate recovery after a crash; the original WAL already supplies durability.
- Database publication uses `commitRecoveredFrames`: stable mapped frame IDs, original video path plus frame index, and output video path plus frame index make retry idempotent. Never use second-resolution timestamps to identify frames.
- Partial encoding, corrupt/truncated tails, missing output, failed publication, and failed enqueue retain the source WAL. Complete valid prefixes can be published without deleting a damaged tail.
- The caller that creates coalesced recovery owns its cancellation; passive joiners must not cancel that shared work. Check cancellation before publication, after enqueue before the committed checkpoint, and before source cleanup, including when an enqueue callback consumes cancellation. Retain the WAL and verified output for idempotent retry.
- Do not delete source files or claim success until all encoded output and database mappings are confirmed. Existing quarantine pruning is separate from active recovery; no production files are touched by unit/integration tests.

## Coding and validation

Use async/await and actors for I/O. Keep filesystem, SQLite, decoding and encoding work off the main/UI actor. Log user/action-scoped recovery progress with `Log` and `.storage`; never log screenshot pixels or extracted private content. New user actions require daily metrics under root instructions; this recovery change repairs an existing startup action.

Tests must use real binary WAL files, FileManager, SQLite and media encoding, including a valid sparse WAL above 512 MiB, corrupt/truncated tails, exact identity mapping and interrupted/retried publication. Run focused checks with `swift test --jobs 4 --filter WALRecoveryTests`, coordinating SwiftPM access with other agents. StorageTests also links Database for real integration checks; production Storage depends only on Shared.

Only edit Storage unless an explicit cross-module assignment authorizes a narrow protocol change. Keep this file current when files or recovery semantics change.

November repair: HEVC encoder inventory availability, explicit hardware preference and unverified actual usage are separate. `HEVCEncoderTests` exercises native encode/decode with a hardware preference without claiming verified hardware use. Automatic selection remains the production default.

## 13 November V24 original-image candidate (not installed)

New capture writes `wal/original_segment_{pathID}`. Legacy `active_segment_` records remain readable. Finalisation/cancellation seals original pixels instead of deleting them. `OriginalFrameSpool` releases a source only after same-store durable extraction or deletion, exact native archive validation and reader drain; immutable V24 source aliases protect deletion before filesystem-map registration. Unknown, corrupt and unattributed sources remain retained. Admission preserves the 5 GiB ceiling and 20 GiB free-space headroom without eviction. App owns one joined sweep with per-record/per-sample governor admission; native archive verification is outside the recording writer.

`WALFrameCodec` supports old V1, complete-metadata raw V2, and optional independently decoded V3 LZFSE/LZ4 with raw fallback, checksums and bounded decompression. `StorageConfig.originalPixelCompression` defaults to disabled. This V24-only reader rejects unknown future metadata it cannot preserve. `OriginalFrameSpoolTests`, `OriginalFrameAliasTests`, `WALFrameCodecTests`, `WALFrameCompressionTests` and `WALWriterCompressionTests` use private files/SQLite/native HEVC. Source, focused runtime and separate clean release checks are verified; full-suite follow-up details and installation limits are separately recorded in `docs/repair-20261113-original-retention.md`.

Advisory follow-up: App passes the governor into reconciliation without holding a permit. Storage acquires/releases per record proof and per decoded archive sample. Admission accounting is cached and updated by owned file/reserve deltas; a cross-owner epoch invalidates stale caches. Processing supplies the immutable V24 source-path alias, avoiding scans of unrelated sessions. Explicit app-filter skip proofs share archive verification but remain distinguishable from OCR.
