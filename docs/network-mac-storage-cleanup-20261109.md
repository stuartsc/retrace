# Networked Mac storage cleanup — 9 November 2026

Stuart authorised urgent space recovery on the networked Mac. The target was verified over the existing strict-host-key SSH connection as `Stuarts-MacBook-Pro-5.local` (`stuartbond@100.82.166.96`), the M3 Max with 36 GB memory that runs the primary intelligence services. This was filesystem cleanup, not an application release, database migration or recording-retention change.

## Verified result

Three guarded cleanup operations removed five exact directories. Their combined measured net available-space increase was **15,235,735,552 bytes (15.24 GB)**. Final independent verification found **39,479,230,464 bytes (39.48 GB)** available on the Data volume, reported as 96% used. The immediately preceding check was about 40.23 GB. Space changed with background activity before and between operations, so the entire increase from the earlier 4.43 GB reading is not attributed to this cleanup.

| Removed content | Reported target allocation | Measured net available-space increase during removal |
| --- | ---: | ---: |
| Two inactive old application signing copies | 2,655,744,000 bytes | 1,909,678,080 bytes |
| May 12 derived search-index recovery snapshot | 11,218,862,080 bytes | 11,169,075,200 bytes |
| Seven incomplete model-download payloads in two temporary directories | 2,174,746,624 bytes | 2,156,982,272 bytes |

APFS clones and concurrent writes make folder allocation different from uniquely recoverable physical space. Each operation recorded its own immediate before/after volume availability. Removal bypassed Trash and was permanent; retained copies and the precise value relinquished are described below.

## Exact removals and retained value

### Inactive application copies

Removed only these old signing-copy leaves on the remote Mac:

- `/private/var/folders/cs/_0dwpl614577wgjw1l3rg8nm0000gn/X/com.google.Chrome.code_sign_clone/code_sign_clone.IRVvN9`
- `/private/var/folders/cs/_0dwpl614577wgjw1l3rg8nm0000gn/X/com.citrolabs.ego.lite.code_sign_clone/code_sign_clone.ugUuzY`

These held Chrome 154.0.8037.99 and ego 0.5.1.13, were about 28 days old and had no observed open handles. Installed Chrome 156.0.8078.80 and ego 0.6.2.9 remained, with executable and Info.plist hashes unchanged. The active signing-copy leaves `MEdVJo` and `fJQzCo` were protected. Chrome and ego processes remained running after removal.

### Old search-index snapshot

Removed the whole obsolete recovery snapshot:

`/Users/stuartbond/mac2-archives/backups/lancedb/tier2_20260512_0030`

The snapshot contained 29,999 regular files, no hardlinks or symlinks, and no observed open handles or references in the bounded application/configuration/LaunchAgent checks. It was the May 12 derived Tier-2 index, version 10000 with 495,487 rows. This operation relinquished that dated index rollback. It did not delete raw recordings, communications or current search data, and it does not claim a row-by-row historical superset.

Both current indexes passed bounded read-only opening, schema and count checks before and after cleanup:

| Retained current store | Version | Rows |
| --- | ---: | ---: |
| Remote `/Users/stuartbond/outlook/intel/lancedb/tier2` | 19059 | 583,319 |
| Laptop `/Users/stuartbond/outlook/intel/lancedb/tier2` | 19053 | 583,308 |

The schemas matched, including 3,072-value vectors. The remaining archive's graph recovery and small recording/recovery artifacts were preserved. These checks establish readable current stores, not full index integrity or search-quality acceptance.

### Incomplete model downloads

Removed only:

- `/Users/stuartbond/.cache/modelscope/hub/models/._____temp/damo/face_chain_control_model`
- `/Users/stuartbond/.cache/modelscope/hub/models/._____temp/SoulNut/facechain_LoRA`

All seven payloads were dated 30 June, ordinary single-link files owned by Stuart, and had no observed model-cache handles or lock-named files. Six safetensors headers declared more required tensor bytes than their files contained. The seventh PyTorch ZIP lacked a readable central directory. These are incomplete downloads; the cost is losing partial download progress if those missing weights are requested again. The complete canonical model directories outside `._____temp`, Hugging Face weights, Ollama models and active Python environments were protected.

## Storage still in active use

The largest apparent duplicate, `/Users/stuartbond/retrace-mirror`, reports about 252 GB of allocation but is actively consumed by a second Retrace analysis pipeline. Its audio is about 98.74 GiB and video chunks 48.30 GiB. The published database and staging each report 43.98 GiB, but the sync script APFS-clones staging into the published database, so their reported sizes overlap. The sync worker had the staging database open. The published mirror, staging and media were preserved.

Both this mirror's media sync and Outlook's capture-mirror media transfers are additive. They do not propagate source deletion or apply destination retention. Old media can accumulate, but deletion requires exact current database and derived-record reference checks; age and duplicate-looking directory names are insufficient. No media was classified as disposable in this pass.

The three daily decision-run snapshots and six recent Neo4j cold backups are within their implemented retention policies. Their summed allocations overstate physical consumption because of APFS clones. Current replication staging was preserved. The earlier full-home scan was stopped, so this is not a complete account of every file on the Mac.

Other excluded candidates:

- VS Code and Grok Bot update caches had active updater processes and newer staged versions than installed versions.
- The uv cache contained active Python runtime environments and held locks; no broad cache prune or forced clean was run.
- The root-owned Logi cache was not writable by the user, and its opaque files were not established as disposable.
- Public Ollama Gemma and Qwen downloads could be evicted for further space, but future configuration use and exact-version restoration require separate handling. Complete public/custom models were retained.
- No Data-volume APFS snapshots were found to prune. The sealed OS snapshot and swap were preserved. Final swap usage was about 34,279 MiB of 35,840 MiB allocated; no apps or services were stopped to force reclamation.

## Verification, receipts and workarounds

All five exact target directories are absent. The primary SQLite database remained readable with schema version 168 and 86 tables. Current search indexes retained the same checked versions/counts/schema. Previously observed autosync, MCP, intel-daemon, dashboard and Retrace-sync processes retained their PIDs; Neo4j remained running. No service-control, credential, capture or retention-setting actions were performed. Nightly Retrace's pre-existing exit status 1 was not changed or repaired by this cleanup.

Executors used explicit allowlists, complete target metadata inventories, no-open-handle checks, pinned non-symlink parent directory descriptors, symlink-resistant tree removal, protected identities/hashes and post-delete checks. One advisory review covered the deletion implementation; scoped reviews covered each later allowlist change. Reviews and compilation found no unresolved material issue. Process/open-handle checks are observations rather than a universal writer lock, which is why only old inactive targets were admitted.

The remote default `python3` is Apple's 3.9 and lacks the required `shutil.rmtree(..., dir_fd=...)` argument. This was caught before deletion. All executors used the verified `/Users/stuartbond/outlook/.venv/bin/python` 3.11.16, with an explicit capability guard. Another inventory workaround was using `du -s -x -k` for exact leaves because macOS rejects `du -a -d` together.

Remote receipts:

- `/Users/stuartbond/storage-cleanup-receipts/2026-11-09-unused-app-copies/`
- `/Users/stuartbond/storage-cleanup-receipts/2026-11-09-old-search-index/`
- `/Users/stuartbond/storage-cleanup-receipts/2026-11-09-incomplete-model-downloads/`
- `/Users/stuartbond/storage-cleanup-receipts/2026-11-09-final-verification.json`

Local copies of the plans, results, incomplete-download proof and final receipt are retained at `/Users/stuartbond/Library/Application Support/Retrace Cleanup Receipts/2026-11-09-network-mac/`. The executors remain with these receipts and on the remote Mac. Their result guards prevent an unexamined repeat.
