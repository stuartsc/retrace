# One searchable history of your computer

Accepted implementation direction, **2026-09-24**. The workspace answers “What's
happening now?”, “Where did I see or hear that?”, and “What happened around that
moment?”. This is the delivery ledger for the supplied plan, not an installation
or acceptance receipt.

## Confirmed choices

- macOS 26 or newer, Apple Silicon; preserve archive readers and imported history.
- All enabled displays, meaningful changes, and audio under existing recording settings.
- Apps plus significant jobs; process presence alone does not establish user activity.
- One resizable Now / History workspace with shared search, timeline and inspector.
- Quiet contextual intelligence; background reasoning remains local.
- Optional Codex assistance only for explicitly requested searches and selected evidence.
- No project assignment or bulk historical recompression in the initial rollout.

## Delivery order and gates

| Milestone | Required behavior | Source status | Installed acceptance |
| --- | --- | --- | --- |
| 1. Capture quality | Recoverable original pixels; native capture candidate; bounded direct visible text; measured speech/document/codec comparisons | Original spool, native candidate, bounded direct text and streaming comparison implemented; integrated validation pending | Pending |
| 2. Unified workspace | Now / History, pinned moments, displays/text/audio/context, timeline navigation and quiet Intel | Switched-off candidate and reviewed capture-group association implemented; integrated validation pending | Pending |
| 3. Semantic recall | Source-qualified hybrid retrieval, exact identifiers, bounded fresh-first indexing and historical coverage | Native screen-text V25 worker, explicit local activation and bounded hybrid workspace route implemented; integrated verification pending | Pending |
| 4. Requested Codex assistance | Version-pinned isolated App Server, read-only evidence tools, cancellation and genuine progress | Blocked: pinned public App Server 0.156.1 lacks an enforceable exclusive tool policy; source/schema receipts retained | Not activated |
| 5. Live assistance | Corroborated call states, significant jobs, local topics and source-backed FuseIntel suggestions | Call comparison and bounded local-context/topic candidates integrated; job adapters and richer assistance pending | Pending |

Do not promote a candidate based only on successful compilation or source tests.
Each feature needs its own switch and rollback. Existing capture settings and the
installed application remain the comparison baseline until explicitly promoted.

The macOS 26 SDK marks the legacy Core Graphics screenshot functions obsolete.
`CaptureLegacyBridge` isolates their existing public runtime entry points for the
comparison baseline and fails explicitly when unavailable. It does not grant
screen-recording access or establish that the legacy backend works on every
supported OS build. Both SwiftPM and XcodeGen include the bridge.

Review corrections preserve an old recording stream only when a failed change
affects the comparison backend/display policy alone. Privacy changes and failed
restoration stop capture; the App coordinator joins pipeline teardown and reports
stopped status. Each restoration uses a fresh policy epoch. Original-image
recovery rechecks canonical deletion aliases, preserves previously published
archives when re-encoding surviving frames, and scopes corruption to the exact
store/frame rather than denying unrelated archive reads.

## Capture requirements

ScreenCaptureKit must preserve display/window attribution, exclusion and redaction
behavior at native resolution. Compare all displays, display removal, restart,
sleep/wake, capture gaps, CPU and energy with the legacy backend. Use per-display
deduplication and retain meaningful digit, status and text changes. Missing or
overflowed capture is an explicit coverage gap.

The original spool starts with a **5 GiB admission ceiling** and **20 GiB free-space
headroom**. Pressure stops new admissions and is visible; it never evicts pending
originals. Encoding completion is not extraction completion. Original release
requires durable extraction, a verified current archive mapping and finished
readers. Recovery remapping must preserve exact original lookup. Deletion must
prevent restart/recovery from recreating evidence.

Bounded Accessibility reads belong to the captured window and visible viewport,
with secure fields excluded and context/pixel timing checked. Direct text, OCR and
interpretations retain distinct provenance. General desktop OCR remains native
resolution. Compare document recognition on tables/structured documents before
using it selectively. Compare streaming SpeechAnalyzer with Whisper on timestamps,
Australian English, names, overlap and silence; retain fallback. Benchmark higher
quality HEVC and lossless changed tiles independently before changing archives.

## Workspace requirements

A selected moment presents its displays, screenshot, selectable text, transcript,
audio and app context together. Transcript selection seeks audio and timeline time.
Support inline playback, waveform, speed and keyboard navigation. Historical
selection remains pinned until explicit navigation or Return to now. Add day/hour/
minute zoom, meaningful-change/search markers, back/forward and bookmarks.

Reuse the existing timeline performance work. Keep stable identities, bounded
thumbnail caches, cancellable decoding and virtualized content. Load selected
evidence before neighbors. Recording, transcription and indexing freshness have
separate states. Intel stays quiet and becomes a drawer at narrow widths.

The independently switched V26 capture-group strip identifies companion displays
by durable attempts and preserves each native read's distinct sample time. Pending,
unavailable and deleted members stay explicit. Legacy/imported captures receive
no invented group; time proximity never implies simultaneous pixels.

## Recall and intelligence requirements

Extend source-qualified evidence contracts for captured window/text context, jobs,
derived moments and insight claims. Every derived item retains evidence references,
revisions, timestamps and availability. Combine lexical retrieval, local embeddings,
time/app filters and reranking across screen text, transcripts and context. Preserve
exact identifier matches. Start from the saved retrieval benchmark, index fresh
material first and backfill history in bounded resumable work with visible coverage.

Return a few useful moments, why they match, excerpts and exact timeline navigation.
Chronology/comparison questions expand neighboring evidence. Weak-text scenes may
use metadata and selective descriptions, explicitly marked as interpretation.

Codex is opt-in per requested search via a pinned, isolated App Server integration.
Its tools are read-only search/expand/resolve over selected evidence. Captured
content cannot grant permissions. Show Finding moments, Checking evidence and Ready
only when those stages occur; support partial results, cancellation and reduced
motion, without invented progress percentages.

Local context combines visible evidence, speech, lifecycle and explicit significant
job events. Call states are possible, corroborated active and ended; a running
meeting app/profile photo is insufficient. Suggestions cite prior discussions,
decisions, questions and possible follow-ups. FuseIntel uses a provenance/freshness
preserving adapter with contextual ranking and duplicate suppression. Foundation
Models topics/summaries are optional and runtime-gated. Coalesce meaningful changes,
expire stale suggestions and do not infer on every frame.

## Verification

Use real CoreGraphics, Accessibility, Vision, audio, SQLite, HEVC and filesystem
inputs. Include cancellation, deletion during work, restart, display removal,
sleep/wake, disk pressure and exclusions. Reviewed fixtures must have zero wrong-
frame navigation, correct critical text tokens and no concealed capture gaps.

Measure OCR/audio errors, retained meaningful changes, bytes/day, energy, memory
and capture-to-search latency. Foreground p95 may not regress more than 10%.
Initially target warm indexed semantic results within two seconds, evaluated on
independently annotated ambiguous, contradictory, missing and visual-only evidence.
Excluded/deleted evidence must remain absent from summaries, embeddings, caches and
Codex tools. Use additive migrations and verify rollback separately from builds.

## Capture integration contracts

Direct-text contracts and the durable sampling-group journal below are in source.
They connect direct text and multiple displays to the existing
exact evidence model without changing old OCR block ordinals.

- A capture receipt identifies the session, sampling group, individual attempt,
  configuration generation and display attachment. It records the actual start
  and end of the pixel read using wall and monotonic clocks. Numeric display IDs
  alone do not identify a display attachment across removal or a mode change.
- A durable group journal begins before sampling and records every targeted
  display. Sampling completion remains separate from durable frame admission.
  Outcomes distinguish pending, retained, suppressed-similar, unavailable,
  dropped, cancelled and deleted. Suppression may cite an earlier attempt but
  preserves that earlier sample's time; perceptual deduplication does not prove
  that all pixels were unchanged. Imported history receives no inferred group.
- Keep direct text separate from OCR. Its immutable observation identifies the
  extractor, source window, read intervals, exact UTF-16 ranges, visible bounds
  and partial/unavailable reasons. A future direct-text locator must identify
  that observation and its runs; existing screen-reference block IDs stay OCR-only.
- The first AX reader is restricted to the proved focused window. It requires a
  unique public-AX/WindowServer match, current observer/configuration/privacy
  fences, and proof that the pixel policy includes that window. Display-only
  captures continue through OCR. Never use the whole-application live AX helper
  to enrich a retained screenshot.
- Bound node traversal, child pages, text ranges, encoded payload size and elapsed
  messaging time. Exclude secure ancestry before reading content. A visible
  character range may include horizontally clipped text, so each admitted run
  also needs verified viewport/display bounds and no occlusion or privacy mask.
  Missing visibility/security proof means unavailable, not assumed visible.
- Read candidate text before pixels and revalidate the same elements, ranges,
  text, geometry and notifications afterwards. Label this as a same-window
  bracket. Public AX and ScreenCaptureKit do not provide one atomic snapshot;
  never describe the result as atomic or pixel-verified.
- The bounded WAL v2 payload now preserves complete capture metadata, checks its
  checksum and binds it to the record timestamp, dimensions and display. Legacy
  v1 records retain their four strings and display ID without invented optional
  provenance. Direct-text receipt validation is integrated at both record
  admission and readback; missing payload remains unavailable rather than
  borrowing context.

Tests must use an owned native text/scrolling/secure-field helper, mutation
handshakes during the pixel read, occlusion, duplicate titles, Unicode, timeout and
cancellation. SQLite/filesystem recovery tests must cover every admission boundary,
corruption, deleted dedup anchors and old WAL compatibility. New metrics contain
only categorical outcomes, never text, titles or window identities.

Native API limitations: [visible character ranges](https://developer.apple.com/documentation/appkit/nsaccessibilitystatictext/accessibilityvisiblecharacterrange())
and [per-object messaging timeouts](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout).

## Semantic integration preparation

The existing native feed and admission tables are intentionally insufficient for
a ready search index: V22 work states are blocked/invalidated/deleted, and V23
artifacts are opaque, leased and unpublished. Preserve those contracts. Add typed
index manifests/chunks and explicit canonical input/publication operations under
the writer's current source, policy, revision and input-digest fences. Store exact
reference/range/transform identities and validated vectors rather than copied text;
retrieve excerpts through current evidence admission. Completion requires every
bounded page, and deletion invalidates vectors in the canonical transaction.

Fresh-first scheduling needs separate tail and bootstrap consumers. Start the tail
at a current feed checkpoint before historical keyset work, then resume both with
bounded ownership, cancellation and visible coverage. Published index lifetime
must not depend on an expired worker attempt; restart requires current-owner
revalidation before serving stored vectors.

The saved MiniLM candidate is 384-dimensional float32 with 224-token content
windows, 32-token overlap, attention-mask mean pooling and L2 normalization.
An isolated Core ML conversion/parity experiment passed six artifact checks using
only the authored corpus and pinned local artifacts. The CPU-only float32 model
matched all twelve saved rankings across an initial and three warm passes; the
maximum vector component error was `1.639e-7`, with minimum cosine `0.99999994`.
The twenty-four input windows include the complete 616-token Unicode-tail input.
CoreMLTools 9.0 required isolated NumPy 2.2.6 for conversion; its NumPy 2.4.1
failure is retained separately. The model package is 89,935,805 bytes. On this
loaded host, per-window warm median/p95 were 182/390 ms; these are diagnostic
timings, not indexed-query acceptance. Session receipts are under
`/tmp/retrace-unified-20260924/minilm-coreml-spike/`.
That conversion experiment alone did not establish a production worker. The
separate native runtime, V25 worker and App route are now implemented as described
below, with integrated tests and installed acceptance tracked independently.
The primary paginated AppCoordinator/DataAdapter route remains lexical; the
explicit workspace route combines exact lexical matches, supported constraints,
reciprocal-rank fusion and exact navigation.
The saved BGE comparison does not justify making the larger reranker the default.

## Installed baseline diagnostic — September 24

A five-second read-only stack sample at **16:55 Brisbane** verified the running
baseline as **2609.18.1**, macOS 26.1. The report recorded a `1.7G` physical
footprint (`3.5G` historical peak, in the report's units). Sampled worker stacks included the old JPEG
conversion path; main-thread stacks included synchronous LaunchServices lookups
from `ActivityAXRegistration` notification callbacks. These observations identify
paths to investigate, not CPU percentages or a controlled foreground benchmark.
The app was not restarted and no history/preferences were changed. The receipt is
`/tmp/retrace-unified-20260924/installed-baseline-stack.txt` for this working session.

## Implementation receipts

- Initial checkout was clean. Native OCR/archive-pixel source checkpoint was present.
- Swift 6.2.4 and the macOS 26.2 Xcode SDK resolve in this session. Initial dependency
  resolution succeeded. The first compilation was invalidated by a concurrent
  scaffold edit; it is not a passing baseline. Retain the build log separately.
- The fourth compilation checkpoint completed the production Storage, Capture and
  Processing targets, then stopped on a misordered initializer argument in a new
  Capture test. That call is corrected. Earlier checkpoints retained a native
  speech compile failure and a Storage test checksum-collection error, both now
  corrected. No complete suite pass is established by these checkpoints; final
  actor/protocol validation still requires a clean build after integration.
- New raw sessions use `wal/original_segment_<pathID>` from creation. Older recovery
  readers only enumerate `active_segment_`, so rollback cannot prematurely consume
  new retained originals. New readers understand both namespaces. Unbound legacy
  journals remain retained and count toward pressure; they are not silently adopted
  into another database.
- Additive V24 aliases bind the native store UUID and original capture position to
  the frame in the same SQLite transaction. Deletion latches a tombstone even when
  a crash prevents the filesystem frame-ID mapping. Recovery rechecks the alias
  before encoding and again in its publication transaction.
- WAL v2 checksums bounded complete metadata and reads mixed legacy/new records.
  Review reproduced a damaged-tail bug after a valid prefix had reached SQLite:
  strict whole-file indexing blocked that earlier frame's mapping and handoff on
  every restart. Targeted reads now validate boundaries only through the requested
  record, while full-stream reads remain strict. New recovery assertions cover
  queue admission, exact originals, archive receipts and idempotent restart. The
  failing native receipt is retained. A directly linked native harness now passes
  both launches with one exact frame, queue admission, verified archive mapping
  and the damaged tail retained; integrated XCTest validation remains pending.
- `captureCoverage` metrics record only component, outcome and categorical reason.
  A bounded inbox retains the first gap and final state during bursts; shutdown
  joins its consumer before closing SQLite. Disk pressure, native gaps and lost
  coverage delivery remain distinct in cached UI health.
- Workspace search and neighboring timeline context are admitted as bounded
  batches. Their publication stamp includes source identity, native search
  mutation revision (or imported SQLite version/change counters) and current
  privacy rules. A deletion or exclusion during later admission discards the
  whole earlier batch; source identity by itself is insufficient.
- AX callbacks now retain their registration's process identity, avoid per-event
  LaunchServices lookup, and coalesce only consecutive pending notifications.
  Every notification still advances the capture revision; retired callbacks are
  rejected, observer setup is bounded, and teardown joins its owner. Three direct
  native-helper runs passed with 10,001 callbacks each. Whole-target compilation,
  actual AX delivery and installed foreground/resource comparison remain separate.
- A capture-policy fingerprint is integrated for new live frames. Current
  foreground metadata alone cannot re-evaluate every contributor to an old
  multi-window or display-only scene. New policy-bearing frames require exact
  capture/current policy agreement, with the fingerprint preserved in the
  recoverable raw record. Old nil fingerprints remain legacy-unverified; reader
  compatibility does not manufacture a composition or policy attestation.
- ScreenCaptureKit is selected with `captureBackend=screenCaptureKitCandidate`;
  `captureDisplayPolicy=allDisplays` is the candidate default. The workspace uses
  `unifiedHistoryWorkspaceEnabled=false` by default. Settings are in the existing
  `io.retrace.app` suite; no installed preferences were changed by development.
- `NativeSpeechTranscriptionService.compareStreaming` is an explicit developer
  comparison over supplied PCM. It preserves source times, requests volatile/final
  spans, supports paced input and cancellation, and keeps only finalized text in
  the final transcript. Ordinary tests exercise real AVAudio conversion; installed
  speech tests require explicit authored audio/assets. This is not a microphone
  routing change or an Australian English quality acceptance receipt.
- No new local trial or release is recorded by this ledger. Current host load is
  unsuitable for interpreting build/test elapsed time as performance acceptance.
- `MixedDisplayPipelineTests` now drives interleaved native-rendered 640x360 and
  960x540 frames through the real App writer path, private SQLite, original WAL,
  HEVC readers and Vision. It checks exact source/display/archive indices and
  release only after durable extraction. Source review is clear; XCTest execution
  and physical multi-display acceptance remain open. Initial standalone test
  typechecks stopped on missing test/App modules and are not functional RED proof.
- The native MiniLM runtime passes all 45 pinned upstream tokenizer cases (2,121
  token IDs). Three actual Core ML passes reproduce all 24 saved vectors and all
  twelve complete authored rankings: maximum component error 1.6391277e-7,
  minimum unit-vector dot product 0.9999998749647562. Q11's pre-existing oracle
  ambiguity remains unchanged. Real cancellation, input bounds, artifact rejection
  and joined cleanup pass in the same private native harness. The 18 integrated
  XCTest methods and production worker/index are separate checks. Retained
  receipts are under `/tmp/retrace-unified-20260924/native-embedding/`; pinned
  oracle/provenance/license fixtures are tracked in `Search/Tests/Fixtures/MiniLM/`.

## Durable display groups — September 24 implementation

The default-off SCK-only capture-group switch journals a bounded target inventory before native reads, assigning every target an attempt and attachment lifetime. Each frame retains its own native pixel interval. Suppressed samples point to an exact earlier attempt without changing its timestamp; sleep/removal/backpressure/cancellation remain categorical outcomes. Sampling end does not imply durable media admission.

V26 adds group/member/attachment/event tables without assigning old history to invented groups. Begin retries repeat current writer/epoch checks. Frame, original-source alias and group member binding commit together; a revoked fresh insert rolls back while durable WAL remains recoverable. Recovery retains the original capture-policy identity and canonical deletion fences. Reads use current permissions and journal/source/metadata stamps; the pinned UI reloads the same target before navigation and refreshes pending outcomes.

Capture owns and joins journal/fatal-stop tasks; App stops the source then drains its bounded output instead of discarding admitted candidates on iterator cancellation. Known pre-WAL skips receive explicit cancelled outcomes. Post-append uncertainty preserves originals for recovery. New fixtures cover private SQLite retry/rollback, native CoreGraphics stream pressure, actual WAL/HEVC restart recovery, deletion, and unrelated recording during a pinned display click. These are staged source tests, not executed GREEN receipts. Independent source review cleared reported findings. Journal bytes/day, physical multi-display capture, sleep/wake, exclusion, energy and foreground p95 still require measurement.

## Native screen-text semantic integration — September 24

V25 stores typed 384-dimensional vectors and exact fragment/channel spans under
the verified MiniLM projection/model pin. Independent durable fresh-tail and
historical cursors survive feed compaction and writer restart; current source,
revision, privacy, metadata, deadline and input identity fence every publication.
Deletion and visibility changes invalidate current retrieval before limits.
The legacy blocked/unpublished feed interfaces remain unchanged.

`LocalRecallController` owns one optional native runtime, its indexing/query
scheduler and bounded categorical metrics. Settings accepts an explicit local
model package, validates its pinned inventory/hash off main, and stores only the
acknowledged selection. The tokenizer and license are bundled; weights are not
automatically downloaded. A first enable creates a private owned cache parent.
Default-disabled requests perform no model/cache work. OCR commit signals a
coalesced wake; foreground searches preempt and join background prediction.

Service shutdown fences new queries/configuration, joins exact claim cancellation
and native work, then drains metrics before ending the Capture writer and closing
SQLite. A failed canonical cancellation retains its owner and database for retry.
Private SQLite commit-veto tests and a held actual Core ML result exercise this
boundary; they do not substitute a policy owner or store.

The explicit workspace route fuses constrained lexical and semantic ranks,
reserves independently verified whole-identifier matches, and obtains excerpts
from current retained evidence without decoding screenshots. Native/imported IDs
remain source-qualified. Unsupported filters/syntax preserve the existing lexical
route. Source/policy batch stamps and the semantic generation are revalidated
after ranking. Why-match labels report retrieval signals only. The UI separates
recording, OCR, transcript and semantic-index readiness, and reports bounded scans
and pending/skipped history. This index covers native screen text only; audio,
imported text, direct AX-only text and visual descriptions are not semantic-index
coverage yet. No all-history completeness or two-second performance claim follows
from authored native parity or source review.

Verification receipts: checkpoint10 compiles the integrated core App target;
checkpoint11 compiles DatabaseTests including the new V25/V26 regressions. Neither
executes XCTest. Final actor/protocol validation still requires a clean complete
suite, the separate optimized build and actual native/UI comparison receipts.

## Corroborated call comparison integration

The independent default-off comparison requires visible same-window call controls and actual Core Audio running-input evidence from the same proven process lifetime. App presence/profile images alone stay possible. Unknown, expired, excluded or unsupported evidence cannot release the separate no-consent audio protection; a complete fresh absence inventory can. Possible/supported/end dates are observed evidence times, never inferred true call start times. Retained supported process identity survives transient inventory failure so affirmative process termination can still end it. Capture policy revisions bracket AX reads, including A-to-B-to-A configuration changes.

App injects the owning Capture policy into AudioCaptureManager, records bounded categorical daily metrics through an awaited handler and presents current assessment freshness. The comparison-only setting preserves microphone, system-audio and consent fields and leaves the existing audio streams running. Pipeline startup now uses the acknowledged audio configuration instead of recreating defaults. Processing emits a content-free quality receipt only after sentence rows commit; App bridges accepted transcriptions with original audio dates, no app attribution or fabricated audio evidence references. Old/invalid occurrences are discarded. Source tests include real PCM/audio writer/SQLite success and insertion rejection, settings preservation and metric shape; compilation/execution/installed call accuracy remain separately recorded.

## Optional Codex boundary

The September 24 investigation pinned the installed 0.156.1 executable, generated stable/experimental schemas under a network/write-restricted sandbox, and checked the corresponding official release source. The new startup tool allowlist is an internal Rust extension, not an exposed App Server wire/config field. Dynamic tools add to the tool catalog; they cannot enforce the requested three-tool boundary. [Evidence, exact pins and conditional integration design](codex-assistance-boundary.md) are retained alongside small machine-readable receipts. No App Server session, authentication or evidence disclosure was started. This milestone remains blocked on a supported enforceable isolation interface; prompt instructions or guessed JSON fields are not substituted for it.

## Local contextual evidence candidate — September 24

The quiet workspace inspector reads a bounded selection of exact native screen/activity evidence. Original screen excerpts and app observations remain distinct from an optional short Foundation Models topic, which is explicitly an interpretation. The setting is off by default; unavailable Apple Intelligence leaves recorded context usable. No tool, job-completion, audio-summary, whole-history or inferred-decision authority is granted by an excerpt.

ServiceContainer lazily owns one local context service and closes admission before joined model, public read and final metric cleanup. Selected source identity, policy capability/epoch, extraction, current hidden tags and activity corrections are rechecked after model/metric suspension. V27 adds two partial indexes for correction visibility; a final canonical transaction fences policy, store, screen revision, native feed sequence and activity revision together. No durable summary cache is added.

The UI owns generation and cancellation independently of the shared Now/health/Intel refresh loop. Routine refresh clears displayed cards while coalescing an identical in-flight request; selection/source replacement cancels it. Publication uses the original process-local monotonic deadline as well as wall time. A native timer expires the card even without another poll. Dates identify the evidence's observed moment, including historical selections; process presence never asserts current engagement.

The existing FuseIntel panel retains its source-labelled read-only adapter and ranking. Optional external context input has a separate provider/revision/citation type and requires a provider-owned whole-snapshot revalidator. Root integration currently leaves that input absent; it does not relabel the independent feed as native evidence.

Source review corrected a final-read deletion race, a missing partial-coverage flag, a model request blocking unrelated refresh, and wall-clock renewal of a monotonic lease. Real private SQLite regressions and native task/timer tests are authored; integrated execution and installed acceptance remain separate gates. Tests use no live history or native model by default.

## Codec comparison scope

The ordinary authored 4K changed-tile regression writes/reads real compressed files, replays baseline, digit/status change and reversal byte-for-byte, and rejects a wrong base or truncated patch. Exported comparisons measure the declared HEVC 0.5/0.7/0.9 runs separately from four lossless changed-tile scenes. Different workloads are not a storage-ratio winner; no energy, bytes/day or production recovery result is inferred. The production archive remains HEVC and no historical recompression runs.

## Current verification boundary

CaptureTests and ProcessingTests compile with the September 24 meeting/audio changes (checkpoint18); AppTests compiles with the same integration (checkpoint19). These are compilation checkpoints only. A clean full suite is still required after the final shared/actor layouts, followed by the separate optimized build and explicit native/UI comparison runs. Installed 2609.18.1 remains untouched. Native semantic coverage is still screen text only; audio/context/job search and model/foreground performance remain open in the delivery table.

The legacy fullscreen preview also uses the public runtime bridge on macOS 26. Its detached capture is cancelled and joined, with late pixels discarded. Native invalid-bound/window-ID checks pass without reading pixels. A temporary 64 MiB constraint-solver diagnostic identified large SwiftUI builders; those diagnostic timeouts are not default-budget failures. The top-level timeline layer extraction preserves its original state, ordering and modifiers. Native layout/performance verification is still pending.

The Codex boundary document is explicitly included in Git alongside its source/schema receipts, so the blocked milestone can be reviewed with the implementation.

Authored Australian English names/amounts, silence and controlled-overlap inputs are retained in [the speech fixture pack](fixtures/unified-history/speech/README.md), with byte hashes, separate oracles and native PCM/AAC provenance. Synthetic fixtures and comparator diagnostics do not establish human recognition accuracy or runtime acceptance.

## Original audio source repair — September 24

V28 binds new raw recording rows to their original source and preserves that
receipt when transcription intentionally retires its pending placeholder. Both
refiners obtain the receipt before decoding or model work and revalidate it in
the publication transaction; cancellation, conflicting lineage and deletion
leave retained transcripts unchanged. Older refined rows are never relabelled
as original-source evidence. This does not infer historical consent or app
ownership and does not establish exact audio recall or media identity.

Refinement inspects at most 256 indexed rows per cycle and carries its cursor
past unavailable legacy work. A private SQLite 10,000-row-prefix regression
reduced one page from 785,188 to 725 VM steps; the source tests also cover native
AAC decoding and guarded publication but await integrated Swift execution.
The existing offline retrieval benchmark's eleven tests pass against the pinned
local tokenizer and corpus. Neither result is installed-app acceptance.

## Integrated runtime checkpoint — September 24

A clean macOS 26.2 debug compilation and link completed with V28. The first full
XCTest attempt was interrupted after an owned native helper stalled in teardown;
the stack sample and interruption receipt are retained under
`/tmp/retrace-unified-20260924/`. A diagnostic continuation explicitly excluded
that class and completed 1,489 tests, with 28 skips and failures in 26 cases
(1,753 assertions, dominated by repeated privacy-mask pixel checks). This is a
failed diagnostic run, not complete-suite acceptance. The source manifest stayed
unchanged during both attempts. Repairs and native coordinate checks are in
progress; no installed state or performance acceptance changed.

V29 now adds the source-reviewed explicit-command observation API and immutable
job chronology. It does not start a watcher or external command listener. The
App lifecycle owner and unified local presentation still need integration; the
authored SQLite/native Process regressions are awaiting the next clean build.

## Exact cross-source integration checkpoint — September 25

V30 and its separate lazy transcript reader are now integrated with exact local
audio/job resolution and the candidate workspace's pin, refresh and bookmark
paths. All 71 selected non-AX tests passed in the completed cross-source run:
26 original-source/migration tests, six reader-owner tests, 14 resolver tests,
16 job persistence tests, three transcript workspace tests and six job workspace
tests. Native AX remained failing and is being repaired from categorical traces;
this is not complete-suite acceptance. The [retained receipts](fixtures/unified-history/validation/README.md)
preserve both failed clean attempts and scoped passing evidence.

The reviewed explicit job owner and one-field screen/transcript search are also
integrated in source. The latter preserves exact excerpts, source coverage and
current batch checks across independent stores. Twenty-three App search tests,
three additional UI search tests and 12 job owner tests await the next clean
run. Transcript text matching is lexical; semantic audio/context retrieval,
the V30 historical-preparation App owner, standalone verified audio playback,
external job adapters and installed/native performance acceptance remain open.
