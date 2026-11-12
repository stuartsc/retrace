"""Bounded evidence-link expansion; model quality has separate native acceptance."""

import math
import sys
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch

from retrace_companion.context import LocalRanker, propose_context
from retrace_companion.contract import CompanionError, validate_result


class ContextExpansionTests(unittest.TestCase):
    def job(self, names):
        store = str(uuid.uuid4())
        observed = 1_800_000_000_000
        return {
            "version": 1,
            "kind": "context",
            "sourceStoreID": store,
            "observedAt": observed,
            "context": {
                "markerID": str(uuid.uuid4()),
                "markerRevision": str(uuid.uuid4()),
                "snapshotID": str(uuid.uuid4()),
                "query": "Preserve the decision and the supporting reasons",
                "verbatimExplanation": "Keep the explanation even if interrupted.",
                "developing": True,
                "incomplete": True,
                "evidence": [
                    {
                        "id": name,
                        "start": observed + (index - len(names)) * 600_000,
                        "end": observed + (index - len(names)) * 600_000 + 1_000,
                        "text": name,
                        "reference": {
                            "sourceStoreID": store,
                            "kind": "v23Transcript",
                            "v23Transcript": {
                                "version": 1,
                                "nativeStoreID": store,
                                "source": "microphone",
                                "rowID": index + 1,
                                "snapshotSHA256": "a" * 64,
                            },
                        },
                    }
                    for index, name in enumerate(names)
                ],
            },
        }

    def test_two_hop_supports_preserve_direct_priority_and_exact_evidence(self):
        names = ["decision", "confirmation", "earlier reason", "later reason", "noise"]
        job = self.job(names)
        queries = []

        def rank(query, texts):
            self.assertEqual(texts, names)
            queries.append(query)
            return {
                "decision": [1, 0.4, 0.92, 0.3, 0.1],
                "confirmation": [0.7, 1, 0.99, 0.9, 0.1],
            }.get(query, [0.94, 0.8, 0.1, 0.2, 0.1])

        proposal = propose_context(job, "a" * 64, rank=rank)
        self.assertEqual(
            [item["supportIDs"][0] for item in proposal["ranges"]], names[:4]
        )
        self.assertEqual(
            [item["score"] for item in proposal["ranges"]], [0.94, 0.8, 0.92, 0.8]
        )
        self.assertEqual(len(queries), 3)
        self.assertIn(
            "2 direct supports followed by 2 suggested two-hop supports",
            proposal["method"],
        )
        self.assertTrue(proposal["developing"])
        self.assertTrue(proposal["incomplete"])
        self.assertEqual(
            proposal["verbatimExplanation"], job["context"]["verbatimExplanation"]
        )
        # The actual wire validator checks each interval/text against its exact
        # supplied support; generated rationale cannot replace the excerpt.
        validate_result(
            {
                "version": 1,
                "jobID": "a" * 64,
                "kind": "context",
                "sourceStoreID": job["sourceStoreID"],
                "contextProposal": proposal,
            },
            job,
            "a" * 64,
        )

    def test_unrelated_and_indirect_evidence_cannot_become_expansion_seeds(self):
        job = self.job(["direct", "linked", "unrelated"])
        calls = []

        def rank(query, texts):
            calls.append(query)
            if len(calls) == 1:
                return [0.8, 0.1, 0.1]
            self.assertEqual(query, "direct")
            return [1.0, 0.9, 0.49]

        result = propose_context(job, "a" * 64, rank=rank)
        self.assertEqual(
            [r["supportIDs"] for r in result["ranges"]], [["direct"], ["linked"]]
        )
        self.assertEqual(len(calls), 2)

    def test_invalid_scores_in_either_hop_abort_without_a_partial_proposal(self):
        job = self.job(["direct", "other"])
        for invalid in (
            [math.nan, 0],
            [math.inf, 0],
            [-0.1, 0],
            [1.1, 0],
            [True, 0],
            ["bad", 0],
            [0.9],
        ):
            for failing_call in (1, 2):
                with self.subTest(invalid=invalid, failing_call=failing_call):
                    calls = 0

                    def rank(query, texts):
                        nonlocal calls
                        calls += 1
                        return invalid if calls == failing_call else [0.9, 0.1]

                    with self.assertRaisesRegex(CompanionError, "invalid_ranking"):
                        propose_context(job, "a" * 64, rank=rank)
                    self.assertEqual(calls, failing_call)

    def test_four_seed_and_sixteen_output_limits_are_deterministic(self):
        names = [f"source-{index:03}" for index in reversed(range(256))]
        job = self.job(names)
        calls = []

        def rank(query, texts):
            calls.append(query)
            if len(calls) == 1:
                return [0.8] * 6 + [0.1] * 250
            return [0.9] * 256

        result = propose_context(job, "a" * 64, rank=rank)
        self.assertEqual(calls[1:], sorted(names[:6])[:4])
        self.assertEqual(len(calls), 5)
        self.assertEqual(len(result["ranges"]), 16)
        self.assertEqual(
            [item["supportIDs"][0] for item in result["ranges"]],
            sorted(names[:6]) + sorted(names[6:])[:10],
        )

    def test_duplicate_seed_text_is_ranked_once_and_supports_are_unique(self):
        job = self.job(["first", "second", "reason"])
        job["context"]["evidence"][0]["text"] = "same decision"
        job["context"]["evidence"][1]["text"] = "same decision"
        calls = []

        def rank(query, texts):
            calls.append(query)
            return [0.9, 0.8, 0.1] if len(calls) == 1 else [1, 1, 0.9]

        result = propose_context(job, "a" * 64, rank=rank)
        self.assertEqual(len(calls), 2)
        self.assertEqual(
            [r["supportIDs"] for r in result["ranges"]],
            [["first"], ["second"], ["reason"]],
        )
        self.assertEqual(result["ranges"][2]["score"], 0.9)

    def test_no_expansion_without_a_direct_support_or_when_output_is_full(self):
        for count, relevance in ((0, 0.9), (3, 0.49), (20, 0.9)):
            with self.subTest(count=count, relevance=relevance):
                calls = []

                def rank(query, texts):
                    calls.append(query)
                    return [relevance] * len(texts)

                result = propose_context(
                    self.job([str(n) for n in range(count)]), "a" * 64, rank=rank
                )
                self.assertEqual(len(calls), int(count > 0))
                self.assertEqual(len(result["ranges"]), 16 if count == 20 else 0)


class LocalRankingScopeTests(unittest.TestCase):
    class Vectors:
        def __init__(self, count):
            self.count = count

        def __matmul__(self, other):
            return [1.0] * self.count

    def adapter(self):
        calls = []
        pairs = []
        adapter = LocalRanker()

        def encode(texts, **kwargs):
            calls.append(list(texts))
            if texts[0].startswith("Represent this sentence"):
                return [[0.0]]
            return self.Vectors(len(texts))

        def predict(candidates, **kwargs):
            pairs.append(candidates)
            return [2.0] * len(candidates)

        adapter.embedder = SimpleNamespace(encode=encode)
        adapter.reranker = SimpleNamespace(predict=predict)
        return adapter, calls, pairs

    def test_corpus_vectors_reused_inside_scope_and_not_across_snapshots(self):
        adapter, calls, pairs = self.adapter()
        texts = [f"passage-{index}" for index in range(256)]
        torch = SimpleNamespace(nn=SimpleNamespace(Identity=lambda: None))
        with patch.dict(sys.modules, {"torch": torch}):
            first = adapter.for_snapshot(texts)
            for query in (
                "initial question",
                "first support",
                "second support",
                "third support",
                "fourth support",
            ):
                scores = first(query, texts)
                self.assertEqual(len(scores), 256)
                self.assertEqual(sum(score > 0 for score in scores), 32)
            self.assertEqual(len(calls), 6)  # one corpus plus five queries
            self.assertEqual(sum(len(batch) for batch in pairs), 160)
            with self.assertRaisesRegex(CompanionError, "ranking_snapshot_changed"):
                first("changed", texts[::-1])
            second = adapter.for_snapshot(texts)
            second("new snapshot", texts)
            self.assertEqual(len(calls), 8)  # corpus is not retained by adapter

    def test_invalid_native_similarities_never_reach_the_reranker(self):
        adapter, _, pairs = self.adapter()
        torch = SimpleNamespace(nn=SimpleNamespace(Identity=lambda: None))

        class InvalidVectors:
            def __matmul__(self, other):
                return [math.nan]

        original_encode = adapter.embedder.encode
        adapter.embedder.encode = lambda texts, **kwargs: (
            original_encode(texts, **kwargs)
            if texts[0].startswith("Represent this sentence")
            else InvalidVectors()
        )
        with patch.dict(sys.modules, {"torch": torch}):
            rank = adapter.for_snapshot(["passage"])
            with self.assertRaisesRegex(CompanionError, "invalid_ranking"):
                rank("question", ["passage"])
        self.assertEqual(pairs, [])

    def test_bad_native_logits_fail_instead_of_becoming_valid_scores(self):
        adapter, _, _ = self.adapter()
        torch = SimpleNamespace(nn=SimpleNamespace(Identity=lambda: None))
        with patch.dict(sys.modules, {"torch": torch}):
            rank = adapter.for_snapshot(["passage"])
            for logits in ([math.nan], [math.inf], []):
                with self.subTest(logits=logits):
                    adapter.reranker.predict = lambda *args, **kwargs: logits
                    with self.assertRaisesRegex(CompanionError, "invalid_ranking"):
                        rank("question", ["passage"])


if __name__ == "__main__":
    unittest.main()
