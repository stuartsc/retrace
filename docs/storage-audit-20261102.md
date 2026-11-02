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

## Follow-up: further cleanup candidates

Stuart asked what else was safe to remove after the backup cleanup. This follow-up is read-only; no additional deletion was performed. The latest `df` check reported 25,754,316 KiB available (26.37 GB); free space continues to vary while other applications run.

### Recommended first: approximately 12.94 GB of rebuildable files

The nine `.build` folders listed above now report 5,066,145,792 bytes. Five older release-build trees add 3,105,800,192 bytes, giving **8.17 GB** total:

- `/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-09-29-masked-history/release`
- `/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-10-01-cpu-guard/release`
- `/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-10-06-microphone-routing/release`
- `/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-10-06-audio-freshness/release`
- `/Users/stuartbond/Library/Application Support/Retrace Candidates/2026-10-19-recovery/Release build`

All 14 roots are real directories, dependency checkouts are clean, and no active Swift/Xcode build or visible open target files were found. Installed Retrace loads its Whisper, ggml and Sparkle dependencies from its application bundle. Removing these build trees requires recompilation/downloads for later development, not changes to the running app or recording library. Preserve the enclosing source, app and receipt directories.

Unused package and automation-browser downloads add approximately **4.77 GB**:

| Exact path | Reported allocation |
| --- | ---: |
| `/Users/stuartbond/.npm/_cacache` | 1.067 GB |
| `/Users/stuartbond/.npm/_npx` | 0.698 GB |
| `/Users/stuartbond/.cache/puppeteer` | 0.598 GB |
| `/Users/stuartbond/.cache/puppeteer-fusecall` | 0.725 GB |
| Six older Playwright folders below | 1.684 GB combined |

The six Playwright folders under `/Users/stuartbond/Library/Caches/ms-playwright/` are `chromium-1208`, `chromium-1228`, `chromium-1234`, `chromium_headless_shell-1208`, `chromium_headless_shell-1228` and `chromium_headless_shell-1234`. No matching open handles or process arguments were found. Removing these makes packages reinstall; automation using those browser versions may require its browser installation command again. Retain the current browser versions and recheck activity immediately before deletion.

### Additional candidates requiring more care

- Generated simulator cache `/Library/Developer/CoreSimulator/Caches/dyld/25B78`: **7.86 GB**. Simulator devices are shut down and no visible payload handles were found. This is root-owned (0755); before removal, an administrator must stop simulator services and check root-owned handles, which this audit could not fully inspect. Cache regeneration is required on subsequent use. Preserve simulator device data.
- Optional installed iOS simulator runtimes: **17.38 GB** allocated across iOS 18.3.1 and 26.2. `simctl` reports both deletable. Remove through runtime management, not the mounted `Volumes` or `Cryptex` paths. Removing one disables tests on that iOS version until it is downloaded again. Mounted directory totals duplicate these backing images and must not be added again.

### Exclusions and low-value targets

- Preserve live tool runtimes: a Python process runs directly from `.cache/uv/archive-v0/1kKEB3y3ciLztAjnH1jTN`. Do not clear `.cache/uv` wholesale.
- VS Code's updater, Codex caches, Chrome caches and the latest Playwright Chromium have current process/handle use. Leave them in place during this session.
- Preserve HuggingFace models, Codex runtimes, `.claude/projects`, `.codex/sessions`, Claude virtual machines, and application profiles. Their size does not make them disposable cache.
- Docker occupies approximately 25 GB, but its local engine is stopped and the storage query could not inspect unused images/volumes. Do not delete its backing disk or volumes without an application-level audit.
- Downloads contains only 29.74 MB of installer DMGs. Larger Downloads folders contain documents, recordings or unverified archives; do not clear Downloads as a whole.
- A 2.14 GB `Retrace/logs/cpu_process_usage.jsonl` diagnostic file exists, but its producer and unique validation value were not established. It is not part of the recommended deletion set.
- Xcode DerivedData is empty; Time Machine reports no local snapshots. Device-backup storage remains permission-restricted.

These are allocated-file totals, not promised free-space gains. Measure actual free space around any subsequent authorised cleanup.
