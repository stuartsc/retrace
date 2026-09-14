# Progressive recall: capture context, exact evidence and local refinement

Saved: 2026-09-11. Scope corrected by Stuart: **2026-09-14**. Work remains on `feature/push-to-dictate`. The original review baselines and historical acceptance results are retained in [the validation ledger](progressive-recall-validation.md).

**Phase 2A/2B is implemented and installed for local assessment.** Settings and exact timeline navigation are repaired, the project/visit surface is removed, and Screenshots shares the structured OCR/evidence inspector. The full suite passed 938 tests with five intentional skips and zero failures; a subsequent test-only addition passed in the 167-test focused selection. Independently verified **2609.15.1** was installed and launched hidden on September 15. The Settings status-menu route opened its native window, and all 31 captures in the bounded post-launch cohort completed. Full timeline/Screenshots visual checks, resource limits and broader recall acceptance remain open; see the [trial evidence](progressive-recall-validation.md). Stuart's instruction to commence Phase 2 supersedes the previous hold on later work; it does not retroactively pass those gates. The durable feed and hybrid retrieval in 2C/2D remain subsequent work.

## Product scope and delivery order

Collect and preserve screen/audio evidence, capture its app/document context where supported, make the evidence searchable, and reopen the exact supporting moment. **Project assignment, work-episode classification, app-visit grouping and focus-duration presentation are outside this delivery.** Remove that workflow from the app. Existing captured records and compatibility contracts do not need to be deleted to remove a product surface.

The main **Screenshots** dashboard should bring the recorded image, OCR text, capture context and exact evidence identity together. Search selection must stay at the requested historical moment in the timeline. A separate Activity & Evidence dashboard is no longer the intended product structure. Optional user selection/bookmarking of evidence is a later roadmap possibility, not a prerequisite for collection or retrieval.

| Phase | Deliverable | Required exit condition |
|---|---|---|
| 0. Baseline and reproducible failures | Reviewed real questions, source fixtures, retrieval/navigation/privacy regressions and fixed capture workloads. | Correctness, coverage and resource limits are measurable; authored fixtures remain distinct from actual-user acceptance. |
| 1. Correct recall and exact navigation | Independent capture-context records, immutable evidence identity, constrained search, retained text and exact screen resolution. | Every reviewed selection opens its requested retained source/revision or an explicit unavailable state; zero wrong-frame displays. |
| 2. Structured observations and retrieval | Repair Settings and in-timeline search navigation; remove the project/visit workflow; unify evidence with Screenshots/OCR; add structured observations, bounded exact expansion, then a durable evidence feed and local hybrid retrieval. | Context/text/geometry retain their source and revision; expansion and retrieval improve access without unsupported attribution, privacy loss or foreground regression. |
| 3. Coordinated inspection | Shared admission/cancellation, exact-frame inspection outside the request-serving process and a benchmark-gated local visual model. | Difficult inquiries improve while capture, dictation and normal service remain responsive. |
| 4. Measured refinement | Durable bounded jobs, retained alternatives and evidence-based preferred versions. | Paired evaluation demonstrates better extraction or recall within measured resource limits. |

Retrace owns capture, retention, local evidence lookup and presentation. FuseIntel may consume permissioned source observations and perform wider interpretation in its own system. No project classifier, correction service or FuseIntel connection is required to collect or inspect a recording. The repositories do not write each other's databases.

## 1. Capture context without project or visit workflows

### Durable context and coverage

Retain the independent `ActivityEvent` storage mechanism as capture-context evidence. Its implementation name does not imply an app-visit dashboard or a timesheet. Observation time, app/window/document identity, method, coverage and uncertainty explain what a retained screen may belong to. They do not prove reading, authorship, intent or time spent on a project.

Context persists independently of screenshot admission/deduplication, encoding and OCR. A context-only record does not prove visible document contents. Link media only with verified source/session/window-generation/timing provenance; a nearby timestamp alone is insufficient. Keep image capture time separate from context observation, enrichment and persistence times.

Preserve meaningful transitions and administrative coverage markers through the existing bounded canonical writer. Pause, sleep/wake, permission loss, observer failure, queue overflow, clock discontinuity and storage errors must remain explicit. Never turn an unobserved gap into continuous focus or interpret missing retained images as inactivity.

Repeated title/move notifications must not manufacture window lifetimes. Keep window identity separate from notification ordering, invalidate sampling on an intervening notification including A→B→A, and allow one bounded enrichment read plus a request to resample the current app. A delayed retry cannot replay an old app as newly focused. Enrichment cannot fill an old record from the desktop that happens to be focused after an await.

Bound unchanged reconciliation and coverage heartbeats; do not persist duplicate titles simply to count visits. Context-only changes must survive image deduplication, while small consequential pixel changes remain a separate tested requirement.

### Source context and privacy

Use application → window/pane → document/conversation identity → readable label → permitted URL/path, with acquisition method and uncertainty. Native process generation and actual display identity matter; PID or a title alone is not a stable document identity. Same-title documents stay distinct. A renamed document retains continuity only when an exposed stable identifier supports it.

Use native/app-exposed metadata before visual inference. Priority fixtures remain Word, ChatGPT, Codex, Claude, existing browser integrations, then Cursor, Excel, Finder and meeting surfaces, subject to the user's visible-surface and privacy restrictions. Generic app titles remain generic; unavailable conversation or pane identity must not be invented. Unsupported background execution signals remain unknown.

Apply master pause, capture exclusions and credential scrubbing to every metadata sink. Keep context collection independently controllable in Capture settings. An exclusion cannot be bypassed through a context event, log, cache, index or export. Collection state is independent of presentation; removing project/visit controls does not change the user's existing capture preferences.

### Evidence presentation and health

Screenshots, OCR text, captured context and exact source/revision links belong to the same selected recording. A search hit opens that immutable evidence inside the historical timeline. Normal refresh, pending focus restoration, a late image decode or current live capture cannot replace the selected historical screen. Explicit scrubbing or a different selection may leave that pinned state.

Expose recording/text/audio readiness where it helps inspect evidence. Distinguish observed, retained, processing, unavailable and excluded states. Retained text remains usable if exact media is missing. Current document/website opening is a separate action from replaying the recorded screen.

Do not load project corrections, derive visit groups, calculate focus duration or require annotation confirmation to open evidence. Preserve existing V21 correction records and Codable values for historical compatibility and deletion sanitisation; no new assignment workflow is exposed.

## 2. Stop incorrect recall and establish an evidence address

### Correctness prerequisites

- Apply reliable constraints before candidate truncation in `DataAdapter.searchRelevant`; fix cursor exhaustion so a sparse eligible result is not mistaken for the end of available evidence. Raising the global limit is not a correctness fix. Align relevant, chronological, fallback and FuseIntel search semantics with shared conformance fixtures; retain the filter-before-final-limit foundation already present in `FTSManager`.
- Replace title/highlight-position deduplication in both relevant and chronological paths with grouping that retains every source-qualified observation and its chronology. Same-title documents with changed amounts, negations or decisions remain distinct evidence. Page cursors advance over examined source records, not only displayed groups.
- Keep queued/historical extraction structurally unable to query live Accessibility, even if a configuration enables Accessibility elsewhere. Phase 0/1 implemented the retained-frame extractor with no Accessibility or frontmost-app dependency; it uses retained pixels and saved capture metadata. This closes the previously configurable unsafe path without claiming that historical contamination was observed.
- Replace qualifying OCR repair-error `deleteFrame` calls with media-unavailable outcomes that preserve text and provenance. Cover the actual empty-video/out-of-range branches; do not imply every missing-file error currently deletes evidence. Only explicit deletion or established retention policy may remove retained evidence.
- Bind searchable text, block provenance and geometry to the same extraction revision. Derive flattened text and offsets from that structure. Phase 1 must suppress unsupported legacy highlights; it must not wait for Phase 2 to stop displaying false precision.

### Shared identity and resolution

Introduce `EvidenceRef` in Shared and propagate it through database lookup, citations, UI selection, async completion guards and caches:

```text
ActivityEvidenceRef
  storeUUID
  sourceKind
  eventID

ScreenEvidenceRef
  storeUUID
  sourceKind
  observationID
  frameID
  extractionRevision
  blockIDs

AudioEvidenceRef
  storeUUID
  sourceKind
  recordingID / segmentID
  transcriptRevision
  sample or time offsets
  word/span IDs when available
```

Return a result kind (`activity`, `screen` or `audio`) and linked-evidence availability alongside the appropriate address. Compatibility records may retain old grouping identifiers, but new evidence references do not require a derived interval or episode. Activity-only resolution returns the event and coverage, never a manufactured frame/observation reference.

Keep capture time, display identity, saved pixel dimensions, media identity/availability and inspection provenance alongside the address where applicable. `observationID` is independent of `frameID`: new context can create a new observation while reusing unchanged pixels. Establish minimal stable observation/extraction snapshots in Phase 1; Phase 2 extends their capture-time structure and change feed. Give legacy records durable identities through bounded materialisation and a persistent store registry; mark legacy context as uncertain and do not modify imported databases.

Add one asynchronous `EvidenceResolver` contract for agent inspection, citation opening and historical preview. It resolves only the requested store/source, validates observation and revision, checks deletion/privacy policy, and proves media/frame identity. Missing Rewind connectivity must never fall back to native storage using the same integer ID.

Exactness is unconditional for evidence resolution, regardless of timeline visibility. Validate the decoder's actual presentation timestamp against the requested encoded sample and its index/mapping; reject invalid timestamps and neighbouring samples. Reuse strict decoding and fresh-generator retry where appropriate, but do not route evidence through the currently weaker `ImageExtractor` path. Explicitly tolerant ordinary playback remains separate.

Support newest-frame previews from the recording journal immediately in Phase 1. Require a verified frame-to-record mapping and consistent timestamp/dimensions/display identity. A missing mapping must not silently become index-only lookup; return finalising/unavailable until identity can be proven. Handle journal-to-finalised-video transitions and late async completions without changing the requested evidence.

Return typed states: resolved; not permitted; source disconnected; recording missing; frame finalising; evidence deleted; requested extraction superseded/unavailable; or integrity/exactness failure. Check disclosure authorisation before returning availability details: a denied client must not learn whether restricted evidence exists or was deleted. A retained superseded revision can still resolve as that revision, with its status exposed. An unavailable old revision must not borrow newer text or highlights.

### Citation-driven historical navigation

Add an evidence deep-link route carrying `EvidenceRef` and an explicit historical-evidence navigation mode. Existing search/timestamp routes retain their ordinary meanings. **View recorded screen** must resolve the target directly, select its exact source-qualified frame, then load surrounding history; it must not clear relevant context, snap to newest, initiate a live screenshot for the citation, or substitute the nearest timestamp when a bounded neighbourhood lacks the target. Background recording continues normally.

Key image caches by source-qualified media/frame identity and overlay/selection caches by observation and extraction revision as well. Apply highlights only when block provenance, revision, saved dimensions, clipping and coordinate transforms match the resolved image. Otherwise show the recorded screen with an explicit unsupported-highlight state.

Keep **Open current document/website** as a separate action. Preserve the selected historical timeline while expanding its retained source observations. Linked audio/screen evidence remains contextual: simultaneity alone does not establish speaker identity or what a statement refers to.

## 3. Capture context, preserve revisions and enforce privacy

Use the independent context stream as a capture-time context source, then bind each retained image observation to a timing/identity-consistent snapshot of visible surfaces. The event stream continues during OCR/encoding backlog; lack of screenshot evidence stays explicit. Context-only changes must survive image deduplication, and small consequential visual changes must be tested separately. A title or URL learned later cannot rewrite an earlier canonical observation or backfill a closed segment as an asserted past fact. Later-derived context is a separately attributed interpretation.

Group visible text by its owning surface and preserve supported headings, chat turns, table cells/headers, code, statuses and reading order. A block carries text, provenance, geometry, source dimensions and extraction revision together. Render complete structured and readable observations from the same blocks; never prepend/replace flattened Accessibility text while reusing offsets derived from another OCR sequence. Unknown ownership, obscured text and missing roles remain explicit; the visible excerpt is not the whole document.

Extend the existing atomic OCR commit rather than adding another canonical writer. In one transaction, preserve the immutable extraction, update the preferred text/region/FTS projection, publish processing outcome and append its monotonic change-feed event. Retries and later refinements keep the original capture time and do not become new user activity. Audio already retains earlier passes; add conditioning provenance and quality-based preference instead of assuming the highest pass is best.

The consumer atomically records immutable applied-event IDs and durable lexical/vector work before advancing its checkpoint. Enforce monotonic per-observation revision guards so duplicate or older events cannot downgrade a projection. Track lexical and vector coverage/revisions independently. Bootstrap from a recorded change-feed boundary in short keyset pages, then replay intervening changes idempotently. Retain events required by unexpired bootstrap/consumer cursors; compaction must explicitly expire affected cursors and require reconciliation or rebootstrap, never silently skip a feed gap. Close upstream read transactions before decode or model work; long SQLite WAL readers can prevent checkpoint completion. [SQLite WAL concurrency documentation](https://www.sqlite.org/wal.html#concurrency)

Deletion overrides search snapshots and queued/active jobs. Check fencing, policy, expected revision and the writer's durable source-state/tombstone projection in the same transaction that accepts a result, avoiding a local check-then-write race. The cross-store feed does not create a distributed transaction: later canonical changes invalidate derived projections, and exact resolution rechecks canonical state before returning evidence. Propagate tombstones to mirrors, vectors and worker copies. Missing or expired media is a separate availability fact and follows existing text-retention policy. Retained superseded versions remain provenance, never silently current context.

Apply one privacy policy across pixels, Accessibility, OCR/transcripts, derived text/vectors, helper staging and MCP responses. Capture-time AX is limited to proven visible portions of captured surfaces, bounded by time/node count, with secure fields and excluded/redacted content removed before persistence or indexing. Application-wide hidden children are not an acceptable substitute. Where visibility/occlusion cannot be established, omit AX content and expose the coverage gap.

Apply exclusions and credential scrubbing before activity/evidence metadata reaches storage, caches, logs, indexes, helpers or exports. Remove URL userinfo; strip secret-bearing query/fragment values and default to dropping unrecognised query/fragment fields, preserving only adapter-validated non-secret identifiers. Signed/opaque links whose path cannot be safely retained use an opaque local identity and safe label instead. Never retain the raw URL in diagnostic fields. Test encoded/mixed-case credentials and token variants across every sink; this is a tested policy, not a claim to recognise every possible secret. Remove existing logging of excluded window titles and log only opaque suppression reasons. Capture exclusion must not be bypassed by recording app/document names in an independent event stream.

Local processing and disclosure to an agent are separate controls. The existing private SSH helper is an allowed compute destination; it receives only selected policy-permitted inputs. New evidence export defaults to local use. A remote agent, including one reached through a local broker, needs a separately configured client/disclosure grant covering sources, time range and permitted evidence detail. Do not infer that grant from local model use. Revalidate policy at output, minimise returned context, and delimit all captured content as untrusted data. Privacy exclusions and explicit source restrictions are never relaxed for recall.

### Phase 2 implementation slices and Shared coordination

**2A — usable evidence navigation:** repair the Settings entry points and keep exact text-search selections in the timeline. Remove the standalone project/visit workflow and bring the evidence inspector into Screenshots alongside OCR.

**2B — structured observations and bounded expansion:** the coordinated Shared additions are `StructuredScreenObservation`, `EvidenceTextBlock`, explicit extraction provenance and exact expansion/continuation value types. Database owns immutable payload construction in the existing OCR transaction; App owns current source/privacy/deletion checks and bounded expansion; UI consumes the same observation for source context and readable text. Keep `ScreenEvidenceRef` and its existing main-then-chrome ordinal block IDs stable. Unknown semantic roles, ownership, extractor versions and legacy geometry remain explicit. Optional added payload fields must decode old snapshots without rewriting them. Root coordinates these Shared/Database/App contracts before module implementation.

The initial expansion API is local-only and accepts an exact source/store/observation/revision address. Bound returned blocks and text bytes, retain valid Unicode and an exact-revision continuation, and recheck permissions/deletion/source identity on every page. This adds no user evidence-bookmarking flow, automatic project assignment, new model or historical rewrite.

The same slice coordinates one opaque source-generation string across existing App/UI seams: DataAdapter exposes the current connection generation plus store identity with imported-file guards, ProgressiveRecallService forwards it, and screenshot list reads, frame selection, thumbnails and text expansion validate it around suspension points. UI rows retain the token acquired with that read; they cannot borrow a newer token from a global map. Announced source changes invalidate old UI work, and source-specific OCR reads fail closed after disconnection. This adds no project or classification dependency and needs no new Shared payload type.

**2C — durable evidence publication and bootstrap:** add transactional revision/tombstone feed entries, a coherent bootstrap boundary, applied-event/work persistence and independent lexical/vector readiness. `recall_search_revision` is an invalidation stamp, not a change feed. Multiple context observations sharing retained pixels need a separate schema/API design; V21 currently has one screen observation per store/frame.

**2D — local hybrid retrieval:** benchmark pinned local embeddings and ranking against the reviewed evidence corpus. Preserve full questions, exact-match coverage, source-qualified deduplication and explicit continuations. Do not enable the excluded `VectorSearchTODO` implementation unchanged; its bare frame IDs do not satisfy the current identity contract.

## 4. Retrieve broadly, assess the pool, expand and answer

| Stage | Required behaviour | Initial budget, with continuation |
|---|---|---|
| Find | Diverse candidates from direct text, captured source metadata, bounded typo/OCR variants and local semantic channels, with explicit reliable restrictions applied before truncation. Inferred labels never become an implicit prerequisite. | 200 compact candidates per page |
| Score | Assess useful text windows from the entire candidate page against the complete question before choosing the expansion set. Combine channels with explicit exact-match representation. | All candidates on the page; bounded model windows |
| Expand | Select approximately 20 after scoring; retrieve full blocks/context, retained variants, change evidence and neighbouring observations. | 20 candidates; 32,000 returned tokens |
| Inspect | Use the shared exact resolver, accurate OCR and optional local visual inference only for unresolved shortlisted evidence. | Three frames per batch; 30-second request deadline |

Reserve five of the initial twenty expansion positions for the strongest distinct exact names, numbers, phrases or identifiers when available; fill unused positions from the combined ranking. This is a diversity default to benchmark, not a confidence guarantee. Keep explicit matches discoverable through continuation even when a page is crowded. Preserve the complete original question; split long model inputs into meaningful windows instead of silently truncating the inquiry.

Each interpreted constraint carries `explicitRestriction`, `inferredHint` or `unresolvedAmbiguity`, its origin and whether a hint was relaxed. "Only Tuesday" is hard; "I think Tuesday" is a visible ranking hint. Existing foreground-app filters retain their meaning. Content-source requests such as "the Word document I saw" search visible-surface ownership and retain uncertain legacy candidates for later resolution; they must not silently become foreground-app restrictions. Never relax privacy or explicit source boundaries.

The initial neighbourhood is ten observations from the same surface within 30 seconds, not an episode definition. Continue beyond that budget by document/surface continuity and expose uncertainty when continuity is inferred. Group repeats without removing references; duplicate captures do not provide independent corroboration.

Include weak-text and visual-only screens in Find evaluation. Start with available metadata, nearby text and selective derived descriptions of weak-text screens. Inspect cannot recover a frame that Find never considers. Add a dedicated image-retrieval index only if the corpus shows these routes are insufficient; do not run an 8B model over every historical image by default.

Expose dedicated screen-search, expansion and inspection tools through the existing FuseIntel MCP boundary. Interactive inspection returns transient results; persistent idle work is a separate operation accepted only by its owner. Dispatch expensive work to a bounded worker outside the request-serving process, so model loading/decode cannot monopolise the existing single-worker backend. Search/status requests remain responsive during inspection.

Return actual excerpts or captured activity context, result kind, source-qualified references, revisions, linked-media availability, match reasons, constraint handling, per-channel coverage, unavailable sources and remaining continuations. Target initial warm indexed results within two seconds. Return partial per-frame inspection outcomes at the 30-second deadline; cancel remaining request work and retain an expiring continuation, not an implicitly authorised persistent job. Search continuations preserve a ranking/index snapshot while still enforcing current deletion and privacy state.

Answers use a claim-to-evidence contract: each factual claim cites supporting activity events, observations/blocks or audio spans and is labelled observed content, supported inference or unresolved interpretation. A metadata-only claim may cite an activity event (for example, which document was reported focused); it cannot assert the document's contents without the corresponding evidence. Keep conflicting observations available and show material disagreement. A reranker score is relevance, not truth probability; a larger model or higher pass is not verification. Contextual audio must retain neighbour IDs/revisions and prompt/model provenance and must not count as independent confirmation of those neighbours. An unsuccessful answer states what indexed evidence was searched, coverage, unavailable sources, unresolved constraints and remaining work; it must not claim the event never happened.

### Provisional local models

Benchmark `sentence-transformers/all-MiniLM-L6-v2` and the previously observed `BAAI/bge-reranker-v2-m3` as the initial baseline. Verify and pin their installed model/tokenizer revisions before the benchmark. MiniLM defaults to truncation beyond 256 word pieces: include metadata prefixes and special tokens inside the budget, start with at most 224 content/header word pieces and 32 overlap, chunk at meaningful boundaries, and retain complete original blocks for expansion. Use a separate 384-dimensional local screen index; never mix it with cloud-provider vectors. Verify BGE's runtime limits independently rather than assuming MiniLM's limit applies. [MiniLM model documentation](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)

Evaluate Qwen3-VL 8B Instruct Q4 on the helper after Phase 1 acceptance. The listed Q4_K_M artifact is approximately 6.1 GB and requires compatible Ollama (0.12.7 or later); this establishes neither working-memory use nor speed. Pin its digest, cap inference context/output, and compare native OCR alone against OCR plus visual inference on dense text, tables, overlapping windows and weak-text imagery, measuring cold load and warm runs. Enable only if measured benefit fits the limits; otherwise retain OCR-only inspection and explicit unresolved visual coverage. [Ollama model specification](https://ollama.com/library/qwen3-vl%3A8b-instruct)

The two private Macs remain the processing boundary, with no cloud-model fallback. Additional model files are capped at **20 GB aggregate across both machines**. Helper-first installation remains the candidate placement, not permission to skip validation. Earlier read-only checks found the helper reachable but its Ollama service unavailable; recheck runtime and capacity during implementation rather than treating that snapshot as current readiness.

## 5. Enforce capacity and refinement limits

Decide whether optional work can run from queue/latency, CPU, memory, thermal, disk and execution-budget measurements. Input quiet, permitted playback and speech signals are conservative scheduling inputs, not attention or project-duration claims. An unattended compile may deny capacity. Existing meeting detection uses active/visible-app heuristics in places; do not label those as measured microphone use.

Use one resource coordinator across native OCR/audio maintenance, embedding and derived visual work, with per-host admission and a shared heavy-work permit. Priorities are durable activity/capture, dictation, fresh OCR/transcription, requested inspection, then unattended history. Keep the initial five-minute input-quiet interval as a conservative admission condition for automatic work, not a verdict that the user is inactive. It does not gate a requested inspection. All optional work respects foreground/resource limits, and capture/retention continues according to explicit settings rather than an inferred idle-discard rule.

Initial unattended admission requires five minutes without input on the executing Mac, 60 seconds of quiet incoming speech/accepted visual changes and stable queue health, AC power, normal memory pressure, nominal/fair thermal state and normalised CPU utilisation below 50%. Microphone enabled is not speech activity; watching a meeting/video is not necessarily spare capacity. Reserve projected peak optional-worker memory plus 4 GiB headroom, use an initial 12 GiB optional-worker ceiling per host, and retain at least 20 GiB free on the capture/staging volumes after reservations. Phase 0 measurements may lower admission limits; increasing them requires recorded comparison evidence. Disk latency and fresh queue age can deny admission even with low CPU use.

Allow one heavy optional unit per host. Under Low Power Mode, admit at most **10 seconds of elapsed worker execution in a rolling 60 seconds**, restricted to bounded OCR/audio/text work; otherwise start at 30 seconds and permit visual inference. Charge from admission until confirmed stop, including input reads/decoding, cold model loading, inference, output handling and cancellation drain. Waiting in an unadmitted queue is not charged. Reserve shutdown allowance inside the unit's budget; record overruns and block further admission until the rolling budget recovers. Leave macOS power settings unchanged.

Cancellation must reach the operation. Wire Whisper's abort callback to a thread-safe per-operation deadline/cancellation token before claiming enforcement. Check between decode/inference stages; use small checkpoints or job-owned worker processes for optional operations without reliable in-process cancellation. Admit only units demonstrated to fit the remaining budget including termination. Split oversized audio work or defer it to the helper; do not repeatedly restart an oversized unit. Cancelled work is resumable and does not consume a quality-failure attempt. Record actual yield latency and pause further admission after failed preemption.

Give three unattended slots to unresolved inquiries or weak evidence, then one to the oldest eligible work. Persist source identity/revision, operation/model version, job fingerprint, attempts, lease, checkpoint and typed outcome. Quality-based preference compares valid source coverage, language and unsupported-content flags against retained alternatives; additional text alone is not improvement.

Reuse the private SSH dispatcher with one helper worker and job-scoped inputs/results. Renew leases every five seconds through a control loop independent of blocking inference. Cancel the running operation and stop admission immediately on explicit revocation or lease expiry; also cancel after 15 seconds without renewal. Every job has a separate execution deadline and fencing token; the accepting writer rechecks authorisation, source revision, deletion and fencing before idempotent acceptance. Heartbeat responsiveness does not extend a revoked job. Escalation may terminate only that job's owned process, never broad remote `pkill` targets.

Keep computation off the request-serving backend; the helper gets only selected media/context and cannot write central databases. Use checksummed incremental results with acknowledgements. A remote transfer failure is not proof that local source media is missing. If the helper is unavailable, return deferred/unavailable status and continue only the main Mac's existing bounded allowance.

Cap newly staged helper media at **5 GiB**, separately from the model allowance; reserve capacity before transfers/downloads. Remove acknowledged media, expire abandoned new-job media after 24 hours, retain compact bounded receipts and reuse unchanged content/embeddings. Reconcile the pre-existing approximately 4.1 GB results file before any cleanup. Preserve original evidence and avoid permanent duplicate screenshots.

## 6. Mandatory acceptance and rollout

| Area | Required scenarios |
|---|---|
| Independent activity and coverage | App/document transitions during screenshot deduplication, delayed encoding and OCR backlog; rapid switches during slow enrichment; same-title URL-cache collisions; observer/permission loss; bounded writer overload; restart, pause, sleep/wake and wall-clock changes. Distinguish unchanged focus from unknown gaps. |
| Source context and integrated evidence | Priority application/pane titles and available session identifiers; rename versus new same-title document; real display identity; unsupported ownership stays unknown; Screenshots image/OCR/context agree; no project/visit assignment or correction dependency. |
| Health and privacy controls | Green recording with stalled OCR/transcription; context observed but not durable; retained/reused screenshot distinction; pause/exclude/delete semantics; URL userinfo, encoded tokens and signed links in every sink; excluded window titles in logs; activity-only mode explicitly selected. |
| Retrieval completeness | Eligible result below thousands of stronger out-of-scope matches; sparse and subsequent pages; exhausted versus resumable cursors; equivalent native/FuseIntel constraints; long questions and exact identifiers amid semantic duplicates. |
| Distinct evidence and context | Same-title documents with different amounts/decisions and chronology; ChatGPT with Canvas; named/unsaved/renamed Word documents; same-title URL navigation; overlapping windows; continuity beyond ten observations/30 seconds. |
| Historical isolation and privacy | Process an old frame with unrelated live AX content and configuration enabled; hidden/offscreen/secure/excluded AX nodes; redacted pixels whose raw text appears in AX; denied helper/export clients; local broker forwarding to a remote agent; exclusion changes during a request. |
| Exact navigation | Native/Rewind numeric ID collisions; disconnected requested source; hidden/visible/previously live timeline; target absent from a bounded neighbourhood; stale async selection/cache; no nearest-frame or current-screen substitution; activity-only references without fabricated frames and delayed links with mismatched timing/window generation. |
| Exact media and highlights | Decoder timestamp mismatch/gap/invalid value; exact journal mapping, missing/conflicting map and finalisation races; AX/OCR disagreement; obsolete extraction; display scaling/transforms and partly obscured text. Suppress unsupported overlays. |
| Revisions, repair and deletion | Crash between revision/event publication; consumer crash before checkpoint; lexical ready/vector pending; revise/delete during bootstrap, continuation, inspection and helper work; stale/fenced results; actual repair-error branches preserve text when media is unusable. |
| Capture sensitivity | Real rendered frames at representative display resolutions/scales changing one important digit, negation or draft/sent/error status. Require retention of reviewed consequential changes; sampled-pixel thresholds alone do not establish this. |
| Visual-only and answer quality | Charts/diagrams/image-heavy screens with weak OCR; claim-level support, conflicting versions, unknown ownership, dependent audio context, duplicate captures and honest unsuccessful-search coverage. |
| Scheduling and service isolation | Active call/video without keyboard activity; AC Low Power Mode; thermal/memory/disk pressure; in-operation Whisper abort; slow/non-cancellable unit; helper loss/revocation during inference; ordinary search/status latency during cold model load. |

Use real Vision, SQLite, filesystem/media and UI workflows for acceptance, with independently annotated sources and a reviewing agent given only the rendered text. Keep synthetic SQL as a reproducible query-shape regression, not proof of application correctness. Require **zero wrong-frame displays** in reviewed navigation fixtures; explicit failure is preferable to the wrong screen. Add daily metrics for context durability/gaps, exact evidence opening/expansion, distinct privacy actions, stage health, queue coverage, pause/preemption reasons and revision acceptance, without captured text in telemetry.

Use a fixed evidence-capture and recall workload covering ordinary work, same-title documents, quick changes, quiet reading, meetings, background work, sleep/wake and an OCR backlog. Review the retained screenshots as adjudication evidence. Compare correct source attribution, preserved consequential changes, honest gaps and time to locate a requested moment. Selecting the result must open the exact supporting screen or explicitly report absent evidence. The earlier Timely comparison is historical research, no longer a delivery gate for this evidence-focused scope.

Compare the same evidence/workload and settings before and after: retrieval recall and answer/citation precision; attribution and highlight integrity; OCR character/audio word error; capture gaps, fresh queue growth and capture-to-search p50/p95; dictation and ordinary service latency; cold/warm inspection latency, peak memory, energy and disk growth. Require improved quality without attribution/privacy regression and no more than a 10% increase in foreground-processing p95. Baseline capture gaps/queue age are separate gates; an acceptable percentile must not hide dropped captures or accumulating backlog.

Also measure notification-to-durable-context p50/p95, missing/late context rate, adapter coverage and context-stream bytes per day. Metadata search and evidence navigation must remain useful before OCR completes; more metadata rows alone do not establish better recall.

Use additive migrations and independent switches for context, hybrid retrieval, inspection and idle refinement. Coordinate Shared contracts before module implementation; use existing module owners, tests first and appropriate code/database/security reviews. Preserve prior application/configuration and compatible data rollback strategy. Update AGENTS when adding files and CHANGELOG for meaningful changes. Record a **Local trial** only after verifying installation and launch, with the exact navigation and comparison checks clearly scoped; a commit or passing suite is not a release.

## Historical Timely research (superseded product scope)

These references record the earlier planning input, not the current product specification. Stuart removed project assignment and visit grouping from scope on September 14. Retain useful capture/privacy lessons only; none of this section makes a Timely-style workflow or comparison a delivery requirement.

- Timely describes Memory's app/window titles, URLs, occasional filenames and timing, and explicitly excludes screenshots, keystrokes and audio. Its brief-glance limits should not become Retrace's retention policy. [What is captured by Memory?](https://www.timely.com/help/handbook/privacy/what-is-captured-by-memory/)
- The May 7, 2026 Mac update describes Codex and Claude Chat/Cowork/Code titles and URLs when available; that release listed ChatGPT Desktop support as forthcoming. The May 19 update distinguishes Cursor Agents from the editor and describes URL credential scrubbing. Neither establishes comprehensive agent-execution telemetry or an exhaustive sanitisation algorithm. [Claude and Codex support](https://www.timely.com/product-updates/2026-05-07-memory-app-claude-codex-tracking/), [May 19 Memory update](https://www.timely.com/changelog/2026-05-19-memory-app-update/)
- Classic Timeline documents grouping, interruption continuity, title labels and visual suppression of short activities. Memory for Mac documents idle exemptions/fullscreen differences, recent activity, diagnostic state, pauses, schedules and ignore/rewrite controls. Retrace borrows organisation and explicit controls, not idle-based evidence discard. [Classic Timeline](https://www.timely.com/help/handbook/classic/classic-timeline-view/), [Memory for Mac](https://www.timely.com/help/handbook/autosheet/memory-for-mac/)
- AutoSheet documents learning from submitted days and reviewed assignments/summary edits rather than drafts. Retrace's earlier design used explicitly confirmed local annotations/rules and excluded uncorrected AI guesses from approved examples. That assignment workflow is now outside active scope. [Teaching AutoSheet](https://www.timely.com/help/handbook/autosheet/teaching-autosheet/)

## Historical review verification at the original checkpoint

The first amendments were checked against `118b790` source; the activity/context follow-up was checked against `4207f4b`. This was not a fresh audit of the running Macs or the separate FuseIntel/SSH implementation. No Mac acceptance suite, matched Timely comparison or model inference was run for these documentation amendments.

- Existing `DisplaySwitchMonitor` notifications feed screenshot/display handling, not an independent durable activity stream. `CaptureManager` suppresses/coalesces some window-triggered captures and deduplicates images before metadata enrichment. `AppCoordinator` currently derives an idle condition from gaps between retained frames; activity coverage must replace that inference.
- `AppInfoProvider` supplies useful AX/window-list fallbacks but reports the main display and lacks the proposed stable document/pane identity contract. `BrowserURLExtractor` uses title/PID cache identity in one path and does not scrub credentials before returning extracted URLs. Excluded window titles can still enter a capture log. The proposed activity path must fix these identity/privacy gaps before adding another metadata sink.
- Current capture/processing/audio statistics provide useful counts and timestamps, but not the complete observed/persisted/indexed health contract. A meeting-detection helper labelled microphone use is an active/visible-app heuristic; the engagement model must retain that qualification.

- `DataAdapter.searchRelevant` limits global BM25 matches before constraints, and both relevant/chronological paths discard some title/position-similar rows. `FTSManager` applies filters before its final limit; entry-point parity must be tested.
- Normal App injection disables live AX text merging, but Processing's enabled path reads the focused app and can replace metadata. The AX walker lacks visible-surface checks. Merged text and OCR-derived offsets can disagree.
- URL enrichment can overwrite/backfill segment context. Qualifying OCR repair errors can delete frames; this is narrower than saying every missing-file error deletes evidence. Audio older passes are retained, but reads favour the highest pass without proving quality.
- Unqualified lookups/caches and Rewind fallbacks can resolve another source. One timeline path reports success after selecting a nearest frame when its target is absent. `ImageExtractor` ignores actual decoder time, whereas `StorageManager` has a strict retry/check path; the plan unifies evidence resolution without claiming every existing read is weak.
- A dashboard journal-preview seam exists, but its absent-ID-map fallback to index is insufficient identity proof for citations. Exact journal-backed evidence preview still needs implementation.

An independent in-memory SQLite 3.51.0 reproduction used 2,000 stronger out-of-scope matches and one eligible Word frame at global rank 2,001: global limit 1,500 then filter returned zero; filter before limit returned frame 2,001. The supplied sandbox attachment was not present in this workspace, so this was a separately recreated probe, not execution of the supplied file. The following standalone SQL reproduces that query-shape result in SQLite with FTS5 and materialised CTE support:

```sql
CREATE VIRTUAL TABLE searchRanking USING fts5(text);
CREATE TABLE segment(id INTEGER PRIMARY KEY, bundleID TEXT);
CREATE TABLE frame(id INTEGER PRIMARY KEY, segmentId INTEGER, createdAt INTEGER);
CREATE TABLE doc_segment(docid INTEGER, frameId INTEGER);
INSERT INTO segment VALUES (1, 'outside'), (2, 'com.microsoft.Word');
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<2000)
INSERT INTO searchRanking(rowid, text)
SELECT i, 'contract contract contract' FROM n;
WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<2000)
INSERT INTO frame SELECT i, 1, 200 FROM n;
INSERT INTO searchRanking(rowid, text)
VALUES (2001, 'contract ' || replace(hex(zeroblob(200)), '0', 'detail '));
INSERT INTO frame VALUES (2001, 2, 100);
INSERT INTO doc_segment SELECT id, id FROM frame;

-- Defective shape: zero eligible rows survive the global shortlist.
WITH ranked AS MATERIALIZED (
  SELECT rowid AS docid, bm25(searchRanking) AS rank
  FROM searchRanking WHERE searchRanking MATCH 'contract'
  ORDER BY bm25(searchRanking), rowid LIMIT 1500
)
SELECT f.id FROM ranked r JOIN doc_segment ds ON ds.docid=r.docid
JOIN frame f ON f.id=ds.frameId JOIN segment s ON s.id=f.segmentId
WHERE s.bundleID='com.microsoft.Word' AND f.createdAt=100
ORDER BY r.rank, f.id LIMIT 150;

-- Correct constraint placement: returns 2001.
SELECT f.id FROM searchRanking
JOIN doc_segment ds ON ds.docid=searchRanking.rowid
JOIN frame f ON f.id=ds.frameId JOIN segment s ON s.id=f.segmentId
WHERE searchRanking MATCH 'contract'
  AND s.bundleID='com.microsoft.Word' AND f.createdAt=100
ORDER BY bm25(searchRanking), f.id LIMIT 150;
```
