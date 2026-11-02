# Disk-space audit — 2 November 2026

The initial read-only audit was followed by Stuart's explicit instruction to safely delete the four identified older backups. Deletion completed at 17:20 Brisbane on 2 November. No application settings were changed. Builds and the unfinished transcript-scrolling installation remain paused while space is addressed.

## Completed cleanup

- Permanently removed exactly the four database-only backup directories listed below: four SQLite databases and two empty WAL files. No development caches, application files or live recording files were deleted.
- Fresh checks confirmed the exact directory/file identities, regular files without symlinks, valid SQLite headers, empty backup WAL files and no open target handles. Deletion used pinned directory handles and checked file identities; no recursive wildcard deletion was used.
- Retained the newest V23 backup and signed recovery app. The retained backup's inode, size, modification time and sampled first/last-page digest were unchanged after deletion; its store identity matched the live database both before and after. This is not a full database integrity scan.
- Verified all four target directories are absent, current audio/chunks/context directories remain present, and the live database still opens read-only. Retrace remained running as PID 2289 throughout; no application restart was performed.
- Available space immediately before deletion was 23,802,011,648 bytes and immediately after was 24,602,902,528 bytes: **800,890,880 bytes (0.80 GB) net increase**. A separate check at 17:20:45 reported 24,472,444,928 bytes available (24.47 GB).
- Available space fluctuated substantially while the Mac was active: about 3.66 GB at the first execution-turn check and 1.36 GB at plan capture, then 23.80 GB before the first deletion. Do not attribute that earlier change to this cleanup. The approximately 162 GB reported file allocation did not translate into equivalent reclaimed space; APFS shared allocations and concurrent system activity limit attribution.
- Exact plan, per-file deletion result and post-delete verification are retained in `/Users/stuartbond/Library/Application Support/Retrace Cleanup Receipts/2026-11-02-backups/`. The retained backup and other recovery receipts remain in their original locations.

## Initial audit state (before cleanup)

- APFS Data volume: 97% full; approximately 30 GiB (32 GB) available.
- Current native library: `/Users/stuartbond/Library/Application Support/Retrace`, approximately 150 GiB allocated. No custom storage location is configured. Preserve this entire library, including database, audio, screen chunks and journals.
- Installed app remains 2610.22.5. No Retrace process or Swift build was found during this audit.
- `Retrace Backups` is empty. `Retrace Candidates` reports approximately 195.14 GiB allocated.
- The October 22 temporary scrolling-repair handoff and build receipts no longer exist. Source survives in the live-context worktree; tests and installation must be freshly verified before claiming that repair delivered.

## Old restore copies removed after authorisation

These were standalone database backups, separate from the live library. The corresponding older restoration points have now been removed.

| Folder under `~/Library/Application Support/Retrace Candidates/` | Allocated size |
| --- | ---: |
| `2026-10-06-microphone-routing/Database before microphone routing repair` | 31.01 GiB |
| `2026-10-19-recovery/Database before recovery repair` | 39.83 GiB |
| `2026-10-19-recovery/followup-2610.19.2/Database before recovery repair` | 39.84 GiB |
| `2026-10-19-recovery/followup-2610.19.3/Database before recovery repair` | 39.88 GiB |

Total: approximately 150.56 GiB (162 GB). Retain the newer `2026-10-19-recovery/followup-2610.19.4/Database before recovery repair` (39.90 GiB), the signed `followup-2610.19.6/Retrace 2610.19.6 candidate.app`, and the small receipts, source patches and installation records. Do not remove the whole Candidates directory.

Checks: valid SQLite headers and declared lengths on all five snapshots; empty optional WAL files; existing receipts identify quiescent database-only backups and successful installs. The retained newest snapshot opens read-only, reports V23 and matches the live database's evidence-store identity. Its recovery app passes strict deep signature verification. No open candidate/backup handles were observed. A full database integrity scan was not performed.

## Rebuildable development files

Nine `.build` folders total 4,947,408 KiB (4.72 GiB / 5.07 GB):

- `/Users/stuartbond/backintime-live-context/.build` — 1.50 GiB
- `/Users/stuartbond/backintime-timeline-recovery/.build` — 1.25 GiB
- `/Users/stuartbond/backintime-recovery/.build` — 1.25 GiB
- `/Users/stuartbond/backintime/.build`
- `/Users/stuartbond/backintime-hotfix-masked-history/.build`
- `/Users/stuartbond/backintime-hotfix-audio-freshness/.build`
- `/Users/stuartbond/backintime-hotfix-microphone-routing/.build`
- `/Users/stuartbond/backintime-hotfix-cpu-guard/.build`
- `/Users/stuartbond/backintime/.claude/worktrees/agent-a26cbf51/.build`

These cache roots are not symlinks. Their dependency checkouts are clean, and no active builds or open files under them were found. They can be regenerated; deletion requires subsequent dependency downloads and compilation. Preserve the source worktrees themselves: main and live-context contain extensive uncommitted work.

## Measurement limits

Allocated file totals do not establish unique reclaimable APFS blocks. Measure volume free space after any authorised deletion. No Time Machine local snapshots were listed. Downloads occupy approximately 17.4 GiB and accessible user caches approximately 8.2 GiB, but neither was approved for blanket deletion; protected cache folders and Trash could not be inspected.

No additional deletion is authorised by this audit. Build caches, other candidate files and the retained recovery set were left in place.
