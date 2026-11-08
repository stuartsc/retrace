# Retrace storage efficiency — 7 November 2026

Stuart asked whether the live library and remaining Candidates folder could use less space without losing their value. This was a read-only library audit plus one isolated audio-copy experiment. No recorded files, settings, database rows, application builds or recovery material were changed.

## Measured current state

Installed build remains 2610.22.5. The running app uses the default native root, `/Users/stuartbond/Library/Application Support/Retrace`. The live folder reports about 169.10 GB allocated; the earlier supplied screenshot showed 165.6 GB. Temporary raw capture buffers vary while recording runs. The Data volume had approximately 100.6 GB available at the later check.

| Live category | Reported allocation |
| --- | ---: |
| Audio | 72.71 GB |
| Main SQLite database | 47.15 GB |
| Encoded screen chunks | 41.25 GB |
| Raw frame recovery/capture WAL | 3.26 GB at scan time |
| Local models | 2.20 GB |
| Diagnostic logs | 2.14 GB |

Candidates reports 44.76 GB. The retained `2026-10-19-recovery/followup-2610.19.4/Database before recovery repair/retrace.db` accounts for 42.84 GB (95.7%). All five previously removed release-build trees are still absent. The remaining approximately 1.93 GB comprises apps, native source/binaries and recovery/validation records. The retained 2610.19.6 recovery app passes strict signature verification.

File allocations must not be added as uniquely reclaimable physical disk space: APFS copies can share blocks. The 2 November cleanup's actual net gains remain separately recorded in `storage-audit-20261102.md`.

## Audio: strongest engineering opportunity

A bounded query of the newest 3,000 unique microphone batch paths found a median duration of 15.005 seconds and median spacing of 10.005 seconds. All 2,999 adjacent intervals were between 9 and 11 seconds. About five seconds are therefore persisted repeatedly in neighbouring batches. Current sentence transcripts reference their canonical batch file; four bounded older-row samples did not demonstrate disposable sentence-file duplication.

Persisting each sample once would reduce duplicated stored duration by approximately one third for this stream. That is not a promise of one-third byte savings or recoverable historical storage. The separate main-worktree ten-second chunk candidate remains default-off and unaccepted: its short authored fixture used 6.95% more total bytes and failed a native recognition gate. Per-file overhead must be measured with the actual storage design before rollout. See `/Users/stuartbond/backintime/docs/responsiveness-storage-validation.md:82`.

Small MP4 atom-header samples also found approximately 21–23 KB of unused padding per M4A file, about 19–33% of sampled file sizes. Removing container padding without changing AAC packets is a promising lossless design, separate from overlap prevention.

### Isolated remux experiment: rejected

One existing recording was copied into a private scratch directory and remuxed there. No live file was overwritten. The copy decreased from 69,014 to 46,181 bytes (33.0846%). All 237 encoded AAC packet hashes, packet durations and skip metadata matched, but packet timestamps shifted by 2,112 samples. Stream start changed from 0.132 seconds to zero, and duration changed from 15.168 to 15.036 seconds. This fails preservation of timing.

Native source decoding completed, but the receipt reader rejected Apple's extensible WAV format before native PCM equality could be established. No further remuxes were attempted after the timing failure. The smaller copy is not suitable for the library.

The failed probe is retained locally at `/Users/stuartbond/Library/Application Support/Retrace Cleanup Receipts/2026-11-07-audio-padding-probe/report.json`. Future work must preserve container timing, priming, tail, packet bytes, native decoded sample counts/content and Retrace seeking before any migration. A broader eligible-file inventory is needed before estimating historical savings; do not apply the sampled percentage to all 72.71 GB.

## Diagnostic logs: a small, lossless opportunity

`logs/cpu_process_usage.jsonl` contains 2,144,479,189 bytes of process CPU/memory diagnostics. It has not changed since 19 October, and no open handle was observed. `UI/Components/ProcessCPUMonitor.swift` is its producer. This is diagnostic telemetry, not screen or audio history.

Three 1 MiB samples compressed to 9.3–15.3% of their original size. A lossless archive could plausibly recover about 1.8–1.9 GB while retaining every record; this is a sample estimate, not a completed archive. The current reader consumes only the final 4 MiB/256 records and does not read gzip. A proper implementation should keep a compatible bounded current tail, retain the verified compressed archive and rotate future logs through the owning writer. No log was compressed or removed during this audit.

## Raw frame WAL: recovery before cleanup

This directory is the app's raw screen evidence, distinct from SQLite's adjacent `retrace.db-wal` file. It is not disposable simply because a segment is old or has no open handle.

- `active_segment_1793860812881`: approximately 1.65 GB, 28 valid raw records and 27 persisted frame mappings. Its recovery journal contains a 509,901-byte encoded output but is marked `committed=false`; reconciliation remains necessary.
- `active_segment_1793863181216`: approximately 332 MB, 40 valid raw records and 40 mapped frames. An archive exists at 914,948 bytes, but only 5/40 OCR jobs were completed and exact archive decoding/mapping was not verified.
- `active_segment_1793870694433`: approximately 102 MB and one mapped frame. Its referenced archive is zero bytes and the database records zero encoded frames; the raw WAL may contain the only retained pixels. Preserve it.
- Today's active 5120×2880 capture uses roughly 59 MB per raw frame. The current source targets approximately 2 GiB per active segment. A tiny old 1×1 fixture and empty quarantine provide negligible savings.

The app's recovery path must validate the encoded output, commit exact mappings and enqueue OCR before retiring these originals. Lossless raw-frame compression is a future writer/reader change; manually compressing the files would break current reads.

## Database: no demonstrated quick compaction saving

The live file contains 11,511,734 pages of 4,096 bytes and zero freelist pages. No vacuum, checkpoint, rebuild or index modification was performed. Zero freelist pages do not rule out partially filled pages, but do not demonstrate an easy large reclaim either. SQLite documents that [VACUUM may also repack partly filled pages](https://www.sqlite.org/lang_vacuum.html); any benefit must be measured safely before choosing a migration.

Important correction to earlier source comments/planning: the installed screen `searchRanking` table is ordinary content-bearing FTS5. Its actual `CREATE VIRTUAL TABLE` statement has no `content=` option; `searchRanking_content` is its internal content table. Audio FTS does use external content. Simply changing the screen FTS mode does not prove savings because its canonical text must remain available for search and exact offsets. Node text and immutable screen-extraction payloads merit a measured duplication/compression audit, with all original identities/revisions preserved.

Bounded read-only [dbstat](https://www.sqlite.org/dbstat.html) probes were limited to five seconds per table to avoid prolonged pressure on the live writer. The four large tables (`screen_extraction`, `node`, `searchRanking_content`, `searchRanking_data`) exceeded that budget; their allocation remains unmeasured. Completed probes found daily metrics about 144.6 MB and document/frame links about 27.1 MB. No full 47 GB allocation scan was completed, so there is no quantified database-reduction claim.

## Moving data while preserving access

Moving the retained backup and recovery records to another drive, verifying the destination and then removing the internal copy preserves recovery value without changing the live library. No external storage drive was mounted during this audit. Shared APFS blocks mean reclaimed local space may be smaller than the backup's reported size. Compressing that backup on the same internal disk can increase usage if it creates new blocks while the original copy shares blocks with the live database.

The source supports choosing a complete native library on another disk through `customRetraceDBLocation`, with recording stopped and an app restart. The Settings chooser only changes the path; it does not migrate existing data. The whole library must first be copied and verified. The drive must remain connected for recording and historical access. This is not a currently implemented split between local recent history and externally stored older media, and installed migration/unplug acceptance has not been performed here.

## Recommended delivery order

1. Implement bounded diagnostic-log rotation with verified lossless archival.
2. Build and validate AAC container-padding removal that preserves exact packet/native timing; then measure eligible historical files on a representative corpus before proposing migration.
3. Persist future audio samples once with container overhead, transcription boundaries and playback verified. Preserve existing recordings throughout rollout.
4. Reconcile retained raw-frame recovery sessions through the app, and assess lossless spool compression.
5. Audit database payload/index allocation during a quiet period; measure exact-data compression or deduplication before any schema conversion.

Backup relocation is an independent optional space measure. Bulk historical audio/video recompression, deletion of likely silence, shortening retention and deletion of unverified WAL originals are outside this proposal. No live data was changed by this audit.

## 9 November: diagnostic archive completed

Stuart asked whether anything could now be deleted. The inactive CPU process log was archived losslessly, and only its redundant full-size uncompressed copy was removed. The log was still 2,144,479,189 bytes, unchanged since 19 October, with one hard link and no observed open handles. Audio, screenshots, OCR/search data, raw recovery frames, models, preferences, the installed app and the retained database rollback were outside the operation.

| Measurement | Verified result |
| --- | ---: |
| Original diagnostic content | 2,144,479,189 bytes |
| Complete gzip archive | 407,184,504 bytes |
| Compatible current plain-text tail | 4,183,253 bytes |
| Reduction in reported file allocation | 1,720,143,872 bytes (1.72 GB) |
| Data-volume available space before preparation | 93,311,500,288 bytes |
| Data-volume available space after removal | 94,664,208,384 bytes |
| Net available-space increase during operation | 1,352,708,096 bytes (1.35 GB) |

File allocation and net volume availability are deliberately reported separately. Retrace and the rest of the Mac remained active during the operation; concurrent usage affects the volume-wide change. A subsequent independent check reported 94,664,753,152 bytes available.

The archive is `/Users/stuartbond/Library/Application Support/Retrace/logs/cpu_process_usage.through-20261019.jsonl.gz`. Decompressing its entire contents reproduces all 2,144,479,189 original bytes with SHA-256 `137b343c255f61f6bbf229d591ea8633d88e0a5d4cf202020907257cefbbdc09`. The original filename retains a bounded plain-text tail. A separately compiled copy of the actual `ProcessCPULogReader.swift` returned the same 204 complete diagnostic records before and after replacement, with the same length-prefixed record hash `1455dd43cf036560fbdda1a34094f17968972afe602a667c878567ce5e14c61d`. The gzip retains all earlier records independently of this bounded view.

The one-time executor used pinned, non-symlink directory descriptors, exclusive output creation, full source/archive hashes, identity checks and an atomic macOS filename swap. The original inode remained present until its contents were verified again after the swap and no open handle was observed. One advisory review identified the need for macOS `F_FULLFSYNC` durability barriers; these were added and exercised on a private fixture before removal. Successful file/directory flushing and full-sync barriers were required for the archive and replacement tail. The exact redundant original was then unlinked, bypassing Trash; its complete contents remain in the verified archive.

Post-operation checks confirmed the native database remained readable, the database/media-directory identities were unchanged, the retained rollback database metadata was unchanged, and the installed executable and process-group metadata retained their hashes. Retrace remained running as PID 68427. No restart or recording interruption was requested. This verifies the scoped storage cleanup, not a new capture, transcription or performance acceptance run.

Local execution and verification receipts are in `/Users/stuartbond/Library/Application Support/Retrace Cleanup Receipts/2026-11-09-cpu-log-archive/`: `plan.json`, `review.json`, `swap.json`, `verified-before-removal.json`, `result.json`, `verification.json` and native reader comparison outputs. The executor and its fixture/wrapper are retained there for review. This was a one-time inactive-file cleanup; it does not install future log rotation or provide exclusion against a live writer. No further large disposable live-library files have been demonstrated. The recovery backup and unverified raw-frame originals remain protected.
