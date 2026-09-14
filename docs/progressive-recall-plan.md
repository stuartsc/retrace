# Progressive recall with activity context, exact evidence and idle refinement

Saved and amended: 2026-09-11. Initial review baseline: [`118b790863a43d21ff8997b0bdd43bd5fb8bbf45`](https://github.com/stuartsc/retrace/commit/118b790863a43d21ff8997b0bdd43bd5fb8bbf45), `feature/push-to-dictate`. The activity-context amendment was checked against [`4207f4b`](https://github.com/stuartsc/retrace/commit/4207f4b9fab7cce41d7f5e153216de25ff4c0f3c).

**Status: Phase 0 baseline/fixtures and Phase 1 core code implemented; installed Mac acceptance is in progress.** Stuart authorised implementation on 2026-09-11. The latest integrated run passed **880 tests with five intentional skips and zero failures**; source review is complete. Native Word fixtures passed document identity and metadata search before OCR; Claude exposed only its generic window title. Copied-library validation drove a defensive SQLite reader compatibility fix, and trial preparation added awaited shutdown and durable metric acknowledgement. The September 14 installed trial verified exact same-title proposal links and exposed a notification storm. After that correction, a native process-identity edge case and unknown-notification attribution were repaired; optimized **2609.14.2** is now installed and running in the background. Saved-link reopen was verified on **2609.14.1**, before this capture-only follow-up. The native database remains V21; the prior app and earlier whole-library recovery copy are retained. The actual-user question corpus, remaining priority-app fixtures, matched Timely exercise and wider correctness/performance gates remain outstanding. Implementation and acceptance evidence are tracked in [progressive-recall-validation.md](progressive-recall-validation.md). The Phase 0/1 checkpoint is committed for continued development; this remains an unreleased local trial. Phase 2 is unstarted. Existing fixes and local trials remain documented in [CHANGELOG.md](../CHANGELOG.md).

## Objective and delivery order

Find the right historical evidence, preserve what it actually says, explain its limitations, and reopen precisely the recorded screen supporting an answer. A text-only agent should understand visible application/document/conversation context and supported changes. Add an independent durable activity stream so context and document-first navigation remain useful while screenshot encoding or OCR is delayed. Activity signals can establish which document was reported focused, but cannot establish its contents without linked evidence. Progressive retrieval, immutable context, exact resolution and local refinement remain the architecture.

| Phase | Deliverable | Required exit condition |
|---|---|---|
| 0. Baseline and reproducible failures | Versioned real questions with independently annotated expected evidence, retrieval/navigation/privacy fixtures, the SQL shortlist reproduction and a matched Timely comparison. Record the same workload and settings. | Correctness, coverage and performance are measurable against fixed evidence; synthetic SQL and product comparisons are distinguished from Mac acceptance. |
| 1. Activity context, correct recall and exact navigation | Persist independent activity events and coverage; add application adapters, a document-first episode/interval/evidence timeline, confirmed classification corrections and stage health. Repair truncation and evidence-dropping deduplication, isolate historical extraction from live Accessibility, preserve text after media-repair errors, and open exact evidence including journal previews. | Activity remains searchable during OCR/encoding backlog; brief transitions and unknown gaps stay represented. Every reviewed citation opens the requested retained screen or an explicit unavailable/integrity state; **zero wrong-frame displays**. No new model required. |
| 2. Structured observations and hybrid retrieval | Extend capture-time context and the initial activity feed to unified text/geometry blocks, immutable extraction revisions, bounded bootstrap/catch-up, local semantic retrieval and deeper contextual expansion. | Recall improves without attribution, privacy or highlighting regression; activity labels never become a compulsory retrieval filter. |
| 3. Coordinated on-demand inspection | Shared admission/cancellation, exact-frame inspection outside the request-serving process, bounded helper jobs and a benchmark-gated local visual model. | Difficult questions improve without compromising capture, dictation or ordinary service responsiveness. |
| 4. Measured historical refinement | Prioritised weak-evidence work, durable progress, retained alternatives and quality-based preferred versions. | Paired evaluation shows more correct evidence or lower extraction error, without unsupported claims or foreground regressions. |

| Component | Responsibility |
|---|---|
| Retrace activity capture | Durable app/window/document context events, timing, observation method and coverage, independent of image acceptance or OCR. |
| Retrace evidence capture | Canonical screenshots, audio, immutable observations/revisions, exact resolution and native refinements. |
| FuseIntel | Consume the activity/evidence feeds through its designated writer; derive versioned intervals/episodes, correlate sources, apply confirmed classification mappings, retrieve evidence and answer inquiries. |
| Retrace timeline | Show episodes, document/conversation intervals and exact recorded evidence; submit explicit correction annotations and expose capture/indexing health. |

FuseIntel does not write into Retrace or imported Rewind databases. The two repositories share contract fixtures for identity, constraints, coverage and availability. Start episode organisation with deterministic local rules and confirmed mappings; a model download or broad visual backfill is not a prerequisite. If classification is unavailable, show persisted activity events and available exact evidence with that limitation, rather than an empty or falsely complete timeline.

## 1. Independent activity capture and contextual timeline

### Durable events before image processing

Introduce a lightweight `ActivityEvent` stream independent of screenshot admission/deduplication, encoding and OCR. Reuse app-activation and AX window/title notification mechanisms already observed by `DisplaySwitchMonitor`, but give activity its own observer lifecycle, handler and persistence path, not the screenshot path's coalescing, related-title suppression or delayed capture. A screenshot worker restart/failure must not stop activity observation; master pause/exclusion still applies. Extend `AppInfoProvider` and `BrowserURLExtractor`; do not replace their working native extraction wholesale.

An event carries store/session identity, immutable event ID and sequence, observation wall time, monotonic timing within the session, persistence time, event kind, permitted app/window/pane/document context, actual display identity, method/version, uncertainty and coverage status. Image/audio references are optional links that can arrive later; persist links with provenance without changing the original event. Validate source/session/window generation and observation timing when linking, and retain the media's actual capture time. Nearby or reused older media is contextual unless its relationship to the observation is proven; nearest timestamp alone is never enough. A successful event with no image establishes observed activity only, not visible document contents or a screenshot citation.

Record meaningful transitions promptly through the existing canonical writer using short transactions and a bounded queue. Persist a minimal permitted event before expensive enrichment; background enrichment must use a captured snapshot and the original window/process generation, with its own observation time. It must not fill an old event from whatever becomes focused after an await. Publish a small resumable activity feed in Phase 1, with atomic event/feed publication and durable consumer checkpoints; Phase 2 extends the same contract to richer evidence revisions.

Start with bounded reconciliation every two seconds while activity collection is enabled and awake, and a compact coverage heartbeat every 30 seconds when unchanged. Notifications preserve observed brief transitions; periodic reconciliation is a fallback and must disclose missed-event uncertainty. Persist transitions, not repeated copies of unchanged titles. Do not coalesce away different documents, panes or quick app switches. Test sampling/admission latency against the actual workload before claiming two-second glances are captured reliably.

Keep window lifetime identity separate from notification ordering. Repeated title/move notifications must not manufacture new window visits, while any notification during context sampling or pixel capture must invalidate that capture's admission receipt, including an A→B→A round trip. Delayed document enrichment needs the same ordering check before enqueue and consumption. Bound enrichment to one in-flight read and a request to resample the current app; a retry must never replay a formerly focused app as a newly observed focus. The installed September 14 trial exposed the need for these distinctions.

Represent startup, shutdown, pause, sleep/wake, permissions loss, observer failure, queue overflow, clock discontinuity and storage failure explicitly. Use session/boot boundaries and monotonic time to avoid negative durations. Distinguish observed unchanged focus, explicit pause/sleep and unknown coverage. Do not infer inactivity from missing retained screenshots, as the current segment tracker does. Do not bridge an unobserved gap as continuous focus. If persistence fails, mark health degraded immediately and write a bounded gap/reconciliation marker when storage recovers; never silently discard transitions or block screenshot capture behind enrichment.

### Application-specific context contract

Use the extraction hierarchy: **application → specific window/pane → document/conversation identity → readable title → permitted URL/path → method and uncertainty**. Window identity includes process/session generation to handle reused IDs; report the window's actual display, not automatically the main display. LaunchServices launch dates are optional: establish an observed native process lifetime without inventing a date or relying on PID alone. Missing or terminated notification identity stays an unknown gap; a later reconciliation may sample the current application with its own observation time. Titles are labels: same-title documents/tabs remain distinct, and a rename preserves identity only when a stable document/session identifier supports it. Replace title-plus-PID URL cache keys with source/window/document-qualified identities and invalidate on navigation or generation changes. Credential scrubbing must not merge distinct contexts merely because their sanitised URLs become equal; retain separately observed navigation/identity boundaries when a safe stable identifier is unavailable.

Prioritise Word, ChatGPT, Codex, Claude Chat/Cowork/Code, and the existing browser integrations; then Cursor editor/Agents, Excel, Finder and meeting-app context. Build real adapter fixtures for installed priority applications in Phase 1. Unsupported or unavailable title/pane/session URL extraction stays explicit; do not claim a universal conversation identity from a generic window title. Use native/Accessibility/app-exposed metadata before asking a visual model to infer project identity, while preserving the visible-surface and privacy restrictions below.

Keep foreground focus and background agent execution on separate tracks. Record agent work only to the extent exposed by trustworthy app/session signals, with method and uncertainty; app visibility alone does not establish actual execution duration. Background agent time never inflates a measure of the user's attention. Focus intervals are not proof of reading, authorship or engagement.

### Three levels of presentation, with lossless expansion

| Level | Presentation and evidence rule |
|---|---|
| Work episode | A versioned derived overview, for example “Georgetown IM: Word, browser research and Excel”. Show classification provenance, elapsed span, interruptions and unknown coverage. |
| Activity intervals | Specific documents, conversations, panes and application switches, derived from retained events. Preserve actual observed focus intervals separately from an episode's elapsed span; never double-count parallel background agents as attention. |
| Recorded evidence | Exact source-qualified screenshots, text blocks and audio segments, reached through the shared resolver. Activity-only intervals explicitly show that linked media/text is pending or unavailable. |

Allow grouping/ungrouping, document/page titles and configurable visual suppression of short intervals. Start with no duration-based hiding; if the user enables it, retain a visible hidden-item count and expansion. These are presentation controls, never evidence deletion or search-index filtering. Candidate episodes may bridge short interruptions, initially up to 60 seconds only with matching document/session identity or a confirmed project mapping; retain the interruption itself and mark inferred continuity. Longer episodes can be expanded or explicitly grouped without asserting continuous activity.

Selecting an evidence-bearing search hit opens its matching recorded screen inside the episode, not the episode's representative image. A separate expansion control reveals surrounding activity. An activity-only hit opens its interval and coverage state without substituting a nearby screenshot. Keep direct text/semantic retrieval independent of activity/episode search: a wrong episode label must not hide matching evidence, and broad retrieval must remain usable before episode classification completes.

### Confirmed corrections and honest health

Support corrections such as project assignment, separating two same-title documents, episode rename and grouping. Store these as versioned annotations/mappings with author, confirmation state, target scope and supporting IDs, separate from captured facts. Default a correction to the selected episode/interval; reusing it for a stable document/conversation or future work requires an explicit reusable mapping. Provide undo/revoke, preserve earlier annotation versions and show material mapping conflicts. Exact user-confirmed annotations outrank inherited rules and model labels for that selected scope; they cannot alter recorded content or identity.

Only explicitly confirmed corrections become reusable examples/rules. Draft mappings, unaccepted summaries and the absence of a correction are not approval. Begin with local rules and mappings, not fine-tuning; an AI-generated classification must not become its own training evidence. Reclassification changes derived revisions and search facets, never the immutable activity/evidence stream. Evidence deletion also removes or sanitises dependent annotations under the same retention/privacy policy.

Retrace's canonical writer atomically persists each annotation command and its outbox/feed event, including command ID, target IDs, expected derived revision, scope and confirmation state. FuseIntel's designated writer consumes commands idempotently, checks targets/deletion/revision, then publishes an acknowledgement and derived episode revision through its existing read API. Retrace reads that projection back; it does not directly edit FuseIntel tables. Keep confirmation distinct from application status: outages leave confirmed corrections pending, while conflicting/stale targets surface as unresolved rather than silently changing scope. Raw activity and exact evidence remain navigable offline. Revoke/undo follows the same durable command path.

Expose stage health separately: **activity observed/persisted; screenshot observed/retained or deliberately reused; text indexed; audio transcribed; refinement pending/deferred**. Show last successful observation/commit, oldest pending age, known gaps and paused/excluded/unsupported/degraded states. Separate lexical/vector readiness when added. A green “Recording” indicator means collection is enabled, not that every downstream stage is current. Use authoritative stage receipts/heartbeats so deduplication is not mistaken for capture failure, and missing telemetry is not mistaken for inactivity.

Keep controls distinct: **Exclude from capture** prevents collection across activity and evidence; **Hide from timeline** changes presentation; **Rename/group** adds derived organisation; **Delete evidence** removes the selected source and its derivatives. A master pause/schedule applies to activity content too, unless the user explicitly selects activity-only collection. During pause, administrative pause/resume markers may be stored without app/document content. Diagnostics and user-facing controls must identify their scope.

## 2. Stop incorrect recall and establish an evidence address

### Correctness prerequisites

- Apply reliable constraints before candidate truncation in `DataAdapter.searchRelevant`; fix cursor exhaustion so a sparse eligible result is not mistaken for the end of available evidence. Raising the global limit is not a correctness fix. Align relevant, chronological, fallback and FuseIntel search semantics with shared conformance fixtures; retain the filter-before-final-limit foundation already present in `FTSManager`.
- Replace title/highlight-position deduplication in both relevant and chronological paths with grouping that retains every source-qualified observation and its chronology. Same-title documents with changed amounts, negations or decisions remain distinct evidence. Page cursors advance over examined source records, not only displayed groups.
- Make queued/historical extraction structurally unable to query live Accessibility, even if a configuration enables Accessibility elsewhere. Until saved capture-time snapshots exist, queued work uses retained pixels and saved metadata only. The normal App configuration currently disables live Accessibility merging; the unsafe path remains configurable, so this is a prevention requirement rather than a claim of observed current contamination.
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

Return a result kind (`activity`, `screen` or `audio`) and linked-evidence availability alongside the appropriate address. Derived interval/episode references also carry their IDs/revisions and underlying event/evidence references; an episode label is not itself a captured fact. Activity-only resolution returns the event and coverage, never a manufactured frame/observation reference.

Keep capture time, display identity, saved pixel dimensions, media identity/availability and inspection provenance alongside the address where applicable. `observationID` is independent of `frameID`: new context can create a new observation while reusing unchanged pixels. Establish minimal stable observation/extraction snapshots in Phase 1; Phase 2 extends their capture-time structure and change feed. Give legacy records durable identities through bounded materialisation and a persistent store registry; mark legacy context as uncertain and do not modify imported databases.

Add one asynchronous `EvidenceResolver` contract for agent inspection, citation opening and historical preview. It resolves only the requested store/source, validates observation and revision, checks deletion/privacy policy, and proves media/frame identity. Missing Rewind connectivity must never fall back to native storage using the same integer ID.

Exactness is unconditional for evidence resolution, regardless of timeline visibility. Validate the decoder's actual presentation timestamp against the requested encoded sample and its index/mapping; reject invalid timestamps and neighbouring samples. Reuse strict decoding and fresh-generator retry where appropriate, but do not route evidence through the currently weaker `ImageExtractor` path. Explicitly tolerant ordinary playback remains separate.

Support newest-frame previews from the recording journal immediately in Phase 1. Require a verified frame-to-record mapping and consistent timestamp/dimensions/display identity. A missing mapping must not silently become index-only lookup; return finalising/unavailable until identity can be proven. Handle journal-to-finalised-video transitions and late async completions without changing the requested evidence.

Return typed states: resolved; not permitted; source disconnected; recording missing; frame finalising; evidence deleted; requested extraction superseded/unavailable; or integrity/exactness failure. Check disclosure authorisation before returning availability details: a denied client must not learn whether restricted evidence exists or was deleted. A retained superseded revision can still resolve as that revision, with its status exposed. An unavailable old revision must not borrow newer text or highlights.

### Citation-driven historical navigation

Add an evidence deep-link route carrying `EvidenceRef` and an explicit historical-evidence navigation mode. Existing search/timestamp routes retain their ordinary meanings. **View recorded screen** must resolve the target directly, select its exact source-qualified frame, then load surrounding history; it must not clear relevant context, snap to newest, initiate a live screenshot for the citation, or substitute the nearest timestamp when a bounded neighbourhood lacks the target. Background recording continues normally.

Key image caches by source-qualified media/frame identity and overlay/selection caches by observation and extraction revision as well. Apply highlights only when block provenance, revision, saved dimensions, clipping and coordinate transforms match the resolved image. Otherwise show the recorded screen with an explicit unsupported-highlight state.

Keep **Open current document/website** as a separate action. Preserve the foreground-app timeline while allowing a grouped result to expand its retained observations and candidate document/conversation episodes. Linked audio/screen evidence remains contextual: simultaneity alone does not establish speaker identity or what a statement refers to.

## 3. Capture context, preserve revisions and enforce privacy

Use the independent activity stream as a capture-time context source, then bind each retained image observation to a timing/identity-consistent snapshot of visible surfaces. The event stream continues during OCR/encoding backlog; lack of screenshot evidence stays explicit. Context-only changes must survive image deduplication, and small consequential visual changes must be tested separately. A title or URL learned later cannot rewrite an earlier canonical observation or backfill a closed segment as an asserted past fact. Later-derived context is a separately attributed interpretation.

Group visible text by its owning surface and preserve supported headings, chat turns, table cells/headers, code, statuses and reading order. A block carries text, provenance, geometry, source dimensions and extraction revision together. Render complete structured and readable observations from the same blocks; never prepend/replace flattened Accessibility text while reusing offsets derived from another OCR sequence. Unknown ownership, obscured text and missing roles remain explicit; the visible excerpt is not the whole document.

Extend the existing atomic OCR commit rather than adding another canonical writer. In one transaction, preserve the immutable extraction, update the preferred text/region/FTS projection, publish processing outcome and append its monotonic change-feed event. Retries and later refinements keep the original capture time and do not become new user activity. Audio already retains earlier passes; add conditioning provenance and quality-based preference instead of assuming the highest pass is best.

The consumer atomically records immutable applied-event IDs and durable lexical/vector work before advancing its checkpoint. Enforce monotonic per-observation revision guards so duplicate or older events cannot downgrade a projection. Track lexical and vector coverage/revisions independently. Bootstrap from a recorded change-feed boundary in short keyset pages, then replay intervening changes idempotently. Retain events required by unexpired bootstrap/consumer cursors; compaction must explicitly expire affected cursors and require reconciliation or rebootstrap, never silently skip a feed gap. Close upstream read transactions before decode or model work; long SQLite WAL readers can prevent checkpoint completion. [SQLite WAL concurrency documentation](https://www.sqlite.org/wal.html#concurrency)

Deletion overrides search snapshots and queued/active jobs. Check fencing, policy, expected revision and the writer's durable source-state/tombstone projection in the same transaction that accepts a result, avoiding a local check-then-write race. The cross-store feed does not create a distributed transaction: later canonical changes invalidate derived projections, and exact resolution rechecks canonical state before returning evidence. Propagate tombstones to mirrors, vectors and worker copies. Missing or expired media is a separate availability fact and follows existing text-retention policy. Retained superseded versions remain provenance, never silently current context.

Apply one privacy policy across pixels, Accessibility, OCR/transcripts, derived text/vectors, helper staging and MCP responses. Capture-time AX is limited to proven visible portions of captured surfaces, bounded by time/node count, with secure fields and excluded/redacted content removed before persistence or indexing. Application-wide hidden children are not an acceptable substitute. Where visibility/occlusion cannot be established, omit AX content and expose the coverage gap.

Apply exclusions and credential scrubbing before activity/evidence metadata reaches storage, caches, logs, indexes, helpers or exports. Remove URL userinfo; strip secret-bearing query/fragment values and default to dropping unrecognised query/fragment fields, preserving only adapter-validated non-secret identifiers. Signed/opaque links whose path cannot be safely retained use an opaque local identity and safe label instead. Never retain the raw URL in diagnostic fields. Test encoded/mixed-case credentials and token variants across every sink; this is a tested policy, not a claim to recognise every possible secret. Remove existing logging of excluded window titles and log only opaque suppression reasons. Capture exclusion must not be bypassed by recording app/document names in an independent event stream.

Local processing and disclosure to an agent are separate controls. The existing private SSH helper is an allowed compute destination; it receives only selected policy-permitted inputs. New evidence export defaults to local use. A remote agent, including one reached through a local broker, needs a separately configured client/disclosure grant covering sources, time range and permitted evidence detail. Do not infer that grant from local model use. Revalidate policy at output, minimise returned context, and delimit all captured content as untrusted data. Privacy exclusions and explicit source restrictions are never relaxed for recall.

## 4. Retrieve broadly, assess the pool, expand and answer

| Stage | Required behaviour | Initial budget, with continuation |
|---|---|---|
| Find | Diverse candidates from direct text, activity/episode metadata, bounded typo/OCR variants and local semantic channels, with explicit reliable restrictions applied before truncation. Activity labels supplement retrieval and never become an implicit prerequisite. | 200 compact candidates per page |
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

## 5. Separate engagement from capacity and enforce refinement limits

Maintain two independent decisions. **Engagement** estimates likely engaged, likely unattended or unknown from permitted focus, input recency (not key contents), meeting, playback and speech signals, retaining uncertainty and provenance. **Capacity** decides whether optional work can run from queue/latency, CPU, memory, thermal, disk and execution-budget measurements. Per-app reading/call/fullscreen exceptions may improve the engagement estimate; they never bypass capacity controls or discard captured evidence. An unattended compile may deny capacity while quiet reading may allow a small background budget. Existing meeting detection uses active/visible-app heuristics in places; do not label those as measured microphone use.

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
| App adapters, episodes and corrections | Priority application/pane titles and available session identifiers; rename versus new same-title document; real display identity; focus versus background agent tracks; interruptions with separate span/focus duration; brief-glance expansion; confirmed versus draft mappings, reuse scope, conflict and undo; offline outbox replay, duplicate commands and stale episode revisions. Wrong labels must not suppress direct evidence matches. |
| Health and privacy controls | Green recording with stalled OCR/transcription; activity observed but not durable; retained/reused screenshot distinction; pause/exclude/hide/rename/delete semantics; URL userinfo, encoded tokens and signed links in every sink; excluded window titles in logs; activity-only mode explicitly selected. |
| Retrieval completeness | Eligible result below thousands of stronger out-of-scope matches; sparse and subsequent pages; exhausted versus resumable cursors; equivalent native/FuseIntel constraints; long questions and exact identifiers amid semantic duplicates. |
| Distinct evidence and context | Same-title documents with different amounts/decisions and chronology; ChatGPT with Canvas; named/unsaved/renamed Word documents; same-title URL navigation; overlapping windows; continuity beyond ten observations/30 seconds. |
| Historical isolation and privacy | Process an old frame with unrelated live AX content and configuration enabled; hidden/offscreen/secure/excluded AX nodes; redacted pixels whose raw text appears in AX; denied helper/export clients; local broker forwarding to a remote agent; exclusion changes during a request. |
| Exact navigation | Native/Rewind numeric ID collisions; disconnected requested source; hidden/visible/previously live timeline; target absent from a bounded neighbourhood; stale async selection/cache; no nearest-frame or current-screen substitution; activity-only references without fabricated frames and delayed links with mismatched timing/window generation. |
| Exact media and highlights | Decoder timestamp mismatch/gap/invalid value; exact journal mapping, missing/conflicting map and finalisation races; AX/OCR disagreement; obsolete extraction; display scaling/transforms and partly obscured text. Suppress unsupported overlays. |
| Revisions, repair and deletion | Crash between revision/event publication; consumer crash before checkpoint; lexical ready/vector pending; revise/delete during bootstrap, continuation, inspection and helper work; stale/fenced results; actual repair-error branches preserve text when media is unusable. |
| Capture sensitivity | Real rendered frames at representative display resolutions/scales changing one important digit, negation or draft/sent/error status. Require retention of reviewed consequential changes; sampled-pixel thresholds alone do not establish this. |
| Visual-only and answer quality | Charts/diagrams/image-heavy screens with weak OCR; claim-level support, conflicting versions, unknown ownership, dependent audio context, duplicate captures and honest unsuccessful-search coverage. |
| Scheduling and service isolation | Active call/video without keyboard activity; AC Low Power Mode; thermal/memory/disk pressure; in-operation Whisper abort; slow/non-cancellable unit; helper loss/revocation during inference; ordinary search/status latency during cold model load. |

Use real Vision, SQLite, filesystem/media and UI workflows for acceptance, with independently annotated sources and a reviewing agent given only the rendered text. Keep synthetic SQL as a reproducible query-shape regression, not proof of application correctness. Require **zero wrong-frame displays** in reviewed navigation fixtures; explicit failure is preferable to the wrong screen. Add daily metrics for activity durability/gaps, timeline expansion/grouping, correction confirmation/revocation, distinct privacy actions, stage health, queue coverage, pause/preemption reasons and revision acceptance, without captured text in telemetry.

Run a matched Timely comparison in Phase 0/Phase 1 using a small timestamped action script plus reviewed recordings as adjudication evidence. Include ordinary work, same-title documents, quick tab switches and two-second glances, quiet reading, meetings, unattended compiles/background agents, sleep/wake and an OCR backlog. Compare correct document/conversation attribution, preserved transitions, honest gaps, attention/execution separation and time to locate a requested moment. For Retrace, selecting the result must open the exact supporting screen or explicitly report absent evidence. Timely is a benchmark, not ground truth; record both product versions/settings and their different capture scopes. Do not claim comparison results before running this matched exercise.

Compare the same evidence/workload and settings before and after: retrieval recall and answer/citation precision; attribution and highlight integrity; OCR character/audio word error; capture gaps, fresh queue growth and capture-to-search p50/p95; dictation and ordinary service latency; cold/warm inspection latency, peak memory, energy and disk growth. Require improved quality without attribution/privacy regression and no more than a 10% increase in foreground-processing p95. Baseline capture gaps/queue age are separate gates; an acceptable percentile must not hide dropped captures or accumulating backlog.

Also measure notification-to-durable-activity p50/p95, missing/late transition rate, context adapter coverage, episode correction accuracy, focus-duration error and activity-stream bytes per day. Phase 1 must demonstrate useful metadata search and document-first navigation without OCR completion or another model download; more metadata rows alone do not establish better recall.

Use additive migrations and independent switches for context, hybrid retrieval, inspection and idle refinement. Coordinate Shared contracts before module implementation; use existing module owners, tests first and appropriate code/database/security reviews. Preserve prior application/configuration and compatible data rollback strategy. Update AGENTS when adding files and CHANGELOG for meaningful changes. Record a **Local trial** only after verifying installation, launch, exact navigation and comparison results; a commit or passing suite is not a release.

## Timely references and adaptation limits

These are documented product behaviours, not access to Timely's implementation. The independent durable stream, evidence hierarchy and immutable correction design above are Retrace requirements informed by them.

- Timely describes Memory's app/window titles, URLs, occasional filenames and timing, and explicitly excludes screenshots, keystrokes and audio. Its brief-glance limits should not become Retrace's retention policy. [What is captured by Memory?](https://www.timely.com/help/handbook/privacy/what-is-captured-by-memory/)
- The May 7, 2026 Mac update describes Codex and Claude Chat/Cowork/Code titles and URLs when available; that release listed ChatGPT Desktop support as forthcoming. The May 19 update distinguishes Cursor Agents from the editor and describes URL credential scrubbing. Neither establishes comprehensive agent-execution telemetry or an exhaustive sanitisation algorithm. [Claude and Codex support](https://www.timely.com/product-updates/2026-05-07-memory-app-claude-codex-tracking/), [May 19 Memory update](https://www.timely.com/changelog/2026-05-19-memory-app-update/)
- Classic Timeline documents grouping, interruption continuity, title labels and visual suppression of short activities. Memory for Mac documents idle exemptions/fullscreen differences, recent activity, diagnostic state, pauses, schedules and ignore/rewrite controls. Retrace borrows organisation and explicit controls, not idle-based evidence discard. [Classic Timeline](https://www.timely.com/help/handbook/classic/classic-timeline-view/), [Memory for Mac](https://www.timely.com/help/handbook/autosheet/memory-for-mac/)
- AutoSheet documents learning from submitted days and reviewed assignments/summary edits rather than drafts. Retrace's first version uses explicitly confirmed local annotations/rules; uncorrected AI guesses are not approved examples. [Teaching AutoSheet](https://www.timely.com/help/handbook/autosheet/teaching-autosheet/)

## Review verification at the checkpoint

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
