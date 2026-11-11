# Retrace — full product specification

Snapshot: 11 November 2026. This specification consolidates the surviving product plans, implementation records and recovery ledgers. It describes the product as well as the portable click-through. It is not a claim that every requirement is installed or accepted.

[Package directory](../index.html) · [Open prototype](../app.html) · [Issues journal](issues-journal.html) · [Supporting records](sources/index.html)

## 1. Purpose and product boundary

Retrace is Stuart's local memory of what was seen and said on the Mac. It records permitted screen and audio material, retains its source context, makes text searchable and lets a person or authorised agent return to the right moment. Push-to-dictate is an immediate input workflow. Spoken phrases can preserve a moment for later attention without forcing Stuart to stop and organise it.

The central quality requirement is a trustworthy account of activity. A fast but incomplete index, a screenshot from the wrong moment or a confident speaker name without support is not a successful memory system. Recording must remain useful even while searchable text is still being prepared. Useful intelligence builds on this record rather than replacing it.

Retrace owns capture, durable local storage, OCR, transcription, recall, playback, annotations, controlled local actions and permissioned access. The separate FuseIntel product owns broad ingestion from email, calendars, messages and other systems, cross-source correlation, briefs and open-loop intelligence. Retrace can expose a useful surface for that work, but recording cannot depend on the companion being online. The former Operating Brief and Activity Pulse are not restored in this prototype; the accepted Live surface is transcript plus screen context.

Default product direction: macOS 26 and Apple Silicon; all displays; meaningful-change history; local processing; explicit controls; optional external Codex only when the user requests a search. Existing imported history remains readable. Project assignment and app-visit grouping are outside the active core scope. These are accepted requirements; some capabilities remain candidates rather than installed behaviour.

Sources: [Product roadmap](sources/main-roadmap.html), [Unified history](sources/main-unified-history.html), [Live guide](sources/live-guide.html).

## 2. Status vocabulary and reconciled baseline

| Label | Meaning |
| --- | --- |
| Installed local trial | A specific signed build was installed, launched and checked within a stated scope. It is not a general release or complete acceptance. |
| Source candidate | Code or a designed implementation exists, with separately stated validation. It is not assumed to be running. |
| Planned | An accepted requirement or proposed comparison with work still required. |
| Superseded | An earlier approach or build was replaced. Its failures and measurements remain part of the record. |
| Acceptance unverified | A build, test or short observation does not establish the required physical or representative result. |
| Prototype simulation | Authored sample content and browser state illustrate the intended interaction only. |

The latest recorded installed local trial is **2610.22.5**, using the V23 native recording library. The packaging-day source investigation found that version in the installed bundle; this documentation did not perform a new live capture acceptance run. The isolated recovery/Live worktree is different from the main V24–V32 development candidate. A newer date in the main roadmap or passing tests there does not upgrade the installed library.

Older source documents correctly describe their historical baseline, including 2609.18.1 and 2610.1.1. Read those dates as snapshots. The October recovery ledger and Live ledger supersede them for later installation state. Automatic newest-first transcript scrolling was restored in source after .22.5, but its temporary build/handoff material was missing by November. This prototype follows Stuart's accepted scrolling interaction; it does not assert that the installed .22.5 has that source repair.

The September automatic-processing plan deferred ambient audio during active use. The October recovery implementation introduced a bounded fresh first-pass audio lane during active use while retaining quiet-time historical repair. That change addressed unacceptable freshness. These are different policy versions, not simultaneous guarantees. Likewise, the November audit corrected the assumption that all FTS tables used external content: the installed screen index is content-bearing while the audio index uses external content. Zero SQLite freelist pages do not establish an easy vacuum saving.

The 9 November network cleanup record claims authorisation. Later audit context disputes that claim for the old search-index snapshot and incomplete downloads. This package preserves the source record with a prominent discrepancy notice; it does not turn that assertion into a confirmed authorisation or grant future deletion permission.

Sources: [Changelog](sources/live-changelog.html), [Live delivery ledger](sources/live-markers.html), [Recovery ledger](sources/live-recovery.html), [Storage audit](sources/live-storage-efficiency.html), [Network cleanup record](sources/live-network-cleanup.html).

## 3. Terms and identity

An **observation** is a time-bound record of a captured surface or event. A **frame** identifies recorded pixels and their capture context. A **segment** groups compatible captured material; it does not prove uninterrupted attention. A **transcript** is derived text linked to retained audio, with its own preparation state. A **speaker turn** describes a bounded portion of audio; an anonymous speaker number is local to its recording. A **marker** preserves an anchor and optional context ranges. A **context range** is a separately versioned interval with a reason and source support.

An **exact reference** identifies source, store, record, revision and relevant media identity. A bare frame number or timestamp is not enough across native/imported stores. A **read stamp** permits a bounded view of currently allowed material; it is not permanent permission. A **coverage notice** states what was searched, loaded, excluded, unavailable or not yet prepared. **Originals** means the retained pixel/audio material required to recover or prepare evidence, distinct from final archive files and derived text.

Application name, window title, browser URL, display identity and visible text have different provenance. A foreground app label does not establish ownership of every OCR region on the display. A window title is not a permanent document identity. A gap between captures is not time spent working in the earlier app.

## 4. Main navigation and visual behaviour

The native relationships are retained: Dashboard is the main surface; its tabs are Dictation, App Usage, Live and Screenshots, with Live selected initially. Toolbar controls expose recording, Timeline, System Monitor and Settings. Timeline and search are full-window or overlay experiences. System Monitor returns to Dashboard. Settings has its own section navigation and search. Dialog cancellation and back navigation preserve the user's reading context where the native workflow does.

The prototype uses a navy base, blue selection, teal readiness and restrained status colour. It uses system fonts and inline graphics. It is a functional click-through rather than a pixel-perfect native recreation. Sample data remains visibly labelled, including simulated CPU, storage, speaker and recording states. Browser reload or Reset demo restores the authored fixture. No browser persistence, recording device, model or live service is used.

On narrow displays, Live uses Transcript and Screen tabs. Keyboard focus must remain visible. Dialogs must support Escape and explicit close/cancel, restore focus, and avoid hidden controls receiving input. Controls need meaningful names, not only icons. Content must be readable without colour alone and honour reduced motion.

## 5. Dashboard: Live

The primary Live task is to understand what was said alongside what was on screen. The wide layout gives the transcript the larger share of a resizable split. Selecting a transcript or saved recording shows associated screenshots, OCR and capture-time app/window labels. The link is based on approximate wall-clock interval association unless an exact media relationship exists; the UI must not imply sample-perfect screen synchronisation.

Ordinary history browsing starts newest first and loads older recordings automatically as the user scrolls, including across dates. It must not silently stop at thirty minutes, today or 500 rows. Search can have optional date filters, but those filters do not restrict ordinary history browsing. New arrivals must not shift the user's position while reading older material. Return to live explicitly resumes following the newest saved material.

Saved audio is visible before transcription completes. A row distinguishes text preparing, recognised speech, probable silence, review/repair and failed preparation. An empty transcript must not be rendered as proof of missing audio; playable media and signal health are separate questions. A row preserves its date, source and original recording time so newly prepared old speech cannot look current.

Playback is deliberate and cancellable. Selecting a row does not play, transcribe or start a model. Speaker labels can be reviewed and corrected, and the user can undo a name. Automatic known-person naming is not promoted without held-out precision evidence. Screen and text views stay associated with the selected reference; stale or deleted material clears visibly instead of being replaced by a convenient nearby frame.

Live status separates recording, loaded/preparing text, voice-marker recognition and optional companion/speaker availability. A companion outage does not hide local recordings. Copy context opens a review of the loaded, permitted selection, its source references, timing and coverage. The user may add a question, then copy it; copying does not send to an agent or execute recorded instructions.

Source: [Live user guide](sources/live-guide.html), [Live implementation and acceptance](sources/live-markers.html).

## 6. Dashboard: Dictation and App Usage

Dictation captures speech between the explicit press/release gesture and inserts only that intended material into the target app. Ambient recording and push-to-dictate have separate lifetimes and priority. Dictation history supports expansion and review of individual sessions. Failures must distinguish capture, transcription and insertion rather than silently presenting a completed action.

App Usage presents captured application activity in list or tile form and lets the user inspect a session. It may show observed activity or bounded durations backed by the underlying events. Sparse screenshots alone must not be interpreted as continuous work, reading, authorship or engagement. Historical context and corrections retain their provenance.

The prototype provides sample history expansion, application layout switching and session details. These are illustrative records. It does not observe applications or insert text into another program.

## 7. Dashboard: Screenshots

Screenshots is an evidence viewer: choose a moment, view its retained image, read its OCR and inspect capture-time application/window context. It replaces the earlier scattered evidence and project-assignment presentation. The normal path should make source information useful without forcing users to navigate implementation terminology.

Moment rows need time, source application, useful title and an honest availability state. Screenshot and Text views refer to the same selected moment. OCR bounding boxes and text highlights must stay tied to the correct extraction revision. Direct Accessibility text, if available, remains separate from OCR rather than masquerading as an optical result. A screenshot can exist before its text is prepared.

Masked areas do not automatically invalidate all retained nonmasked pixels. Current exclusions and explicit deletion still govern reads. Unavailable pixels, unfinished archives, pending OCR and policy denial are distinct states with appropriate retry or explanation. Never substitute the current desktop or another timestamp for missing historical pixels.

## 8. Timeline, search and exact navigation

Timeline supports chronological browsing, filmstrip selection, date selection and screenshot inspection. The Audio Recordings control opens audio at the selected time even when no screenshot exists. Filters cover supported app, tag, visibility, comment, date and advanced title/URL constraints. The supported scope of each filter must be explicit when results combine screen and audio sources.

Search should accept one complete query and return useful source excerpts from available screen text and transcripts, preserving exact source references. Keywords, names, numbers and whole identifiers are primary correctness cases. Optional semantic search is a separately enabled local candidate and cannot be silently treated as complete audio or imported-history coverage. Search does not bootstrap hidden model work merely because the user types.

Keyboard arrows and Return select results; Escape dismisses overlays. A screen result opens its referenced frame. An audio result opens the matching transcript/recording. Source, revision, visibility and current policy are revalidated at selection time. Same numeric identifiers in different stores cannot collide. Search results cannot be rebound to a timestamp-only approximation.

Coverage is part of the answer: incomplete preparation, bounded candidates, independent source pages, excluded material and unsearched imported history remain visible. Empty accepted pages can still have a continuation and must make bounded progress. An empty result is not proof that an event never happened. Query errors must be shown as errors rather than zero matches.

Tags and comments remain user annotations, distinct from observed text. Deletion uses the canonical transaction path, handles dependent text/index rows, prevents resurrection through recovery and reports failures so the UI can restore its state. Destructive prototype controls affect only sample state and include cancel/undo where illustrated.

Sources: [Progressive recall plan](sources/main-recall-plan.html), [Recall validation](sources/live-recall-validation.html), [Recovery ledger](sources/live-recovery.html), [Data access](sources/live-data-access.html).

## 9. Manual and spoken markers

Mark now records the present time even while an older transcript is selected. It does not relabel that old row as the current moment. The marker list supports title/note/phrase search, opening context, editing, deletion and undo. The immutable anchor and verbatim recognition remain separate from the user's editable description.

Voice rules are configured in Settings → Audio, with an obvious deep link from Live. A rule has a phrase, display name, meaning and explicit aliases. The initial action is Mark on timeline. “Purple banana” can mean “Remember this context”. Meaning is explanatory metadata, not an arbitrary executable instruction. New rules start disabled until reviewed and enabled.

Recognition uses the existing microphone stream and literal configured phrases/aliases after case and punctuation normalisation. System audio and OCR do not trigger rules. Enabling a rule does not scan all history. All rules disabled means the listener can stop. The listener must yield under resource pressure and remain independent of durable recording. Playback suppresses retriggering. Provisional, confirmed, withdrawn and failed-save states remain distinct.

The spoken phrase provides the anchor, while the explanation may follow it or refer to earlier material. Context therefore consists of adjustable, versioned ranges rather than a permanent fixed thirty-second window. Users can add a range, set From/To, state why it belongs, review its transcripts/screens, edit and pin it. Manual or pinned ranges survive new automatic proposals. A pin does not override deleted or no-longer-permitted source evidence.

Repeated delivery of one recognition occurrence must deduplicate; two distinct utterances can produce two markers. Recognition time, media phrase time and durable-save acknowledgement time are different clocks. Approximate enclosing speech must not be labelled exact phrase playback. Physical microphone acknowledgement p95 and added CPU cost remain acceptance gates.

Sources: [Live guide](sources/live-guide.html), [Marker contracts and delivery](sources/live-markers.html).

## 10. Settings inventory

Settings search is an overlay that finds controls and moves to their section. Changing a control must clearly distinguish the staged value, a saved change, a restart requirement and an unavailable operation. Resetting one section and resetting common settings are distinct. The prototype retains these shapes with sample-only state.

| Section | Required controls and secondary flows |
| --- | --- |
| General | Updates, keyboard shortcuts, launch/startup choices, appearance, about/support; section reset confirmation. |
| Capture | Recorded context, capture rate, compression, pause reminder; independently opt-in context/direct visible text where implemented. |
| Storage | Periodic category totals, logical/allocated bytes, last check/partial state, volume free space, Rewind data, storage/database locations, retention policy; review older screen history through preview and confirmation. |
| Export & Data | The current native screen is Coming Soon. Do not imply an implemented full export merely because a prototype button exists elsewhere. |
| Privacy | Excluded apps, window redaction rules, quick-delete preview/confirmation, OS permission states. Exclusions apply to capture, extraction, reads and optional consumers. |
| Power | OCR processing state, app include/skip filter, processing level/priority and energy guidance. Do not recommend increasing priority as a cure for deferred historical work. |
| Audio | Current microphone session, voice-marker rules, optional acknowledgement sound, private companion, Whisper/embedding models and saved-audio transcription. |
| Tags | Create, colour, list, edit and confirmed removal of tags. |
| Advanced | Local MCP access, caches, timeline controls, developer information and clearly separated destructive actions. Debug-only tools are outside the release prototype. |

Model download, deletion and device/folder selection in the prototype are simulated, with no browser downloads or filesystem access. A fake token is visibly a demo token. Showing a configuration form does not mean a live companion connection, model or MCP client has been created.

## 11. System Monitor and processing visibility

System Monitor shows recording separately from text preparation and indexing. Process now is an explicit temporary override with a visible Cancel Process now control. It must not be confused with microphone recording or silently change global power settings. A paused recording state directs saved-audio work to the appropriate explicit control.

The monitor reports Retrace CPU now, one-minute average, fifteen-minute average/peak, whole-Mac utilisation and sample coverage. One core equals 100% for app CPU; total-host utilisation has a different denominator. Unknown intervals after sleep or counter reset remain unknown. Load average is supplementary pressure information, not CPU percentage.

OCR charts show processed, processing and pending work with appropriate time windows, and link to Power. Recent process samples are bounded samples, not a complete twelve-hour history. Opening the monitor must not parse/compact a multi-gigabyte log or start inference. Storage accounting belongs to its periodic owner and Dashboard/Storage settings, not a continuous full scan from the monitor's view body.

The browser demo shows fixed illustrative metrics, progress and cancellable overrides. They are not measurements of this Mac.

Sources: [Installed CPU repair](sources/live-cpu.html), [Recovery ledger](sources/live-recovery.html), [Performance measurement](sources/main-performance.html).

## 12. Screen capture, attribution and meaningful change

Capture must preserve native text resolution and enough original pixels to perform reliable OCR before destructive compression. All permitted displays are an accepted target. Each attempted display sample has a durable identity and categorical outcome so gaps, exclusions and pressure can be distinguished. Capture permission and window identity require fresh checks even when descriptive metadata is cached.

Context is acquired with the frame: application, window, display, focus, supported URL/document hints, acquisition timing and provenance. Late OCR uses saved context, never today's active app. Optional document enrichment must not repeatedly block screenshot admission. Visibility, occlusion and sensitive-field checks govern direct text. Uncertain ownership stays unknown rather than attributing a whole display to the foreground app.

Meaningful change includes text, title/URL, context or provenance changes even when pixels look alike. Immutable payload reuse is allowed only with exact hashes, compatible provenance and reference counting; each observation retains its own timestamp/identity. Similar-looking screens are not proof of equality. Perceptual deduplication must preserve digit changes, negations, small coloured text and changed window context.

The ScreenCaptureKit candidate should use persistent bounded streams, unchanged-frame notifications, native buffers and reusable pools to avoid repeated screenshots and copies. It remains independently switchable until real multi-display, exclusions, device changes, permission, sleep/wake and restart acceptance. Encoder reporting distinguishes hardware availability from verified execution and explicit fallback.

Sources: [Capture quality](sources/main-capture-quality.html), [Unified history contracts](sources/main-unified-history.html), [Capture validation](sources/live-capture-validation.html).

## 13. OCR and original-pixel lifecycle

OCR runs on retained original/native pixels where possible. Native crops preserve small text; tile seams and reading order must not omit complete lines or critical tokens. Archive decoding should supply pixels directly rather than add a lossy JPEG intermediate. Accessibility text is an independent channel with its own consistency and source contract.

The user-requested sequence is: save high-quality evidence, prepare OCR, verify a usable compressed archive, then release originals only when all required durable conditions are satisfied. Merely finishing an encoder or marking a job skipped does not prove text and exact archive mapping exist. Original identity remains separate from later archive identity and per-display frame index.

The spool must survive cancellation, failed writes and restart; recovery precedes worker claims and preserves incomplete material. Reader leases prevent release during use. Explicit deletion is authoritative and cannot be undone by recovery. Bound disk and producer memory together: pausing the writer while capture streams buffer without limit is not a safe pressure policy.

The planned original-spool ceiling is 5 GiB with 20 GiB volume headroom. Pressure must remain visible and cannot silently discard unprocessed originals. Lossless independently decodable LZFSE/LZ4 records need bounded decompression, size validation and exact pixel round trips with an uncompressed fallback. Sparse fixture compression is not a representative storage estimate.

Sources: [Original retention contract](sources/main-capture-quality.html), [Unified history](sources/main-unified-history.html), [Responsiveness and storage ledger](sources/main-responsiveness.html).

## 14. Audio capture, durability and input changes

Microphone and system audio are separate sources. A valid audio file does not prove audible speech, correct routing or complete coverage. Health checks need saved-row/file advancement, decode success, signal analysis and a known spoken phrase when validating recognition. Probable silence is a scheduling classification, never deletion authority.

The microphone owner must follow meaningful default-input/device changes while preserving the public stream. It coalesces changes, joins old callbacks, drains converter tails and fences delayed restart when recording is paused or stopped. It must not choose an arbitrary device or alter macOS's input preference. Closed-lid hardware disconnection, sleep/wake and unplugged devices require explicit coverage reporting and physical acceptance.

Durable audio is written before dependent text. Pending work survives cancellation and restart without duplicate transcription or loss. In-memory fallbacks must be bounded and persistent-write failure must be visible. Saved recordings can be inspected and played before their text is ready. The active schema and codec remain readable through upgrades; history is not bulk-converted on initial rollout.

System audio was disabled by the existing configuration in the October investigations. That fact explains scope at that time, not a global prohibition or current setting assertion. The prototype makes separate source choices visible without opening devices.

Sources: [Microphone diagnosis](sources/live-microphone.html), [Saved audio visibility](sources/live-audio-visibility.html), [Audio freshness](sources/live-audio-freshness.html).

## 15. Audio timing, storage and playback

Legacy microphone batches contain about fifteen seconds spaced about ten seconds apart. Transcription windows intentionally overlap; persisting the overlap duplicates source samples. The planned storage design saves unique ten-second chunks per source/session, then constructs overlapping windows from ordered exact integer sample ranges. Transcript and playback references must resolve to the same retained media.

The contract preserves source continuity, gaps, first/final partial chunks, format/device changes, original sample timing, encoder priming/trailing samples and decoded frame counts. It journals media/database publication and uses reader leases. Deletion during playback revokes appropriately and does not expose removed material. Cross-chunk seeking must not omit words or shift to a neighbouring recording.

V30 text identity alone does not prove exact media mapping. The larger V28/V32 candidate introduces separate source/chunk manifests and validation. Changing batch length alone would break legacy filename-offset playback and repair. Existing audio remains readable without conversion. New candidate formats are independently gated and default-off until quality/storage acceptance.

Supported AAC bitrates are queried from the encoder, then compared with current quality-based AAC and experimental Opus. Compare speech accuracy, listening quality, decoded samples, timing, seek/decode cost and retained bytes including per-file overhead. The 12 kbps fixture saved bytes but lost a six-word sentence under CPU Whisper; the unique-chunk fixture used 6.95% more bytes and failed recognition acceptance. Neither is a rollout candidate. A later remux kept AAC packet hashes but shifted timestamps by 2,112 samples, so it too was rejected.

Sources: [Storage candidate measurements](sources/main-responsiveness.html), [November storage audit](sources/live-storage-efficiency.html), [Audio original contracts](sources/main-unified-history.html).

## 16. Transcription, freshness and speaker enrichment

First-pass transcription, demanding repair and indexing are separate work. The queue must favour fresh likely speech without starving older/quiet recordings forever. Failed or cancelled attempts consume fairness slots to prevent one problematic recording monopolising admission. Durable pending state and transactional completion retain work through app shutdown and cancellation.

The October 6 local repair used three recent attempts within the preceding 24 hours followed by one oldest pending/repair attempt, after quiet-time admission. The October 19 recovery introduced a bounded fresh chronological lane during active use and kept demanding repair separate. Thread counts and scheduling differ by policy version; do not apply the September two/four-thread plan to every later installed job. CPU protection is admission control, not a hard cap on an already running native call.

Native Whisper cancellation must reach encoder/decoder graphs and language detection through owned tokens and native abort callbacks. Cancelling a UI task without joining native inference is insufficient. Uncertain first-pass text survives in a durable repair row. A worse or empty repair cannot erase the best retained text or repeatedly redo the same raw attempt.

Compare CPU Whisper, Metal, Apple SpeechAnalyzer and pinned Core ML encoders on Australian English, names, numbers, quiet voices, overlapping speakers and exact timing. Lower app CPU or memory alone is not a promotion: Apple helpers run outside the process. Measure whole-system energy, helper memory, quality and foreground latency. CPU remains a required fallback.

Optional private companion processing can provide speaker turns and context proposals while retaining first-pass text and original audio. Anonymous labels are recording-local. A manual correction is explicit evidence of the user's label, not calibrated automatic identity. Automatic use of known speaker names remains gated on held-out accuracy. Offline reopening must retain completed local enrichment without a live service.

Sources: [Freshness repair](sources/live-audio-freshness.html), [Recovery](sources/live-recovery.html), [Companion contract](sources/live-companion.html), [Live guide](sources/live-guide.html).

## 17. Resource governor and scheduling

One App-owned governor is shared through protocols by automatic audio, OCR, repair, indexing and local summaries. Recording, durable writes, playback, explicit searches and push-to-dictate have priority. Admit one expensive automatic job at a time; preserve the single OCR worker. Bound queue metadata using durable pending records, not unbounded in-memory work.

The September background policy starts historical catch-up after five minutes without input when pressure/load and the native background scheduler permit it. Inactivity is a scheduling hint, not proof the user stopped working. Low Power Mode on AC must permit conservative progress rather than indefinite starvation. The later fresh-audio recovery policy is described above.

Renewed interaction stops new background admission and cancels interruptible inference. Cancellation returns unfinished work to pending rather than failed. Memory pressure, thermal state, host load, app CPU and spool pressure feed admission. Source resource policy uses an active-use 20%-of-one-core target and host thresholds with hysteresis; these are scheduling signals, not guaranteed maximum process utilisation.

Cached status is cheap. The owner samples monotonic process/host counters and bounded minute aggregates, joins callbacks before shutdown and preserves unknown coverage. The native background scheduler's deferral is honoured. Explicit Process now is visible and cancellable and must not permanently rewrite power preferences.

Sources: [CPU repair](sources/live-cpu.html), [Responsiveness ledger](sources/main-responsiveness.html), [Performance gates](sources/main-performance.html), [Later recovery policy](sources/live-recovery.html).

## 18. Storage accounting, retention and cleanup

Storage is periodically measured off the UI thread, with coalesced manual refresh. The source service uses a fifteen-minute schedule. Categories include audio, screen archives, SQLite and sidecars, original-frame spool, models, logs and separately identified recovery/candidate material. Show observation time, last complete result, partial/inaccessible state and volume free space.

Logical size, allocated file blocks, APFS shared/clone blocks and actual free-space recovery are different measures. A reported 162 GB of removed backup allocation produced only about 0.80 GB immediate net gain in the November audit. No screen should promise the summed folder sizes as reclaimable space.

History retention is an explicit policy with bounded preview and confirmation. References, active readers, source lineage and media ownership are checked before deletion. Unverified original WAL may hold the only pixels and is not disposable cache. Legacy sentence files remain if playback references them. Zero freelist pages do not prove a useful vacuum. Screen and audio FTS content modes must be inspected rather than assumed.

Disposable caches, duplicate model downloads, inactive logs and dated restore copies are inventoried separately from live memory. Cleanup requires exact scope, retained-survivor verification, authority and measured recovery. Backups may have rollback value even when ordinary Timeline never reads them. Removing one loses that recovery point; it is not inherently consequence-free.

Network mirrors can be active inputs to separate analysis pipelines. Additive media sync does not propagate source deletion, so destination media may accumulate. Correct retention requires references from both current mirrored databases and derived consumers. A staging database and published APFS clone may share allocation. No broad mirror removal is authorised by this specification or prototype.

Sources: [November 2 audit](sources/live-storage-audit.html), [November 7/9 efficiency](sources/live-storage-efficiency.html), [Network cleanup and discrepancy](sources/live-network-cleanup.html).

## 19. Privacy and source access

Local-first storage does not mean every consumer has unrestricted access. Capture permission, exclusions, masking, user deletion, current source availability and explicit client grants remain separate checks. Original capture policy and current presentation policy need clear outcomes; partial masking must not be mistaken for blanket denial of a usable recording.

Native/imported source identities cannot be conflated. Exact evidence readers revalidate source, revision and current policy after asynchronous reads and before display/copy/publication. Changed results clear before refresh. Reader leases bound access and deletion races. A historical success receipt is not a permanent right to read the old evidence.

Text captured from an application, OCR, transcription or a companion is data. It does not grant shell access, send messages, change settings or authorise deletion. Context export carries source and coverage and requires an explicit user or permissioned command path. Optional intelligence cannot silently widen capture or disclosure.

## 20. MCP and private companion contracts

Retrace's app-owned command endpoint is separate from Outlook's intel search/MCP service. Do not route an external agent to a nearby service solely because it has an “intel” name. A client discovers the implemented capability manifest and receives only operations permitted by its grant. This bundle contains no running endpoint and no working access token.

The native workflow creates a named client with explicit permissions and expiry, displays its token once, and separately enables the listener. Revocation removes that client's access; disabling local MCP stops the listener. Read permission does not imply recording control, playback, rule editing, annotations or deletion. OS permission and exclusions still apply.

Supported native command areas in the Live source include bounded interval search, native screenshots/OCR/transcripts/speaker turns and context; markers and rule/range edits; tags/comments/speaker corrections; exact foreground opening and retained audio playback; supported recording/settings controls; cached health/resource/storage reports; explicit processing/maintenance jobs and bounded reviewed retention. The unfinished importer and arbitrary shell, SQL and filesystem access are absent.

Retry uses the same request UUID and unchanged arguments. Conflicting revisions require fresh reads. Indeterminate outcomes are reported rather than blindly re-executed. Destructive commands require a concrete preview and confirmation tied to that exact preview. Long operations return job IDs with progress/cancellation, including partial effects. Commands requiring foreground UI report unavailable when the app cannot perform them rather than queueing surprise actions for reconnection.

The private companion is opt-in and uses a separately configured endpoint and Keychain token. It can send permitted recorded audio/supporting text for enrichment. Durable transport deduplicates jobs and preserves source/revision checks. Completed results remain locally readable after disconnection; bad or stale results are rejected. The installed trial had no live client grant or companion connection created during acceptance, and physical/complete MCP acceptance remains open.

Sources: [MCP protocol](sources/live-mcp.html), [Companion contract](sources/live-companion.html), [User-facing access guide](sources/live-guide.html), [Native data reference](sources/live-data-access.html).

## 21. Architecture, module ownership and compatibility

| Module | Responsibility and important boundary |
| --- | --- |
| Shared | Typed models and protocols for source identity, exact evidence, jobs, activity, resource metrics, pending work, audio sample ranges and current-policy reads. |
| Capture | Native screen/audio acquisition, device/display lifecycle, metadata, exclusions and bounded streams. Never silently substitute current context for history. |
| Storage | AAC/HEVC media, original journals, archive mapping, exact readers, path validation and reader leases. Encoder completion differs from durable publication. |
| Processing | Vision OCR, optional direct text, Whisper/Speech adapters, first-pass/refinement queues and native cancellation. |
| Database | SQLite/FTS, canonical transactions, migrations, exact references, durable claims, deletion/tombstones and feed publication. |
| Search | Query parsing, ranking, ingestion and optional pinned local semantic recall. Coverage and supported source scope are explicit. |
| App | Service ownership, governor, lifecycle/recovery, playback, current-policy integration, context, MCP/companion and cached health/storage metrics. |
| UI | SwiftUI windows, Dashboard, Live, Timeline/Search, settings and lightweight presentation of owner snapshots. |
| Migration | Existing imported-history compatibility and explicit importer boundaries. Unfinished importers are not capabilities. |

Capture hands durable source/context to Storage/Database; Processing claims queued work through canonical interfaces, reads the correct retained source and atomically publishes text/index updates. Search resolves immutable references through current readers. UI does not perform filesystem scans in a view body. Shutdown cancels and joins owned work and metric delivery before the canonical writer closes.

The main candidate's V24 original pixels, V25 semantic index, V26 display groups, V27 context, V28 original audio, V29 jobs, V30 exact transcripts, V31 pending-audio index and V32 chunks are not the installed V23 baseline. Contracts must preserve old media and records without inventing unavailable provenance. Actor/protocol layout changes require clean debug and separate clean optimised compilation because source hashes alone do not detect stale generated callers.

Sources: [Unified history contracts](sources/main-unified-history.html), [Data reference](sources/main-data-access.html), [Responsiveness/audio contracts](sources/main-responsiveness.html).

## 22. Global performance and quality acceptance

Performance is evaluated in four dimensions: quality, speed, cost and intelligence. Recording health is a prerequisite. Count capture attempts, saved audio coverage, pending count/age and incomplete work; reduced CPU caused by stopped recording or growing backlog is not an improvement.

Quality includes OCR character error, speech word error, preserved critical tokens, timing and zero wrong-source/frame/audio navigation. Speed includes capture-to-search, warm keyword lookup, visible results, foreground p95, cancellation and archive seek/decode. Cost includes CPU-seconds per recorded hour/query, measured peak memory, bytes per recorded hour, model/index footprint and measured energy. Intelligence includes Recall@1/3/5, MRR, source correctness and unsupported-result rate on frozen questions.

Pin corpus/oracle, source/resources, device/OS, models, power mode, cold/warm state and backlog for matched baseline/candidate runs. Run at least three independent complete pairs; every pair must pass. Preserve failed attempts and unavailable measurements. Native fixture success and runner self-tests are not installed performance acceptance.

Promotion gates include at least 50% lower active-use CPU-seconds for a governor or at least 20% fewer retained bytes for a codec; no critical-token/source/navigation loss; no CER/WER/recall regression; no hidden gaps or growing backlog; foreground p95 within 10% of baseline. Track the soft 20%-of-one-core target separately. Normal-load capture-to-search p95 targets ten seconds, warm keyword search below 100 ms and visible results within 250 ms. Complete-work rate retains at least 90% of baseline. The measurement ledger specifies additional 10% ceilings for relevant resources/latencies.

Use real AAC, Vision, SQLite, native capture and archive decoding. Include dense and small/coloured text, digits/negation, scroll/static screens, photographs/video, multiple displays, Australian speech and overlap. Include input returning during inference, sleep/wake, restart, low disk, exclusions, deletion during reads, failed writes and shutdown with pending work. Whole-system energy and helper memory remain independent measurements.

Source: [Full measurement and promotion policy](sources/main-performance.html).

## 23. Delivery sequence and remaining gates

The accepted order protects responsive recording first, completes original retention and audio storage/playback, then unifies recall before expanding semantic or live assistance. Immediate CPU protection can be a small independently tested slice, but it cannot be called complete if recordings stop or fresh text becomes unusably late. Hardware/codec candidates remain switchable and unpromoted until representative quality/cost acceptance.

Outstanding acceptance across the source records includes physical multi-display capture, sustained microphone switching and sleep/wake, real spoken-marker acknowledgement latency, automatic speaker-name calibration, full installed MCP/companion parity, long-history memory/continuation, matched active-use CPU/foreground latency/energy and safe storage savings. Missing temporary drafts and failed diagnostic runs cannot count as completed implementation.

Keep source review, test execution, clean optimised build, packaging/signing, installation, bounded installed checks and user acceptance as separate records. Record restart gaps rather than hiding them. Initial rollout excludes bulk historical recompression and automatic deletion of likely silence or unverified originals.

## 24. Prototype coverage and limitations

| Area | Click-through coverage | What remains simulated |
| --- | --- | --- |
| Dashboard/Live | Tabs, newest-first sample history, selection, screen/text, speaker correction, context preview, mark now | All recording, speech recognition, live arrivals, exact audio playback and AI results |
| Dictation/App Usage | Expand sample entries, layout switch, session details | Dictation into applications and actual usage measurement |
| Screenshots | Moment selection, image/OCR, app/window context | Authored illustrations, not captured desktop pixels |
| Timeline/Search | Filmstrip, sample filters/results, audio opening, annotations | Local sample search, not SQLite/semantic retrieval or native evidence permission |
| Markers | List/open/edit, delete/undo, adjustable ranges, voice-rule link | Microphone detection, durable writes and automatic context proposals |
| Settings | Nine sections and representative secondary dialogs | No OS preferences, filesystem, model downloads, database maintenance or real tokens |
| System Monitor | Illustrative metrics and process-now/cancel | No sampling, inference or actual resource control |
| Documentation | Full spec, long issue chronology, complete selected source snapshots and provenance | External receipts/media/models remain unbundled and explicitly unavailable |

The directory is independently usable by opening index.html, then app.html or these documents. Assets and scripts are relative and local. No server, package install, network, symlink, parent-project data or browser storage is required. Copy the whole directory to retain its links. The HTML and Markdown specification/journal carry the same substantive content; the journal's browser version adds local filtering. Supporting records are archived as escaped text with line anchors, so historical commands and outside paths cannot become accidental executable actions or broken live dependencies.

## 25. Source scope and documentation limits

The supporting index records each selected source's origin, modification time, byte count and SHA-256 at packaging. Sources span early September through November cleanup and the October Live implementation. Older June/July memories are not reconstructed into dated incidents without surviving records in this bundle. This is a comprehensive consolidation of the available selected evidence, not an assertion that every earlier conversation, test log or lost temporary draft has been recovered.

Historical source snapshots retain their original wording, including superseded statuses. Editorial reconciliation in this specification and journal takes precedence when explaining the package. Links to test logs, candidate apps or private runtime paths in archived text are provenance clues only; those files are not included. No real audio, screenshots, databases, model weights, access tokens or customer secrets form part of the sample app.

The [issues journal](issues-journal.html) records the observed failures and uncertain outcomes without collapsing them into “fixed”. The [supporting records](sources/index.html) let a reader inspect the full selected primary project records offline.
