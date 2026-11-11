# Authored native MiniLM fixtures

These tests open authored text and explicitly supplied local model artifacts only.
They do not open a Retrace history, download a model, or activate a search index.

`tokenizer.json` is the unmodified tokenizer from
`sentence-transformers/all-MiniLM-L6-v2`, revision
`1110a243fdf4706b3f48f1d95db1a4f5529b4d41`, SHA-256
`be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037`.
The upstream model card declares Apache-2.0; see the accompanying license.
Its WordPiece vocabulary is derived from the uncased BERT vocabulary.

`tokenizer-oracle.json` records upstream tokenizers 0.22.1 IDs and original
UTF-16 ranges for 45 authored cases, including combining marks, unassigned
characters, control characters, supplementary Chinese, literal special tokens,
and long Unicode suffixes. Four explicit supplementary CJK boundary cases bind
the pinned Rust tokenizer's U+2B920 start (which differs from some BERT references).
Its windows come from the actual saved
`scripts/recall_benchmark/benchmark.py:chunk_inputs` implementation: 224-token
budget, 32-token overlap and nearby sentence/newline boundaries. No token is
truncated or decoded and retokenized.

`embedding-oracle.json` contains 24 float32 vectors from the hash-verified saved
PyTorch experiment: eight authored screens, twelve fixed questions and one long
question in four windows. Native tests compare component error, normalization
and all rankings on three runs. The original Q11 oracle ambiguity remains; rank
agreement does not establish that Q11 is an independently validated answer.

`transform.json` and `provenance.json` bind the tokenizer, boundary rules,
pooling/normalization and converted model inventory to the exact fixtures.
The original fixed-stride diagnostic oracle is retained outside the repository
and was not rewritten. Sentence boundaries change only its two long cases.

To run native model parity, supply `RETRACE_MINILM_MODEL_PACKAGE` as the explicit
local path to the pinned 89,935,805-byte `.mlpackage`. The model is not included
in this repository. Absent that variable, model-dependent tests report a skip;
tokenizer and artifact rejection tests still run. This is source/runtime
validation, not an installed app or production index acceptance result.
