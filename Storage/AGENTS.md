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
├── ImageExtractor.swift.bak             # Existing backup; not production source
├── Audio/
│   ├── AudioFileDecoder.swift
│   └── AudioSegmentWriter.swift
├── FileManager/
│   ├── DirectoryManager.swift
│   └── StorageHealthMonitor.swift
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
    ├── StorageManagerTests.swift
    ├── WALRecoveryTests.swift
    └── TestLogger.swift
```

The storage root is configurable through `AppPaths`. Screen video lives under `chunks/YYYYMM/DD/{timestampID}` (extensionless MP4); raw recovery files live under `wal/active_segment_{timestampID}/`. The timestamp-based path ID is distinct from the database `video.id`. Never substitute one for the other.

Strict encoded-frame reads retry a stale image generator once, then reject a timestamp mismatch instead of returning a neighboring capture. Explicitly tolerant playback remains available. `StorageManagerTests` covers this with a real HEVC timestamp gap.

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
