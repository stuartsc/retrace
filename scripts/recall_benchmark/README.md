# Authored screen retrieval benchmark

This developer experiment compares the primary `DataAdapter.search` route with
local MiniLM embeddings, reciprocal-rank fusion and a BGE reranker. It does not
enable semantic search, a persistent index, model downloads, imported-store
indexing or an unattended worker in Retrace.

The retained v1 run has one known oracle defect: Q11 permits both the draft and
archived 42000 proposal, but its expected set names only the draft. An independent
audit recorded this before score inspection. Interpret the explicitly named
eleven-question unambiguous subset in the [validation ledger](../../docs/progressive-recall-validation.md#oracle-audit-before-score-inspection).
Keep the original twelve-question output unchanged; correcting the question or
labels requires a separately frozen v2 evaluation.

The corpus is eight authored JPEGs, with twelve questions fixed before ranking.
An independent reviewer inspected the six new JPEGs without seeing the renderer,
questions or benchmark code. The original two Cedar screens retain their prior
independent review. The frozen dataset includes exact amounts, approval negation,
a ticket identifier, a temporal boundary, an explicit app restriction, paraphrases
and an 18-word question ending in `"NOT GRANTED"`.

The Swift test decodes those exact JPEG bytes, runs real Vision, commits the OCR
to private in-memory SQLite, binds complete source/store/observation/frame/revision
references and computes each allowed pool before ranking. It validates references
through the real service and tests wrong-store, disconnected-source, excluded-app
and deleted-reference refusal. It cannot open an installed library or decode media.
The cross-source check is a native ID attributed to an unavailable Rewind source;
it is not a two-connected-store collision trial.

## Reproduce

Use the exact Python and package versions in `model-pins.json`, and an existing
Hugging Face cache containing the two pinned snapshots. The evaluator refuses
missing/mismatched artifacts and cannot download replacements. No cloud inference
is used. The cached artifacts total approximately 2.38 GB; those bytes are not
checked into Git.

From the checkout, create a new private directory under `/tmp` and export:

```sh
trial_dir=$(mktemp -d /tmp/retrace-recall-benchmark.XXXXXX)
RETRACE_TEST_DISABLE_FILE_LOGGING=1 \
RETRACE_RECALL_BENCHMARK_EXPORT="$trial_dir/export.json" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
nice -n 10 swift test --jobs 4 --disable-automatic-resolution \
  --filter ProgressiveRecallBenchmarkTests

RETRACE_BENCHMARK_MODEL_CACHE="$HOME/.cache/huggingface/hub" \
python3 -m unittest discover -s scripts/recall_benchmark -p 'test_*.py'

python3 scripts/recall_benchmark/benchmark.py run \
  --export "$trial_dir/export.json" \
  --export-sha256 '<exportSHA256 printed by the successful Swift test>' \
  --cache "$HOME/.cache/huggingface/hub" \
  --output "$trial_dir/results" --deadline 600
```

Only the selected benchmark tests are requested by this command. Full-suite runs
also need the repository's existing optional native/Whisper fixture configuration.
Never run concurrent SwiftPM commands or edit Swift sources while one is running.
The export and results directories refuse overwrite. Keep the export receipt with
its corresponding result; native UUIDs are freshly generated for each ingestion.
The retained run's complete [Vision export](../../docs/fixtures/progressive-recall/phase2d/vision-export.json)
and [measurement artifacts](../../docs/fixtures/progressive-recall/phase2d/measurement-20260916/)
are versioned for review. For that export, the required SHA256 is
`ff7fbb8f304d62d73c9415cffc6835995acef2f3e3676eb10d678b1b2a9e379f`.

## Fixed methods and measurement boundaries

- **Lexical full question:** unchanged question, production FTS AND/phrase
  semantics and primary BM25 order. Metadata is filtered but is not searchable
  body text in this baseline.
- **Lexical authored keywords:** a separately labelled, manually authored keyword
  query fixed in the dataset before scoring. These hints are not an implemented
  automatic question-rewriting feature.
- **Embedding:** `all-MiniLM-L6-v2`, 384-dimensional float32 vectors, attention-mask
  mean pooling and L2 normalization. No added prompt/prefix or metadata text.
  Main and chrome OCR are joined with a newline for the semantic input, while
  their original channels and full text stay in the export. Local chunks use at
  most 224 content tokens and 32 overlap, preferring line/sentence boundaries;
  special tokens remain inside the 256-token operating budget. Token IDs and
  original offsets are retained without decode/re-tokenize truncation. For long
  questions, mean over query-window best-passage cosine scores covers every window.
- **Fusion:** reciprocal-rank fusion of full-question lexical and embedding
  rankings with constant 60, keyed by the complete evidence reference. Ties use
  the frozen allowed-pool order. The authored keyword variant is not fed to fusion.
- **Reranked pool:** BGE cross-encoder scores every allowed candidate in the fused
  pool. Query and passage windows each use 224 tokens/32 overlap and a separately
  checked 512-token pair budget. The pinned model supports longer inputs, but this
  experiment deliberately uses the smaller operating cap. Maximum passage score
  per query window, then minimum across query windows; fusion only breaks ties.
  Scores express relevance, not approval, factual truth or answer correctness.

Models run in an owned subprocess: CPU only, two inference threads, one interop
thread, batch size four, eval/inference mode, float32 and deterministic algorithms.
The parent enforces a maximum ten-minute deadline and 12 GiB RSS ceiling, and drains
its owned process group on cancellation, timeout or exit. Model hashes are checked
before and after inference. The source, export, dataset, model pin and output hashes
are recorded. No captured/user content is sent to a model or included in this corpus.

Report Recall@1/@3/@5 and MRR against exact bound references. Eight screens do not
make recall@20 meaningful. The declared five-slot exact-match expansion reservation
is not exercised here: no expansion shortlist is implemented by this benchmark.
Repeated model rankings must agree across one initial plus three warm runs.
Lexical timings cover `DataAdapter.search`, excluding fixture ingestion, eligibility
construction and exact-reference validation. Their first sample is not cold process
or cold filesystem. Model load/index and worker-entry-to-first-result are separate
from per-question ranking timings. Peak RSS is the whole model worker's maximum;
index bytes include the vector array and exact-reference/chunk sidecar, not a
production database estimate.

These authored screens can expose mistakes and compare the fixed methods. They do
not establish broad question quality, production-scale speed, image reopening,
installed UI acceptance or safe durable derived-result admission. Production
readiness still requires the writer-owned policy/source fence and bounded index
integration described in the saved plan.

Primary model specifications: [MiniLM](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)
and [BGE reranker](https://huggingface.co/BAAI/bge-reranker-v2-m3).
