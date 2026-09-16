"""Real tokenizer, file-integrity and owned-process regressions for the experiment."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

import benchmark


class RecallBenchmarkTests(unittest.TestCase):
    exported = benchmark.DATASET.parent / "vision-export.json"
    export_sha256 = "ff7fbb8f304d62d73c9415cffc6835995acef2f3e3676eb10d678b1b2a9e379f"

    @classmethod
    def setUpClass(cls):
        os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                          TOKENIZERS_PARALLELISM="false")
        from transformers import AutoTokenizer
        cache = Path(os.environ["RETRACE_BENCHMARK_MODEL_CACHE"])
        cls.tokenizer = AutoTokenizer.from_pretrained(
            cache / "models--sentence-transformers--all-MiniLM-L6-v2" / "snapshots" /
            "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
            local_files_only=True, trust_remote_code=False, use_fast=True)

    def test_real_tokenizer_preserves_late_negation_and_all_tokens_across_chunks(self):
        text = ("Cedar proposal review is pending.\n" * 90) + "Approval NOT GRANTED. 東京 🧠"
        tokens = self.tokenizer(text, add_special_tokens=False, truncation=False)["input_ids"]
        chunks = benchmark.chunk_inputs(text, self.tokenizer)
        self.assertGreater(len(chunks), 1)
        covered = set()
        for chunk in chunks:
            self.assertEqual(chunk["input_ids"], tokens[chunk["tokenStart"]:chunk["tokenEnd"]])
            self.assertLessEqual(len(chunk["input_ids"]), 224)
            self.assertEqual(chunk["text"], text[chunk["start"]:chunk["end"]])
            covered.update(range(chunk["tokenStart"], chunk["tokenEnd"]))
        self.assertEqual(covered, set(range(len(tokens))))
        self.assertIn("NOT GRANTED", chunks[-1]["text"])
        self.assertEqual(chunks[0]["start"], 0)
        self.assertEqual(chunks[-1]["end"], len(text))

    def test_chunking_is_bounded_and_rejects_nonprogressing_overlap(self):
        self.assertEqual(benchmark.chunk_inputs("", self.tokenizer), [])
        for budget, overlap in [(0, 0), (32, 32), (32, -1)]:
            with self.assertRaises(ValueError):
                benchmark.chunk_inputs("retained text", self.tokenizer, budget, overlap)
        text = "permission " * 240 + '"NOT GRANTED"'
        chunks = benchmark.chunk_inputs(text, self.tokenizer, 32, 8)
        self.assertGreater(chunks[-1]["tokenStart"], chunks[0]["tokenStart"])
        self.assertIn("NOT GRANTED", chunks[-1]["text"])

    def test_source_store_revision_and_selected_blocks_never_merge_by_frame_id(self):
        base = dict(storeID="00000000-0000-0000-0000-000000000001", source="native",
                    observationID="00000000-0000-0000-0000-000000000002",
                    frameID={"value": 7}, extractionRevision=0, blockIDs=[])
        variants = [base, dict(base, source="rewind"),
                    dict(base, storeID="00000000-0000-0000-0000-000000000003"),
                    dict(base, extractionRevision=2), dict(base, blockIDs=[0])]
        keys = [benchmark.evidence_key(ref) for ref in variants]
        ranked = benchmark.fuse_rankings([keys, list(reversed(keys))], keys)
        self.assertEqual(len(ranked), 5)
        self.assertEqual(set(ranked), set(keys))
        self.assertEqual(ranked[0], keys[0])  # Stable allowed-pool tie breaker.

    def test_actual_vision_export_refuses_changed_pool_or_self_rehashed_ocr(self):
        _, exported, refs = benchmark.load_export(self.exported, self.export_sha256)
        self.assertEqual(len(refs), 8)
        with tempfile.TemporaryDirectory(prefix="recall-export-pin-test-") as directory:
            changed = Path(directory) / "changed.json"
            for mutation in ("pool", "text", "source", "question"):
                altered = json.loads(json.dumps(exported))
                if mutation == "pool":
                    altered["questions"][-1]["allowedIDs"].append("maple-sent")
                elif mutation == "text":
                    screen = altered["screens"][0]
                    screen["mainText"] = "Changed OCR with matching self-reported digest"
                    screen["textSHA256"] = hashlib.sha256((screen["mainText"] + "\n" + screen["chromeText"]).encode()).hexdigest()
                elif mutation == "source":
                    altered["screens"][0]["ref"]["source"] = "rewind"
                else:
                    altered["questions"][5]["question"] = "Cedar proposal"
                changed.write_text(json.dumps(altered))
                with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                    benchmark.load_export(changed, self.export_sha256)

    def test_actual_export_rejects_wrong_result_reference_or_missing_safety_check(self):
        with tempfile.TemporaryDirectory(prefix="recall-export-shape-test-") as directory:
            changed = Path(directory) / "changed.json"
            for mutation in ("reference", "safety"):
                altered = json.loads(self.exported.read_text())
                if mutation == "reference":
                    altered["questions"][1]["fullQuestion"]["orderedRefs"][0]["extractionRevision"] += 1
                else:
                    altered["safetyChecks"] = {"unrelated": True}
                changed.write_text(json.dumps(altered))
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    benchmark.load_export(changed, benchmark.digest(changed))

    def test_fusion_refuses_stale_disallowed_or_duplicate_channel_members(self):
        for ranking in [["allowed", "deleted"], ["allowed", "allowed"]]:
            with self.assertRaises(ValueError):
                benchmark.fuse_rankings([ranking], ["allowed"])
        self.assertEqual(benchmark.fuse_rankings([[], ["b", "a"]], ["a", "b"]), ["b", "a"])

    def test_checksum_validates_real_file_then_refuses_same_size_change_and_escape(self):
        with tempfile.TemporaryDirectory(prefix="recall-pin-test-") as directory:
            root = Path(directory)
            path = root / "config.json"
            path.write_bytes(b'{"a":1}')
            manifest = {"config.json": {"bytes": path.stat().st_size,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}}
            benchmark.verify_files(root, manifest)
            path.write_bytes(b'{"a":2}')
            with self.assertRaises(ValueError):
                benchmark.verify_files(root, manifest)
            with self.assertRaises(ValueError):
                benchmark.verify_files(root, {"../config.json": manifest["config.json"]})

    def test_real_saved_tokenizer_refuses_an_unpinned_extra_loader_input(self):
        with tempfile.TemporaryDirectory(prefix="recall-tokenizer-pin-test-") as directory:
            root = Path(directory)
            self.tokenizer.save_pretrained(root)
            manifest = {str(path.relative_to(root)): {"bytes": path.stat().st_size,
                        "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                        for path in root.rglob("*") if path.is_file()}
            benchmark.verify_files(root, manifest)
            (root / "added_tokens.json").write_text('{"UNPINNED_TOKEN":30522}')
            with self.assertRaises(ValueError):
                benchmark.verify_files(root, manifest)

    def test_owned_timeout_stops_child_before_it_can_publish_late_output(self):
        with tempfile.TemporaryDirectory(prefix="recall-timeout-test-") as directory:
            root = Path(directory)
            script = root / "slow.py"
            script.write_text("import pathlib,time\ntime.sleep(1)\npathlib.Path(__file__).with_suffix('.late').write_text('late')\n")
            with (root / "run.log").open("w") as output:
                with self.assertRaises(TimeoutError):
                    benchmark.run_owned([sys.executable, str(script)], timeout=0.1,
                                        environment=os.environ.copy(), output=output)
            time.sleep(1.1)
            self.assertFalse(script.with_suffix(".late").exists())

    def test_owned_success_returns_actual_nonzero_exit_status(self):
        with tempfile.TemporaryFile(mode="w+") as output:
            result = benchmark.run_owned([sys.executable, "-c", "raise SystemExit(7)"],
                                         timeout=5, environment=os.environ.copy(), output=output)
        self.assertEqual(result, 7)

    def test_finished_parent_cannot_leave_a_child_ignoring_termination(self):
        with tempfile.TemporaryDirectory(prefix="recall-child-test-") as directory:
            root = Path(directory)
            child = root / "child.py"
            child.write_text("import pathlib,signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                             "pathlib.Path(__file__).with_suffix('.ready').touch()\ntime.sleep(1)\n"
                             "pathlib.Path(__file__).with_suffix('.late').touch()\n")
            parent = root / "parent.py"
            parent.write_text("import pathlib,subprocess,sys,time\np=pathlib.Path(__file__).with_name('child.py')\n"
                              "subprocess.Popen([sys.executable,str(p)])\n"
                              "while not p.with_suffix('.ready').exists(): time.sleep(.01)\n")
            with (root / "run.log").open("w") as output:
                self.assertEqual(benchmark.run_owned([sys.executable, str(parent)], timeout=5,
                                 environment=os.environ.copy(), output=output), 0)
            time.sleep(1.1)
            self.assertFalse(child.with_suffix(".late").exists())


if __name__ == "__main__":
    unittest.main()
