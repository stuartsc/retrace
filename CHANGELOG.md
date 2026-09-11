# Updates and changelog

Last updated: 2026-09-11.

This file records meaningful Retrace bug fixes and improvements. Dates under **Unreleased** identify when changes were documented. **Local trial** means a specific build has been installed and launched for assessment; it remains unreleased. Dated, versioned **Released** sections are added only after a verified release.

## Unreleased

Status at 2026-09-09: **0.7.6 (2609.9.1) is installed and running**, launched at **07:15:27 Brisbane** after a fresh recovery snapshot and normal shutdown. The fixed 90-second trial completed **all eight captures**, with **1.005-second median** and **5.003-second maximum** capture-to-OCR completion; three sampled frames and all three controlled text screens passed actual FTS checks. At 07:31:32, sharply increased host load coincided with 10 newer frames pending and one processing, so sustained freshness remains variable. Missing historical source video and the newest unfinished-video preview remain separate limitations. This is a local trial, not a public release or an equal-workload accuracy, energy or disk benchmark.

### 2026-09-11 — Progressive recall plan saved for review

- Saved the [progressive recall and idle refinement plan](docs/progressive-recall-plan.md), covering contextual screen evidence, broad-to-precise retrieval, exact screenshot inspection and bounded background work across the two private Macs.
- The plan remains proposed and awaits Stuart's review. This checkpoint preserves the existing implementation and documentation; it does not implement the new plan or establish a new installed build or release.

### 2026-09-09 — Product requirement: screen context for agents

- Clarified the capture objective: an agent using text alone should understand visible content, its app/document/conversation ownership and supported changes. The [roadmap](docs/roadmap.md#screen-context-for-agents) now defines source context, content grouping, observed-versus-inferred activity and real-screen acceptance checks.
- Recorded the proposed sequence: immutable context at capture, visible-content attribution, complete agent exports, then temporal intelligence. This is a documentation/design update; it does not add these capabilities to installed build 2609.9.1.

### Local trial 2609.9.1 — 2026-09-09

- Installed the reviewed capture lifecycle and bounded maintenance fixes. Full validation passed **596 tests, four opt-in skips, zero failures**; optimized compilation took **743.25 seconds**. The signed installed executable and running process matched. Recovery completed before OCR workers started, recovering one session / 16 frames; the known damaged legacy journal remains preserved.
- In the fixed **07:16:12.108–07:17:42.108** window, **8/8 captures completed**, with no pending, processing, failed or unreadable frames. Capture-to-completion was **0.449–5.003 seconds**, median **1.005 seconds**. Three exact-frame FTS probes passed, and each of three harmless changing text screens was independently found within that same cohort. The first bounded maintenance batch ran during this window while fresh capture continued.
- At **07:31:32**, the later runtime check had **60 post-launch captures completed, 10 pending and one processing**, with none failed. Host load had risen to **92.47 / 58.87 / 57.60**. This separate observation does not change the fixed eight-frame result, but sustained low latency under heavy load is still unproven.
- Recording off/on passed through the UI, followed by two new completed/searchable frames. The Dashboard showed Text ready; an earlier trial image rendered correctly, actual UI search navigated to it, and timeline close/reopen passed. Existing Balanced level 3, one worker, 1 FPS, AC Low Power Mode and CPU Whisper settings were retained.
- Older repair attempts exposed missing source video: at **07:22:04**, all **44 newly failed records** were approximately 188-day-old frames from the same absent video, with no retained journal. Their existing text nodes and search links remain. These are separate from the original 334 failed and 237 unreadable records; the entire historical library is not repaired.
- The latest unfinalized recording can have searchable OCR before its timeline image is available. One strict playback read rejected the previous frame rather than showing it. This existing preview limitation remains; a scoped exact-journal preview is the next App/UI improvement, not part of this installed build. See [installed trial, rollback and remaining limits](docs/capture-improvements-validation.md#installed-trial-and-remaining-limits).

### 2026-09-09 — Recording lifecycle and bounded older-text repair

- Capture restart now waits for the previous worker to stop. Each worker owns its output stream, preventing a late completion or delayed metadata read from closing or publishing into a replacement session. Display changes use the same serialized lifecycle and reject stale sessions.
- Older OCR text repair no longer performs two full-library candidate counts at startup. After recovery and worker activation, one cancellable task checks at most 1,000 node rows per minute and queues at most 25 frames at low priority, within a 25-frame pending-work limit. A persisted cursor and fixed sweep boundary ensure ongoing capture cannot indefinitely postpone revisiting older records. Existing text and search remain until successful replacement.
- The restart blocker was observed directly: all 255 process samples were in the second global SQLite count, while the audio writer waited on the same connection. Removing that scan addresses this proven blocker; it does not conclusively explain the earlier 22-hour saved-capture gap. A normal restart restored recording on build 2609.7.4.
- Regression checks reproduced both lifecycle races and the unbounded scan. The final focused runs passed **25 Capture tests** and **44 Database/App tests**; the full suite passed **596 tests, four opt-in skips, zero failures** in 262.536 seconds, using three actual recorded screenshots. Independent code and database reviews approved the final source. See [9 September evidence](docs/capture-improvements-validation.md#recording-and-maintenance-follow-up-2026-09-09).

### Local trial 2609.7.4 — 2026-09-07

- Installed and launched the reviewed source safeguards. Recovery completed before OCR workers started, recovering two sessions / 25 frames. The known damaged legacy journal remains preserved; no new source-read or timestamp mismatch errors appeared in the bounded observation.
- In the fixed **10:13:45–10:15:15** capture window, 11 frames were captured; at **10:19:06**, two were complete, nine pending and none failed. The two completed frames took **60.135 and 105.671 seconds** from capture and passed actual FTS checks; a third fresh frame outside the cohort also passed. One historical frame older than 24 hours completed.
- Seven measured jobs spent **99.19% of logged elapsed job time in the OCR stage, including Vision waits**. The six fresh jobs took 6–26 ms to read frames and 22.8–63.8 seconds in OCR. Very high host load and substantial swap use prevent an equal-workload performance conclusion. Audio capture continued, but transcription saturation also remains unresolved.
- The Dashboard showed recording and loaded screenshot history; a selected moment opened in the timeline. Existing Balanced level 3 and Mac power settings were preserved. See [installed trial evidence and limits](docs/capture-improvements-validation.md#source-safeguard-local-trial-2026-09-07).

### Earlier signed-candidate checkpoint 2609.7.4 — 2026-09-07

- Optimized release compilation passed in **626.51 seconds**. The complete package passed strict signature verification and is staged for the normal replacement flow.
- At this earlier checkpoint, the canonical installed app was **2609.7.3**. The Mac locked during compilation; its last new capture was at 03:08:39 Brisbane. The candidate had not yet been launched. The later installation and live observations are recorded above.

### 2026-09-07 — Live screenshot source and orphan cleanup follow-up

- Final-build observation exposed a separate startup cleanup race: a new video placeholder was marked finalized before its first raw journal appeared. OCR then read an unfinished encoded video; 27 frames failed and some completed reads accepted a neighbouring image.
- All **64 frames** in the affected recording were verified in its normally finalized HEVC output, with matching frame indices and 30 fps timestamps. A backed-up, bounded repair reprocessed all 64 frames in 74.047 seconds, retaining existing text until successful atomic OCR replacement; three sampled frames passed real FTS lookups.
- Strict encoded-frame reads now reject a wrong timestamp after retrying with a fresh decoder. Explicitly tolerant playback remains available. A real HEVC regression reproduced the fault; all **11 StorageManager tests passed** after the fix. The reviewed **2609.7.4** source prefers exact raw frames, keeps fresh source retries ahead of old backlog, and restricts orphan cleanup to known candidates while protecting live writer placeholders. Retained damaged journals fall back to strict encoded reads; finished writers remain repairable if database publication fails. Independent review and **71 combined application regression checks passed with zero failures**. Build 2609.7.4 is now installed; its bounded live results are recorded above.

### 2026-09-07 — Recovery cleanup ownership

- Recording resume no longer deletes a recovery journal merely because an encoded video file is nonempty. RecoveryManager alone validates the recovered output, publishes frames and cleans the source journal.
- Live startup exposed this race after all ten affected frames had been recovered safely. The original chunk contained only six compressed video packets, demonstrating why nonzero size was insufficient proof for deletion. No database restoration was needed.
- Two real filesystem regressions reproduced the premature deletion; the corrected full App/recovery check passed **16 tests, zero failures in 55.145 seconds**, with independent review approved. This guard is installed in build **2609.7.3**.

### Local trial 2609.7.2 — 2026-09-07

- Installed and launched at **02:22:13 Brisbane**. The previous build quit normally; its app, preferences and persisted-data snapshot were retained.
- All **22 captures** in a fixed 90-second post-warmup observation completed in **18.913–49.778 seconds** from capture. Three exact-frame samples passed real FTS lookups; historical captures from 26 August also continued processing. This is a scoped freshness observation, not an equal-workload accuracy or speed benchmark.
- An older selected screenshot, behind 75 newer captures, changed automatically from “Indexing text” to **“Text ready”** without reselection. It had 56 stored regions and passed a real FTS lookup after a targeted priority diagnostic. That manually promoted frame is separate from the automatic fresh-capture cohort.
- The startup recovery cleanup race above prompted one final correction before handoff. See [live queue and UI evidence](docs/capture-improvements-validation.md#queue-and-dashboard-local-trial-2026-09-07).

### 2026-09-07 — Selected screenshot text refresh

- Older selected screenshots now refresh their stored OCR status and completed text independently of the newest 18 captures, preserving selection and list order. This fixes a completed screenshot remaining on “Indexing text.”
- Concurrent reads share work; selection changes and window/tab lifecycle invalidate stale results. Polling resumes when the Dashboard reopens, and failed reads remain retryable. The repair does not promote OCR priority or modify recorded data.
- Five real SQLite and concurrency checks passed with **0 failures in 0.707 seconds**, after the stale-frame regression reproduced three assertion failures. Independent review approved the source, and all five also passed in the combined application run. This fix first shipped in local build 2609.7.2 and is retained in 2609.7.3. See [selected-frame evidence](docs/capture-improvements-validation.md#selected-screenshot-and-native-ocr-diagnosis).
- Combined validation ran **562 tests with four opt-in skips**. One real screenshot test exceeded its 120-second deadline during heavy host load; it then passed unchanged in **23.374 seconds**, indexing all three screenshots. The failed run and retry are recorded separately in [validation notes](docs/capture-improvements-validation.md#combined-build-timeout-and-host-load).

### 2026-09-07 — OCR queue repair

- Automatic priority now expires after 60 seconds of capture age, so formerly recent screenshots cannot keep permanent precedence. After three current captures, historical work receives one FIFO turn, including deferred items. Explicit manual priority remains available.
- Displayed queue positions follow the same schedule and count each pending frame once. Atomic claims, rollback and duplicate removal remain intact; no queue reset or migration is needed.
- Source validation passed **557 tests, 4 opt-in skips, 0 failures**, including 23 focused queue persistence checks and independent review. This run predates the Dashboard refresh fix; both repairs first shipped in local build 2609.7.2 and are retained in 2609.7.3.
- The screenshot selected during diagnosis finished with **66 stored text regions** and passed an actual search-index lookup after a targeted priority check. Around 61,000 older frames remain queued; this is not a completed backlog repair. See [OCR investigation evidence](docs/capture-improvements-validation.md#ocr-backlog-investigation-2026-09-07).

### Local trial — 2026-09-07

- Launched corrected build **2609.7.1** at **00:41:18 Brisbane** (6 September 14:41:18 UTC). Startup recovery completed before OCR workers started; the former startup claim-reset race did not recur in this check.
- Preserved the user's selected **level 3, Balanced** setting: one worker, 1 FPS, utility priority; Low Power Mode remained on AC. The original comparison used level 1, so this is not an equal-settings speed comparison.
- Existing search returned results and navigated to the timeline. A new capture rendered and reopened, and the dashboard remained recording. The initial older selected frame needed Refresh after showing “Frame not ready”; a perfect startup timeline check is not claimed.
- New text remained queued: all nine new frames in the post-recovery observation were pending while nine backlog frames had completed since launch. Wait for **Text ready**, then check a distinctive phrase and its highlight. Opening a frame does not boost its OCR priority in this build.
- The first trial quit normally, and its app/preferences and a pre-switch persisted-data snapshot were retained. See [corrected-trial evidence and remaining issues](docs/capture-improvements-validation.md#corrected-local-trial-2026-09-07).

### Local trial — 2026-09-06

- Installed and launched build **2609.6.1** at 23:41:38 Brisbane time (13:41:38 UTC). Dashboard, timeline and search opened; capture and audio were active.
- The first observed OCR job processed old backlog in 479.34 seconds; the first observed fresh-frame OCR took 39.68 seconds. These observations prompted further corrections and do not establish capture-to-search improvement.
- The previous app, preferences and persisted-data recovery snapshots are retained for rollback. User settings were preserved, including processing level 1 and Low Power Mode on AC. Production transcription remains CPU Whisper.
- Detailed build identities, comparison limits and recovery notes: [local-trial validation](docs/capture-improvements-validation.md#local-trial-2026-09-06).

### 2026-09-07 — Follow-up corrections

- Startup recovery now completes before OCR workers activate, preventing recovery from resetting claims already being processed. Shutdown cancels and joins the owned startup task.
- Cancellation reaches the active recording-journal recovery task, preserves its source/checkpoint and permits retries with the same frame identifiers. Regression checks cover cancellation before work begins and after enqueue.
- Processing levels 1 and 2 now use utility priority, retaining their 0.25/0.5 FPS limits and one worker without changing saved preferences. A controlled Vision probe showed long delays at background priority on this Mac; it does not yet prove the full app is faster.
- Source validation and final App/Storage/Processing review passed. These corrections first shipped in local-trial build **2609.7.1**. Its historical observation did not establish fresh-frame search latency because those new frames remained queued; later scoped results are recorded above.

### 2026-09-06 — Bug fixes

- Packaged SwiftPM apps resolve UI assets inside the signed app bundle, without requiring the original build directory. Direct SwiftPM and Xcode resource layouts remain supported.
- Search app exclusions now preserve results from untitled windows. Invalid search queries return an error instead of silently appearing to have no matches, and equally ranked results have stable ordering.
- Legacy document operations use the current search index, preserve source metadata and reject duplicate insertion. Editing indexed text removes obsolete highlight boxes; partial writes roll back together.
- Video records save and return their actual frame counts instead of reporting a fixed 150 frames.
- Native timeline deletion uses the database transaction path and reports failures so the timeline can restore the item. Neighboring frames with the same timestamp remain intact.
- Frame and video deletion remove dependent OCR, queued processing and search data atomically. Shared documents and user notes remain where still referenced. Failures roll back the whole deletion.
- Repaired outdated test fixtures for deduplication, storage paths and database identities, and added real SQLite rollback and deletion coverage.

### 2026-09-05 — Capture and processing improvements

- Vision OCR reuses unchanged text and processes bounded changed regions at native pixel detail, with a full-frame fallback for larger changes. This is intended to improve responsiveness while preserving text detail.
- The OCR queue wakes promptly after new work arrives, prevents duplicate claims and balances recent captures with background work. Text, highlights, search links and completion status publish together.
- Microphone and system audio use separate persistent converters for 44.1/48 kHz input. Conversion handles integer/float and planar/interleaved layouts, preserves continuity during priming and drains buffered audio at shutdown.
- Capture recovery reads recording journals incrementally, resumes progress without duplicate frame/video records and retains incomplete or damaged source material for recovery.
- Retention removes old data in bounded transactions and validates file paths and references before deleting media. Routine retention no longer vacuums the database.

### Experimental

- Added an opt-in native Apple Speech batch comparison backend for macOS 26. It is **not enabled for recording or dictation**; production transcription continues to use CPU Whisper.
- One selected recording showed faster native transcription, but accuracy superiority, continuous capture behavior, power usage and disk savings remain unproven. See the [benchmark evidence](docs/capture-improvements-validation.md#native-comparison-one-authorized-recording).

### Validation

- Source for historical build **2609.7.1** passed the full suite on 2026-09-07: **548 tests, 4 opt-in skips, 0 failures**, reported test duration 143.059 seconds. The combined startup/recovery cancellation checks passed **14 tests, 0 failures** after reproducing the faults. Release packaging, signature verification and installed launch also passed.
- Before the first local trial, the full application/test build and suite passed on 2026-09-06: **541 tests, 4 opt-in skips, 0 failures**, including four resource-packaging checks. The earlier failure-repair run passed 537 tests. Coverage includes real recorded-screen OCR/queue pipelines, audio format conversion, filesystem recovery and transactional SQLite failure cases.
- The four skips were the interactive Accessibility inspector, live FuseIntel contract check and two explicit-audio native Speech tests. The selected native/Whisper audio comparison passed separately.
- Builds **2609.6.1 and 2609.7.1** verified launch, UI opening and active capture/audio, with the corrected trial's timeline limitation noted above. Sleep/wake, sustained lifecycle behavior and a valid old/new capture-to-search comparison remain outstanding. Synthetic probe pages were not verified as captured, so their zero search matches are excluded from latency comparisons.
- Detailed scope, reproduction steps and evidence: [Capture improvements: implementation and validation](docs/capture-improvements-validation.md).
