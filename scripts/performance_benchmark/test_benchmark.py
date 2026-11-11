"""Acceptance rules and actual CLI orchestration, using only authored inputs."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import signal
import time
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import benchmark

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def session(cpu: float = 60, retained: int = 1000) -> dict:
    run = {
        "id": "run-1", "duration_seconds": 60, "recorded_seconds": 60,
        "screen_recorded_seconds": 60, "audio_recorded_seconds": 60,
        "screen_gap_seconds": 0, "audio_gap_seconds": 0,
        "process_cpu_seconds": cpu, "query_cpu_seconds": 1,
        "peak_rss_bytes": 1000000, "retained_bytes": retained,
        "index_bytes": 100, "model_bytes": 200,
        "energy_joules": None, "energy_scope": None,
        "backlog_start": 0, "backlog_end": 0,
        "oldest_pending_start_seconds": 0, "oldest_pending_end_seconds": 0,
        "processed_items": 100, "capture_attempts": 20,
        "reference_characters": 1000, "character_edits": 1,
        "reference_words": 100, "word_edits": 0,
        "critical_tokens": 10, "critical_token_errors": 0,
        "navigation_checks": 20, "wrong_navigation": 0,
        "timestamp_checks": 20, "timestamp_errors": 0,
        "source_checks": 20, "incorrect_sources": 0,
        "native_coverage": {name: True for name in benchmark.NATIVE_CHECKS},
        "latency_ms": {name: [10.0] * 20 for name in benchmark.LATENCIES},
        "latency_attempts": {name: 20 for name in benchmark.LATENCIES},
        "queries": [{"id": f"Q{i}", "expected": ["native:screen:1"],
                     "ranking": ["native:screen:1"]} for i in range(20)],
        "receipt_sha256": hashlib.sha256(f"{cpu}:{retained}:1".encode()).hexdigest(),
    }
    runs = [copy.deepcopy(run) for _ in range(3)]
    for i, row in enumerate(runs):
        row["id"] = f"run-{i + 1}"
        row["receipt_sha256"] = hashlib.sha256(f"{cpu}:{retained}:{i}".encode()).hexdigest()
    return {
        "schema_version": 1, "kind": "retrace-performance-session", "scope": "representative",
        "identity": {
            "source_sha256": "a" * 64, "corpus_sha256": "b" * 64,
            "workload_sha256": "c" * 64, "model_sha256": "d" * 64,
            "configuration": {"low_power_mode": True, "threads": 2},
            "hardware": {"model": "authored", "logical_cores": 10, "memory_bytes": 64 * 1024**3},
            "os": "authored-os", "build": "authored-build", "phase": "active-warm",
            "treatment": {"governor": "baseline"},
        },
        "runs": runs,
    }


class MeasurementTests(unittest.TestCase):
    def test_scoped_input_cannot_be_promoted_by_changing_report_label(self):
        base = benchmark.collect_session(session())
        raw = session(cpu=20)
        raw["scope"] = "scoped"
        candidate = benchmark.collect_session(raw)
        candidate["scope"] = "representative"
        with self.assertRaises(benchmark.ValidationError):
            benchmark.compare_reports(base, candidate, "cpu")

    def test_cpu_denominator_is_one_core_and_observed_time(self):
        result = benchmark.collect_session(session())
        row = result["runs"][0]["metrics"]
        self.assertEqual(row["app_cpu_percent_one_core"], 100)
        self.assertEqual(row["cpu_seconds_per_recorded_hour"], 3600)
        self.assertEqual(row["cpu_seconds_per_query"], 0.05)
        self.assertIsNone(row["energy_joules_per_recorded_hour"])
        self.assertEqual(row["retained_bytes_per_recorded_hour"], 60000)

    def test_zeros_are_real_measurements_but_denominators_must_be_positive(self):
        raw = session(cpu=0, retained=0)
        result = benchmark.collect_session(raw)
        self.assertEqual(result["runs"][0]["metrics"]["app_cpu_percent_one_core"], 0)
        for key in ("duration_seconds", "recorded_seconds", "reference_characters", "reference_words"):
            bad = copy.deepcopy(raw)
            bad["runs"][0][key] = 0
            with self.subTest(key=key), self.assertRaises(benchmark.ValidationError):
                benchmark.collect_session(bad)

    def test_invalid_nonfinite_negative_missing_and_boolean_rejected(self):
        for value in (float("nan"), float("inf"), 10**1000, 1e308, -1, "1", None, True):
            raw = session()
            raw["runs"][0]["process_cpu_seconds"] = value
            with self.subTest(value=value), self.assertRaises(benchmark.ValidationError):
                benchmark.collect_session(raw)
        raw = session()
        del raw["runs"][0]["process_cpu_seconds"]
        with self.assertRaises(benchmark.ValidationError):
            benchmark.collect_session(raw)

    def test_percentile_nearest_rank_includes_slow_samples(self):
        self.assertEqual(benchmark.percentile([0] * 18 + [99, 200], 95), 99)
        with self.assertRaises(benchmark.ValidationError):
            benchmark.percentile([], 95)
        with self.assertRaises(benchmark.ValidationError):
            benchmark.percentile([1], -1)

    def test_unicode_ranking_and_recall_use_complete_ids(self):
        metrics = benchmark.ranking_metrics([
            {"id": "Q💡", "expected": ["native:屏:1", "rewind:屏:1"],
             "ranking": ["other:屏:1", "native:屏:1"]},
            {"id": "Q'", "expected": ["native:2"], "ranking": []},
        ])
        self.assertEqual(metrics["recall_at_1"], 0)
        self.assertEqual(metrics["recall_at_3"], 0.25)
        self.assertEqual(metrics["mrr"], 0.25)
        with self.assertRaises(benchmark.ValidationError):
            benchmark.ranking_metrics([{"id": "q", "expected": [], "ranking": []}])
        with self.assertRaises(benchmark.ValidationError):
            benchmark.ranking_metrics([{"id": "q", "expected": ["a"], "ranking": ["a", "a"]}])

    def test_large_authored_query_set(self):
        queries = [{"id": str(i), "expected": [str(i)], "ranking": [str(i)]} for i in range(10000)]
        self.assertEqual(benchmark.ranking_metrics(queries)["mrr"], 1)

    def test_energy_has_explicit_measured_scope(self):
        raw = session()
        raw["runs"][0].update(energy_joules=100, energy_scope="whole_system")
        result = benchmark.collect_session(raw)
        self.assertEqual(result["runs"][0]["metrics"]["energy_joules_per_recorded_hour"], 6000)
        raw["runs"][0]["energy_scope"] = None
        with self.assertRaises(benchmark.ValidationError):
            benchmark.collect_session(raw)

    def test_receipt_identity_and_latency_lengths(self):
        for mutate in (
            lambda d: d["runs"][1].update(id="run-1"),
            lambda d: d["runs"][1].update(receipt_sha256=d["runs"][0]["receipt_sha256"]),
            lambda d: d["identity"].update(corpus_sha256="fake"),
            lambda d: d["runs"][0]["latency_ms"].update(capture_to_search=[]),
            lambda d: d["runs"][0].update(capture_attempts=21),
        ):
            raw = session()
            mutate(raw)
            with self.assertRaises(benchmark.ValidationError):
                benchmark.collect_session(raw)


class ComparisonTests(unittest.TestCase):
    def compare(self, baseline=None, candidate=None, profile="cpu"):
        return benchmark.compare_reports(benchmark.collect_session(baseline or session()),
                                         benchmark.collect_session(candidate or session(cpu=30)), profile)

    def test_all_attempt_denominators_and_initial_backlog_must_match(self):
        raw = session(cpu=30)
        raw["runs"][0]["latency_ms"]["foreground"] = [1] * 19
        with self.assertRaises(benchmark.ValidationError):
            self.compare(candidate=raw)
        raw["runs"][0]["latency_attempts"]["foreground"] = 19
        self.assertEqual(self.compare(candidate=raw)["status"], "not_comparable")
        for field in ("backlog_start", "oldest_pending_start_seconds"):
            base = session()
            base["runs"][0][field] = 100
            self.assertEqual(self.compare(baseline=base)["status"], "not_comparable")

    def test_receipts_cannot_be_reused_across_sides(self):
        base, raw = session(), session(cpu=30)
        raw["runs"][0]["receipt_sha256"] = base["runs"][2]["receipt_sha256"]
        self.assertEqual(self.compare(base, raw)["status"], "not_comparable")
        self.assertEqual(self.compare(base, base, "regression")["status"], "not_comparable")

    def test_improvement_in_one_cost_cannot_hide_other_resource_regressions(self):
        raw = session(cpu=6000, retained=500)
        self.assertEqual(self.compare(candidate=raw, profile="codec")["status"], "failed")
        for field in ("retained_bytes", "index_bytes", "model_bytes"):
            raw = session(cpu=30)
            raw["runs"][0][field] = 10**12
            self.assertEqual(self.compare(candidate=raw)["status"], "failed")

    def test_matched_three_runs_and_exact_thresholds_pass(self):
        result = self.compare()
        self.assertEqual(result["status"], "passed")
        self.assertTrue(result["stability"]["pass_power_3"])
        self.assertEqual(result["stability"]["passing_runs"], 3)
        raw = session(cpu=30)
        for row in raw["runs"]:
            row["latency_ms"]["foreground"] = [11] * 20
        self.assertEqual(self.compare(candidate=raw)["status"], "passed")
        self.assertEqual(self.compare(candidate=session(cpu=30.0001))["status"], "failed")

    def test_each_run_must_pass_not_just_average_or_best_attempt(self):
        raw = session(cpu=1)
        raw["runs"][1]["process_cpu_seconds"] = 40
        result = self.compare(candidate=raw)
        self.assertEqual(result["status"], "failed")
        self.assertTrue(result["stability"]["pass_at_3"])
        self.assertFalse(result["stability"]["pass_power_3"])

    def test_different_conditions_not_comparable_source_treatment_may_differ(self):
        for key, value in (("corpus_sha256", "e" * 64), ("workload_sha256", "e" * 64),
                           ("model_sha256", "e" * 64), ("configuration", {"threads": 4}),
                           ("hardware", {"model": "different"}), ("os", "other"), ("phase", "idle")):
            raw = session(cpu=30)
            raw["identity"][key] = value
            with self.subTest(key=key):
                self.assertEqual(self.compare(candidate=raw)["status"], "not_comparable")
        raw = session(cpu=30)
        raw["identity"].update(source_sha256="e" * 64, build="candidate", treatment={"governor": True})
        self.assertEqual(self.compare(candidate=raw)["status"], "passed")

    def test_missing_native_coverage_never_passes(self):
        raw = session(cpu=30)
        del raw["runs"][0]["native_coverage"]["aac"]
        self.assertEqual(self.compare(candidate=raw)["status"], "incomplete")
        raw["runs"][0]["native_coverage"]["aac"] = False
        self.assertEqual(self.compare(candidate=raw)["status"], "failed")

    def test_insufficient_runs_or_latency_samples_incomplete(self):
        raw = session(cpu=30)
        raw["runs"] = raw["runs"][:2]
        self.assertEqual(self.compare(candidate=raw)["status"], "incomplete")
        raw = session(cpu=30)
        raw["runs"][0]["latency_ms"]["foreground"] = [1] + [None] * 19
        self.assertEqual(self.compare(candidate=raw)["status"], "incomplete")

    def test_recording_gaps_backlog_and_critical_regressions_block(self):
        cases = [("audio_recorded_seconds", 0), ("screen_gap_seconds", 0.1),
                 ("screen_recorded_seconds", 59), ("backlog_end", 1),
                 ("oldest_pending_end_seconds", 1), ("critical_token_errors", 1),
                 ("wrong_navigation", 1), ("timestamp_errors", 1), ("incorrect_sources", 1),
                 ("character_edits", 2), ("word_edits", 1)]
        for key, value in cases:
            raw = session(cpu=1)
            raw["runs"][0][key] = value
            with self.subTest(key=key):
                self.assertEqual(self.compare(candidate=raw)["status"], "failed")

    def test_freshness_failures_remain_in_denominator(self):
        raw = session(cpu=30)
        raw["runs"][0]["latency_ms"]["capture_to_search"][0] = None
        result = self.compare(candidate=raw)
        self.assertEqual(result["status"], "incomplete")
        row = benchmark.collect_session(raw)["runs"][0]
        self.assertEqual(row["metrics"]["unfinished_captures"], 1)
        self.assertIsNone(row["metrics"]["capture_to_search_p95_ms"])

    def test_latency_target_boundaries(self):
        for key, limit, inclusive in (("capture_to_search", 10000, True),
                                      ("keyword", 100, False), ("result_display", 250, True)):
            for value, expected in ((limit, "passed" if inclusive else "failed"), (limit + .001, "failed")):
                raw = session(cpu=30)
                for row in raw["runs"]:
                    row["latency_ms"][key] = [value] * 20
                with self.subTest(key=key, value=value):
                    self.assertEqual(self.compare(candidate=raw)["status"], expected)

    def test_codec_savings_gate_and_decode_regression(self):
        self.assertEqual(self.compare(candidate=session(cpu=30, retained=800), profile="codec")["status"], "passed")
        self.assertEqual(self.compare(candidate=session(cpu=30, retained=801), profile="codec")["status"], "failed")
        raw = session(cpu=30, retained=700)
        raw["runs"][0]["latency_ms"]["archive_decode"] = [12] * 20
        self.assertEqual(self.compare(candidate=raw, profile="codec")["status"], "failed")

    def test_zero_baseline_cannot_claim_fractional_savings(self):
        candidate = session(cpu=0)
        for row in candidate["runs"]:
            row["receipt_sha256"] = hashlib.sha256((row["receipt_sha256"] + "independent").encode()).hexdigest()
        self.assertEqual(self.compare(session(cpu=0), candidate)["status"], "incomplete")
        self.assertEqual(self.compare(session(retained=0), session(cpu=30, retained=0), "codec")["status"], "incomplete")

    def test_missing_energy_explicitly_unknown_not_required_for_cpu(self):
        result = self.compare()
        self.assertEqual(result["energy_comparison"], "unavailable")
        base, candidate = session(), session(cpu=30)
        for row in base["runs"] + candidate["runs"]:
            row.update(energy_joules=1, energy_scope="whole_system")
        self.assertEqual(self.compare(base, candidate)["energy_comparison"], "measured_whole_system")

    def test_imported_scope_and_tampered_derived_metrics_cannot_pass(self):
        base = benchmark.collect_session(session())
        candidate = benchmark.collect_session(session(cpu=60))
        candidate["runs"][0]["metrics"]["cpu_seconds_per_recorded_hour"] = 0
        with self.assertRaises(benchmark.ValidationError):
            benchmark.compare_reports(base, candidate, "cpu")
        candidate = benchmark.collect_session(session(cpu=30))
        candidate["scope"] = "scoped-native-import"
        self.assertEqual(benchmark.compare_reports(base, candidate, "cpu")["status"], "incomplete")


class IOAndNativeTests(unittest.TestCase):
    def test_runner_records_source_and_artifact_pins_and_rejects_bad_pin(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "authored.py"
            script.write_text("print('authored corpus')\n")
            plan = {
                "schema_version": 1, "kind": "retrace-performance-run-plan",
                "pins": [{"path": str(script), "sha256": hashlib.sha256(script.read_bytes()).hexdigest(), "role": "source"}],
                "commands": [{"id": "sample", "argv": [sys.executable, str(script)], "timeout_seconds": 5}],
            }
            report = benchmark.run_plan(plan, root / "run")
            self.assertEqual(report["verified_pins"], plan["pins"])
            self.assertEqual(report["environment"]["logical_cores"], __import__("os").cpu_count())
            script.write_text("print('changed')\n")
            with self.assertRaises(benchmark.ValidationError):
                benchmark.run_plan(plan, root / "wrong-pin")
            self.assertFalse((root / "wrong-pin").exists())

    def test_cpu_acceptance_requires_active_phase(self):
        raw = session(cpu=30)
        raw["identity"]["phase"] = "idle-warm"
        base = session()
        base["identity"]["phase"] = "idle-warm"
        result = benchmark.compare_reports(benchmark.collect_session(base), benchmark.collect_session(raw), "cpu")
        self.assertEqual(result["status"], "incomplete")

    def test_empty_malformed_and_duplicate_command_plans_fail_before_launch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            command = {"id": "same", "argv": [sys.executable, "-c", "print('x')"], "timeout_seconds": 5}
            for commands in ([], [command, command], [None]):
                with self.assertRaises(benchmark.ValidationError):
                    benchmark.run_plan({"schema_version": 1, "kind": "retrace-performance-run-plan", "commands": commands}, root / "run")
                self.assertFalse((root / "run").exists())

    def test_invalid_native_exports_fail_cleanly(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "bad.json"
            for data in (None, [], {}, {"samples": []}):
                source.write_text(json.dumps(data))
                with self.assertRaises(benchmark.ValidationError):
                    benchmark.import_native(source, "ocr", "native-refined")

    def test_main_error_exit_and_scoped_success(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertEqual(benchmark.main(["collect", "--input", str(root / "missing"), "--output", str(root / "out")]), 2)
            path = root / "raw.json"
            path.write_text(json.dumps(session()))
            self.assertEqual(benchmark.main(["collect", "--input", str(path), "--output", str(root / "base")]), 0)
            self.assertEqual(benchmark.main(["compare", "--baseline", str(root / "base/report.json"), "--candidate", str(root / "base/report.json"),
                                             "--profile", "cpu", "--output", str(root / "fail")]), 1)
            self.assertEqual(benchmark.main(["import-native", "--input", str(ROOT / "docs/fixtures/responsiveness/2026-09-28/whisper-cancellation.json"),
                                             "--kind", "cancellation", "--output", str(root / "import")]), 0)

    def test_atomic_private_report_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "report"
            benchmark.write_report(out, benchmark.collect_session(session()))
            self.assertEqual(out.stat().st_mode & 0o777, 0o700)
            self.assertEqual((out / "report.json").stat().st_mode & 0o777, 0o600)
            self.assertIn("unavailable", (out / "report.md").read_text())
            before = (out / "report.json").read_bytes()
            with self.assertRaises(FileExistsError):
                benchmark.write_report(out, {"changed": True})
            self.assertEqual((out / "report.json").read_bytes(), before)

    def test_json_duplicate_keys_nonfinite_symlinks_and_size_bounds(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "input.json"
            for text in ('{"a":1,"a":2}', '{"a":NaN}'):
                source.write_text(text)
                with self.assertRaises(benchmark.ValidationError):
                    benchmark.read_json(source)
            source.write_text('{}')
            link = Path(temp) / "link.json"
            link.symlink_to(source)
            with self.assertRaises(benchmark.ValidationError):
                benchmark.read_json(link)
            source.write_text(' ' * (benchmark.MAX_INPUT_BYTES + 1))
            with self.assertRaises(benchmark.ValidationError):
                benchmark.read_json(source)

    def test_existing_native_exports_import_with_scope_and_missing_targets(self):
        cases = [
            ("ocr", "docs/fixtures/screen-text-quality/2026-09-20-authored-comparison.json", "native-refined", "ocr_cer"),
            ("whisper", "docs/fixtures/responsiveness/2026-09-28/whisper-comparison.json", "cpu_requested", "speech_wer"),
            ("speech", "docs/fixtures/responsiveness/2026-09-28/speech-comparison.json", "native", "speech_wer"),
            ("codec", "docs/fixtures/responsiveness/2026-09-28/codec-comparison.json", "aac_12000", "encoded_bytes"),
            ("cancellation", "docs/fixtures/responsiveness/2026-09-28/whisper-cancellation.json", None, "cancellation_p95_ms"),
            ("recall", "docs/fixtures/progressive-recall/phase2d/measurement-20260916/results.json", "embedding", "recall_at_1"),
        ]
        for kind, path, variant, metric in cases:
            with self.subTest(kind=kind):
                result = benchmark.import_native(ROOT / path, kind, variant)
                self.assertEqual(result["scope"], "scoped-native-import")
                self.assertFalse(result["acceptance_eligible"])
                self.assertIsNotNone(result["metrics"][metric])
                self.assertIsNone(result["metrics"]["capture_to_search_p95_ms"])
                self.assertIn("sha256", result["artifact"])
                self.assertTrue(result["limitations"])
        with self.assertRaises(benchmark.ValidationError):
            benchmark.import_native(ROOT / cases[0][1], "ocr", "missing")

    def test_recall_fusion_keeps_unmeasured_timing_unavailable(self):
        result = benchmark.import_native(ROOT / "docs/fixtures/progressive-recall/phase2d/measurement-20260916/results.json", "recall", "fusion")
        self.assertEqual(result["metrics"]["recall_at_1"], 1)
        self.assertIsNone(result["metrics"]["ranking_mixed_initial_warm_p95_ms"])

    def test_run_failure_and_changed_pin_preserve_receipts(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path = root / "source.txt"
            path.write_text("frozen")
            pin = {"path": str(path), "role": "source", "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            plan = {"schema_version": 1, "kind": "retrace-performance-run-plan", "pins": [pin], "commands": [
                {"id": "first", "argv": [sys.executable, "-c", "raise SystemExit(4)"], "timeout_seconds": 5},
                {"id": "second", "argv": [sys.executable, "-c", "print('should not run')"], "timeout_seconds": 5}]}
            result = benchmark.run_plan(plan, root / "failed")
            self.assertFalse(result["completed"])
            self.assertEqual(len(result["commands"]), 1)
            self.assertTrue((root / "failed/receipt/report.json").exists())
            plan["commands"] = [{"id": "changes", "argv": [sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).write_text('changed')", str(path)], "timeout_seconds": 5}]
            result = benchmark.run_plan(plan, root / "changed")
            self.assertFalse(result["completed"])
            self.assertIn("Pinned input changed", result["pin_error"])

    def test_validation_boundaries(self):
        for raw in (None, [], {}, {"schema_version": 9}):
            with self.assertRaises(benchmark.ValidationError):
                benchmark.collect_session(raw)
        for key, value in (("latency_ms", {}), ("native_coverage", []),
                           ("screen_recorded_seconds", 61), ("recorded_seconds", 61),
                           ("critical_token_errors", 11), ("energy_scope", "unverified")):
            raw = session()
            raw["runs"][0][key] = value
            with self.subTest(key=key), self.assertRaises(benchmark.ValidationError):
                benchmark.collect_session(raw)
        for queries in ([None], [{"id": "q", "expected": ["a"], "ranking": []}] * 2):
            with self.assertRaises(benchmark.ValidationError):
                benchmark.ranking_metrics(queries)
        with self.assertRaises(benchmark.ValidationError):
            benchmark.percentile([1], 101)
        with self.assertRaises(benchmark.ValidationError):
            benchmark.digest(float("nan"))
        with self.assertRaises(benchmark.ValidationError):
            benchmark.compare_reports({}, {}, "unknown")

    def test_cli_collect_compare_and_self_test_really_execute(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name, raw in (("baseline", session()), ("candidate", session(cpu=30))):
                path = root / f"{name}.json"
                path.write_text(json.dumps(raw))
                subprocess.run([sys.executable, str(HERE / "benchmark.py"), "collect", "--input", str(path),
                                "--output", str(root / name)], check=True, capture_output=True)
            compared = subprocess.run([sys.executable, str(HERE / "benchmark.py"), "compare", "--baseline",
                                      str(root / "baseline/report.json"), "--candidate", str(root / "candidate/report.json"),
                                      "--profile", "cpu", "--output", str(root / "comparison")], capture_output=True, text=True)
            self.assertEqual(compared.returncode, 0, compared.stderr)
            receipt = benchmark.self_test(root / "self-test")
            self.assertEqual(receipt["scope"], "runner-self-test")
            self.assertEqual(len(receipt["commands"]), 3)
            self.assertTrue(all(row["exit_code"] == 0 and row["output_sha256"] for row in receipt["commands"]))
            self.assertGreater(receipt["commands"][0]["elapsed_seconds"], 0)
            self.assertFalse(receipt["acceptance_eligible"])

    def test_signal_latch_restores_handlers_and_prevents_next_launch(self):
        previous = {signum: signal.getsignal(signum) for signum in (signal.SIGTERM, signal.SIGINT)}
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.txt"
            source.write_text("authored")
            plan = {"schema_version": 1, "kind": "retrace-performance-run-plan",
                    "pins": [{"role": "source", "path": str(source), "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}],
                    "commands": [{"id": "not-started", "argv": [sys.executable, "-c", "print('must not run')"], "timeout_seconds": 5}]}
            with benchmark.ExecutionInterruption() as interruption:
                signal.raise_signal(signal.SIGTERM)
                signal.raise_signal(signal.SIGINT)
                result = benchmark.run_plan(plan, root / "scratch", interruption)
                self.assertEqual(interruption.signum, signal.SIGTERM)
                self.assertEqual(result["commands"], [])
                self.assertFalse(result["completed"])
                self.assertEqual(result["interrupted_signal"], signal.SIGTERM)
                self.assertFalse((root / "scratch/not-started.log").exists())
        for signum, handler in previous.items():
            self.assertEqual(signal.getsignal(signum), handler)

    def test_cli_signal_stops_owned_process_group_and_keeps_receipt(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                child = root / "child.py"
                child.write_text(
                    "import json,os,subprocess,sys,time\n"
                    "from pathlib import Path\n"
                    "worker=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\n"
                    "Path(sys.argv[1]).write_text(json.dumps({'leader':os.getpid(),'descendant':worker.pid}))\n"
                    "time.sleep(60)\n"
                )
                plan = {
                    "schema_version": 1, "kind": "retrace-performance-run-plan",
                    "pins": [{"path": str(child), "role": "source", "sha256": hashlib.sha256(child.read_bytes()).hexdigest()}],
                    "commands": [
                        {"id": "held", "argv": [sys.executable, str(child), "{scratch}/pids.json"], "timeout_seconds": 30},
                        {"id": "forbidden", "argv": [sys.executable, "-c", "print('must not run')"], "timeout_seconds": 5},
                    ],
                }
                plan_path = root / "plan.json"
                plan_path.write_text(json.dumps(plan))
                runner = subprocess.Popen([sys.executable, str(HERE / "benchmark.py"), "run", "--plan", str(plan_path),
                                           "--scratch", str(root / "scratch")], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                pids = {}
                try:
                    deadline = time.monotonic() + 10
                    pid_path = root / "scratch/pids.json"
                    while not pid_path.exists() and time.monotonic() < deadline and runner.poll() is None:
                        time.sleep(.01)
                    self.assertTrue(pid_path.exists(), "Authored child must start before the interruption")
                    pids = json.loads(pid_path.read_text())
                    runner.send_signal(signum)
                    output, error = runner.communicate(timeout=5)
                    receipt_path = root / "scratch/receipt/report.json"
                    self.assertTrue(receipt_path.exists(), f"Interrupted receipt missing: {output!r} {error!r}")
                    receipt = json.loads(receipt_path.read_text())
                    self.assertEqual(runner.returncode, 128 + signum)
                    self.assertFalse(receipt["completed"])
                    self.assertEqual(receipt["interrupted_signal"], signum)
                    self.assertEqual(len(receipt["commands"]), 1)
                    self.assertEqual(receipt["commands"][0]["interrupted_signal"], signum)
                    self.assertEqual(receipt["commands"][0]["exit_code"], -signal.SIGKILL)
                    self.assertFalse((root / "scratch/forbidden.log").exists())
                    for name, pid in pids.items():
                        deadline = time.monotonic() + 3
                        while time.monotonic() < deadline:
                            state = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
                            if not state.stdout.strip() or state.stdout.strip().startswith("Z"):
                                break
                            time.sleep(.02)
                        self.assertTrue(not state.stdout.strip() or state.stdout.strip().startswith("Z"), f"{name} still running")
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pids["leader"], 0)
                finally:
                    if runner.poll() is None:
                        runner.kill()
                    runner.communicate(timeout=5)
                    if pids:
                        try:
                            os.killpg(pids["leader"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_runner_failure_timeout_and_manifest_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            spec = {"id": "fail", "argv": [sys.executable, "-c", "raise SystemExit(7)"], "timeout_seconds": 5}
            receipt = benchmark.execute_command(spec, root)
            self.assertEqual(receipt["exit_code"], 7)
            spec = {"id": "sleep", "argv": [sys.executable, "-c", "import time; time.sleep(5)"], "timeout_seconds": .02}
            self.assertTrue(benchmark.execute_command(spec, root)["timed_out"])
            for bad in ("../escape", "/absolute", "", "a/b"):
                spec["id"] = bad
                with self.assertRaises(benchmark.ValidationError):
                    benchmark.execute_command(spec, root)


if __name__ == "__main__":
    unittest.main()
