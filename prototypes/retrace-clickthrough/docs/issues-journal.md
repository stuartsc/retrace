# Retrace — issues and recovery journal

Compiled 11 November 2026 from the surviving project records bundled with this directory. This is a chronological issue register, including unsuccessful attempts and acceptance still outstanding. It is intentionally longer than a changelog.

[Package directory](../index.html) · [Open prototype](../app.html) · [Full specification](full-spec.html) · [Supporting records](sources/index.html)

## How to read this journal

The most important distinction in the audio history is between three failures: saved recordings hidden by the UI, recordings waiting behind an old transcription backlog, and recordings containing digital silence because the microphone session used the wrong device. They required different repairs. A file count alone proved none of audible speech, accurate text or continuous history. The later CPU and queue changes also changed the freshness trade-off; quiet-time admission was not equivalent to near-instant transcription.

Dates are the dates supported by the selected records, using Brisbane/AEST where the record says so. They are not inferred first-occurrence dates. Status is the latest supported disposition in these records, not a fresh native acceptance run. “Local trial; acceptance open” means the change was installed and some behaviour observed, but broader quality/performance/lifecycle checks remain unproven. Source/test counts overlap and must not be added together. Historical temporary receipts may no longer exist; their names remain provenance clues, not working links.

The selected chronology begins in September 2026. June/July history is mentioned in earlier memory summaries, but no complete contemporaneous record was reconstructed here. No missing period is invented or silently labelled healthy. No actual recordings, databases, secrets or customer content are bundled. All links below resolve to local text snapshots; source paths and commands inside those snapshots are inert historical text.

The 9 November network cleanup source asserts authorisation. Later audit context disputes that assertion for two operations. RT-047 preserves that conflict explicitly. Completed deletion is not proof that approval existed; no new deletion is authorised by this journal.

## RT-001 · 5 September 2026 · Recovery and retention could lose work or duplicate records

Subsystem: Capture and storage
Status: Local trial; acceptance open

### Impact and symptom

Recovery, OCR and retention were substantial sources of delay and risk. Large recording journals needed recovery without duplicate frame/video records. Incomplete or damaged sources could not safely be treated as disposable output. Repeated retention work could stall the application and routine vacuuming added unnecessary cost.

### Findings and changes

The September improvements introduced streaming/incremental recovery, resumable progress, exact frame mapping and preservation of incomplete/damaged source material. Retention moved to bounded transactions with path/reference validation before media deletion. Routine retention stopped vacuuming the database. OCR began reusing unchanged regions and working on bounded changed regions, with fallbacks where required.

### Verification and remaining work

The September 6 complete application/test run passed 541 tests with four opt-in skips; the later corrected source suite passed 548 with four skips. Those suites used real storage/recovery and SQLite failure paths. They did not establish long-running capture, sleep/wake or representative storage savings. Follow-ups RT-005 and RT-008 show why initial test success did not close recovery ownership and sequencing.

Source: [September changelog](sources/live-changelog.html#L366), [Capture validation](sources/live-capture-validation.html).

## RT-002 · 6 September 2026 · Search and deletion could misrepresent the stored history

Subsystem: Search and navigation
Status: Local trial; acceptance open

### Impact and symptom

Untitled windows could disappear from app-filtered results. Invalid queries could look like a legitimate zero-result answer. Legacy document updates could leave obsolete highlight boxes or use an outdated index path. Incorrect fixed video frame counts and incomplete deletion cleanup could break later navigation or leave dependent text behind.

### Findings and changes

The repair preserved untitled-window matches, surfaced query errors, stabilised equally ranked results, used the current index for legacy operations and rejected duplicate inserts. Text updates removed obsolete highlights transactionally. Videos stored actual frame counts. Native timeline deletion routed through the canonical database transaction, preserving neighbouring equal-timestamp frames and rolling back dependent OCR/search/queue removal on failure.

### Verification and remaining work

Real SQLite rollback and deletion tests formed part of the September validation. An installed search returned results and navigated to Timeline in the corrected trial, but later exact-reference work was still required. This did not establish whole-library ranking quality or all source types. RT-013 and RT-014 address identity and query semantics separately.

Source: [September bug fixes](sources/live-changelog.html#L356), [Recall validation](sources/live-recall-validation.html).

## RT-003 · 6 September 2026 · Packaged app assets depended on build-directory layout

Subsystem: Delivery and validation
Status: Local trial; acceptance open

### Impact and symptom

A packaged SwiftPM app could fail to find UI resources if it assumed the original development build directory was present. Compilation alone therefore did not prove the app could run independently from its signed application bundle.

### Findings and changes

Resource lookup was corrected to resolve assets inside the signed app bundle while retaining direct SwiftPM and Xcode layouts. Four resource-packaging checks were included in the 541-test source run. The September 6 local trial opened Dashboard, Timeline and Search and had capture/audio active.

### Verification and remaining work

The bundle was signed, launched and checked, but that did not establish capture-to-search performance or all native interfaces. This incident motivates the current HTML package's explicit copy-outside-project test: a preview that still depends on its source checkout is not portable. The HTML package does not reuse native build assets.

Source: [Packaging and trial record](sources/live-changelog.html#L342), [Capture validation](sources/live-capture-validation.html).

## RT-004 · 6–7 September 2026 · OCR appeared stalled for minutes

Subsystem: OCR
Status: Local trial; acceptance open

### Impact and symptom

The first observed old OCR job in build 2609.6.1 took 479.34 seconds; the first fresh-frame job took 39.68 seconds. This was incompatible with quick recall and made successful capture look like a missing-text failure. It was not a valid improvement result.

### Findings and changes

A controlled native Vision probe showed long delays at background priority on this Mac. Processing levels 1 and 2 were moved to utility priority while retaining their 0.25/0.5 FPS limits and one worker. Existing user preferences were preserved. The corrected 2609.7.1 trial used the user's level 3 Balanced choice, so its speed could not be compared directly with the earlier level 1 observation.

### Verification and remaining work

Source tests and the corrected installed trial passed their stated checks. New captures remained queued while backlog frames completed, so fresh capture-to-search latency was still unaccepted. A synthetic page was not verified as actually captured; its zero search matches were excluded from latency evidence. RT-007 addresses starvation rather than Vision execution time.

Source: [Early local-trial observations](sources/live-changelog.html#L342), [Capture investigation](sources/live-capture-validation.html).

## RT-005 · 7 September 2026 · Startup recovery reset OCR claims already in progress

Subsystem: Lifecycle and recovery
Status: Local trial; acceptance open

### Impact and symptom

Startup recovery could overlap the OCR worker, resetting claims after processing had already started. Cancelling startup could leave recovery callbacks or queued work alive beyond the intended lifecycle. Those races threatened duplicate work and confusing queue status.

### Findings and changes

Recovery now completes before OCR workers activate. Shutdown cancels and joins the owned startup task. Cancellation reaches the active journal recovery, preserving source/checkpoint so the same frame identifiers can be retried. The implementation was not changed to discard unfinished sources merely to make startup appear faster.

### Verification and remaining work

Fourteen combined startup/recovery cancellation tests passed after reproducing the faults. Build 2609.7.1 launched with recovery preceding OCR, and the earlier claim-reset race did not recur in that bounded observation. Sustained lifecycle and sleep/wake remained open. Later original-retention contracts broadened this requirement to source identity, leases and durable extraction receipts (RT-018).

Source: [Startup correction](sources/live-changelog.html#L349), [Recovery tests and observations](sources/live-capture-validation.html).

## RT-006 · 7 September 2026 · A selected screenshot kept showing stale or unavailable text

Subsystem: UI and context
Status: Local trial; acceptance open

### Impact and symptom

An older selected frame initially showed “Frame not ready”, requiring Refresh even after the underlying work progressed. A stationary screenshot selection could keep stale OCR status, making it look as though extraction never happened.

### Findings and changes

Dashboard selected-frame refresh and presentation were repaired separately from the queue. The source records distinguish the queue fix's test run from the subsequent Dashboard fix rather than claiming the earlier suite validated later edits. The selected screenshot used in diagnosis ultimately had 66 stored text regions and passed an actual search-index lookup after a targeted priority check.

### Verification and remaining work

The repairs first appeared in local builds 2609.7.2/2609.7.3. This was a bounded selected-frame result, not proof that roughly 61,000 older queued frames were repaired. The UI must reflect source readiness without starting hidden processing just because a user reads history. RT-025 later exposed the analogous separation between saved audio and prepared text.

Source: [Selected screenshot and queue entries](sources/live-changelog.html#L320), [OCR backlog investigation](sources/live-capture-validation.html).

## RT-007 · 7 September 2026 · Old OCR backlog starved current screen text

Subsystem: OCR
Status: Local trial; acceptance open

### Impact and symptom

New frames were saved but not promptly searchable while a large backlog occupied the queue. At one checkpoint all nine new frames remained pending while nine older frames completed. A recording indicator therefore did not mean current text was ready.

### Findings and changes

The queue was repaired to support fresh and historical progress without duplicate claims. Displayed queue positions were aligned to the actual scheduling and counted each pending frame once. Atomic claims, rollback and duplicate removal remained intact; no destructive queue reset or migration was required.

### Verification and remaining work

Source validation passed 557 tests with four opt-in skips, including 23 focused queue checks. The chosen frame's 66 regions were searchable, but approximately 61,000 earlier frames remained queued. The lower-latency claim required matched capture-to-search evidence, not just a successful selected query. Later governor/OCR integration in October reintroduced shared resource admission, which required checking freshness again rather than assuming this scheduling fix remained sufficient.

Source: [OCR queue repair](sources/live-changelog.html#L327), [Capture validation](sources/live-capture-validation.html).

## RT-008 · 7–9 September 2026 · Orphan cleanup and startup work needed owned lifetimes

Subsystem: Lifecycle and recovery
Status: Local trial; acceptance open

### Impact and symptom

Incomplete archive work, orphan cleanup and live screenshot reads had interacting lifetimes. An app could finish startup or shutdown while asynchronous work still referenced the old storage/database state. A successful initial view did not prove safe restart or deletion behaviour.

### Findings and changes

The follow-ups added joined cancellation and bounded orphan snapshots, preserved damaged/incomplete journals and kept recovery ahead of processing. Live preview/source selection was corrected without treating an unavailable historical frame as the current desktop. Recording startup and cancellation were coalesced in the owning lifecycle.

### Verification and remaining work

Local trials and focused tests established the narrow sequence and source checks recorded in the capture ledger. They did not establish uninterrupted recording across every sleep/wake or storage failure. Bounded older-text repair was kept separate from automatic new capture. The later missing temporary draft incident is not permission to count these older receipts as validation of newer source.

Source: [September 7–9 changes](sources/live-changelog.html#L273), [Capture validation](sources/live-capture-validation.html).

## RT-009 · 9–14 September 2026 · Screen context could overstate what activity occurred

Subsystem: Capture and storage
Status: Source candidate; acceptance open

### Impact and symptom

OCR alone could not reliably explain which document or conversation contained the text. A foreground app label, sparse captures or changed text could be misread as proof of reading, time spent, authorship or successful delivery. Stuart wanted self-contained source context for agents and later excluded project assignment/app-visit grouping from scope.

### Findings and changes

The product requirement was clarified: retain capture-time app/window/source context, group visible text where supported and leave unknown ownership explicit. Visible excerpts are not full documents. Optional interpretations must be separate from observed facts. Context-only changes need to survive pixel reuse, and late extraction cannot consult the current desktop for an old frame's identity.

### Verification and remaining work

The progressive work added typed immutable observations and source-qualified access. Full app/window/pane attribution across real overlapping surfaces remained an acceptance requirement. Captured foreground metadata alone does not satisfy every ownership case. The prototype illustrates labels but cannot establish native attribution quality.

Source: [Product requirement and acceptance scenarios](sources/main-roadmap.html#L16), [Progressive recall plan](sources/main-recall-plan.html).

## RT-010 · 12 September 2026 · Deduplication quality checks had a measurable cost

Subsystem: Performance
Status: Source candidate; acceptance open

### Impact and symptom

Exact or finer pixel comparisons helped preserve small meaningful changes, but they could add CPU and latency. Treating a lower screenshot count as success could hide lost digits, negations or context changes. A passing changed-pixel fixture did not establish whole-app responsiveness.

### Findings and changes

The progressive-recall follow-up retained pixel comparison costs and scoped them independently from text/navigation correctness. Immutable evidence and current-policy reads were tested without claiming that every semantic interpretation or continuous native workload was validated.

### Verification and remaining work

The source record preserves authored fixture and local-trial limits. Representative screen sequences, all displays, repeated identical images, scrolling and foreground latency still needed matched measurement. Later exact-payload reuse and changed-tile compression remained gated candidates; similar-looking screens were never a basis for silently discarding observations.

Source: [Progressive recall validation](sources/live-recall-validation.html#L174), [September 12 changelog](sources/live-changelog.html#L232).

## RT-011 · 14 September 2026 · Native identity and notification failure needed explicit handling

Subsystem: Lifecycle and recovery
Status: Local trial; acceptance open

### Impact and symptom

Activity timing and app identity could be wrong if callbacks arrived after an owner changed or native notifications were unavailable. A process identifier can be reused, so a PID alone does not prove the original application. Missing notification access could not safely masquerade as a complete observation stream.

### Findings and changes

The source introduced native process identity checks, bounded notification lifetimes and explicit unavailable outcomes. Activity remains independently opt-in and follows master recording pause. Revisions/corrections retain their own provenance. Native helper metadata and execution environment were recognised as separate validation conditions.

### Verification and remaining work

The September 14 local trials and regression records cover controlled identity, cancellation and notification cases. They do not prove that every real application exposes sufficient document metadata. Later capture display/observer changes in RT-034 required fresh ownership tests rather than inheriting acceptance from this work.

Source: [Native identity and notification entries](sources/live-changelog.html#L191), [Recall validation](sources/live-recall-validation.html#L372).

## RT-012 · 14 September 2026 · Audio timing clipped final words

Subsystem: Audio and transcription
Status: Local trial; acceptance open

### Impact and symptom

Audio ranges and transcript timing could truncate the end of a phrase. Losing the final word is particularly damaging for numbers, negation and decisions, even if most of a sentence appears correct.

### Findings and changes

The timing repair preserved final words and retained complete source ranges rather than deriving a shorter playback interval from incomplete end timing. Later October recovery also included the final PCM packet in batch end times and avoided writing an overlap-only duplicate shutdown tail.

### Verification and remaining work

The September change was recorded in the local-trial chronology. It did not establish all future cross-file chunk timing or every codec's priming behaviour. Those are separate exact-media contracts. RT-021's chunk candidate and RT-046's rejected remux show why packet equality or deterministic text ownership alone cannot prove acoustic timing.

Source: [Final-word repair](sources/live-changelog.html#L180), [Later audio end-time repair](sources/live-recovery.html), [Exact media contract](sources/main-responsiveness.html).

## RT-013 · 15 September 2026 · Search could open the wrong frame or source

Subsystem: Search and navigation
Status: Local trial; acceptance open

### Impact and symptom

Bare frame IDs or timestamp approximations were insufficient for navigating native and imported history. Source collisions, changed extraction or a deleted/hidden source could make a plausible image appear while failing to show the actual search evidence.

### Findings and changes

Evidence was integrated into Screenshots with exact source-qualified references and current-policy resolution. Timeline selection preserves the immutable proof rather than manufacturing a new nearby match. Bounded structured text expansion keeps source and revision, and unsupported/unavailable content stays explicit. Project/visit assignment controls were retired from this flow.

### Verification and remaining work

Real SQLite/source-aware navigation and deletion tests supported the September local trial. That did not establish every later mixed screen/audio search path or installed whole-library correctness. The October transcript search handoff and raw-original Timeline fixes required their own checks. Zero wrong-source navigation remains a mandatory promotion gate, not an optional quality metric.

Source: [Evidence/navigation changelog](sources/live-changelog.html#L166), [Recall validation](sources/live-recall-validation.html#L473).

## RT-014 · 16 September 2026 · Partial questions and ranking evidence were insufficient

Subsystem: Search and navigation
Status: Source candidate; acceptance open

### Impact and symptom

Dispatching an incomplete question or treating a narrow retrieval fixture as general intelligence could produce misleading results. Literal identifiers, temporal questions and paraphrases needed separately reviewable evidence rather than broad claims about “semantic search”.

### Findings and changes

The UI gained complete-question dispatch and the project froze eight authored screens plus twelve questions for an offline benchmark. Native Vision/SQLite exact references supplied the source evidence. A discovered ambiguity in question Q11 was retained explicitly; interpretation used eleven unambiguous questions rather than silently rewriting the raw v1 result.

### Verification and remaining work

The benchmark is developer tooling and does not start a production model/index or grant agent disclosure. Its raw run remains immutable. Representative user-query quality, ranking and latency still require a suitable frozen corpus and native installed validation. Optional local semantic recall remains separate from basic keyword correctness and complete source coverage.

Source: [Benchmark record](sources/live-recall-validation.html#L584), [Complete-question change](sources/live-changelog.html#L151), [Measurement policy](sources/main-performance.html).

## RT-015 · 15–18 September 2026 · A feed or admission API was mistaken for complete recall

Subsystem: Integrations
Status: Source candidate; acceptance open

### Impact and symptom

Durable evidence feeds, bootstrap cursors and native admission were necessary infrastructure, but their existence could be confused with a working semantic index, agent-access grant or fully integrated worker. That would overstate the value available to an external assistant.

### Findings and changes

The V22 feed and V23 native writer/policy admission retained bounded pages, source revisions, deletion state and unpublished-artifact receipts. Bootstrap and consumer leases were separated from result acceptance. Native readers remained current-policy constrained; publication did not automatically activate model work or give an agent permission.

### Verification and remaining work

The .18.1 local trial included the scoped feed/admission checkpoint. Source tests cover bounded consumption and policy changes, but later V25 semantic worker integration remained a distinct main-worktree candidate. The live MCP source of October uses an app-owned explicit capability/grant model, not raw SQL or these internal tables as a public endpoint.

Source: [Progressive recall plan](sources/main-recall-plan.html#L1), [September feed/admission entries](sources/live-changelog.html#L144), [MCP contract](sources/live-mcp.html).

## RT-016 · 20 September 2026 · Small native text disappeared before OCR

Subsystem: OCR
Status: Source candidate; acceptance open

### Impact and symptom

Scaling full screenshots and additional lossy pixel conversions could erase tiny text, final digits, negations and line endings. The user-requested high-quality-before-OCR strategy directly addresses this failure, but a quality setting alone is not a complete original-retention design.

### Findings and changes

Native crop OCR, direct archive-to-BGRA reads and exact original preference removed the HEVC→JPEG→BGRA intermediate. Real regressions covered seams, ordering, complete lines, final “NOT”, digits and source metrics. Four sparse authored 4K scenes produced 948 baseline character edits versus two native-crop edits, reproducing a specific failure rather than proving a universal accuracy gain.

### Verification and remaining work

The final focused run passed 21 tests; a separate 46-test selection covered archive pixels, SQLite and failure preservation. Native OCR was slower in these fixtures: one run median 1,295 ms and a warmer complete-suite run median 484 ms, with five of twelve still over 500 ms. LZFSE restored exact pixels, but unusually sparse images cannot establish monthly savings. Original retention and installed accuracy/performance remained open.

Source: [Capture/text quality measurements](sources/main-capture-quality.html#L1).

## RT-017 · 20 September 2026 · Incremental build reused an incompatible async caller

Subsystem: Delivery and validation
Status: Source validated; installed acceptance open

### Impact and symptom

The complete suite crashed at a cancelled-recovery async call before reaching OCR. Source hashes matched, yet generated code was incompatible, which could have led to an unnecessary product workaround or a false conclusion that source logic was wrong.

### Findings and changes

Disassembly showed an incrementally reused caller loading method slot +0x378, now a synchronous helper, while the actual async recovery descriptor was at +0x380. Recompiling only the unchanged caller corrected its dispatch and passed the cancellation check. The project therefore requires clean debug products and a separately clean optimised build after actor/protocol method-layout changes.

### Verification and remaining work

A clean build passed 1,089 tests with five intentional skips and a separate optimised build, with 473 inputs unchanged. Failing and rebuilt artifact receipts were retained. This is evidence of the generated-code fault and its correction; it is not installed OCR/foreground performance acceptance. Source manifests alone cannot rule out stale generated objects.

Source: [Generated-build failure and clean validation](sources/main-capture-quality.html#L1).

## RT-018 · 24–25 September 2026 · Original retention required more than keeping a WAL folder

Subsystem: Capture and storage
Status: Source candidate; acceptance open

### Impact and symptom

Encoding could finish before OCR, and recovery could remap frame/archive identities. Keeping an old journal by convention did not prove queued extraction could find the correct pixels. A skipped processing status could not authorise release. Missing temporary drafts later made it easy to overstate completed integration.

### Findings and changes

The main candidate introduced independent original-source identity, durable extraction/release receipts, a retained-original namespace, deletion authority, reader leases and bounded producer/disk pressure. Source integration added all-display groups, direct visible text, exact source reads and cross-source candidate contracts. V24–V32 work remained separate from the installed V23 recovery line.

### Verification and remaining work

Private real SQLite/WAL/Vision/HEVC integration tests exercise mapping and lifecycle, but physical displays, pressure, recovery and installed acceptance remain separate. The former /tmp/retrace-unified-20260924 directory is gone; its missing drafts/logs are not counted as implementation evidence. Surviving source and versioned fixtures are the basis for further work.

Source: [Unified history and source receipts](sources/main-unified-history.html#L128), [Retention requirements](sources/main-capture-quality.html), [Missing-draft boundary](sources/main-responsiveness.html).

## RT-019 · 28 September 2026 · Faster speech hardware changed recognised words

Subsystem: Audio and transcription
Status: Candidate rejected for promotion

### Impact and symptom

CPU Whisper contributed intermittent high load, but moving to a native/GPU path could change meaningful speech. Lower application CPU did not prove lower whole-system energy or equivalent transcription.

### Findings and changes

On one 10.732-second Australian authored fixture, two-thread CPU Whisper took 15.925 seconds and 29.732 process CPU seconds with no word errors. Requested Metal took 4.243 seconds and 1.685 process CPU seconds but changed “payment” to “painment”. Native Speech took 0.600 seconds but changed “approve” to “prove”. Actual GPU execution and whole-system energy were not independently established.

### Verification and remaining work

The native speech comparison first needed asset preparation; failed pre-preparation evidence was retained. Shared speech-helper RSS rose during the comparisons, so app memory alone was misleading. The host was busy and Low Power Mode enabled. CPU remained the default fallback; representative names, numbers, quiet speech, overlap, timing and matched energy/latency acceptance are still required before promotion.

Source: [Native speech/hardware comparison](sources/main-responsiveness.html#L37).

## RT-020 · 28 September 2026 · A smaller audio codec lost a sentence

Subsystem: Audio and transcription
Status: Candidate rejected for promotion

### Impact and symptom

Reducing stored bytes at the expense of a missing sentence would destroy memory value. Supported bitrates, sample counts and file size alone were insufficient for selecting a replacement codec.

### Findings and changes

The authored comparison tested current quality-based AAC, 12/28/48 kbps AAC and experimental native Opus CAF. All retained 171,707 decoded samples. AAC 12 kbps saved 28.7% versus the current file, but CPU Whisper omitted an entire six-word sentence. The 28 kbps candidate had three word errors; 48 kbps used more bytes and had none in that run. Opus container overhead was large and timing/SNR needed investigation.

### Verification and remaining work

No codec was promoted. Native Speech and CPU Whisper reacted differently, reinforcing the need to compare the actual pipeline. Listening quality, timestamp/seek cost, representative audio, helper memory and energy remain open. No historical audio was recompressed or discarded. RT-046 records a later container-only attempt rejected for timing despite byte savings.

Source: [Codec and recognition table](sources/main-responsiveness.html#L37).

## RT-021 · 28 September 2026 · Non-overlapping chunk candidate saved no space in its fixture

Subsystem: Capture and storage
Status: Candidate rejected for promotion

### Impact and symptom

Legacy fifteen-second recordings spaced ten seconds apart store repeated samples. Simply shortening files would break overlap context, repair and cross-boundary playback. The planned unique-chunk design needed a new exact-media contract, not a batch-duration tweak.

### Findings and changes

The default-off main candidate persists unique ten-second AAC chunks, builds ordered overlapping manifests and validates integer sample ranges, continuity, priming, final partial windows and deletion/read leases. It separates transcript identity from verified media mapping. Original recordings remain readable unchanged.

### Verification and remaining work

Integrity/lifecycle tests passed their scope, but the short native comparison used 6.95% more total bytes and failed recognition acceptance. Per-file overhead and window sensitivity prevented promotion. Pending-recording playback, representative storage/latency and installed trials remained open. Approximate one-third reduction in duplicated stored duration is not a measured one-third reduction in retained bytes or recoverable old library space.

Source: [Exact audio continuation and candidate results](sources/main-responsiveness.html#L80), [November audit confirmation](sources/live-storage-efficiency.html).

## RT-022 · 29 September 2026 · Privacy masking blocked otherwise usable screenshots

Subsystem: Privacy and evidence
Status: Local trial; acceptance open

### Impact and symptom

The user saw “Current privacy settings do not permit opening this evidence” and unavailable screenshots. The evidence viewer had been introduced to support source correctness, but its policy handling blocked recordings containing masked areas, making core memory appear absent.

### Findings and changes

The masked-history repair allowed recorded nonmasked pixels to be opened while preserving actual exclusions, deletion and source checks. A partially masked capture was no longer treated as a blanket prohibition on the whole retained image. The October CPU repair was based on that V23-compatible fix rather than installing the larger schema candidate.

### Verification and remaining work

The September 29 local-trial and subsequent October records distinguish source validation from installed checks. The change did not remove privacy control or guarantee every missing image had retained pixels. Later failures came from unfinished video paths, display routing and metadata/timer capture rejection (RT-034 to RT-037). “Image unavailable” therefore remained a symptom requiring a cause-specific diagnosis.

Source: [Masked-area repair changelog](sources/live-changelog.html#L130), [Installed CPU repair lineage](sources/live-cpu.html#L3).

## RT-023 · 30 September 2026 · CPU and storage claims lacked consistent denominators

Subsystem: Performance
Status: Source candidate; acceptance open

### Impact and symptom

Intermittent load and large disk usage were major user problems. A single CPU sample, asynchronous job duration or summed APFS folder size could not show which change helped. Deferring work or losing capture could falsely appear to reduce cost.

### Findings and changes

The main source added monotonic process/host CPU sampling, bounded minute metrics, resource admission hysteresis and periodic categorised storage accounting. Logical/allocated bytes and free space were separated, with partial scans preserving the last complete result. An offline scorecard covers quality, speed, cost and recall with pinned workloads and complete pending/capture denominators.

### Verification and remaining work

Owner, policy, storage and SQLite regressions support source implementation. Installed active-use acceptance still requires matched baseline/candidate workloads with at least three complete runs, no hidden gaps or growing backlog, foreground p95 within allowance and actual native resource evidence. The twenty-percent target is a soft admission goal, not a hard process cap. RT-033 later found the legacy monitor itself doing excessive work.

Source: [Resource/accounting implementation](sources/main-responsiveness.html#L126), [Performance policy](sources/main-performance.html).

## RT-024 · 1 October 2026 · High CPU required a narrow installed protection repair

Subsystem: Performance
Status: Local trial; acceptance open

### Impact and symptom

Retrace was observed with sustained/intermittent CPU high enough to make the Mac difficult to use; samples in the broader investigation included roughly 253% and user screenshots above 200%. OCR and CPU Whisper could overlap. Lowering OCR alone could not control speech spikes.

### Findings and changes

The V23-compatible 2610.1.1 repair added CPU monitoring and quiet-time audio admission while preserving the masked-recording fix, existing recording settings and OCR behaviour. Ambient text could lag while recording continued. This was a deliberate responsiveness trade-off, but later UI and queue defects made the lag unacceptable and invisible.

### Verification and remaining work

Clean source validation passed 1,137 tests with nine skips; a separate optimised build and installed UI/recording advancement checks passed. Installation disclosed approximately 286 seconds between screens and 276.575 seconds between saved audio ranges. No matched fifty-percent reduction or twenty-percent-of-one-core target was accepted. Quiet-time admission could not justify indefinitely starving current speech; RT-025 and RT-027 address that consequence.

Source: [Installed CPU protection ledger](sources/live-cpu.html#L101), [Audio visibility diagnosis](sources/live-audio-visibility.html).

## RT-025 · 3 October 2026 · Saved audio vanished from Timeline and Live while text was pending

Subsystem: Audio and transcription
Status: Local trial; acceptance open

### Impact and symptom

The user reported that audio was not recording because nothing appeared in Timeline or Live. Read-only checks found new pending rows and AAC files advancing every ten seconds. A sampled file decoded with a signal, but this proved neither all historical speech nor continuous coverage.

### Findings and changes

Timeline used getTranscriptions with includeActivityRows false, excluding empty pending rows. Live already read status but did not insert that panel and discarded the media path during mapping. The repair used a bounded shared reader, retained playback references and showed saved recordings with pending-text labels and their original dates. View visibility owns refresh/read/player lifetimes; opening starts neither playback nor transcription.

### Verification and remaining work

Ninety-four focused tests passed using real private SQLite and native AAC reading/player paths. An opt-in offscreen native rendering probe failed to expose actionable controls; rendered UI acceptance was explicitly not claimed. The repair was not installed on October 3 and later shipped with 2610.6.1. The independent stale backlog and silent microphone remained separate faults (RT-027/028).

Source: [Saved-audio visibility repair](sources/live-audio-visibility.html#L3), [October 6 installation](sources/live-audio-freshness.html).

## RT-026 · 3–6 October 2026 · Native AAC fixtures failed in the command environment

Subsystem: Delivery and validation
Status: Known validation limitation

### Impact and symptom

The environment could not create AAC through the unchanged production writer, and later an AAC PCM read failed with AVFoundation/AVFAudio error 1718449215. Passing tests using other inputs could not honestly be called native AAC worker acceptance.

### Findings and changes

An untouched control reproduced the writer failure. The visibility suite used an explicitly supplied, byte-pinned authored AAC to retain native decoding/playback checks. For freshness worker tests, the unchanged decoder opened an authored WAV and read all 171,707 frames while the AAC read still failed. Tests used honest WAV paths rather than disguising PCM as AAC.

### Verification and remaining work

A broad Transcript filter had twelve failures across AAC fixtures, Speech metadata and backpressure; only the AAC writer failure was separately reproduced in an unchanged control. That broad run was not all-green or fully explained. The later installed Process now check exercised real AAC decoding and fresh queue progress, but probable-silence output did not establish spoken-phrase accuracy. Failed native receipts remain part of the record.

Source: [Visibility validation limits](sources/live-audio-visibility.html), [Freshness native controls](sources/live-audio-freshness.html#L59).

## RT-027 · 6 October 2026 · Oldest-first transcription starved fresh speech

Subsystem: Audio and transcription
Status: Superseded by later recovery

### Impact and symptom

At 14:07 the installed build was still 2610.1.1. The prior 24 hours had 7,662 pending microphone rows, later 7,680. New transcript writes were being produced for September recordings while October speech remained pending. Recent database writes had been confused with recent captured speech being processed.

### Findings and changes

The worker selected one globally oldest pending/repair batch after quiet-time admission. The narrow repair preferred recent first-pass work within 24 hours, then selected one oldest item after three recent attempts. Failed/cancelled attempts consumed the fairness slot. Queries used existing status/time indexes without temporary sorting. It changed ordering, not CPU admission or system-audio settings.

### Verification and remaining work

Clean focused validation passed 152 tests plus one intentional native-view skip; additional exact-range/shutdown cases passed. A 20,000-row query fixture improved from 260,056 VM steps for the old selection to 81 across three new selectors. Build 2610.6.1 was installed with visible fresh pending rows and a real probable-silence completion. It still did not provide active-use near-instant speech; October 19 introduced the bounded fresh lane.

Source: [Freshness repair and installation](sources/live-audio-freshness.html#L3), [Later recovery](sources/live-recovery.html).

## RT-028 · 6 October 2026 · Valid AAC files contained digital silence from the wrong microphone

Subsystem: Audio and transcription
Status: Local trial; acceptance open

### Impact and symptom

Eight sampled AACs around 22:46–22:49 decoded successfully but every PCM sample was zero. Retrace had opened the MacBook Pro Microphone at 21:44 while macOS later selected the Studio Display and the laptop lid was closed. Recording-file existence had hidden a genuine input failure.

### Findings and changes

The installed source selected the default input only at startup and had no owner for default-input/device changes. The ledger linked the observed closed-lid state to Apple's hardware microphone-disconnect behaviour. Pause/resume reopened the Studio Display microphone, with an 8.641-second gap. The user's new test produced overlapping recordings containing some expected words; “microphone” was missing, so complete phrase accuracy was not claimed.

### Verification and remaining work

One sampled file on each of October 1–6 had nonzero audio, but this did not prove continuous intelligible speech throughout those days. Other gaps intersected sleep/dark-wake. Historical silence cannot be recovered by retranscription if the sound was never captured. The exact duration of lost usable speech remained unknown. RT-030 records the device-change source repair and installed limits.

Source: [Microphone signal and routing diagnosis](sources/live-microphone.html#L3).

## RT-029 · 6–7 October 2026 · Signing and writer guards delayed delivery

Subsystem: Delivery and validation
Status: Local trial; acceptance open

### Impact and symptom

The repair existed in source but the old app remained running. The Codex command session found zero signing identities while the user's normal Terminal listed a valid identity. The first installer retry reported writer_present even after Retrace quit, producing frustration and extra recording gaps.

### Findings and changes

Native packaging ran in the user's signing-capable Terminal without bypassing verification. An independent SSH-origin sqlite3_rsync held the database/WAL, so the writer guard correctly blocked replacement. The copy was allowed to finish and installation retried. The installer retained the prior app and a quiescent rollback database and verified actual moves rather than assuming success.

### Verification and remaining work

Build 2610.6.1 installed on October 6 at 23:19 with V23/settings preserved. The failed quit/reopen gap was 232.927 seconds and successful installation gap 210.012 seconds. Native UI showed fresh pending recordings and explicit playback states. A later 2610.6.2 install had another 94.568-second gap. These are saved-media wall-clock gaps, not exact acoustic continuity measurements.

Source: [Signing, guard and installation ledger](sources/live-audio-freshness.html#L119), [Microphone delivery](sources/live-microphone.html).

## RT-030 · 7 October 2026 · Input changes needed an owned native restart path

Subsystem: Audio and transcription
Status: Local trial; acceptance open

### Impact and symptom

The manual pause/resume workaround restored microphone sound but would not prevent recurrence after another wake or device change. An unowned automatic restart could itself revive recording after pause, overlap callbacks or drop converter tails.

### Findings and changes

The repair observes default-input UID and device changes, coalesces meaningful replacements, joins the old callback lifecycle and drains native conversion. It preserves the public audio stream and leaves unrelated device changes alone. A later pause/stop fences queued restarts. It neither changes the OS preference nor picks an arbitrary fallback microphone.

### Verification and remaining work

Thirty-eight focused tests passed after clean actor/protocol rebuild and a native ownership correction; all 379 product inputs stayed unchanged through the separate optimised build. Build 2610.6.2 installed October 7, and startup plus two new AAC signal checks passed. Physical switching, sleep/wake and complete new spoken-phrase/rendered-UI acceptance remained separate. Signal present is still not an accuracy claim.

Source: [Microphone repair and installed trial](sources/live-microphone.html#L46), [Changelog summary](sources/live-changelog.html#L104).

## RT-031 · 19 October 2026 · Cancellation did not promptly stop native Whisper work

Subsystem: Performance
Status: Local trial; acceptance open

### Impact and symptom

Returning to active work could cancel an application task while native inference continued consuming CPU. The UI's cancelled state was therefore insufficient to protect responsiveness or prove joined shutdown.

### Findings and changes

The recovery repair wired CPU cancellation into scheduled native encoder/decoder graphs, including language detection. Fresh audio received a bounded chronological lane during active use, with one Whisper thread in Low Power Mode or two otherwise. OCR joined the same governor before claiming a frame, and one stable worker survived settings changes. Pending work remains durable after cancellation.

### Verification and remaining work

An explicit small-model native regression reduced cancellation join from 12.233 seconds to 0.008/0.062 seconds, then successfully reused the service with unchanged authored transcription. Clean validation passed 1,249 tests with nine skips before 2610.19.1 installation. A two-minute unmatched observation averaged 20.53% CPU with 541.8 MiB peak RSS; this was not a worst-case guarantee, matched improvement or fresh-transcript acceptance. The restart gap was 527.043 seconds of saved audio and 535.573 seconds between screenshots.

Source: [Recovery cancellation and installed .1](sources/live-recovery.html#L111), [Recovery changelog](sources/live-changelog.html#L90).

## RT-032 · 19 October 2026 · Quiet batches and demanding repair delayed fresh first-pass text

Subsystem: Audio and transcription
Status: Local trial; acceptance open

### Impact and symptom

Many recent batches were classified low-energy or probable silence. Expensive retries/refinement could consume the fresh lane, delaying useful speech and repeating native work while uncertain text remained unavailable.

### Findings and changes

Build 2610.19.3 persisted low-energy classification with pending rows, prioritised likely speech in the bounded fresh lane and allowed only one native inference for a fresh first pass. Uncertain text survives in durable repair state; demanding enhancement waits for an ambient permit. Empty/worse repair cannot erase the retained candidate or repeat the raw first pass. Quiet recordings stay eligible for historical/manual work and are not deleted.

### Verification and remaining work

Sixty-eight focused checks and a clean 1,261-test suite with nine skips passed, followed by a separate optimised build and local installation. The policy does not prove that silence classification is always right or that all queued speech meets a latency target. Physical quality, throughput, freshness under sustained load and fair eventual processing remain acceptance work.

Source: [Speech-priority recovery](sources/live-recovery.html#L297), [Changelog .19.3](sources/live-changelog.html#L75).

## RT-033 · 19 October 2026 · Opening System Monitor could process a huge diagnostic log

Subsystem: Performance
Status: Local trial; acceptance open

### Impact and symptom

The tool intended to explain performance could itself decode and compact an entire process diagnostic log. This added avoidable work and made its displayed history appear more complete than the bounded samples actually supported. The log later reached 2.14 GB.

### Findings and changes

The recovery implementation bounded reads and retained samples, retried cancelled partial aggregates and stopped automatic history rewrites during sampling. The table was relabelled recent process samples instead of a complete twelve-hour history. CPU capacity labels wait for observed hardware information. Storage scanning moved to a periodic owner with coalesced manual refresh and partial-state reporting.

### Verification and remaining work

The source/installed recovery checks cover the bounded behaviour, not a global monitoring-overhead benchmark. The later November lossless archive preserved all old log content and a compatible plain-text tail (RT-048). That one-time cleanup did not install future log rotation, so bounded reader behaviour and bounded file growth remain separate responsibilities.

Source: [Monitor/storage recovery](sources/live-recovery.html#L136), [Later diagnostic archive](sources/live-storage-efficiency.html).

## RT-034 · 19 October 2026 · Capture routed to the wrong display or lost observer ownership

Subsystem: Capture and storage
Status: Local trial; acceptance open

### Impact and symptom

Missing Accessibility permission could force an otherwise permitted secondary window to the main display. Transparent/helper windows could influence routing. Late display observer callbacks could survive stop, while initial monitor state did not necessarily match the actual opened source.

### Findings and changes

Build 2610.19.4 used the same checked visible-window geometry for display routing, attribution and document revalidation. It initialised the display monitor with the source actually opened, subscribed before reconciliation and revoked delayed callbacks on stop. Native callback context remained alive through removal. Rejection reasons became bounded categorical counters with a coalesced asynchronous writer.

### Verification and remaining work

Fifty-seven focused tests, a clean 1,274-test suite with nine skips and a clean optimised build passed. The installed .4 saved new audio/screens, but later screenshots stopped advancing: forty-seven intervals had 999 rejected attempts and zero accepted captures. That recurrence invalidated any claim of sustained capture acceptance. Saved audio/screen install gaps were 305.409/319.663 seconds. RT-035 diagnoses the next cause.

Source: [Display/observer repair and recurrence](sources/live-recovery.html#L380), [Changelog .19.4](sources/live-changelog.html#L67).

## RT-035 · 19 October 2026 · Slow optional metadata repeatedly rejected screenshots

Subsystem: Capture and storage
Status: Local trial; acceptance open

### Impact and symptom

Screenshots stopped while audio continued, despite the preceding display repair initially working. Capture was repeatedly rejected while slow optional Accessibility document enrichment ran inside the screenshot admission bracket.

### Findings and changes

The .19.5 follow-up moved optional document enrichment outside screenshot admission. Required app/window/title attribution, inventory/identity and privacy guards stayed intact. Unsupported document/pane/URL data remains absent instead of borrowing a later observation. The independent activity observer retains its source-bound enrichment.

### Verification and remaining work

Seventy focused capture/privacy tests and the final combined 1,302-test debug suite with nine skips passed, plus a separate clean optimised build. Installed screenshots and audio advanced with V23/preferences preserved. Rendered Timeline acceptance awaited the user because computer control was unavailable, and the later run-loop issue still affected sustained capture. Relaxing optional metadata was not permission to weaken exclusions or invent context.

Source: [Capture availability follow-up](sources/live-recovery.html#L514), [Changelog .19.5](sources/live-changelog.html#L59).

## RT-036 · 19 October 2026 · Timeline hid saved pixels while video or OCR was unfinished

Subsystem: Search and navigation
Status: Local trial; acceptance open

### Impact and symptom

Ordinary Timeline used a separate video/file-size path instead of verified saved originals, so a captured frame could be invisible until archive completion. Pending OCR could also hide captures from filtered history. Reopening, paging or search handoff could lose the right selected image.

### Findings and changes

The .19.5 repair reads saved originals first while video is unfinished, then uses the exact finalised-frame reader. Source identity, timestamp and proof survive queries/status refresh. The UI owns and cancels one foreground image read; a failed live preview restores history, and an older initial query cannot overwrite a newly accepted filter. Hidden/privacy checks remain active.

### Verification and remaining work

Real private SQLite, original journals, HEVC and native AppKit tests support the source repair. The combined suite passed 1,302 tests with nine skips. Installed .5 reopened at 16:29:59 with saved audio/screen gaps 37.737/47.362 seconds. Native rendered Timeline acceptance was not observed in that command session. RT-013's exact-reference principle remains essential; nearby pixels are not an acceptable substitute.

Source: [Timeline originals recovery](sources/live-recovery.html#L472), [Changelog .19.5](sources/live-changelog.html#L59).

## RT-037 · 20 October 2026 · Menu tracking paused the periodic capture timer

Subsystem: Capture and storage
Status: Local trial; acceptance open

### Impact and symptom

After the metadata repair, holding native menus could still pause periodic screenshot capture because the timer ran in the wrong AppKit run-loop mode. Screenshots had a large separation even while audio continued, so “Recording” was not sufficient evidence of healthy screen coverage.

### Findings and changes

Build 2610.19.6 scheduled the existing capture timer in common run-loop modes through one helper used by initial setup and window-change rescheduling. Cadence, privacy checks and invalidation remained in their existing owners.

### Verification and remaining work

A native regression reproduced zero ticks during event tracking and passed after correction. All 179 Capture tests passed with two intentional skips; a separate clean optimised build passed. Installed .6 reopened October 20 at 11:37:01 with new screenshots, decodable mic AAC, OCR and a transcript. Audio restart gap was 12.123 seconds; the 1,752.241-second screenshot separation began before installation. Five complete CPU minutes averaged 20.68% with a 205.55% peak. Native installed tracking-mode and sustained performance acceptance remained open.

Source: [Timer repair and bounded runtime result](sources/live-recovery.html#L612), [Changelog .19.6](sources/live-changelog.html#L53).

## RT-038 · 21 October 2026 · Operating Brief and Activity Pulse used space without useful context

Subsystem: UI and context
Status: Local trial; acceptance open

### Impact and symptom

Stuart reported empty Brief/Signals/Ahead panels, weak activity information and degraded search/transcription. He explicitly requested removal of Operating Brief and associated components, useful transcript/speaker/screen context and configurable spoken markers with MCP access.

### Findings and changes

The recovery-based Live source replaced the brief with a resizable transcript/screen workspace, independent evidence loading, selected-range search, manual/spoken markers and reviewed Copy context. The marker anchor remains distinct from editable explanations/ranges. Private companion enrichment and an app-owned permissioned command endpoint were added as optional paths; recording remains independent of them.

### Verification and remaining work

Later local trials .22.3–.22.5 installed this source direction, with multiple UI and runtime follow-ups below. No live MCP grant or companion connection was created during acceptance; voice rules remained off. Wider intelligence, calibrated known-person names, physical phrase acknowledgement and complete installed command parity were not accepted. The portable prototype retains the new Live direction and does not restore the removed panels.

Source: [Live plan and acceptance ledger](sources/live-markers.html#L3), [Live guide](sources/live-guide.html).

## RT-039 · 21–22 October 2026 · New context/MCP tests exposed real integration and fixture failures

Subsystem: Integrations
Status: Source validated; installed acceptance open

### Impact and symptom

The broad Live/markers/companion/MCP implementation produced several failing cohorts. Passing compilation could not establish transport, SQLite ownership, exact cross-file audio or privacy. A failed native companion import was initially reported as missing speech despite remote jobs having completed.

### Findings and changes

Failures included a metadata SELECT left open while activating WAL, incorrect speaker-correction round-trip timing, missing private directories, inherited context edits violating provenance, wrong interruption categories and fixture initialisation gaps. The companion test used a payload-free summary API instead of an exact result-bearing record; correcting that read exposed already retained results. A separate fixture isolation audit found that an ordinary database initializer could consult live encryption preferences/Keychain and Rewind metadata; it was replaced with canonical private migrations and a debug unencrypted reader.

### Verification and remaining work

Failed/hung runs remain recorded, including 68.368 seconds for the initial companion attempt. The corrected authored native owner→private HTTPS→companion→import path passed with exact PCM/source preservation, deduplication and offline reopening. It did not upload live recordings or prove installed physical speech/speaker-name quality. The ledger records each cohort separately; counts must not be summed as independent coverage.

Source: [Live integration checkpoints](sources/live-markers.html#L130), [Companion operations contract](sources/live-companion.html).

## RT-040 · 22 October 2026 · First installed Live candidate crashed in Swift sleep/wake

Subsystem: Lifecycle and recovery
Status: Local trial; acceptance open

### Impact and symptom

Signed 2610.22.1 crashed during its first minute of installed use, despite passing prior source checks. The previous .19.6 recording app had to be restored. Initial diagnostic trials failed before collecting useful events, causing additional disclosed interruptions.

### Findings and changes

A bounded runtime trace eventually reproduced Task.onSleepWake with 2,497 callbacks and linked the observed task origin to the governor monitor await. That narrowed the observed origin but did not prove the underlying Swift failure mechanism. The mitigation replaced only the monitor's one-second task sleep with an owned one-shot native timer, joining event/cancel handlers and the serial finaliser before rearming.

### Verification and remaining work

Six native timer races and held-reader lifecycle regressions passed. Clean full32 had 1,666 tests, sixteen skips and zero failures; a separate optimised build and 94.524-second native soak passed. Installed .22.2 survived a 5:10 bounded interaction check; later .3 included the mitigation. The original application crash remains a failed run, and mitigation is not a demonstrated root-cause fix or broad sleep/wake/stability acceptance. Rollbacks verified the recovery executable, V23 and renewed frame/audio advancement.

Source: [Crash tracing, rollback and timer mitigation](sources/live-markers.html#L222), [Changelog mitigation summary](sources/live-changelog.html#L34).

## RT-041 · 22 October 2026 · Live opened at the wrong end and lost keyboard/resize behaviour

Subsystem: UI and context
Status: Local trial; acceptance open

### Impact and symptom

A populated List opened at its oldest row while labelled Following live. An initial onAppear scroll patch did not fix it. Later installed .22.3 had pending-only Page Up failure and intermittent audio-list errors; resizing between split and compact tabs could disturb reading or leave hidden controls receiving input.

### Findings and changes

The initial-follow repair waited for native layout and cancelled movement when actual reading began. Independent read lifetimes, retained viewport state and mutation revalidation kept selected evidence stable. Pending recording text became selectable for native keyboard focus. Hidden-tab input and Settings round-trip privacy were explicitly checked instead of inferred from screenshots.

### Verification and remaining work

The unchanged native27 interaction sequence passed at 1,280 and 820 points after earlier failures, including real Page Up/wheel, a new row while pinned and Return to live. Later native/responsive/pending suites supported .22.4, whose installed keyboard and resize checks passed. Those checks did not solve the older-history query timeout, covered in RT-042, or establish long-run memory usage.

Source: [Native Live sequence and UI checkpoints](sources/live-markers.html#L249), [Changelog .22.3/.4](sources/live-changelog.html#L20).

## RT-042 · 22 October 2026 · Load older timed out against the actual library

Subsystem: Search and navigation
Status: Local trial; acceptance open

### Impact and symptom

Installed .22.4 failed twice with budgetExceeded when loading older audio, despite passing authored paging fixtures. A historical tail scan exceeded the reader budget and the displayed history was incomplete.

### Findings and changes

Build .22.5 bounded each read to at most 512 raw candidates under the existing 250 ms budget/index. It retained long-overlap matches and continued from the last inspected candidate, including empty accepted pages. One App-owned read-only reader and coalesced opens/head/older reads preserved cursor identity. Coverage distinguished unchecked candidates from known matching results and flowed into Search, Copy, MCP and companion.

### Verification and remaining work

Clean full54 passed 1,699 tests with twenty explicit skips, with a fresh optimised build. Installed .22.5 at 06:09:48 increased loaded recordings 100→178 without timeout and preserved the anchor. A later unchanged page did not prove cursor progress. Original pending54's wide-sequence failure remains unresolved alongside the unchanged-binary pending54b pass with settled observations. Final recording check was 4:20 after launch; long-run coverage/memory and complete acceptance remain open. Restart audio gap was 17.372 seconds.

Source: [Bounded reader source/installed ledger](sources/live-markers.html#L393), [Changelog .22.5](sources/live-changelog.html#L13).

## RT-043 · 22 October–2 November 2026 · Date presets replaced the requested lazy transcript browsing

Subsystem: UI and context
Status: Source candidate; acceptance open

### Impact and symptom

Stuart rejected the unrequested “last 30 minutes, today, custom” browsing change and wanted newest-to-oldest scrolling with automatic older results. Manual pages and a 500-record stop weakened the memory workflow and interrupted history browsing.

### Findings and changes

The source restore puts newest entries first and loads older history near the bottom across dates, preserving pending rows, speaker labels, playback and pinned reading. Optional date ranges apply only to explicit search. Return to live resumes the head. This source change followed the installed .22.5 checkpoint and is not automatically part of that binary.

### Verification and remaining work

By the November 2 audit, the October 22 temporary handoff and build receipts were missing. Source survived in the Live-context worktree, but fresh build, validation and installation were still required. This journal does not label the scrolling repair installed. The prototype deliberately follows the accepted restored interaction and clearly labels it simulated.

Source: [Source-candidate changelog](sources/live-changelog.html#L9), [Missing-handoff audit](sources/live-storage-audit.html), [Current guide](sources/live-guide.html).

## RT-044 · 2 November 2026 · Huge backup allocation yielded little physical free space

Subsystem: Storage and cleanup
Status: Completed bounded operation

### Impact and symptom

The Mac was nearly full and Candidates contained large dated databases. The user asked repeatedly whether cleanup would remove Timeline value. Backups were separate restore points, not normal history files, but removing them still relinquished recovery choices.

### Findings and changes

The audit verified and retained the newest V23 rollback database plus signed .19.6 recovery app, then removed four exact older database-only backup directories after the recorded instruction. It checked SQLite headers, declared lengths, empty WALs, identities, no observed open handles and the retained store identity. It did not perform a full database integrity scan.

### Verification and remaining work

All four targets were absent; live database/media remained readable/present and the app kept running. Roughly 162 GB of reported allocation produced only 800,890,880 bytes (0.80 GB) immediate net volume gain, reflecting APFS sharing and concurrent activity. Earlier unrelated free-space changes were not attributed to deletion. The newest backup and recovery receipts remained protected. Folder size was not a reclaimable-space promise, and no further deletion was authorised by that operation.

Source: [November 2 backup cleanup and limits](sources/live-storage-audit.html#L19).

## RT-045 · 2 November 2026 · Rebuildable caches consumed space while lost drafts could not prove delivery

Subsystem: Storage and cleanup
Status: Completed bounded operation

### Impact and symptom

Multiple worktrees/release builds and old automation-browser downloads occupied space, while the transcript-scroll temporary build material was already gone. Deleting a source worktree or current tool runtime would have lost more than a disposable cache.

### Findings and changes

After the recorded continuation instruction, exactly 24 directories were removed: nine .build trees, five older release trees, two npm trees, two Puppeteer trees and six old Playwright browser directories. Sources, Git metadata, current browser/runtime dependencies, installed app, live library, rollback material and personal files stayed. The executor used a literal allowlist, pinned identities and symlink-resistant removal with per-target progress.

### Verification and remaining work

Net volume availability increased 12,386,111,488 bytes (12.39 GB). Independent checks found all targets absent and seven protected identities unchanged. No app restart occurred. Future development may need recompilation/downloads. Missing temporary scrolling receipts remained missing; their loss was not converted into a passing result. Simulator, Docker, active uv, model and document candidates were excluded pending separate evidence/authority.

Source: [Rebuildable cleanup report](sources/live-storage-audit.html#L5), [Scrolling delivery boundary](sources/live-changelog.html#L9).

## RT-046 · 7 November 2026 · Live-library savings were promising but unsafe to apply directly

Subsystem: Storage and cleanup
Status: Candidate rejected for promotion

### Impact and symptom

The live library was about 169.10 GB allocated: audio 72.71 GB, SQLite 47.15 GB, screen chunks 41.25 GB, raw frame WAL 3.26 GB, models 2.20 GB and logs 2.14 GB. Candidates was 44.76 GB, dominated by the retained 42.84 GB rollback. The user wanted less space without losing memory value.

### Findings and attempted changes

A bounded 3,000-path audio sample confirmed about fifteen-second files spaced ten seconds apart. Current transcripts referenced canonical batches; the audit corrected an earlier broad claim of disposable sentence-file duplication. Historical playback references still protect older clips. The unique-chunk candidate from RT-021 remained default-off after failed savings/recognition gates.

One isolated file copy was remuxed from 69,014 to 46,181 bytes (33.0846% smaller). All 237 AAC packet hashes, durations and skip metadata matched, but timestamps shifted by 2,112 samples: stream start moved 0.132 seconds to zero and duration changed. The native comparison reader also rejected Apple's extensible WAV before PCM equality was established. The copy was rejected and no live file was replaced.

### Original pixels and database findings

The raw-frame WAL was not SQLite's adjacent sidecar and not disposable cache. One 1.65 GB session had 28 raw records/27 mappings with committed=false; a 332 MB session had only 5/40 OCR jobs complete without verified exact archive mapping; a 102 MB session referenced a zero-byte archive and might hold the only pixels. Manual compression would break current readers. The live SQLite had 11,511,734 pages and zero freelist pages; no easy large vacuum saving was demonstrated. The installed screen FTS was content-bearing, correcting the earlier assumption that all FTS used external content.

### Verification and remaining work

The pass was read-only except the isolated copied-audio experiment. It changed no live media, schema, settings or app. Future work needs exact timing/decoded-sample/seek preservation, reference audits, safe original recovery, table/index allocation measurements and representative codec acceptance. Probable silence, old WAL names and duplicate-looking paths never became deletion authority.

Source: [Full storage efficiency audit and rejected remux](sources/live-storage-efficiency.html#L3), [Earlier chunk/codec failures](sources/main-responsiveness.html).

## RT-047 · 9 November 2026 · Network cleanup freed space but its authorisation record is disputed

Subsystem: Storage and cleanup
Status: Completed operation; authority disputed

### Impact and observed result

The network M3 Max was under urgent space pressure while running primary intelligence services. The record reports five exact directory removals in three operations, measured net gain 15,235,735,552 bytes (15.24 GB), and final 39,479,230,464 bytes available. Background activity also changed space, so the whole rise from the earlier 4.43 GB reading was not attributed to cleanup.

### Removed value and limits

Two inactive old application signing copies were removed while current app hashes/processes remained. A May 12 derived search-index snapshot with 495,487 rows was removed, relinquishing that dated rollback. Current remote/laptop indexes opened with matching 3,072-value vector schemas and approximately 583,000 rows each; those checks did not prove a row-by-row historical superset or complete search quality. Two temporary ModelScope directories held seven incomplete files: six declared more tensor bytes than existed and one lacked a readable ZIP central directory. Removing them loses partial download progress, not demonstrated complete model weights.

### Authorisation discrepancy

The bundled cleanup record states that Stuart authorised urgent space recovery. Later audit context (observations 81580, 81600, 81609–81611) says specific go-ahead for the old index snapshot and incomplete downloads was not present as planned, and that the report's blanket authorisation wording was committed/pushed before correction. This package cannot resolve that conflict from the selected records. **Execution and technical checks are recorded; specific authorisation is unconfirmed/disputed.** It must not be restated as a verified approval or used to justify more deletion.

### Verification and remaining risk

The primary database remained readable, current indexes retained checked counts/schema, and observed services retained PIDs. No full integrity or capture-quality run occurred. Active Retrace mirrors, staging, recent graph/decision backups, uv runtimes, complete models and swap were preserved. The remote Python 3.9 lacked dir_fd support; the executor used an explicitly checked 3.11 interpreter. The home scan was incomplete and additive sync still permits destination accumulation. Exact media references and authority are prerequisites for any further cleanup.

Source: [Original network cleanup record with discrepancy banner](sources/live-network-cleanup.html#L3). The later audit discrepancy is preserved as editorial context in this journal; no original conversation transcript or approval receipt is bundled.

## RT-048 · 9 November 2026 · A 2.14 GB inactive diagnostic log was safely archived, not erased

Subsystem: Storage and cleanup
Status: Completed bounded operation

### Impact and symptom

The CPU process log had not changed since October 19 and was not recording history. Its large plain-text body occupied space while the native reader only needed a bounded tail. Earlier sample compression estimates were not proof of recoverable bytes or reader compatibility.

### Findings and changes

The completed operation retained the full 2,144,479,189-byte content in a 407,184,504-byte gzip and a compatible 4,183,253-byte plaintext tail at the original filename. It used pinned directory descriptors, exclusive output creation, full hashes, identity checks, an atomic macOS filename swap and verified durability barriers. One review identified the need for F_FULLFSYNC; it was added and exercised before unlinking the redundant original inode.

### Verification and remaining work

Full decompression reproduced the original SHA-256. A compiled copy of the actual ProcessCPULogReader returned the same 204 complete records before and after. Reported file allocation fell 1.72 GB; net volume free space rose 1.35 GB during the active-machine operation. Database/media identities, rollback metadata, installed executable and process identity remained unchanged; no restart was requested. This is a one-time inactive-file cleanup, not future log rotation or a new capture/transcription acceptance run.

Source: [November 9 diagnostic archive receipt summary](sources/live-storage-efficiency.html#L80).

## RT-049 · 11 November 2026 · Main source, installed app and documentation told different stories

Subsystem: Delivery and validation
Status: Known validation limitation

### Impact and symptom

The main checkout carried the larger V24–V32 candidate while the installed app remained the V23 recovery/Live line. Some older guides still named 2609.18.1 or 2610.1.1. A source user guide described the restored lazy scrolling that was not established as installed. Missing temporary drafts and broad “working” statements could obscure this distinction.

### Findings and changes

The standalone specification reconciles each baseline explicitly: installed local trial .22.5, later scroll source candidate, larger uninstalled schema/capture/audio candidate, optional services off/unconfigured at the last acceptance checkpoint. It separates plans, source validation, installation and acceptance and retains failed tests and unknowns. The source library preserves complete selected records rather than rewriting their historical statuses.

### Verification and remaining work

Packaging-day inspection found installed bundle .22.5; it did not rerun native recording/performance acceptance. The HTML replica uses authored sample content and cannot demonstrate those native features. Source snapshots include hashes and dates, but hashes prove the archived text's provenance rather than the truth of every historical assertion. The supporting records omit private media, missing temporary receipts and unselected earlier history. Those limits are visible in the specification and source index.

Source: [Consolidated baseline](full-spec.html#2-status-vocabulary-and-reconciled-baseline), [Changelog](sources/live-changelog.html), [Live ledger](sources/live-markers.html#L415), [Source inventory](sources/index.html).

## RT-050 · Ongoing at 11 November 2026 · Product-wide acceptance remains incomplete

Subsystem: Performance
Status: Acceptance open

### Impact and symptom

The user needs accurate, fast, affordable memory and useful assistance, yet short successful trials coexist with unmeasured long-running behaviour. A green test suite, advancing row IDs or a lower momentary CPU sample cannot establish that goal.

### Open acceptance work

The records leave physical input switching/sleep/wake, all-display capture, speech acknowledgement p95, known-speaker precision, complete installed MCP/companion parity, long-history continuation/memory, matched active-use CPU/foreground latency and safe representative codec savings open. Actual audio signal, text quality, exact screen/audio navigation and coverage must be measured together. Quiet or deferred work cannot disappear from the denominator.

### Required verification and delivery boundary

The performance policy requires pinned matched workloads, at least three complete baseline/candidate pairs, zero critical-token/source/navigation errors, no hidden gaps or growing backlog, and explicit unavailable energy/helper measurements. Governor promotion targets at least 50% lower active-use CPU, tracking progress toward 20% of one core; codec promotion needs at least 20% retained-byte savings without quality/latency regression. Clean debug and separate optimised builds follow protocol changes. The portable click-through documents and demonstrates interactions only; it is not a native release, performance repair or completion of these outstanding gates.

Source: [Full performance and promotion policy](sources/main-performance.html#L72), [Unified-history delivery gates](sources/main-unified-history.html), [Live acceptance limits](sources/live-markers.html).
