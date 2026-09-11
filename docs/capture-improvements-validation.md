# Capture improvements: implementation and validation

See [CHANGELOG.md](../CHANGELOG.md) for the ongoing summary of fixes, improvements and release status. This document retains the detailed evidence for the capture improvements and subsequent failure repairs.

Status at 2026-09-09: **0.7.6 (2609.9.1) is installed and running**, launched at **07:15:27 Brisbane** after a fresh recovery snapshot and normal shutdown. The fixed 90-second trial completed **all eight captures**, with **1.005-second median** and **5.003-second maximum** capture-to-OCR completion; three sampled frames and all three controlled text screens passed actual FTS checks. At 07:31:32, sharply increased host load coincided with 10 newer frames pending and one processing, so sustained freshness remains variable. Missing historical source video and the newest unfinished-video preview remain separate limitations. This is a local trial, not a public release or an equal-workload accuracy, energy or disk benchmark. Production transcription remains CPU Whisper.

The [2026-09-05 review patch](/Users/stuartbond/Downloads/retrace-capture-improvements-2026-09-05.patch) isolates the first capture-improvement delivery against its saved pre-change working tree, including existing uncommitted changes; it is not a diff against Git HEAD and does not represent all subsequent corrections in the installed build. Earlier isolated test builds were removed after their validation; the repository's current `.build` remains. Evidence logs and the pre-change backup remain available.

## Recording and maintenance follow-up: 2026-09-09

### Initial live refresh and diagnosis

At 06:24–06:28 Brisbane, canonical build 2609.7.4 was running. Indexed status queries found **zero pending/processing frames globally**, 736,074 completed, 334 failed and 237 not yet readable. The processing queue had 241 distinct rows, but 239 referred to completed frames and two to failed frames; these were not 241 pending jobs. The last saved screenshot was from approximately 08:44 on 8 September, despite the Dashboard showing Recording and audio remaining active. Raw capture and deduplication activity continued. The exact cause of that earlier saved-capture gap was not established.

A normal restart exposed a separate, concrete blocker. All **255 samples** at 06:32:51 were in `AppCoordinator.enqueueLegacyOCRNodeTextBackfillIfNeeded` → the second candidate count → synchronous `sqlite3_step`. The audio writer waited on the same SQLite connection mutex. A low task priority did not release the database actor or connection while this full-library `COUNT(DISTINCT ...) JOIN node` ran. Build 2609.7.4 eventually resumed capture; spot checks at 06:48 found new frames completing in roughly 0.2–1.0 seconds.

Host load at the initial refresh was 15.90 / 14.61 / 20.37 with approximately 1.94 GB swap used, markedly below the earlier trial. Consequently, faster observed OCR cannot be attributed solely to these code changes or compared as equal workload.

### Implemented and reviewed corrections

- `CaptureManager` workers own their continuations; cancellation after metadata work prevents stale publication, and stop joins the worker. Start, stop and display switching share serialized lifecycle admission. A display callback from a retired session cannot restart the source. Natural completion retains buffered-frame draining.
- The startup global counts are removed. A single owned maintenance task begins after recovery/worker activation, waits 60 seconds, then checks one page per minute. App policy is 25 frames, priority -5, pending capacity 25 and node-page size 1,000. Shutdown cancels and joins it before database teardown.
- V20 adds a constant-size cursor/watermark table. Indexed pending checks occur before node reads and include claimed work. Each transaction reads no more than 1,000 node IDs before missing-text filtering; it advances only through inspected rows. A fixed upper ID for each sweep prevents a growing capture tail from starving revisits. Queue/status/cursor updates roll back together. Existing OCR/FTS content is retained until successful atomic worker replacement.
- Existing daily metrics record each maintenance outcome without inventing a global completion count. The migration is additive; the previous app can still open the resulting database. App replacement rollback and persisted-data recovery are separate operations.

### Validation before installation

The first lifecycle RED run reproduced late publication/replacement closure and stop not joining. The display-switch RED run reproduced lifecycle overtaking and stale-session admission. Final GREEN: **25 tests, zero failures, 2.058 seconds** (six lifecycle, sixteen rendered-image deduplication and three window-change checks).

The first maintenance RED run failed seven Database/App tests with eleven assertions/errors, including the real full-library scan and expected missing V20 table. A 60,001-node no-match database required **540,030 SQLite VM steps** before the fix and **18,093** after it. A second RED check reproduced an expanding node tail preventing revisit; the fixed sweep watermark resolved it. Final GREEN: **44 tests, zero failures, 6.740 seconds** (twelve paging, thirty existing database manager and two App maintenance checks). These include real SQLite plans, capacity exhaustion, sparse pages, cancellation, transaction rollback, restart/wrap and retained FTS evidence. The production read-only 1,000-row page probe took **0.002965 seconds**; this is a scoped read measurement, not end-to-end repair time.

Independent code review approved the final capture and App changes; database review approved the final bounded paging/watermark logic. All 276 frozen source and package/resource metadata entries matched the reviewed manifest before optimized compilation. The full suite passed **596 tests, four opt-in skips, zero failures** in **262.536 seconds** (06:54:32–06:58:55 Brisbane), including three JPEGs decoded from actual recorded frames. Focused counts overlap this full suite. The four skips remain interactive Accessibility, live FuseIntel and two explicit-audio native Speech tests. No default-native-transcription claim follows from this run.

### Installed trial and remaining limits

**0.7.6 (2609.9.1)** launched at **07:15:27 Brisbane** on 9 September (8 September 21:15:27 UTC), PID **4300**, from `/Applications/Retrace.app/Contents/MacOS/Retrace`. Optimized compilation completed in **743.25 seconds**. All 276 frozen source/metadata entries remained unchanged. The candidate and canonical installed bundle passed strict signature verification with `Developer ID Application: SIMPLE CLICK PTY LTD (CC88WZ5SQ7)`, retaining the prior entitlements and packaged dependencies/resources. Executable SHA-256: `c9b5756c35e930b97d5a9b5a37b0a312299f49da9f6454f292936d97b4956ea6`. This remains an **Unreleased local trial**; no commit, push or public release was performed.

A fresh coherent APFS snapshot of the database, SQLite WAL/SHM and capture journals was taken at **07:13:17.867**, pausing the old process for approximately **0.053 seconds**, then resuming it. Media remains in place. The old app quit normally; a UI-state read relaunched it once, so that process was also quit normally before replacing the bundle. The former signed 2609.7.4 apps, preferences and both pre-switch persisted-data snapshots are retained at:

`~/Library/Application Support/Retrace Backups/2026-09-09-capture-resume/`

The additive V20 table is compatible with reopening the database in the previous app. For an app rollback, quit Retrace and restore the saved signed bundle to the canonical app path. Do not restore the older database snapshot merely to roll back the app: doing so would discard newer database state. Persisted-data restoration is a separate recovery decision, and these snapshots do not include audio/capture still buffered only in memory at their creation.

Startup applied unchanged Balanced level 3 settings: OCR enabled, one worker, 1 FPS, utility priority, `preferBackgroundProcessing=true`, AC Low Power Mode enabled. Audio capture started at 07:15:32.644. Recovery finished before OCR workers started at **07:15:33.945**, recovering one session / 16 frames. The known damaged legacy WAL `1788533665295` was preserved after its expected recovery failure.

A fixed post-warmup cohort ran from **07:16:12.108 to 07:17:42.108**. At **07:18:14.406**, all **eight captured frames** were completed; zero were pending, processing, failed or unreadable. Capture-to-processed timing for all eight: minimum **0.449 s**, median **1.005 s**, nearest-rank p95/maximum **5.003 s**. The observer uses bounded read-only SQLite statements, a fixed denominator and explicit timeouts; it reported no query errors. Three spaced samples (50736791, 50736795, 50736798) passed actual frame-linked FTS queries. Separate searches proved the distinct phrases from all three changing TextEdit screens were present within the cohort. These controlled screens were actually captured; this differs from the unverified synthetic probes in older trial notes.

The first maintenance page finished at **07:16:36.527**, enqueuing seven older frames during the fresh cohort. Subsequent persisted cursor values advanced by bounded pages; there was no global candidate count at startup. This validates coexistence over a short observation, not long-term background repair throughput. At the initial cohort snapshot, global pending/processing counts were zero, while 349 failed and 237 unreadable records remained. Later maintenance attempts continue to change historical status counts.

A recording off/on check passed through the Dashboard. Two subsequent fresh frames (50736804/50736805) completed and matched the new restart phrase in FTS. Screenshot selection showed **Text ready**. Earlier finalized frame 50736795 displayed the correct recorded image; the actual search overlay returned its phrase and navigated to it. Timeline close → reopen showed that image again without the unavailable state, then returned to a Recording Dashboard. This is a scoped UI smoke check; native display switching, sleep/wake and sustained UI latency/energy testing were not performed.

The newly failed historical records were investigated against the pre-install snapshot and post-launch logs. At **07:22:04**, failures had increased **334 → 378**. All **44** changed records were previously completed frames captured approximately 188 days earlier and requeued in batches **7 + 8 + 6 + 6 + 8 + 9**. Every one referred to missing video **1000001**, with no retained journal at its source location. Every failure matched a missing-video log; all existing nodes and document links remained. At that independent snapshot, fresh frames were 20 completed and one processing, with no capture-pipeline error. Original recordings or another source backup would be required to re-extract these missing-video frames. The bounded scheduler does not recreate absent media.

One separate live-preview limitation remains. Frame **50736805** had successful OCR from its exact journal, but video **1009974** was still unfinalized. Timeline decoding requested **0.100000 s** and returned **0.066667 s**, so strict extraction rejected the neighbouring frame and showed “Come back in a few frames.” The journal remained intact; this was a playback-source rejection, not an OCR failure. Review confirmed an existing preview limitation exposed by the prior strict-timestamp guard, not a demonstrated 2609.9.1 regression. The next bounded App/UI change should expose the existing exact-journal reader, tag the image by selected frame ID and prefer it over the unfinalized-video branch, retaining cancellation/stale-selection checks and the strict encoded fallback. It has **not** been implemented in this trial.

A later runtime check at **07:31:32.839** verified that PID 4300 and the canonical executable still matched 2609.9.1. Across all post-launch captures then present, **60 were completed, 10 pending and one processing**, with no failed/unreadable fresh records. Host load had risen to **92.47 / 58.87 / 57.60**. This is a separate later workload, not a revision of the fixed eight-frame cohort. It demonstrates that sustained fresh-capture latency under host contention remains unresolved; the small successful cohort must not be described as a continuing one-second service level.

The lower host load, drained backlog, changing content and different workload prevent a causal old/new speed claim. Small-sample OCR freshness does not establish text accuracy, power efficiency, daily storage savings, audio transcription throughput or complete historical recovery.

Durable evidence is retained in the backup root’s **`Validation/`** folder: full/focused RED/GREEN logs, frozen-source manifest, package/signature/launch identity, fixed-cohort and phrase checks, restart/UI results, and legacy-failure/source-read investigations. Private OCR emitted by existing tests remains in restricted local logs; no extracted text is included in the structured observer output. The three temporary JPEG test copies are removed after validation; original recordings remain untouched. The harmless native test document is retained locally with the evidence. Earlier `/tmp` evidence from 6–7 September did not survive reboot; the historical results below are retained documentation, not a claim that those old temporary files still exist.


## Implemented scope

- Vision OCR reuses unchanged results and processes bounded changed regions at native pixel detail. Crops include complete affected text regions; large changes fall back to the existing full-frame pixel budget. Coordinate transforms and each frame's row stride are preserved. Language correction remains disabled to preserve identifiers.
- OCR queue claims are atomic and deduplicated. Automatic priorities 1–10 expire after 60 seconds of capture age. After three current claims, historical work receives a FIFO turn across expired automatic, zero, negative and NULL priorities; explicit manual priorities above 10 retain precedence. A wake signal avoids waiting for the idle polling interval after enqueue.
- OCR text, highlight nodes, search links and completion status publish in one database transaction. Deferred or cancelled claims return to the queue; worker shutdown drains tasks before teardown.
- Microphone and system callbacks use separate persistent AVAudioConverter instances for anti-aliased 44.1/48 kHz conversion to 16 kHz mono Int16. Real integer/float, planar/interleaved layouts are handled. Shutdown drains filter tails through the combined stream. Conversion errors reset filter history and timestamps; successful empty priming retains continuity. Failed microphone startup throws and closes streams.
- WAL recovery reads validated frames incrementally, journals progress, and publishes stable frame/video mappings idempotently. Recovery avoids creating a duplicate raw WAL and retains incomplete or corrupt source material.
- Retention uses bounded database transactions and validated paths, rechecking references before unlinking media, including extensionless/`.mp4` alternatives. Runtime retention does not vacuum the database.
- NativeSpeechTranscriptionService is a macOS 26 opt-in, bounded batch comparison backend behind TranscriptionProtocol. It preserves source-relative timing and cancellation, and rejects unsupported prompts. It is not wired into production recording or dictation.

Apple's installed-locale list alone did not establish readiness for the calling test process. Initialization now checks AssetInventory status for the exact module configuration used in analysis. Test-only preparation explicitly reserves the locale and invokes the asset installation request when `RETRACE_SPEECH_BENCHMARK_PREPARE_ASSETS=1`; the service does not download automatically. See [Apple AssetInventory](https://developer.apple.com/documentation/speech/assetinventory).

## Native comparison: one authorized recording

Host: M1 Max, 64 GB unified memory, macOS 26.1, Xcode 26 toolchain. Locale: en-AU. Both backends received the same decoded 16 kHz mono Int16 PCM, 14.96625 seconds long, with source offset zero. Whisper used the local `ggml-small.bin` model with GPU disabled.

| Metric | Native Speech | CPU Whisper small |
|---|---:|---:|
| Initialization seconds | 0.054096375 | 15.479463541 |
| Transcription seconds | 0.848090917 | 8.095890292 |
| Initialization + transcription seconds | 0.902187292 | 23.575353833 |
| Transcription real-time factor | 0.056666894980372508 | 0.54094314153512069 |
| Timed spans | 18 | 16 |
| Output characters | 95 | 91 |

Native asset preparation took 3.276301459 seconds separately; it is excluded from the initialization/transcription totals. Native-vs-Whisper word disagreement was 0.05, with **no ground truth**. This is not an accuracy score against a verified transcript.

These are single cold-batch observations with other repository work running, not medians or steady-state results. Native inference was approximately 9.55 times faster for this clip. Accuracy superiority, language/name coverage, continuous capture behavior, power consumption and storage savings remain unproven. Native timed spans retain Apple's segmentation; they are not guaranteed to be individual words.

The actual comparison and installed-service tests passed, including nonempty timed spans, valid offsets, pre-cancellation and in-flight cancellation. Logs may contain private output from the existing Whisper library; only share the `NATIVE_SPEECH_*` metric lines.

## Reproduce the checks

Run from the repository with the full Xcode toolchain. Coordinate SwiftPM access with other builds. Set the paths to explicitly selected local fixtures; neither command starts recording.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export RETRACE_SPEECH_BENCHMARK_AUDIO_PATH='/absolute/path/to/selected-recording.m4a'
export RETRACE_SPEECH_BENCHMARK_WHISPER_MODEL_PATH='/absolute/path/to/ggml-small.bin'
# Explicitly allows native asset reservation/installation in this test process:
export RETRACE_SPEECH_BENCHMARK_PREPARE_ASSETS=1
# Optional verified ground truth enables reference_word_error_rate:
# export RETRACE_SPEECH_BENCHMARK_REFERENCE_PATH='/absolute/path/to/reference.txt'
swift test --jobs 4 --filter NativeSpeechTranscriptionServiceTests \
  > /tmp/retrace-native-comparison.log 2>&1
rg '^NATIVE_SPEECH_' /tmp/retrace-native-comparison.log
```

Without explicit audio/model paths, the two real-audio tests skip. Omit the preparation flag to require assets already ready for the exact configuration in the calling process. The batch limit is 120 seconds; transcripts stay out of the structured metric output.

The existing screenshot pipeline tests read a directory of `.jpeg` fixtures and use isolated temporary databases/storage. Select a small representative directory; the tests enumerate its fixtures.

```sh
export TEST_SCREENSHOT_PATH='/absolute/path/to/selected-jpeg-fixtures'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --jobs 4 --filter 'OCRPipelineTests|AsyncQueuePipelineTests'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --jobs 4 \
  --filter 'AudioFormatConverterTests|AudioStreamBufferingPolicyTests|VisionOCRIncrementalTests|FrameProcessingWakeSignalTests|FramePipelinePersistenceTests|RetentionPersistenceTests|RetentionPathValidationTests|WALRecoveryTests'
```

## Test-failure repairs (2026-09-06)

The follow-up reproduced the 88 original assertion failures before changing the failing groups. It then corrected stale fixtures and repaired the underlying production defects:

- FTS app exclusions preserve untitled windows; malformed queries propagate SQLite errors instead of becoming empty results. Ranking ties have deterministic ordering.
- Legacy document CRUD uses the active `searchRanking` / `doc_segment` schema, preserves source metadata, rejects duplicate insertion and rolls back partial writes. Text updates discard obsolete OCR highlights.
- Video queries persist and read actual frame counts instead of hardcoding 150.
- Native timeline deletion routes through the database actor even with an attached adapter; forced SQLite errors reach the timeline so it can restore its staged item. A same-timestamp neighboring frame remains intact.
- Public frame/video deletion atomically removes dependent OCR, queue and search evidence. Shared frame/session documents and user notes survive where still referenced. Injected failures before frame deletion and after frame cleanup prove rollback.
- Deduplication tests use actual pixel differences and current threshold semantics. Directory tests verify real extensionless storage paths. Database tests use generated IDs and separate app-session/video identities. The public video cascade and low-level SQLite `SET NULL` behavior have separate tests.

The failure-repair work itself did not install the app or run cleanup against the live database; the subsequent local trial is recorded below. The dormant legacy `AppCoordinator.cleanupOldData` path still mixes storage filename IDs with database video IDs; runtime retention uses the separately guarded implementation described above.

## Validation history

- **Failure-repair full suite: 537 tests, 4 opt-in skips, 0 failures**, 59.10 seconds, exit 0 (`/tmp/retrace-failures-final-full-suite.log`, 2026-09-06). The application/test build passed. This includes the real recorded-screen OCR/queue pipelines and the new native timeline deletion route. The four skips are the interactive Accessibility inspector, live FuseIntel contract test, and two explicit-audio native Speech tests; the previous authorized native-audio comparison remains separately evidenced below.
- **First-trial full suite: 541 tests, 4 opt-in skips, 0 failures**, 98.874 seconds, exit 0 (`/tmp/retrace-local-trial-20260906/full-suite-final.log`, 2026-09-06). This includes four added checks for resource lookup in packaged SwiftPM apps. It predates the startup/scheduling corrections found during live assessment and is not a final validation of those corrections.
- **Corrected-source full suite: 548 tests, 4 opt-in skips, 0 failures**, reported test duration 143.059 seconds, exit 0 (`/tmp/retrace-local-trial-20260906/full-suite-corrected.log`, 2026-09-07). The combined startup/recovery cancellation regression run passed **14 tests, 0 failures**, reported duration 56.947 seconds, after earlier RED checks reproduced the faults (`/tmp/retrace-storage-app-cancellation-green.log`). These focused checks overlap the full suite. Final App/Storage/Processing code review approved the corrections. Release build completed in **887.46 seconds**; the installed package passed strict signature verification. Installed observations and their limits are recorded below.
- Failure-fix review patch: [retrace-failure-fixes-2026-09-06.patch](/Users/stuartbond/Downloads/retrace-failure-fixes-2026-09-06.patch). It compares the failure-repair phase against the saved working tree immediately before those repairs, preserving the earlier delivery and unrelated edits. It is not a diff against Git HEAD and predates the later packaging/startup/scheduling corrections in the installed build.
- Focused RED/GREEN evidence: FTS 27 passing checks, query/edge 49, dedup/directory 21; integration 19 and database-manager 30; native timeline routing 2. Trigger-based tests prove both early and late rollback. Final source and SQL reviews found no remaining material issues. These focused counts overlap the full suite.

Earlier delivery evidence:

- Full application and test build passed. The final focused run passed **75 tests, 2 opt-in skips, 0 failures** in 35.76 seconds (`/tmp/retrace-phase1-final-focused.log`). It includes the real recorded-screen end-to-end queue and OCR pipelines, all new SQLite, Vision, conversion, recovery and filesystem regressions. Three JPEG fixtures were decoded read-only from an existing local recording into temporary test storage. The queue test includes the deliberately retained 15-second startup backfill delay, so its 19.1-second drain is not a steady-state capture latency benchmark.
- Native isolated harness: 6 tests passed on the explicit recording, including actual native/Whisper comparison and cancellation (`/tmp/retrace-native-speech-actual-3.log`).
- Capture isolated harness: 11 tests passed, followed by 2 additional passing checks for priming continuity and unstarted system-stream closure (`/tmp/retrace-capture-review-green.log`, `/tmp/retrace-capture-priming-green.log`). These exercise real AVFoundation/CoreMedia buffers and an unstarted AVCaptureSession, without recording.
- Historical baseline: the earlier 507-test run had 89 assertion failures; 88 were independently reproduced from the saved pre-change source in the six legacy groups (`/tmp/retrace-baseline-legacy-groups.log`). The remaining queue fixture handoff was corrected in the first delivery. The follow-up resolves the legacy failures and preserves both public video-cascade and low-level foreign-key behavior in separate real SQLite tests.
- The earlier delivery's final code review found no remaining material issues. `git diff --check` and the continuous-clock sleep guard passed. That evidence did not establish live capture, sleep/wake or installed lifecycle behavior; subsequent installation and observations are recorded below.

## Local trial: 2026-09-06

The first trial installed **0.7.6, build 2609.6.1**, and launched at **2026-09-06 13:41:38 UTC / 23:41:38 Brisbane**. The installed executable SHA-256 was `4eaca6ab74e24ec84a74dd58924d01aa30712367e0574f5c5c890ba2f885e5a8`. Dashboard, timeline and search opened, and capture/audio were active. Production transcription remained CPU Whisper. Preferences were unchanged: processing level 1, one worker, 0.25 FPS limit; AC power with Low Power Mode enabled.

The previous executable was dated 2026-08-26, with unresolved numeric version placeholders and SHA-256 `7ce868100cc262e392c3bc51814df184b7d16a00b1b6d93e836354da7efafed3`. The old app did not exit after Quit and was subsequently force-quit. Its signed bundle, preferences and persisted-data recovery snapshots are retained at `/Users/stuartbond/Library/Application Support/Retrace Backups/2026-09-06-local-trial/`. The pre-switch SQLite database/WAL snapshot was cloned while the old process was stopped with `SIGSTOP`, then resumed with `SIGCONT`; this preserves persisted state, with no guarantee for audio/capture still buffered in memory. Existing recording media remain in place. No destructive cleanup was run.

### Observed behavior and comparison limits

- The first observed OCR request processed old backlog in **479.34 seconds**. The first observed fresh-frame OCR took **39.68 seconds**. These request observations are not end-to-end capture-to-search measurements.
- The old build's 30-second baseline had median process CPU **65.8% of one core** and RSS **2377 MiB**. The first trial's startup sample had medians **115.7%** and **1283 MiB**. The different startup/backlog/workload conditions make this unsuitable for a performance or memory-improvement claim; neither sample measures energy.
- The synthetic in-app-browser page returned no matches in old/new probes, but its foreground capture visibility was not verified. Those probes are invalid for latency comparison. A native Chrome probe also had not yet been proven present in captured frames.
- The older 2026-09-05 journal `1788533665295` contains **one 1×1-pixel Chrome capture in 190 bytes**, linked to database frame `50728402`. It cannot produce valid readable encoded recovery output. The raw source and database records remain intact; this is a legacy one-pixel capture, not a large damaged archive. Evidence: `/tmp/retrace-local-trial-20260906/legacy-wal-observation.json`.

### Scheduling probe

Eighteen isolated Vision requests used three selected screenshot fixtures in forward and reverse order. Settings were accurate recognition, en-US, language correction off, a 1.75-megapixel budget and one process per request with a 30-second timeout. The Mac remained on AC with Low Power Mode enabled. Evidence: `/tmp/retrace-local-trial-20260906/vision-probe/results-combined.json`.

| Worker priority | `preferBackgroundProcessing` | Completed | Request duration for completed runs | Timeouts at 30 seconds |
|---|---|---:|---|---:|
| Background | `true` | 2/6 | 6.31 and 24.58 seconds | 4 |
| Utility | `true` | 6/6 | 1.46–3.93 seconds | 0 |
| Utility | `false` | 6/6 | 1.47–3.33 seconds | 0 |

The utility advantage persisted with reversed order. Completed requests returned the same region count per fixture; equal counts do not prove equal text accuracy. The incomplete background sample cannot support a normal median comparison. This is an isolated scheduling diagnostic, not a full-app throughput, energy or accuracy result. Apple documents that [`preferBackgroundProcessing`](https://developer.apple.com/documentation/vision/vnrequest/preferbackgroundprocessing) can reduce resource contention at the cost of longer execution time.

### Follow-up corrections included in build 2609.7.1

Live investigation found that startup recovery could reset OCR claims after workers had begun processing, and that background scheduling could greatly delay Vision work. The follow-up sequences recovery before worker activation and owns the startup task so shutdown cancels and joins it. Cancellation propagates to the inner recording-journal recovery task; checks before work and after enqueue preserve source/checkpoint material and retry with the same frame identifiers. Processing levels 1/2 now use utility priority while retaining one worker, their 0.25/0.5 FPS limits and existing saved preferences.

- Final source validation: **548 tests, 4 skips, 0 failures**, with 14 passing focused startup/recovery cancellation regressions and approved final App/Storage/Processing review; see the validation history above.
- The release package was installed and launched as **0.7.6 (2609.7.1)**. Fresh-frame capture-to-search timing, sleep/wake and representative daily storage/energy/accuracy comparison remain unverified.

## Corrected local trial: 2026-09-07

Build **0.7.6 (2609.7.1)** launched at **2026-09-07 00:41:18 Brisbane / 2026-09-06 14:41:18 UTC**, running from `/Applications/Retrace.app` as PID `42759` during observation. The installed executable SHA-256 was `f96222cd1e47be164215b86e47b62d35f2e6697dab7add5a1e495b59c285761e`; the signature passed strict verification. The process and executable identity remained stable throughout the sampled checks.

The first trial quit normally through the app's Quit flow. Its app is retained at `Retrace Backups/2026-09-06-local-trial/First trial 2609.6.1.app`, alongside `Pre-corrected-switch data` and the saved first-trial preferences. Before quitting, the user selected **level 3, Balanced**. The replacement preserved that preference: one worker, 1 FPS, utility priority, `preferBackgroundProcessing=true`, AC power and Low Power Mode enabled. This differs from the original level-1 baseline and prevents an equal-settings speed comparison.

### Installed observations

- Startup recovery took **83.47 seconds**; OCR workers started **28 ms after recovery completed**. The retained legacy one-pixel journal described above remains unresolved. No source or database cleanup was performed.
- By **2026-09-06 14:47:38 UTC**, logs showed **11 queue completions and zero queue failures**. Mixed queue service duration was p50 **23.055 seconds**, p95 **41.14 seconds**. These are service times across the observed work, not capture-to-search latency.
- The approximately 90-second post-recovery observation covered **nine new frames, all still pending**, with nine backlog frames completed since launch and **192 priority-10 items still eligible/pending** at its end. No fresh indexed frame was available from this cohort to establish capture-to-search timing or OCR accuracy.
- In that post-recovery window, median process CPU was **152.4% of one core** and RSS **1452.3 MiB**. Startup, backlog and the changed processing level make this an unfair comparison with the previous build's baseline. Disk growth and energy were not measured.
- Audio continued producing transcripts; the latest transcript's start was **23.4 seconds before the final post-recovery observation**. Thirteen audio saturation warnings recorded batches persisted to disk. This preserves work for processing, but does not establish low-latency transcription or verified speech accuracy.
- Existing-text search returned **15 visible results**, and selecting one navigated to its historical timeline frame. The initial older selected frame displayed **“Frame not ready”**; Refresh rendered a newer capture. Corrected-build frame `50730833` opened and then closed/reopened successfully, while its OCR queue position moved from **186 to 185**. A perfect startup/no-stale-frame smoke check is not claimed.
- General and Storage settings opened; the folder picker opened and was canceled without a storage change. The final visible window was the Dashboard's Screenshots view showing recording. The three temporary decoded JPEG fixtures, owned browser probe tabs, local fixture server and test RTF were removed or closed.
- Two bounded index-consistency read attempts did not complete. This trial therefore adds no completed full-index consistency or text-accuracy result beyond the scoped automated tests.

Evidence in `/tmp/retrace-local-trial-20260906/`: `corrected-build.json`, `corrected-launch-observation.json`, `corrected-ui-validation.json`, `final-live-observation.json` and `post-recovery-live-observation.json`. Log-derived timings and warning counts are saved in `corrected-startup-metrics.json`, with their bounded source excerpt in `corrected-startup-through-144738.log`. The first live sample covered startup; the second covered post-recovery activity. Their frame cohorts and pending results must remain separate from mixed queue service metrics.

### Assessment and remaining issues

At the final handoff check (**7 September 01:00:50 Brisbane**), the same corrected process and executable hash were still active. **82 captures made since launch remained pending OCR**, and the latest capture was 0.53 seconds old. This later count covers a larger cohort than the nine-frame observation above; it confirms ongoing capture and unresolved text freshness. Evidence: `/tmp/retrace-local-trial-20260906/final-handoff-status.json`.

The main remaining issue is **backlog plus slow OCR**, which makes a new screenshot available before its text is searchable. To assess a frame, confirm the screenshot actually contains a distinctive phrase, wait for **Text ready**, then search that phrase and check the highlight. Record capture time and readiness time separately from search response time. Opening a frame does not request an OCR priority boost in this build.

Use the same processing level, power mode and representative workload for a future old/new comparison. Sleep/wake, sustained recording/shutdown behavior, verified transcription/visible-text accuracy, daily disk growth and energy remain outstanding. The successful tests and live startup check do not resolve those measurements.

User assessment and managed rollback notes are also available in [Retrace local trial](/Users/stuartbond/Downloads/retrace-local-trial-2026-09-06.md).

## OCR backlog investigation: 2026-09-07

The user's selected screenshot exposed both a real queue backlog and a stale Dashboard status. At 01:04 Brisbane, the database held 61,063 pending queued frames: 262 at priority 10, 60,791 at priority 0 and 10 deferred at priority -1. Most were captured from 26 August onward. A later check found no pending frames missing a queue entry. Existing completed/failed queue rows were excluded from these pending counts and left intact.

Automatic priority never expired in the old scheduler, so a growing queue of formerly recent captures could delay new work. Its historical lane also favored priority 0 ahead of deferred negative priorities. The queue repair treats automatic priorities 1–10 as current only for captures made within 60 seconds, then uses historical FIFO across expired automatic, zero, negative and NULL priorities. Three current claims allow one historical turn. Manual priorities above 10 retain precedence without changing that counter. Claims, duplicate removal and publication remain transactional; no migration or queue reset is required. Displayed positions follow this same schedule.

Focused real-SQLite checks reproduced the old ordering failures and then passed **23 tests, zero failures in 1.921 seconds**, with independent code review approved. The combined queue-source full suite passed **557 tests, 4 opt-in skips, zero failures in 137.219 seconds** (`/tmp/retrace-ocr-diagnosis-20260907/full-suite-corrected-fixtures.log`). An initial run failed because the temporary JPEG names were not timestamps; the queue integration test skipped all three inputs. Renaming those selected fixtures to the required timestamp format resolved the failure without a production or test-code change. This full-suite result predates the subsequent Dashboard refresh fix. Tests include actual claim query plans, rollback, duplicate frames, deferred retry order, manual precedence and displayed position agreement. Evidence: `/tmp/retrace-queue-fairness-red.log` and `/tmp/retrace-queue-fairness-final-green.log`.

### Combined-build timeout and host load

The first combined queue/UI application compiled in 193.37 seconds. Its real screenshot-to-search test hit its unchanged 120-second drain limit after completing two of three valid fixtures; the third had already been claimed and was still processing. Those two jobs spent 13.7–14.0 seconds extracting frames and 39.8/74.5 seconds in OCR, while database preparation/indexing remained milliseconds. The same inputs had completed much faster in the earlier passing run. A process sample found the remaining worker inside native Vision/TextRecognition waits, not blocked on queue selection. No queue error or retry was logged; the timeout does not establish a lost frame. Evidence: `/tmp/retrace-ocr-diagnosis-20260907/full-suite-final-reviewed.log` and `full-test-process.sample`.

At 02:09:15 Brisbane, a host snapshot showed 938 processes, 112 running, a one-minute load average of 229.11, no idle CPU and roughly 33 GB of compressed memory. This is a heavily loaded observation, not proof of the exact cause of each native request delay. No unrelated process or Mac power setting was changed. The timeout result remains part of validation history; later retries must be recorded separately. The full run finished **562 tests, 4 opt-in skips, three assertions failing in that one timed-out test**, in 409.390 seconds. All five new Dashboard checks passed in the full application. The affected screenshot test then passed **unchanged on a separate rerun in 23.374 seconds**, with all three frames indexed and a 22.5-second queue drain (`async-pipeline-unchanged-rerun.log`). Its OCR durations were 2.476, 5.260 and 3.957 seconds. No test deadline, input or production setting was changed. All tests have passing results across these runs; this is not a claim that the initial 562-test run was clean.

### Selected screenshot and native OCR diagnosis

The selected frame `50730913`, captured at 01:01:12 Brisbane, was still pending at 01:29. One bounded diagnostic promoted its existing queue row from priority 10 to manual priority 100; it did not reset the frame, rewrite OCR or remove media. About 22.6 seconds later, the frame was complete with **66 stored text regions**, one linked search document, no missing node text in that document and a successful actual row-restricted FTS phrase lookup. This proves the selected frame was waiting for processing; the interval includes in-flight work and is not an automatic capture-to-search benchmark. Evidence: `/tmp/retrace-ocr-diagnosis-20260907/manual-priority-check.json` and `manual-priority-result.json`.

At 01:38, the Dashboard still displayed “Indexing text” for that completed frame. Its eight-second refresh only fetched the newest 18 frames, leaving older selected rows unchanged. The cache comparison then compared two stale status values. This is a separate presentation defect; the real queue backlog also remains.

The reviewed UI repair uses `DashboardSelectedFrameRefresher` to read the selected native frame by ID and, when its cache is stale, load completed OCR nodes. Dashboard selection and periodic refresh use this production helper. Results update only the same selected ID/source still retained in the list, without changing order or selection. Concurrent reads join; synchronous selection invalidation and tab/window cancellation prevent older requests from publishing after a change. Polling restarts when the window reopens. The legacy text loader also checks the retained processing status and no longer caches read errors as completed empty text. The actual read is measured by `dashboard.selected_frame_refresh`; it performs no priority promotion or recorded-data writes.

`UI/Tests/DashboardSelectedFrameRefreshTests.swift` exercises the production helper and reconciliation against real SQLite. The initial older-frame regression failed **three status/cache/text assertions in one test** (`/tmp/retrace-dashboard-selected-red.log`). The final focused run passed **5 tests, 0 failures in 0.707 seconds** (`/tmp/retrace-dashboard-selected-final-green.log`): an OCR commit for a selection outside the newest 18 frames, joined reads with a canceled waiter, invalidation and same-ID reselection, removed/changed selection, and retry after an actual SQLite node-table read failure. Independent review approved the helper and View lifecycle wiring. These checks also passed in the combined application run. Installed older-selection behavior was subsequently verified in build 2609.7.2 below; this scoped test result alone does not establish OCR speed.

A five-second process sample showed the worker inside native Vision text recognition and Apple Neural Engine calls. Sixteen controlled requests on two actual slow frames all completed within 30 seconds. Median durations were 4.950 seconds with Vision's background preference and 3.958 without; the ranges overlapped substantially (2.021–6.354 and 2.543–10.944 seconds). A separate fixed-preference executor comparison found medians 3.628 seconds on GCD utility and 2.919 on a utility Swift task, again with overlapping ranges. Region counts matched by fixture, which does not establish text accuracy. These results do not justify a GCD rewrite or disabling Vision's background preference. Evidence: `/tmp/retrace-ocr-diagnosis-20260907/execution-probe/summary.json`.

The app also accelerated for a period without any settings or code change. The cause of varying native OCR service times is not established. Balanced level 3, one worker, Vision's background preference and the Mac's power settings remain unchanged. A 61,000-frame historical backlog is not cleared by changing its scheduling policy; sustained catch-up rate, energy and accuracy still need observation.

## Queue and Dashboard local trial: 2026-09-07

**0.7.6 (2609.7.2)** launched at **02:22:13 Brisbane / 16:22:13 UTC on 6 September**, PID `96541`, from `/Applications/Retrace.app`. SHA-256: `1432a2b9fa69e596c64245324e5cbe7cdeaad1324189f5d5c849b95af27719a5`. The installed signature and actual loaded bundled Sparkle/Whisper libraries were verified. Release compilation took 457.68 seconds. The previous build quit normally; `Corrected trial 2609.7.1.app`, its preferences, `Pre-queue-repair-switch data` and the snapshot manifest are retained in the existing local-trial backup folder. Capture and Balanced level 3 continued with one utility worker, 1 FPS limit, Vision background preference and Low Power Mode on AC unchanged.

A fixed post-worker-warmup cohort from **16:23:36 through 16:25:06 UTC** contained **22 captures, all completed**. Capture-to-completion duration was minimum **18.913s**, median **41.1305s**, nearest-rank p95 **49.244s**, maximum **49.778s**. Exact frames `50731931`, `50731942` and `50731952` each had one search document, 48/51/47 stored regions respectively, and a successful actual FTS phrase lookup. No manually promoted frame was in this cohort. These are completed-capture timings with the full cohort denominator retained, not OCR service times or a verified text-accuracy result. Different host load/workload prevents treating the earlier pending-only cohort as a controlled benchmark. Three historical captures from 26 August (`50670434`–`50670436`) also completed after launch with stored regions and search documents.

Selected frame `50731896` remained pending behind 75 newer captures. A bounded diagnostic promoted its existing queue row from 10 to 100 without resetting the frame, text or media. It completed with **56 regions and one searchable document**, and the unchanged Dashboard selection automatically changed from “Indexing text” to **“Text ready”**. This verifies the actual older-row refresh bug in the installed app; it is separate from automatic capture freshness. A subsequent Cmd-W check returned the Dashboard with the same completed selection, but a closed intermediate window was not observed, so this alone is not a definitive close/reopen lifecycle proof.

Evidence in `/tmp/retrace-ocr-diagnosis-20260907/`: `queue-repair-build.json`, `queue-repair-launch.json`, `queue-repair-fresh-capture-proof.json`, `queue-repair-history-proof.json`, `dashboard-live-priority-check.json` and `dashboard-live-refresh-proof.json`. Only aggregates and identifiers are retained in these JSON files; sampled phrase text stays inside SQLite.

### Recovery journal ownership follow-up

Startup exposed a competing cleanup path: `AppCoordinator.resumeWriterState` deleted WAL `1788711659692` at **16:23:15.537 UTC** because the old encoded file was nonempty, while RecoveryManager was still replaying it. Recovery's subsequent checkpoint write failed because its directory had disappeared. In this launch, all ten frames had already been remapped to video `1009873` (`chunks/202609/07/1788711737549`); all ten indices and queue entries were verified. The recovered output has ten compressed video packets, versus six in original video `1009871`, which has no remaining frame links. The selected final recovered frame also rendered and later passed OCR/search checks. No restoration or live database repair was necessary.

The App-only correction removes this independent journal deletion while preserving file-size inspection, writer creation, old-video database finalization and new-video insertion order. RecoveryManager retains sole ownership of verified recovery-source cleanup. Real WALManager/filesystem tests reproduced deletion of raw frames, metadata and checkpoint files for both extensionless and legacy video layouts: **two tests, ten failed assertions/errors**. Corrected isolated tests passed **11 checks**, including nine existing recovery tests. Final normal App integration passed **16 tests, zero failures in 55.145 seconds** after a 21.48-second build. Independent review approved the patch. The correction was subsequently installed as **2609.7.3**; final launch evidence is recorded below.

Evidence: `recovery-resume-race-evidence.json`, `/tmp/retrace-interrupted-wal-red.log`, `/tmp/retrace-interrupted-wal-isolated-red.log`, `/tmp/retrace-interrupted-wal-isolated-green.log`, and `recovery-final-app-tests.log`. The retained legacy one-pixel journal is a separate earlier issue; this repair does not delete it or claim its image is recoverable.

## Source-readiness follow-up: 2026-09-07

Build **2609.7.3** launched at **02:51:59 Brisbane**, PID `405`, with installed SHA-256 `d913ea346449467053ee2c70b19f2c0b19e7e6b0dac86f33dda42f3cf267130f`. Strict signature verification and the loaded bundled Sparkle/Whisper libraries passed. Build compilation took 458.41 seconds. The prior build quit normally and is retained as `Queue trial 2609.7.2.app`, with preferences and `Pre-final-recovery-switch data`.

Recovery ran for **58.431 seconds**; workers started **24 ms afterward**. Two frames recovered into a valid two-packet output with stable identifiers and completed OCR. There were no competing App journal deletions or missing-folder checkpoint errors. The interrupted old video was empty on this launch; regression tests cover the earlier nonempty-file trigger. The known legacy 1×1 journal remains retained. Evidence: `final-recovery-live-proof.json`.

A separate race occurred while startup orphan cleanup took its WAL snapshot: new video `1009880`, path `1788713579697`, was inserted before its first WAL append and was marked finalized at **16:52:59.890 UTC**. Periodic metadata updates do not change processingState. Subsequent captures therefore took the encoded-video path despite intact exact-ID raw records. The partial 90-second cohort observation had **6 completed and 7 failed frames** before the window closed; it is not a successful freshness benchmark. Decoder logs also showed completed reads accepting the previous timestamp, so those completion results do not prove correct screenshot text.

The affected video finalized normally at **03:00:00.819 Brisbane**, containing **64 HEVC packets**, exactly matching its 64 database indices and the synthetic 30 fps timestamps. Before correction its status counts were 36 completed, 27 failed and one pending. No frame or recording had been deleted. On 7 September at approximately **03:04 Brisbane**, a bounded transaction requeued all 64 frames at diagnostic priority 100. Existing nodes and search documents were preserved until each successful atomic OCR commit. A coherent persisted-database clone and the finalized affected video were saved in `Pre-source-repair data`. A proposed live processingState repair was not executed because preflight detected that the video had already finalized normally. All 64 subsequently completed after the repair commit, with the last completion 74.047 seconds later. First, middle and last samples had 73, 73 and 71 regions and each passed a real FTS lookup. Evidence: `affected-video-reprocessing-proof.json`.

The strict encoded-read regression creates a real HEVC timestamp gap. Before the correction, requesting index 1 at 0.033 seconds accepted the image at 0.000 seconds, producing one test failure. After correction, strict reads throw after a fresh-generator mismatch while explicit tolerant playback succeeds. All **11 StorageManager tests passed, zero failures in 0.651 seconds**, after a 2.73-second build. The source for **2609.7.4** is independently reviewed and frozen. Normal combined application validation passed **71 tests, zero failures in 131.891 seconds**, after a **225.17-second build**. This includes queue persistence, Dashboard refresh, source readiness, wake signal, orphan ownership, startup sequencing, StorageManager and WAL recovery. It is a focused combined run, not a replacement claim for the earlier 562-test full-suite history. Evidence: `source-safeguard-app-tests.log`. The optimized release build subsequently passed in 626.51 seconds; signed-candidate status is recorded below.

The App repair snapshots unfinalized candidates before WAL lookup, protects writer paths before placeholder insertion, and finalizes only known orphan IDs. A concurrent insertion, pre-WAL live placeholder, real WAL-backed candidate, latest metadata, cancelled insertion and cancelled sweep have real SQLite/filesystem coverage. RED reproduced six assertions across three cases; six focused checks then passed. Review caught an ownership leak after encoder success but database failure: a real SQLite trigger reproduced two failures. The final production helper releases ownership with `defer` around metadata publication, keeping concurrent sweeps excluded until success or failure. All **seven orphan tests passed, zero failures in 0.634 seconds**. Exact helper extraction is scoped evidence; the normal application test follows separately.

Processing now prefers available exact-ID raw WAL frames even when finalized metadata is stale. A temporarily unavailable live source releases its claim at automatic priority 10 without consuming error retries; the existing 60-second capture-age expiry and historical fairness remain. A real priority-zero backlog test reproduced the former priority -1 deferral burying fresh work. WAL file presence alone is not considered live ownership: retained unreadable journals with finalized metadata fall through to strict encoded media or bounded terminal handling, preserving evidence. A retained-WAL regression reproduced two failures before this correction. **Eight source/wake checks passed, zero failures in 76.339 seconds**, including four real SQLite/claim/WAL source tests.

Storage exposes actor-owned live-session membership separately from retained files. The final strict-read/live-ownership run passed **12 checks, zero failures in 1.759 seconds**. Logs: `/tmp/retrace-orphan-snapshot-red.log`, `/tmp/retrace-orphan-publish-red.log`, `/tmp/retrace-orphan-publish-final-green.log`, `/tmp/retrace-processing-priority-red.log`, `/tmp/retrace-processing-retained-wal-red.log`, `/tmp/retrace-processing-source-reviewed-green.log` and `/tmp/retrace-source-storage-final-green.log`. Reviewed source hashes are in `source-safeguard-reviewed-source.json`.

Evidence in `/tmp/retrace-ocr-diagnosis-20260907/`: `final-build.json`, `final-launch.json`, `final-installed-identity.json`, `final-fresh-capture-proof.json`, `affected-video-finalized-proof.json` and `affected-video-requeue.json`. Strict decoder RED/GREEN logs are `/tmp/retrace-strict-frame-red.log` and `/tmp/retrace-strict-frame-green.log`.

## Earlier signed candidate and unlock checkpoint: 2026-09-07

At this checkpoint, **2609.7.4** was packaged at `/tmp/retrace-ocr-diagnosis-20260907/Source-safe Retrace.app` and staged at `/Applications/.Retrace-install-2609.7.4.app`. The hidden candidate was subsequently moved to the canonical app path during the installation below. Executable SHA-256: `c478796fcdadbeeb494ab14b77e93807d33e771071fe2c30260a1e84c9f2ca32`. The complete bundle retains its resources and bundled Sparkle/Whisper libraries, and strict signature verification passed. The 13 reviewed source hashes were unchanged during the combined test and release builds. Optimized compilation took **626.51 seconds**.

At the final checkpoint, `/Applications/Retrace.app` remained build **2609.7.3**, PID `405`, SHA-256 `d913ea346449467053ee2c70b19f2c0b19e7e6b0dac86f33dda42f3cf267130f`. macOS reported `CGSSessionScreenIsLocked=true`; CUA could not access the app window. The latest screenshot was frame `50732201`, captured at **03:08:39 Brisbane**, and its text was complete. New capture freshness cannot be measured while the screen is locked. Earlier progress updates saying capture continued during compilation were too broad after this lock; they must not be treated as uninterrupted-recording evidence.

A bounded read-only count found **58,948 distinct pending queued frames** at approximately **03:35 Brisbane**. The historical backlog is not cleared. No restart, forced quit, lock bypass or power/preference change was performed after discovering the lock. The user was asked to unlock macOS. After unlock, the remaining work is a fresh persisted-data/preferences snapshot, normal app quit, preservation of the current bundle, canonical replacement with the signed candidate, and verification of startup recovery, actual process identity, selected-frame UI and fresh OCR/FTS. The candidate's source/build success is not installed-app proof.

Evidence: `source-safeguard-build.json`, `source-safeguard-app-tests.log`, `source-safeguard-release.log`, `screen-lock-checkpoint.json` and `source-safeguard-handoff.json` in `/tmp/retrace-ocr-diagnosis-20260907/`.

## Source-safeguard local trial: 2026-09-07

After the user resumed and the Mac was verified unlocked, a fresh coherent APFS clone preserved the database, SQLite WAL/SHM and interrupted recording material. Snapshot time was **10:10:22 Brisbane**. The previous build quit through its normal Quit flow; its bundle is retained as `Recovery trial 2609.7.3.app`, alongside `Pre-source-safeguards-switch data`, `recovery-trial-2609.7.3-preferences.plist` and `source-safeguards-switch-snapshot.json` under `~/Library/Application Support/Retrace Backups/2026-09-06-local-trial/`. Existing media remain in place.

The canonical `/Applications/Retrace.app` launched **0.7.6 (2609.7.4)** at **10:11:25 Brisbane / 00:11:25 UTC**, PID **74615**. Its executable SHA-256 is `c478796fcdadbeeb494ab14b77e93807d33e771071fe2c30260a1e84c9f2ca32`. Independent preflight verified the staged signature/resources and all 13 frozen source hashes; runtime verification confirmed the installed identity and executable hash. No source changes were made during this resumed installation. Balanced level 3, one worker / 1 FPS / utility priority, and Low Power Mode on AC were preserved.

Startup recovered **two sessions / 25 frames**, finalized one orphan, and completed recovery before workers started at **10:13:29.274**. The known legacy one-pixel WAL `1788533665295` remains preserved. The bounded log observation found no additional retained-WAL failure, wrong-timestamp read or source-read error. Startup required approximately two minutes before workers activated; absence of a new error is not proof of every recovery scenario.

The fixed capture cohort was **10:13:45.274–10:15:15.274 Brisbane**, beginning 16 seconds after worker startup and lasting 90 seconds. It contained **11 frames**. At **10:19:06**, **two were completed, nine pending, none failed**. The completed frames took **60.135 and 105.671 seconds** from capture; their completed-only p50/p95 were 82.903/103.394 seconds. With nine still pending, these percentiles are not the full cohort's latency. Both completed cohort frames and a third earlier post-launch frame passed actual nonempty OCR plus row-restricted FTS lookups without disclosing private phrases. The third frame took 117.515 seconds from capture.

One historical frame captured more than 24 hours before launch completed. A separate queue snapshot held **39,325 rows / 39,323 distinct frames**; the pending-only status join exceeded its three-second query bound, so this is a queue-membership count rather than an exact count of unfinished OCR. The observation exceeded the intended five-minute bound; the final cohort snapshot was at 10:19:06 and the measured-job cutoff was 10:19:12. No queue reset, manual promotion or data repair occurred in this trial.

Seven completed jobs through **10:19:12** spent **324.425 of 327.082 seconds (99.19%)** in the OCR stage. The six fresh 3840×2160 jobs took **6–26 ms** to read their frame and **22.8–63.8 seconds** in OCR. Indexing across all seven took 613 ms total. A three-second process sample at 10:14 placed the OCR worker in Vision/TextRecognition internal waits, rather than storage or SQLite. At approximately 10:19, the ten-logical-CPU Mac had load averages **248.77 / 248.84 / 203.99**, with **16.57 GiB swap used**; Retrace used 151.7% of one core and approximately 1.72 GiB RSS. These are point observations, not energy measurements or proof of the precise cause of the native Vision wait. They prevent a fair old/new speed conclusion.

The Dashboard showed **Recording** and loaded screenshot history. Selected frame `50733139` opened in the timeline at its matching 10:10:46 timestamp without a missing-frame message; the Dashboard was recording again afterward. The second open's subsequent accessibility read returned the Dashboard, so a repeated-open/no-hitch guarantee is not claimed. This older selected frame remained pending; the .2 trial's verified automatic Text ready transition is recorded separately above. No new selected-frame refresh success is inferred from a pending frame.

One initial microphone conversion warning did not repeat, and later audio batches were persisted. Repeated transcription saturation warnings remain; this check does not establish healthy live transcript latency. The installed build is available for assessment, but OCR throughput, backlog completion and sustained audio processing still require work. No equal-workload accuracy, daily storage or power improvement is established.

Evidence in `/tmp/retrace-ocr-diagnosis-20260907/`: `source-safeguard-launch.json`, `independent-preflight-2609.7.4.json`, `independent-runtime-2609.7.4.json`, `independent-ocr-performance-2609.7.4.json`, `independent-source-startup.log`, `source-safeguard-startup.sample` and `source-safeguard-ui.json`. The source/test/build record remains in `source-safeguard-build.json`.

## Next rollout measurements

Measure capture-to-search p50/p95 separately for recent captures and backlog, plus queue depth/age and OCR latency. Measure CPU and RSS for both Retrace and Apple's separate AI service processes, then compare GB/day of retained media and database growth using the same workload and retention policy. Run sleep/wake, source restart, mute/unmute and shutdown-drain checks. Use verified transcripts across quiet speech, names and representative languages before deciding whether to route production work to native Speech.
