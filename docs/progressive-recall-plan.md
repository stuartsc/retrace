# Progressive recall with contextual capture and idle refinement

Saved: 2026-09-11.

**Status: proposed, awaiting Stuart's review.** This is the plan retained from the discussion. Saving and committing it does not authorize implementation or establish installation. Existing capture fixes and local trials are recorded separately in [CHANGELOG.md](../CHANGELOG.md).

## Summary

Build a system that **finds broadly, narrows systematically, and checks original evidence when needed**. A text-only agent should understand the visible application, document or conversation, its contents, and the activity those observations support.

Use Retrace for capture and factual evidence; extend the existing FuseIntel pipeline for retrieval and interpretation. Processing stays on your Macs, including the verified SSH-connected M3 Max. Allow up to **20 GB of additional model files across both machines**, with a small background budget even under Low Power Mode.

This capability is planned; the complete pipeline is not yet installed.

## 1. Preserve understandable, trustworthy evidence

- Introduce a versioned `ScreenObservation` containing capture time, source-frame references, visible windows and panes, document/conversation titles, grouped text, focus, supported changes and coverage limitations.
- Capture window metadata and bounded Accessibility information alongside the screenshot. Check for app/window changes during acquisition; uncertain ownership remains explicit. Historical processing must use saved context.
- Attribute text to its visible surface instead of assigning an entire display to the foreground application. Preserve headings, chat turns, table relationships and code where supported.
- Preserve context-only changes despite image deduplication. Later title or URL changes must not rewrite earlier observations.
- Produce structured evidence and self-contained readable text from the same record. Separate observed facts from inferred activity and visual descriptions; delimit captured content as untrusted source material.
- Identify evidence using store UUID, source kind and frame ID, with extraction revisions and block references. Retain originals and provenance when refinements change preferred text.
- Add a monotonic change feed covering new observations, revisions and deletions. FuseIntel consumes it through the existing read-only database connection, so improvements to old records become searchable.
- Retrace owns canonical observations and native OCR/audio refinements. FuseIntel owns derived alternatives and intelligence; it does not write into Retrace's database.

Historical records receive whatever context their retained evidence supports. Missing capture-time information must not be invented.

## 2. Find broadly, then increase precision

| Stage | Behaviour | Initial work budget |
|---|---|---|
| Find | Combine keyword, prefix, bounded typo/OCR variants, contextual metadata and local semantic matches. | 200 compact candidates per page |
| Narrow | Retrieve actual text and source context, compare against the question, group repeated captures, and rerank. | 20 candidates; up to 32,000 tokens |
| Inspect | Decode exact retained frames, rerun accurate OCR and use a local visual model for unresolved content or relationships. | Three frames per batch |

These are processing budgets, with continuation available—not limits on how far back the system can search.

- Preserve the complete question. Apply reliable time/source constraints during candidate selection, avoiding the current global shortlist that can discard relevant matches before filtering.
- Keep existing foreground-app filters compatible. A request such as “the Word document I saw” must also consider historical records with unknown content ownership, even when another app was foreground.
- During expansion, include up to ten nearby observations from the same surface within 30 seconds. Keep every underlying evidence reference when grouping repeated captures.
- Return excerpts, match reasons, source revisions, coverage and unresolved constraints. Distinguish unavailable sources from no matches; candidate counts must not imply exhaustive recall.
- Add dedicated screen-search, evidence-expansion and frame-inspection tools to the existing FuseIntel MCP service. Interactive inspection returns transient evidence; persistent refinement remains a separately owned background operation.
- Target initial indexed results within two seconds. Bound each deeper inspection request to 30 seconds, returning completed findings and per-frame status with a continuation tied to the search snapshot.

Use the cached **MiniLM** model for a separate local screen-vector index and the existing **BGE reranker**. Chunk within model limits while preserving full source text for expansion. MiniLM's documented input limit makes explicit chunking necessary. [MiniLM model documentation](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2)

Install **Qwen3-VL 8B Instruct Q4**, approximately 6.1 GB, on the helper first. Verify its Ollama runtime, pin the model digest, and use bounded context and output sizes. The helper service is currently unreachable; unavailable visual inference must produce an explicit limitation, with no cloud fallback. [Ollama model specification](https://ollama.com/library/qwen3-vl%3A8b-instruct)

## 3. Improve history when capacity is available

Create one resource coordinator covering OCR maintenance, audio refinement, embeddings and visual enrichment.

- Prioritise capture, dictation and fresh transcription/OCR, followed by requested searches, then unattended historical improvement.
- Admit unattended work after five minutes without input and 60 seconds of quiet workload on the executing Mac. Require AC power, normal memory pressure, nominal/fair thermal state, CPU utilisation below 50%, and fresh processing within its latency budget.
- Measure speech activity, accepted visual changes and queue age. An untouched keyboard during a meeting or video is insufficient evidence of spare capacity.
- Allow one heavy job per machine. Start with **10 seconds of computation per minute under Low Power Mode**, restricted to bounded OCR, audio and text work; allow 30 seconds per minute otherwise, including visual inference. Leave macOS power settings unchanged.
- Revoke local background admission when foreground processing needs capacity. Wire Whisper's abort callback to cancellation/deadline handling; use small checkpoints for operations that cannot stop promptly. Oversized audio work must be split or deferred, rather than repeatedly exhausting its budget.
- Give three scheduling slots to unresolved searches or weak evidence, then one to the oldest eligible historical work. Persist progress so restarts do not repeat completed sweeps.

Reuse the existing SSH dispatcher with one helper worker. Replace large batches and global process termination with job-specific ownership, source fingerprints, resumable results and renewable leases. Renew every five seconds independently of inference; stop admission after 15 seconds without renewal and reject stale results.

The helper receives only necessary media and context. Results return to the designated local writer, which validates source identity and revision before acceptance. A larger model or later pass does not automatically establish better accuracy.

Cap new helper staging at **5 GiB**, remove acknowledged media, and expire abandoned job media after 24 hours. Reconcile the existing approximately 4.1 GB results file separately before cleanup. Reuse unchanged text and embeddings; avoid permanent duplicate screenshots.

## 4. Delivery, validation and comparison

Implement in this order:

1. Context capture, immutable observations and revision feed.
2. Corrected broad retrieval, contextual expansion and local semantic indexing.
3. Shared resource scheduling, durable jobs and bounded helper transfers.
4. Visual inspection and measured idle refinement.

Bootstrap existing text in bounded pages, then enrich history progressively. Report indexing coverage. Source revisions invalidate stale derived results; evidence deletion propagates to mirrors, vectors and worker copies. Missing media remains distinct from deleted evidence.

Acceptance must include:

- **Text-only reconstruction:** real ChatGPT/Canvas, named and unsaved Word documents, overlapping windows, scrolling, renamed documents and same-title browser navigation.
- **Historical retrieval:** vague wording, misspellings, paraphrases, incorrect legacy foreground labels, repeated screens and searches requiring final screenshot inspection.
- **Evidence correctness:** exact-frame matching, partial visibility, conflicting refinements, missing recordings and no invented authorship or successful sending.
- **Recovery:** interrupted work, SSH loss, expired leases, duplicate results, revised/deleted sources and resumable indexing.
- **Performance:** matched before/after measurements of retrieval recall, attribution, OCR/audio accuracy, capture-to-search latency, dictation latency, memory and disk growth.

Require improved evidence quality without attribution regression, and no more than a 10% increase in foreground-processing p95 latency during the matched background-work trial.

Keep migrations additive and features independently switchable. Preserve the previous application and configuration for comparison. Update `CHANGELOG.md` and validation notes throughout; record a **Local trial** only after verifying installation and launch.
