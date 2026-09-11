# Progressive recall, exact evidence navigation and idle refinement

Saved and amended: 2026-09-11. Review baseline: [`118b790863a43d21ff8997b0bdd43bd5fb8bbf45`](https://github.com/stuartsc/retrace/commit/118b790863a43d21ff8997b0bdd43bd5fb8bbf45), `feature/push-to-dictate`.

**Status: proposed; implementation remains on hold for Stuart's review.** This revision incorporates the review of the September checkpoint. Saving or committing the plan does not implement it, install a build or establish a release. Existing implemented fixes and local trials remain documented in [CHANGELOG.md](../CHANGELOG.md).

## Objective and delivery order

Find the right historical evidence, preserve what it actually says, explain its limitations, and reopen precisely the recorded screen supporting an answer. A text-only agent should understand visible application/document/conversation context and supported changes. Progressive retrieval, immutable capture context and local refinement remain the architecture; exact resolution and timeline navigation belong in the first functional deliverable.

| Phase | Deliverable | Required exit condition |
|---|---|---|
| 0. Baseline and reproducible failures | Versioned real questions with independently annotated expected evidence, retrieval/navigation/privacy fixtures and the SQL shortlist reproduction below. Record the same workload and settings for comparisons. | Correctness, coverage and performance are measurable against fixed evidence; synthetic SQL is distinguished from Mac acceptance. |
| 1. Correct recall and exact navigation | Repair premature truncation and evidence-dropping deduplication, isolate historical extraction from live Accessibility, stop media-repair errors deleting retained text, introduce minimal stable evidence/revision identity, and open exact evidence including journal-backed previews. | Every reviewed citation opens the requested retained screen or an explicit unavailable/integrity state; **zero wrong-frame displays**. No visual model required. |
| 2. Structured observations and hybrid retrieval | Capture-time context, unified text/geometry blocks, immutable revisions, transactional change feed, bounded bootstrap/catch-up, local semantic retrieval and contextual expansion. | Recall improves without attribution, privacy or highlighting regression. |
| 3. Coordinated on-demand inspection | Shared admission/cancellation, exact-frame inspection outside the request-serving process, bounded helper jobs and a benchmark-gated local visual model. | Difficult questions improve without compromising capture, dictation or ordinary service responsiveness. |
| 4. Measured historical refinement | Prioritised weak-evidence work, durable progress, retained alternatives and quality-based preferred versions. | Paired evaluation shows more correct evidence or lower extraction error, without unsupported claims or foreground regressions. |

Retrace owns canonical screen/audio evidence and native refinements. FuseIntel owns derived variants, retrieval intelligence and cross-source interpretation, using its existing designated writer. It does not write into Retrace or imported Rewind databases. The two repositories must share contract fixtures so their entry points agree on identity, constraints, coverage and availability.

## 1. Stop incorrect recall and establish an evidence address

### Correctness prerequisites

- Apply reliable constraints before candidate truncation in `DataAdapter.searchRelevant`; fix cursor exhaustion so a sparse eligible result is not mistaken for the end of available evidence. Raising the global limit is not a correctness fix. Align relevant, chronological, fallback and FuseIntel search semantics with shared conformance fixtures; retain the filter-before-final-limit foundation already present in `FTSManager`.
- Replace title/highlight-position deduplication in both relevant and chronological paths with grouping that retains every source-qualified observation and its chronology. Same-title documents with changed amounts, negations or decisions remain distinct evidence. Page cursors advance over examined source records, not only displayed groups.
- Make queued/historical extraction structurally unable to query live Accessibility, even if a configuration enables Accessibility elsewhere. Until saved capture-time snapshots exist, queued work uses retained pixels and saved metadata only. The normal App configuration currently disables live Accessibility merging; the unsafe path remains configurable, so this is a prevention requirement rather than a claim of observed current contamination.
- Replace qualifying OCR repair-error `deleteFrame` calls with media-unavailable outcomes that preserve text and provenance. Cover the actual empty-video/out-of-range branches; do not imply every missing-file error currently deletes evidence. Only explicit deletion or established retention policy may remove retained evidence.
- Bind searchable text, block provenance and geometry to the same extraction revision. Derive flattened text and offsets from that structure. Phase 1 must suppress unsupported legacy highlights; it must not wait for Phase 2 to stop displaying false precision.

### Shared identity and resolution

Introduce `EvidenceRef` in Shared and propagate it through database lookup, citations, UI selection, async completion guards and caches:

```text
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

Keep capture time, display identity, saved pixel dimensions, media identity/availability and inspection provenance alongside the address. `observationID` is independent of `frameID`: new context can create a new observation while reusing unchanged pixels. Establish minimal stable observation/extraction snapshots in Phase 1; Phase 2 extends their capture-time structure and change feed. Give legacy records durable identities through bounded materialisation and a persistent store registry; mark legacy context as uncertain and do not modify imported databases.

Add one asynchronous `EvidenceResolver` contract for agent inspection, citation opening and historical preview. It resolves only the requested store/source, validates observation and revision, checks deletion/privacy policy, and proves media/frame identity. Missing Rewind connectivity must never fall back to native storage using the same integer ID.

Exactness is unconditional for evidence resolution, regardless of timeline visibility. Validate the decoder's actual presentation timestamp against the requested encoded sample and its index/mapping; reject invalid timestamps and neighbouring samples. Reuse strict decoding and fresh-generator retry where appropriate, but do not route evidence through the currently weaker `ImageExtractor` path. Explicitly tolerant ordinary playback remains separate.

Support newest-frame previews from the recording journal immediately in Phase 1. Require a verified frame-to-record mapping and consistent timestamp/dimensions/display identity. A missing mapping must not silently become index-only lookup; return finalising/unavailable until identity can be proven. Handle journal-to-finalised-video transitions and late async completions without changing the requested evidence.

Return typed states: resolved; not permitted; source disconnected; recording missing; frame finalising; evidence deleted; requested extraction superseded/unavailable; or integrity/exactness failure. Check disclosure authorisation before returning availability details: a denied client must not learn whether restricted evidence exists or was deleted. A retained superseded revision can still resolve as that revision, with its status exposed. An unavailable old revision must not borrow newer text or highlights.

### Citation-driven historical navigation

Add an evidence deep-link route carrying `EvidenceRef` and an explicit historical-evidence navigation mode. Existing search/timestamp routes retain their ordinary meanings. **View recorded screen** must resolve the target directly, select its exact source-qualified frame, then load surrounding history; it must not clear relevant context, snap to newest, initiate a live screenshot for the citation, or substitute the nearest timestamp when a bounded neighbourhood lacks the target. Background recording continues normally.

Key image caches by source-qualified media/frame identity and overlay/selection caches by observation and extraction revision as well. Apply highlights only when block provenance, revision, saved dimensions, clipping and coordinate transforms match the resolved image. Otherwise show the recorded screen with an explicit unsupported-highlight state.

Keep **Open current document/website** as a separate action. Preserve the foreground-app timeline while allowing a grouped result to expand its retained observations and candidate document/conversation episodes. Linked audio/screen evidence remains contextual: simultaneity alone does not establish speaker identity or what a statement refers to.

## 2. Capture context, preserve revisions and enforce privacy

Capture bounded window/Accessibility metadata alongside the image, with acquisition timing and identity checks. Context-only changes must survive image deduplication; small consequential visual changes must be tested separately. A title or URL learned later cannot rewrite an earlier canonical observation or backfill a closed segment as an asserted past fact. Later-derived context is a separately attributed interpretation.

Group visible text by its owning surface and preserve supported headings, chat turns, table cells/headers, code, statuses and reading order. A block carries text, provenance, geometry, source dimensions and extraction revision together. Render complete structured and readable observations from the same blocks; never prepend/replace flattened Accessibility text while reusing offsets derived from another OCR sequence. Unknown ownership, obscured text and missing roles remain explicit; the visible excerpt is not the whole document.

Extend the existing atomic OCR commit rather than adding another canonical writer. In one transaction, preserve the immutable extraction, update the preferred text/region/FTS projection, publish processing outcome and append its monotonic change-feed event. Retries and later refinements keep the original capture time and do not become new user activity. Audio already retains earlier passes; add conditioning provenance and quality-based preference instead of assuming the highest pass is best.

The consumer atomically records immutable applied-event IDs and durable lexical/vector work before advancing its checkpoint. Enforce monotonic per-observation revision guards so duplicate or older events cannot downgrade a projection. Track lexical and vector coverage/revisions independently. Bootstrap from a recorded change-feed boundary in short keyset pages, then replay intervening changes idempotently. Retain events required by unexpired bootstrap/consumer cursors; compaction must explicitly expire affected cursors and require reconciliation or rebootstrap, never silently skip a feed gap. Close upstream read transactions before decode or model work; long SQLite WAL readers can prevent checkpoint completion. [SQLite WAL concurrency documentation](https://www.sqlite.org/wal.html#concurrency)

Deletion overrides search snapshots and queued/active jobs. Check fencing, policy, expected revision and the writer's durable source-state/tombstone projection in the same transaction that accepts a result, avoiding a local check-then-write race. The cross-store feed does not create a distributed transaction: later canonical changes invalidate derived projections, and exact resolution rechecks canonical state before returning evidence. Propagate tombstones to mirrors, vectors and worker copies. Missing or expired media is a separate availability fact and follows existing text-retention policy. Retained superseded versions remain provenance, never silently current context.

Apply one privacy policy across pixels, Accessibility, OCR/transcripts, derived text/vectors, helper staging and MCP responses. Capture-time AX is limited to proven visible portions of captured surfaces, bounded by time/node count, with secure fields and excluded/redacted content removed before persistence or indexing. Application-wide hidden children are not an acceptable substitute. Where visibility/occlusion cannot be established, omit AX content and expose the coverage gap.

Local processing and disclosure to an agent are separate controls. The existing private SSH helper is an allowed compute destination; it receives only selected policy-permitted inputs. New evidence export defaults to local use. A remote agent, including one reached through a local broker, needs a separately configured client/disclosure grant covering sources, time range and permitted evidence detail. Do not infer that grant from local model use. Revalidate policy at output, minimise returned context, and delimit all captured content as untrusted data. Privacy exclusions and explicit source restrictions are never relaxed for recall.

## 3. Retrieve broadly, assess the pool, expand and answer

| Stage | Required behaviour | Initial budget, with continuation |
|---|---|---|
| Find | Diverse candidates from lexical, metadata, bounded typo/OCR variants and local semantic channels, with explicit reliable restrictions applied before truncation. | 200 compact candidates per page |
| Score | Assess useful text windows from the entire candidate page against the complete question before choosing the expansion set. Combine channels with explicit exact-match representation. | All candidates on the page; bounded model windows |
| Expand | Select approximately 20 after scoring; retrieve full blocks/context, retained variants, change evidence and neighbouring observations. | 20 candidates; 32,000 returned tokens |
| Inspect | Use the shared exact resolver, accurate OCR and optional local visual inference only for unresolved shortlisted evidence. | Three frames per batch; 30-second request deadline |

Reserve five of the initial twenty expansion positions for the strongest distinct exact names, numbers, phrases or identifiers when available; fill unused positions from the combined ranking. This is a diversity default to benchmark, not a confidence guarantee. Keep explicit matches discoverable through continuation even when a page is crowded. Preserve the complete original question; split long model inputs into meaningful windows instead of silently truncating the inquiry.

Each interpreted constraint carries `explicitRestriction`, `inferredHint` or `unresolvedAmbiguity`, its origin and whether a hint was relaxed. "Only Tuesday" is hard; "I think Tuesday" is a visible ranking hint. Existing foreground-app filters retain their meaning. Content-source requests such as "the Word document I saw" search visible-surface ownership and retain uncertain legacy candidates for later resolution; they must not silently become foreground-app restrictions. Never relax privacy or explicit source boundaries.

The initial neighbourhood is ten observations from the same surface within 30 seconds, not an episode definition. Continue beyond that budget by document/surface continuity and expose uncertainty when continuity is inferred. Group repeats without removing references; duplicate captures do not provide independent corroboration.

Include weak-text and visual-only screens in Find evaluation. Start with available metadata, nearby text and selective derived descriptions of weak-text screens. Inspect cannot recover a frame that Find never considers. Add a dedicated image-retrieval index only if the corpus shows these routes are insufficient; do not run an 8B model over every historical image by default.

Expose dedicated screen-search, expansion and inspection tools through the existing FuseIntel MCP boundary. Interactive inspection returns transient results; persistent idle work is a separate operation accepted only by its owner. Dispatch expensive work to a bounded worker outside the request-serving process, so model loading/decode cannot monopolise the existing single-worker backend. Search/status requests remain responsive during inspection.

Return actual excerpts, source-qualified references, revisions, match reasons, constraint handling, per-channel coverage, unavailable sources and remaining continuations. Target initial warm indexed results within two seconds. Return partial per-frame inspection outcomes at the 30-second deadline; cancel remaining request work and retain an expiring continuation, not an implicitly authorised persistent job. Search continuations preserve a ranking/index snapshot while still enforcing current deletion and privacy state.

Answers use a claim-to-evidence contract: each factual claim cites supporting observations/blocks and is labelled observed content, supported inference or unresolved interpretation. Keep conflicting observations available and show material disagreement. A reranker score is relevance, not truth probability; a larger model or higher pass is not verification. Contextual audio must retain neighbour IDs/revisions and prompt/model provenance and must not count as independent confirmation of those neighbours. An unsuccessful answer states what indexed evidence was searched, coverage, unavailable sources, unresolved constraints and remaining work; it must not claim the event never happened.

### Provisional local models

Benchmark `sentence-transformers/all-MiniLM-L6-v2` and the previously observed `BAAI/bge-reranker-v2-m3` as the initial baseline. Verify and pin their installed model/tokenizer revisions before the benchmark. MiniLM defaults to truncation beyond 256 word pieces: include metadata prefixes and special tokens inside the budget, start with at most 224 content/header word pieces and 32 overlap, chunk at meaningful boundaries, and retain complete original blocks for expansion. Use a separate 384-dimensional local screen index; never mix it with cloud-provider vectors. Verify BGE's runtime limits independently rather than assuming MiniLM's limit applies. [MiniLM model documentation](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)

Evaluate Qwen3-VL 8B Instruct Q4 on the helper after Phase 1 acceptance. The listed Q4_K_M artifact is approximately 6.1 GB and requires compatible Ollama (0.12.7 or later); this establishes neither working-memory use nor speed. Pin its digest, cap inference context/output, and compare native OCR alone against OCR plus visual inference on dense text, tables, overlapping windows and weak-text imagery, measuring cold load and warm runs. Enable only if measured benefit fits the limits; otherwise retain OCR-only inspection and explicit unresolved visual coverage. [Ollama model specification](https://ollama.com/library/qwen3-vl%3A8b-instruct)

The two private Macs remain the processing boundary, with no cloud-model fallback. Additional model files are capped at **20 GB aggregate across both machines**. Helper-first installation remains the candidate placement, not permission to skip validation. Earlier read-only checks found the helper reachable but its Ollama service unavailable; recheck runtime and capacity during implementation rather than treating that snapshot as current readiness.

## 4. Enforce resource limits and safe refinement

Use one resource coordinator across native OCR/audio maintenance, embedding and derived visual work, with per-host admission and a shared heavy-work permit. Priorities are capture/dictation/fresh OCR and transcription, requested inspection, then unattended history. User inactivity gates unattended work, not a requested inspection; all optional work respects foreground/resource limits.

Initial unattended admission requires five minutes without input on the executing Mac, 60 seconds of quiet incoming speech/accepted visual changes and stable queue health, AC power, normal memory pressure, nominal/fair thermal state and normalised CPU utilisation below 50%. Microphone enabled is not speech activity; watching a meeting/video is not necessarily spare capacity. Reserve projected peak optional-worker memory plus 4 GiB headroom, use an initial 12 GiB optional-worker ceiling per host, and retain at least 20 GiB free on the capture/staging volumes after reservations. Phase 0 measurements may lower admission limits; increasing them requires recorded comparison evidence. Disk latency and fresh queue age can deny admission even with low CPU use.

Allow one heavy optional unit per host. Under Low Power Mode, admit at most **10 seconds of elapsed worker execution in a rolling 60 seconds**, restricted to bounded OCR/audio/text work; otherwise start at 30 seconds and permit visual inference. Charge from admission until confirmed stop, including input reads/decoding, cold model loading, inference, output handling and cancellation drain. Waiting in an unadmitted queue is not charged. Reserve shutdown allowance inside the unit's budget; record overruns and block further admission until the rolling budget recovers. Leave macOS power settings unchanged.

Cancellation must reach the operation. Wire Whisper's abort callback to a thread-safe per-operation deadline/cancellation token before claiming enforcement. Check between decode/inference stages; use small checkpoints or job-owned worker processes for optional operations without reliable in-process cancellation. Admit only units demonstrated to fit the remaining budget including termination. Split oversized audio work or defer it to the helper; do not repeatedly restart an oversized unit. Cancelled work is resumable and does not consume a quality-failure attempt. Record actual yield latency and pause further admission after failed preemption.

Give three unattended slots to unresolved inquiries or weak evidence, then one to the oldest eligible work. Persist source identity/revision, operation/model version, job fingerprint, attempts, lease, checkpoint and typed outcome. Quality-based preference compares valid source coverage, language and unsupported-content flags against retained alternatives; additional text alone is not improvement.

Reuse the private SSH dispatcher with one helper worker and job-scoped inputs/results. Renew leases every five seconds through a control loop independent of blocking inference. Cancel the running operation and stop admission immediately on explicit revocation or lease expiry; also cancel after 15 seconds without renewal. Every job has a separate execution deadline and fencing token; the accepting writer rechecks authorisation, source revision, deletion and fencing before idempotent acceptance. Heartbeat responsiveness does not extend a revoked job. Escalation may terminate only that job's owned process, never broad remote `pkill` targets.

Keep computation off the request-serving backend; the helper gets only selected media/context and cannot write central databases. Use checksummed incremental results with acknowledgements. A remote transfer failure is not proof that local source media is missing. If the helper is unavailable, return deferred/unavailable status and continue only the main Mac's existing bounded allowance.

Cap newly staged helper media at **5 GiB**, separately from the model allowance; reserve capacity before transfers/downloads. Remove acknowledged media, expire abandoned new-job media after 24 hours, retain compact bounded receipts and reuse unchanged content/embeddings. Reconcile the pre-existing approximately 4.1 GB results file before any cleanup. Preserve original evidence and avoid permanent duplicate screenshots.

## 5. Mandatory acceptance and rollout

| Area | Required scenarios |
|---|---|
| Retrieval completeness | Eligible result below thousands of stronger out-of-scope matches; sparse and subsequent pages; exhausted versus resumable cursors; equivalent native/FuseIntel constraints; long questions and exact identifiers amid semantic duplicates. |
| Distinct evidence and context | Same-title documents with different amounts/decisions and chronology; ChatGPT with Canvas; named/unsaved/renamed Word documents; same-title URL navigation; overlapping windows; continuity beyond ten observations/30 seconds. |
| Historical isolation and privacy | Process an old frame with unrelated live AX content and configuration enabled; hidden/offscreen/secure/excluded AX nodes; redacted pixels whose raw text appears in AX; denied helper/export clients; local broker forwarding to a remote agent; exclusion changes during a request. |
| Exact navigation | Native/Rewind numeric ID collisions; disconnected requested source; hidden/visible/previously live timeline; target absent from a bounded neighbourhood; stale async selection/cache; no nearest-frame or current-screen substitution. |
| Exact media and highlights | Decoder timestamp mismatch/gap/invalid value; exact journal mapping, missing/conflicting map and finalisation races; AX/OCR disagreement; obsolete extraction; display scaling/transforms and partly obscured text. Suppress unsupported overlays. |
| Revisions, repair and deletion | Crash between revision/event publication; consumer crash before checkpoint; lexical ready/vector pending; revise/delete during bootstrap, continuation, inspection and helper work; stale/fenced results; actual repair-error branches preserve text when media is unusable. |
| Capture sensitivity | Real rendered frames at representative display resolutions/scales changing one important digit, negation or draft/sent/error status. Require retention of reviewed consequential changes; sampled-pixel thresholds alone do not establish this. |
| Visual-only and answer quality | Charts/diagrams/image-heavy screens with weak OCR; claim-level support, conflicting versions, unknown ownership, dependent audio context, duplicate captures and honest unsuccessful-search coverage. |
| Scheduling and service isolation | Active call/video without keyboard activity; AC Low Power Mode; thermal/memory/disk pressure; in-operation Whisper abort; slow/non-cancellable unit; helper loss/revocation during inference; ordinary search/status latency during cold model load. |

Use real Vision, SQLite, filesystem/media and UI workflows for acceptance, with independently annotated sources and a reviewing agent given only the rendered text. Keep synthetic SQL as a reproducible query-shape regression, not proof of application correctness. Require **zero wrong-frame displays** in reviewed navigation fixtures; explicit failure is preferable to the wrong screen. Add daily metrics for new actions/outcomes, queue coverage, pause/preemption reasons and revision acceptance, without captured text in telemetry.

Compare the same evidence/workload and settings before and after: retrieval recall and answer/citation precision; attribution and highlight integrity; OCR character/audio word error; capture gaps, fresh queue growth and capture-to-search p50/p95; dictation and ordinary service latency; cold/warm inspection latency, peak memory, energy and disk growth. Require improved quality without attribution/privacy regression and no more than a 10% increase in foreground-processing p95. Baseline capture gaps/queue age are separate gates; an acceptable percentile must not hide dropped captures or accumulating backlog.

Use additive migrations and independent switches for context, hybrid retrieval, inspection and idle refinement. Coordinate Shared contracts before module implementation; use existing module owners, tests first and appropriate code/database/security reviews. Preserve prior application/configuration and compatible data rollback strategy. Update AGENTS when adding files and CHANGELOG for meaningful changes. Record a **Local trial** only after verifying installation, launch, exact navigation and comparison results; a commit or passing suite is not a release.

## Review verification at the checkpoint

The plan amendments were checked against `118b790` source; this was not a fresh audit of the running Macs or the separate FuseIntel/SSH implementation. No Mac acceptance suite or model inference was run for this documentation amendment.

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
