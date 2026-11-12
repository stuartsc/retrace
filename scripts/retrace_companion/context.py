"""Bounded local semantic selection of exact evidence intervals, never a fixed time window."""

from __future__ import annotations

import math
import os
import uuid
import hashlib
import importlib.metadata
import json
from pathlib import Path
from audio_worker.runtime import configure_torch_runtime

from .contract import CompanionError, validate_job


MIN_RELEVANCE = 0.5
MAX_CONTEXT_RANGES = 16
MAX_EXPANSION_SEEDS = 4
MAX_RERANK_CANDIDATES = 32


def _validated_scores(rank, query, texts):
    scores = list(rank(query, texts))
    if len(scores) != len(texts) or any(
        type(score) not in (int, float)
        or not math.isfinite(score)
        or not 0 <= score <= 1
        for score in scores
    ):
        raise CompanionError("invalid_ranking")
    return scores


def _context_selection(query, evidence, rank):
    """One expansion hop from direct supports, never recursive evidence promotion."""
    if not evidence:
        return []
    texts = [item["text"] for item in evidence]
    # The production adapter prepares immutable corpus vectors once for this
    # proposal. Simple callable rankers remain usable by deterministic fixtures.
    prepare = getattr(rank, "for_snapshot", None)
    snapshot_rank = prepare(texts) if prepare is not None else rank
    direct_scores = _validated_scores(snapshot_rank, query, texts)
    ordered = sorted(
        range(len(evidence)),
        key=lambda index: (-direct_scores[index], evidence[index]["id"]),
    )
    direct = [index for index in ordered if direct_scores[index] >= MIN_RELEVANCE]
    selected = [(direct_scores[index], evidence[index], False) for index in direct]
    if len(selected) >= MAX_CONTEXT_RANGES:
        return selected[:MAX_CONTEXT_RANGES]

    indirect_scores = {}
    direct_set = set(direct)
    ranked_queries = {query}
    for seed in direct[:MAX_EXPANSION_SEEDS]:
        if texts[seed] in ranked_queries:
            continue
        ranked_queries.add(texts[seed])
        edges = _validated_scores(snapshot_rank, texts[seed], texts)
        for index, relevance in enumerate(edges):
            if index in direct_set or relevance < MIN_RELEVANCE:
                continue
            # This is the weakest relevance edge in a two-hop path, not a
            # calibrated probability or proof that the material is necessary.
            path_score = min(direct_scores[seed], relevance)
            indirect_scores[index] = max(indirect_scores.get(index, 0), path_score)
    indirect = sorted(
        indirect_scores,
        key=lambda index: (-indirect_scores[index], evidence[index]["id"]),
    )
    selected.extend(
        (indirect_scores[index], evidence[index], True) for index in indirect
    )
    return selected[:MAX_CONTEXT_RANGES]


def propose_context(job, job_id, *, rank):
    validate_job(job)
    source = job["context"]
    evidence = source["evidence"]
    query = source["query"] + "\n" + source["verbatimExplanation"]
    selected = _context_selection(query, evidence, rank)
    ranges = []
    for score, item, _ in selected:
        ranges.append(
            {
                "id": str(
                    uuid.uuid5(
                        uuid.NAMESPACE_URL, source["markerID"] + ":" + item["id"]
                    )
                ),
                "start": item["start"],
                "end": item["end"],
                "supportIDs": [item["id"]],
                "score": score,
                "explanation": item["text"]
                if len(item["text"].encode()) <= 4096
                else "Local semantic ranking selected exact supporting evidence "
                + item["id"]
                + ". The complete excerpt is retained with the proposal.",
            }
        )
    return {
        key: source[key]
        for key in (
            "markerID",
            "markerRevision",
            "snapshotID",
            "verbatimExplanation",
            "developing",
            "incomplete",
        )
    } | {
        "ranges": ranges,
        "method": (
            f"local BGE: {sum(not indirect for _, _, indirect in selected)} direct supports "
            f"followed by {sum(indirect for _, _, indirect in selected)} suggested two-hop supports; "
            "at most four direct seeds; scores are direct or weakest-path relevance, not certainty"
        ),
    }


class LocalRanker:
    """Reuses already cached spare-Mac models. Explicit local paths and offline flags prevent downloads."""

    def __init__(self, cache=None):
        self.cache = cache or Path.home() / ".cache/huggingface/hub"
        self.embedder = None
        self.reranker = None

    def _snapshot(self, name):
        pins = json.loads(Path(__file__).with_name("runtime-pins.json").read_text())
        for package, version in pins["packages"].items():
            if importlib.metadata.version(package) != version:
                raise CompanionError("runtime_version_mismatch")
        root = self.cache / ("models--" + name.replace("/", "--"))
        model = pins["models"][name]
        revision = model["revision"]
        path = root / "snapshots" / revision
        if not path.is_dir():
            raise CompanionError("model_unavailable")
        for relative, expected in model["files"].items():
            digest = hashlib.sha256()
            with (path / relative).open("rb") as reader:
                while chunk := reader.read(1024 * 1024):
                    digest.update(chunk)
            if digest.hexdigest() != expected:
                raise CompanionError("model_digest_mismatch")
        return path

    def _ensure_models(self):
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        os.environ["OMP_NUM_THREADS"] = "2"
        if self.embedder is None:
            configure_torch_runtime()
            from sentence_transformers import SentenceTransformer, CrossEncoder

            embedder = SentenceTransformer(
                str(self._snapshot("BAAI/bge-base-en-v1.5")),
                local_files_only=True,
                trust_remote_code=False,
                device="cpu",
            )
            reranker = CrossEncoder(
                str(self._snapshot("BAAI/bge-reranker-v2-m3")),
                local_files_only=True,
                trust_remote_code=False,
                device="cpu",
            )
            self.embedder, self.reranker = embedder, reranker

    def for_snapshot(self, texts):
        """Return one bounded, in-memory ranking scope; no cross-job text cache."""
        self._ensure_models()
        corpus = tuple(texts)
        vectors = self.embedder.encode(
            list(corpus),
            normalize_embeddings=True,
            batch_size=16,
            show_progress_bar=False,
        )

        def rank(query, candidates):
            if tuple(candidates) != corpus:
                raise CompanionError("ranking_snapshot_changed")
            import torch

            query_vector = self.embedder.encode(
                ["Represent this sentence for searching relevant passages: " + query],
                normalize_embeddings=True,
                batch_size=1,
                show_progress_bar=False,
            )[0]
            similarities = vectors @ query_vector
            if len(similarities) != len(corpus) or any(
                not math.isfinite(float(value)) for value in similarities
            ):
                raise CompanionError("invalid_ranking")
            selected = sorted(
                range(len(corpus)),
                key=lambda index: (-float(similarities[index]), index),
            )[:MAX_RERANK_CANDIDATES]
            logits = self.reranker.predict(
                [(query, corpus[index]) for index in selected],
                batch_size=4,
                show_progress_bar=False,
                activation_fn=torch.nn.Identity(),
            )
            if len(logits) != len(selected):
                raise CompanionError("invalid_ranking")
            scores = [0.0] * len(corpus)
            for index, logit in zip(selected, logits):
                value = float(logit)
                if not math.isfinite(value):
                    raise CompanionError("invalid_ranking")
                value = max(-60.0, min(60.0, value))
                scores[index] = 1.0 / (1.0 + math.exp(-value))
            return scores

        return rank

    def __call__(self, query, texts):
        if not texts:
            return []
        return self.for_snapshot(texts)(query, texts)
