# Private Retrace companion candidate

This source candidate adds a durable transport and one model-owning worker to the
existing explicit audio worker. Private receiver/worker release `dc82049b…` was
deployed on 21 October with the `/retrace-companion` Tailscale route. Authentication
and routing passed with an empty queue. The first simultaneous startup exposed a
database initialization race; the source repair below is newer than that release.
The installed laptop app has not been connected. Outlook's service, voice enrollment
library, database and MCP route are unchanged. The delivery ledger is maintained in
[`docs/live-context-markers-plan.md`](../../docs/live-context-markers-plan.md).

The App publishes only explicit native evidence supplied by its current-policy
reader. There is no history scanner, cloud provider, arbitrary path endpoint,
remote command execution, automatic model download, or automatic speaker naming.

## Delivery and inference

- The App's private outbox retains exact request bytes, media objects, results,
  import receipts and acknowledgements. SHA-256 identifies immutable requests and
  objects. Construction performs no I/O. A process lock excludes another owner.
- The laptop sender admits at most 256 active jobs in its separate private
  `delivery.db`; completed/invalidated wire requests, results and receipts remain
  immutable history. Indexed source-start keysets retain a fixed import watermark.
  Source sample coverage uses exact UUID/continuity/sample bounds and a bounded VM
  budget. Pending jobs rotate through bounded passes so fresh failures cannot
  indefinitely starve older ready results. A one-time migration retains legacy
  files and exact bytes; offline readers open only published catalogs, without a
  network worker or competing spool lock.
- Context-sidecar V4 records explicit enable epochs. Only newly registered microphone
  manifests during an active epoch become eligible. Indexed reconciliation recovers
  missed callbacks, delayed first-pass text and queue pressure; it never enrolls
  pre-enable history. Original first-pass rows remain exact, revalidated proofs.
  Every uncovered PCM fragment publishes in one group transaction, preserving the
  full first-pass scope and exact AAC offsets. Reused overlap coverage retains job
  dependencies; revoked proofs cannot justify an all-covered result.
- The transport accepts bounded bearer-authenticated requests. Its default listener
  is `127.0.0.1:9013` on the primary spare Mac. The Swift client permits HTTPS or
  loopback HTTP through an explicitly configured private tunnel and refuses
  redirects. Its credential is independent of native MCP client grants.
- The receiver uses a private SQLite ledger (`application_id`, schema version 2),
  FULL synchronous commits, immutable result files and exact result-digest acks.
  A retry never overwrites conflicting data. A durable result left between file
  publication and the ledger commit is reused after restart.
- Initialization validates metadata and migrates within one transaction. A private
  process lock serializes first creation, with a one-second monotonic wait limit;
  a stalled owner cannot leave HTTP handlers or shutdown waiting indefinitely.
  The laptop spool publishes mode-0700 directories and single-link immutable files
  atomically, so concurrent offline readers do not observe intermediate permissions.
- One process lock admits inference. The queue selects the freshest eligible job;
  failed jobs retain a categorical reason and a 30-second retry delay. Audio jobs
  reuse immutable results when only first-pass text changes. Original first-pass
  text stays in the App request and its hash binds every enhancement.
- Microphone jobs are bounded to 60 seconds of exact UUID generation/continuity
  samples at 16 kHz. Verified AAC objects and their sample offsets remain separate
  from approximate wall-clock placement. Producers must choose exact source ranges;
  overlapping AAC files are alternatives, not proof of distinct speech.
- Context input is at most 256 source-qualified items from one paginated native
  snapshot. Pinned local BGE embeddings shortlist at most 32 candidates per query;
  the local BGE reranker first selects direct supports at relevance >= 0.5. Up to
  four highest-ranked direct excerpts then act as evidence-link queries over that
  same snapshot. A suggested two-hop support must meet 0.5 on both edges; newly
  suggested material never becomes another query. Repeated seed text is ranked
  once. This bounded expansion can recover an earlier reason for a later decision
  without recursively collecting unrelated material or imposing a time window.
- Context output retains direct supports first and at most 16 exact intervals in
  total. Its method reports the direct and suggested two-hop counts. A two-hop
  score is the weaker edge along its strongest admitted path, not a probability,
  confidence calibration, or proof that the excerpt is necessary. The worst case
  is five query embeddings and 160 reranker pairs; the corpus is embedded once per
  proposal and its vectors are not cached across jobs. A full direct result or no
  direct support skips expansion. Model token limits may bound ranking text; the
  complete supplied excerpt is retained. All choices remain reviewable proposals.
- Every proposal preserves the original explanation, snapshot/marker revisions,
  source IDs, exact references and developing/incomplete flags. Range IDs remain
  stable for the same marker/support pair. App imports check marker and range
  revisions inside SQLite and preserve manual/pinned ownership.
- The receiver admits at most 256 active jobs. After an exact result acknowledgement,
  it durably archives the original request and compacts its indexed delivery row.
  Historical request/result bytes, first-pass references and inference results stay
  available; retrying an acknowledged ID cannot enqueue another inference.
- Staged AAC has a 1 GiB/4096-object quota. Only copies created by this receiver are
  collected, after durable acknowledgement and an indexed check that no active job
  references their SHA. Original recordings remain on the laptop. A publication
  racing collection fails before admitting the new job and can reupload canonical
  bytes. Interrupted collection is idempotent. Unknown files are never deleted.
- Requests remain bounded to 768 KiB, results to 2 MiB and media objects to 16 MiB.
  New writes require 256 MiB free space plus their payload size. Historical text,
  result and receipt storage grows with retained history; the free-space check
  reports pressure instead of silently deleting historical results. The laptop's
  sender now uses `delivery.db` with the same active/history separation; its Swift
  runtime validation is pending the coordinated source build.

Known names remain suggestions. No held-out calibration receipt establishes 98%
precision for the reused Outlook matcher, so its labels remain `Speaker …`,
`Unknown speaker`, or `Overlapping voices`; candidate names are separate fields.
The importer rejects a known name smuggled into the anonymous label or a result
that asserts `automaticNamesCalibrated: true`.

## Manual host commands

Use the already installed primary-Mac Outlook environment. `runtime-pins.json`
records the package versions and model snapshot/file hashes observed read-only on
21 October 2026. Model loading uses verified local paths, `local_files_only=True`,
`trust_remote_code=False`, and offline environment flags. It never uses Outlook's
generic embedding selector, which can select a cloud provider.

```sh
# Supply RETRACE_COMPANION_TOKEN securely in the launch environment; do not put
# the token in a command argument, source file, log, or MCP configuration.
PYTHONPATH=scripts /Users/stuartbond/outlook/.venv/bin/python -m retrace_companion \
  serve --root /private/retrace-companion

# A separate explicitly owned process performs inference. --once performs one pass.
PYTHONPATH=scripts /Users/stuartbond/outlook/.venv/bin/python -m retrace_companion \
  worker --root /private/retrace-companion --outlook /Users/stuartbond/outlook
```

The deployed instance uses owned LaunchAgents; stopping the worker process
ends its model work. App shutdown cancels and joins its local HTTP/import work;
it does not revoke already durably accepted remote jobs. Running a manual command
does not install a launch service, route, credential or laptop App setting. Preserve
existing Outlook `9011/mcp` and native MCP `9012/retrace-mcp`
routes when updating the deployment. The laptop's native command bridge also
uses 9013 on a different host and is not this service.

## App integration contract

`CompanionEnrichmentService` requires the canonical native store UUID, a private
root, a transport, an awaited current-policy/exact-reference revalidator, and an
idempotent importer. Import callbacks must use `result.jobID` for replay because
a process crash can follow their durable write before the local receipt. The
included context importer is idempotent for unchanged proposed ranges, uses
optimistic source revalidation and transactional marker/range revision checks,
and never overwrites user-owned ranges. Presentation calls `retainedResult`,
which revalidates again; a durable result is not a lasting disclosure permission.

The App coordinator must explicitly own configuration, publication admission,
current-policy evidence pages, speaker presentation and a bounded synchronization
schedule. This transport source alone does not make installed Live cards update.
When offline, requests remain in the outbox and first-pass transcripts remain
available. A failed context import cannot alter recording or canonical transcripts.

## Verification

```sh
PYTHONPATH=scripts /Users/stuartbond/outlook/.venv/bin/python \
  -m unittest discover -s scripts/retrace_companion/tests -v
PYTHONPATH=scripts /Users/stuartbond/outlook/.venv/bin/python \
  -m unittest discover -s scripts/audio_worker/tests -v
ruff check scripts/retrace_companion scripts/audio_worker
ruff format --check scripts/retrace_companion scripts/audio_worker
```

At the context-expansion checkpoint, 39 companion tests pass, including nine
selection/budget/invalid-score regressions with authored ranker outputs. The
unchanged four-case native corpus previously selected 9 of 13 expected supports
with direct-only ranking; the new two-hop implementation still requires a separate
native relevance run against that frozen oracle. The previous separate
audio-worker checkpoint passed 16 tests. They use
private SQLite/files, a real loopback HTTP exchange and authored relevance scores;
the audio suite decodes real AAC fixtures. Archive, acknowledgement and collection
tests cover interrupted publication, active shared media references, low free space,
canonical-file preservation and durable replay. They establish delivery and validation
boundaries, not native BGE relevance, human speaker precision, long-running model
memory, energy, installed UI, or complete App integration. Deployed networking has
separate receipts; authored real-model acceptance is tracked independently in the ledger.
Swift tests are coordinated separately by the root agent and must be recorded
only after their build/test receipt exists.
