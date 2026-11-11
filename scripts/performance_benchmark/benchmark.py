#!/usr/bin/env python3
"""Offline, versioned Retrace performance receipts and conservative comparisons.

Python 3.11+, standard library only. Does not inspect a production library, invoke
models, download assets or start SwiftPM unless explicitly present in a run plan.
"""
from __future__ import annotations

import argparse
from collections.abc import Sequence
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import resource
import signal
import stat
import subprocess
import sys
import time
from typing import Any

SCHEMA_VERSION = 1
MAX_INPUT_BYTES = 32 * 1024 * 1024
MAX_ITEMS = 100000
MIN_RUNS = 3
MIN_LATENCY_SAMPLES = 20
NATIVE_CHECKS = (
    "vision", "aac", "sqlite", "archive", "screen_capture", "archive_readability",
    "sleep_wake", "restart", "exclusions", "low_disk", "deletion_during_read",
    "failed_writes", "shutdown_pending",
)
LATENCIES = (
    "capture_to_search", "keyword", "result_display", "foreground", "cancellation",
    "archive_encode", "archive_decode", "random_seek",
)
MATCHED_IDENTITIES = (
    "corpus_sha256", "workload_sha256", "model_sha256", "configuration", "hardware", "os", "phase",
)
POSITIVE_COUNTERS = (
    "reference_characters", "reference_words", "critical_tokens", "navigation_checks",
    "timestamp_checks", "source_checks", "capture_attempts",
)
COUNTERS = POSITIVE_COUNTERS + (
    "character_edits", "word_edits", "critical_token_errors", "wrong_navigation", "timestamp_errors",
    "incorrect_sources", "peak_rss_bytes", "retained_bytes", "index_bytes", "model_bytes",
    "backlog_start", "backlog_end", "processed_items",
)
SECONDS = (
    "duration_seconds", "recorded_seconds", "screen_recorded_seconds", "audio_recorded_seconds",
    "screen_gap_seconds", "audio_gap_seconds", "process_cpu_seconds", "query_cpu_seconds",
    "oldest_pending_start_seconds", "oldest_pending_end_seconds",
)


class ValidationError(ValueError):
    """Malformed, ambiguous or unbounded benchmark input."""


def number(value: Any, name: str, *, positive: bool = False, integer: bool = False) -> float:
    """Require a finite, nonnegative measured quantity without coercing booleans."""
    if isinstance(value, bool) or not isinstance(value, (float, int)):
        raise ValidationError(f"{name}: expected a measured number")
    try:
        finite = math.isfinite(value)
    except OverflowError as error:
        raise ValidationError(f"{name}: value exceeds finite measurement range") from error
    if not finite or value < 0 or (positive and value == 0):
        raise ValidationError(f"{name}: expected a finite {'positive' if positive else 'nonnegative'} value")
    if integer and not isinstance(value, int):
        raise ValidationError(f"{name}: expected an integer count")
    return float(value)


def text(value: Any, name: str) -> str:
    """Validate a bounded nonempty label, without normalizing evidence identity."""
    if not isinstance(value, str) or not value.strip() or len(value) > 4096 or "\x00" in value:
        raise ValidationError(f"{name}: expected a nonempty bounded string")
    return value


def digest(value: Any) -> str:
    """Hash canonical JSON, rejecting NaN rather than serializing fake measurements."""
    try:
        data = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    except (ValueError, TypeError) as error:
        raise ValidationError("Input is not finite JSON") from error
    return hashlib.sha256(data.encode()).hexdigest()


def sha256(value: Any, name: str) -> str:
    """Require a complete lowercase SHA256 receipt."""
    if not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{64}", value) is None:
        raise ValidationError(f"{name}: SHA256 required")
    return value


def read_bytes(path: Path) -> bytes:
    """Read a bounded regular input, refusing a final symlink and concurrent growth."""
    if path.is_symlink():
        raise ValidationError("Input symlinks are not supported")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_INPUT_BYTES:
            raise ValidationError("Input must be a bounded regular file")
        data = stream.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ValidationError("Input exceeds maximum size")
    return data


def _unique_object(pairs: list[tuple[str, Any]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise ValidationError(f"Nonfinite JSON value: {value}")


def read_json(path: Path) -> Any:
    """Decode bounded JSON without duplicate keys or nonfinite numbers."""
    try:
        return json.loads(read_bytes(path), object_pairs_hook=_unique_object, parse_constant=_reject_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValidationError(f"Invalid JSON in {path.name}") from error


def items(value: Any, name: str, *, allow_empty: bool = False) -> list:
    """Validate bounded JSON collections before computation."""
    if not isinstance(value, list) or len(value) > MAX_ITEMS or (not value and not allow_empty):
        raise ValidationError(f"{name}: expected a bounded {'possibly empty' if allow_empty else 'nonempty'} array")
    return value


def percentile(values: Sequence[float], percent: float) -> float:
    """Nearest-rank percentile; no interpolation or removal of slow observations."""
    number(percent, "percentile", positive=True)
    if percent > 100:
        raise ValidationError("Percentile exceeds 100")
    samples = [number(value, "sample") for value in items(list(values), "samples")]
    samples.sort()
    return samples[math.ceil(percent / 100 * len(samples)) - 1]


def ranking_metrics(queries: list[dict]) -> dict[str, float]:
    """Macro Recall@1/3/5 and MRR over exact source-qualified opaque identities."""
    totals = {"recall_at_1": 0.0, "recall_at_3": 0.0, "recall_at_5": 0.0, "mrr": 0.0}
    ids = set()
    for query in items(queries, "queries"):
        if not isinstance(query, dict):
            raise ValidationError("Query must be an object")
        identifier = text(query.get("id"), "query id")
        if identifier in ids:
            raise ValidationError("Duplicate query id")
        ids.add(identifier)
        expected = items(query.get("expected"), "expected ids")
        ranking = items(query.get("ranking"), "ranked ids", allow_empty=True)
        for entry in expected + ranking:
            text(entry, "evidence id")
        if len(set(expected)) != len(expected) or len(set(ranking)) != len(ranking):
            raise ValidationError("Duplicate evidence identity")
        wanted = set(expected)
        for k in (1, 3, 5):
            totals[f"recall_at_{k}"] += len(wanted.intersection(ranking[:k])) / len(wanted)
        rank = next((i for i, entry in enumerate(ranking, 1) if entry in wanted), None)
        totals["mrr"] += 1 / rank if rank else 0
    return {name: value / len(queries) for name, value in totals.items()}


def _validate_identity(identity: Any) -> None:
    if not isinstance(identity, dict):
        raise ValidationError("identity object required")
    for key in ("source_sha256", "corpus_sha256", "workload_sha256", "model_sha256"):
        sha256(identity.get(key), key)
    for key in ("build", "os", "phase"):
        text(identity.get(key), key)
    for key in ("configuration", "hardware", "treatment"):
        if not isinstance(identity.get(key), dict) or not identity[key]:
            raise ValidationError(f"{key}: nonempty pinned object required")
    digest(identity)


def _run_metrics(run: dict) -> tuple[dict, list[dict]]:
    for key in COUNTERS:
        number(run.get(key), key, integer=True, positive=key in POSITIVE_COUNTERS)
    for key in SECONDS:
        number(run.get(key), key, positive=key in ("duration_seconds", "recorded_seconds"))
    if run["recorded_seconds"] > run["duration_seconds"]:
        raise ValidationError("Recorded wall time cannot exceed observation time; do not sum source durations")
    for key in ("screen_recorded_seconds", "audio_recorded_seconds"):
        if run[key] > run["duration_seconds"]:
            raise ValidationError("Per-stream coverage cannot exceed observation time")
    for errors, checks in (("critical_token_errors", "critical_tokens"), ("wrong_navigation", "navigation_checks"),
                           ("timestamp_errors", "timestamp_checks"), ("incorrect_sources", "source_checks")):
        if run[errors] > run[checks]:
            raise ValidationError(f"{errors} exceeds checked items")
    queries = items(run.get("queries"), "queries")
    metrics = ranking_metrics(queries)
    issues = []

    def issue(state: str, reason: str) -> None:
        issues.append({"status": state, "reason": reason})

    latency = run.get("latency_ms")
    attempts = run.get("latency_attempts")
    if not isinstance(latency, dict) or not isinstance(attempts, dict):
        raise ValidationError("latency_ms and latency_attempts objects required")
    for name in LATENCIES:
        samples = items(latency.get(name), name)
        expected_count = number(attempts.get(name), f"{name} attempts", positive=True, integer=True)
        if len(samples) != expected_count:
            raise ValidationError(f"Every {name} attempt requires a timing or explicit null outcome")
        if name == "capture_to_search" and len(samples) != run["capture_attempts"]:
            raise ValidationError("Every capture attempt requires a latency or explicit null outcome")
        if name in ("keyword", "result_display") and len(samples) != len(queries):
            raise ValidationError("Every query requires a timing or explicit null outcome")
        valid = [number(value, name) for value in samples if value is not None]
        metrics[f"{name}_p95_ms"] = percentile(valid, 95) if len(valid) == len(samples) else None
        if len(valid) < len(samples):
            issue("incomplete", f"{name}: {len(samples) - len(valid)} unfinished or unmeasured outcomes")
        if len(samples) < (1 if name == "cancellation" else MIN_LATENCY_SAMPLES):
            issue("incomplete", f"{name}: insufficient observations")
    metrics["unfinished_captures"] = run["latency_ms"]["capture_to_search"].count(None)
    coverage = run.get("native_coverage")
    if not isinstance(coverage, dict):
        raise ValidationError("native_coverage object required")
    for name in NATIVE_CHECKS:
        if name not in coverage or coverage[name] is None:
            issue("incomplete", f"Native {name} coverage unavailable")
        elif coverage[name] is False:
            issue("failed", f"Native {name} did not pass")
        elif coverage[name] is not True:
            raise ValidationError("Native coverage must be a boolean or null")
    for name in ("screen", "audio"):
        if run[f"{name}_recorded_seconds"] != run["duration_seconds"] or run[f"{name}_gap_seconds"] > 0:
            issue("failed", f"{name} recording coverage incomplete")
    if run["recorded_seconds"] != run["duration_seconds"]:
        issue("failed", "Recording did not cover the full observation interval")
    if run["backlog_end"] > run["backlog_start"]:
        issue("failed", "Pending work grew during observation")
    if run["oldest_pending_end_seconds"] > run["oldest_pending_start_seconds"]:
        issue("failed", "Oldest pending work aged during observation")
    if run["duration_seconds"] < 60:
        issue("incomplete", "Representative interval must contain at least 60 observed seconds")
    for key in ("critical_token_errors", "wrong_navigation", "timestamp_errors", "incorrect_sources"):
        if run[key] != 0:
            issue("failed", f"{key}: {run[key]}")
    energy = run.get("energy_joules")
    if "energy_joules" not in run or "energy_scope" not in run:
        raise ValidationError("Declare energy_joules and energy_scope explicitly, using null when unmeasured")
    if energy is None:
        if run["energy_scope"] is not None:
            raise ValidationError("Unmeasured energy cannot have a measured scope")
    else:
        number(energy, "energy_joules")
        if run["energy_scope"] not in ("whole_system", "owned_processes"):
            raise ValidationError("Measured energy requires an explicit supported scope")
    hours = run["recorded_seconds"] / 3600
    metrics.update({
        "ocr_cer": run["character_edits"] / run["reference_characters"],
        "speech_wer": run["word_edits"] / run["reference_words"],
        "critical_token_errors": run["critical_token_errors"], "wrong_navigation": run["wrong_navigation"],
        "timestamp_errors": run["timestamp_errors"], "incorrect_sources": run["incorrect_sources"],
        "unsupported_result_rate": run["incorrect_sources"] / run["source_checks"],
        "app_cpu_percent_one_core": 100 * run["process_cpu_seconds"] / run["duration_seconds"],
        "cpu_seconds_per_recorded_hour": run["process_cpu_seconds"] / hours,
        "cpu_seconds_per_query": run["query_cpu_seconds"] / len(queries),
        "peak_rss_bytes": run["peak_rss_bytes"], "retained_bytes_per_recorded_hour": run["retained_bytes"] / hours,
        "index_bytes": run["index_bytes"], "model_bytes": run["model_bytes"],
        "processed_items_per_second": run["processed_items"] / run["duration_seconds"],
        "energy_joules_per_recorded_hour": energy / hours if energy is not None else None,
    })
    digest(metrics)
    return metrics, issues


def collect_session(raw: dict) -> dict:
    """Validate a measured session and derive metrics; collecting never grants acceptance."""
    if not isinstance(raw, dict) or raw.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError("Unsupported session schema_version")
    if raw.get("kind") != "retrace-performance-session" or raw.get("scope") not in ("representative", "scoped"):
        raise ValidationError("Explicit performance session kind/scope required")
    _validate_identity(raw.get("identity"))
    rows = items(raw.get("runs"), "runs")
    seen_ids, seen_receipts, results = set(), set(), []
    for row in rows:
        if not isinstance(row, dict):
            raise ValidationError("Run must be an object")
        identifier = text(row.get("id"), "run id")
        receipt = sha256(row.get("receipt_sha256"), "run receipt")
        if identifier in seen_ids or receipt in seen_receipts:
            raise ValidationError("Runs need unique identifiers and independent receipts")
        seen_ids.add(identifier)
        seen_receipts.add(receipt)
        metrics, issues = _run_metrics(row)
        results.append({"id": identifier, "metrics": metrics, "issues": issues})
    return {
        "schema_version": SCHEMA_VERSION, "kind": "retrace-performance-scorecard",
        "scope": raw["scope"], "acceptance_eligible": raw["scope"] == "representative",
        "acceptance": "unaccepted; compare against a matched baseline and review native receipts",
        "identity": raw["identity"], "input_sha256": digest(raw), "input": raw, "runs": results,
        "limitations": ["Input receipts must be independently reviewed; this report is not installation or user acceptance.",
                        "CPU is actual process CPU time, not wall time or energy. Helpers are excluded unless the input explicitly includes them.",
                        "100% app CPU means one logical core. Retained bytes are workload deltas, not APFS reclaimable space."],
    }


def _verify_report(report: dict) -> dict:
    fresh = collect_session(report.get("input"))
    for field in ("schema_version", "kind", "scope", "identity", "input_sha256", "runs", "acceptance_eligible"):
        if report.get(field) != fresh[field]:
            raise ValidationError(f"Derived report was changed or is invalid: {field}")
    return fresh


def _workload_shape(row: dict) -> dict:
    return {**{key: row[key] for key in POSITIVE_COUNTERS},
            "duration_seconds": row["duration_seconds"],
            "backlog_start": row["backlog_start"],
            "oldest_pending_start_seconds": row["oldest_pending_start_seconds"],
            "latency_attempts": row["latency_attempts"],
            "queries": [(q["id"], q["expected"]) for q in row["queries"]]}


def compare_reports(baseline: dict, candidate: dict, profile: str = "regression") -> dict:
    """Require three complete matched repetitions; never promote imported fixtures."""
    if profile not in ("cpu", "codec", "regression"):
        raise ValidationError("Unknown comparison profile")
    result: dict[str, Any] = {"schema_version": SCHEMA_VERSION, "kind": "retrace-performance-comparison",
                              "profile": profile, "status": "incomplete", "reasons": [], "pairs": [],
                              "baseline_sha256": digest(baseline), "candidate_sha256": digest(candidate),
                              "energy_comparison": "unavailable", "stability": {"pass_at_1": False,
                              "pass_at_3": False, "pass_power_3": False, "passing_runs": 0}}
    if baseline.get("scope") != "representative" or candidate.get("scope") != "representative":
        result["reasons"].append("Only representative native sessions can pass promotion")
        return result
    base, new = _verify_report(baseline), _verify_report(candidate)
    if not base["acceptance_eligible"] or not new["acceptance_eligible"]:
        result["reasons"].append("Only representative native sessions can pass promotion")
        return result
    old_receipts = {row["receipt_sha256"] for row in base["input"]["runs"]}
    new_receipts = {row["receipt_sha256"] for row in new["input"]["runs"]}
    if old_receipts.intersection(new_receipts):
        result.update(status="not_comparable", reasons=["Baseline and candidate require independent, non-reused receipts"])
        return result
    mismatches = [key for key in MATCHED_IDENTITIES if base["identity"][key] != new["identity"][key]]
    if mismatches:
        result.update(status="not_comparable", reasons=[f"Different pinned conditions: {', '.join(mismatches)}"])
        return result
    if profile == "cpu" and base["identity"]["phase"] not in ("active-warm", "active-cold"):
        result["reasons"].append("CPU reduction requires a matched active-use workload")
        return result
    if len(base["runs"]) < MIN_RUNS or len(base["runs"]) != len(new["runs"]):
        result["reasons"].append("At least three independent matched runs on each side are required")
        return result
    states = []
    for old_input, new_input, old, current in zip(base["input"]["runs"], new["input"]["runs"], base["runs"], new["runs"]):
        if _workload_shape(old_input) != _workload_shape(new_input):
            result.update(status="not_comparable", reasons=["Run workload counts, timing coverage or query oracles changed"])
            return result
        issues = [dict(issue, side=side) for side, row in (("baseline", old), ("candidate", current)) for issue in row["issues"]]
        gates = []
        a, b = old["metrics"], current["metrics"]

        def gate(name: str, passed: bool | None, detail: str) -> None:
            state = "incomplete" if passed is None else "passed" if passed else "failed"
            gates.append({"name": name, "status": state, "detail": detail})

        for name, limit, inclusive in (("capture_to_search_p95_ms", 10000, True),
                                       ("keyword_p95_ms", 100, False), ("result_display_p95_ms", 250, True)):
            value = b[name]
            gate(name, None if value is None else value <= limit if inclusive else value < limit,
                 f"candidate={value}, required {'<=' if inclusive else '<'}{limit} ms")
        for name in ("foreground_p95_ms", "cancellation_p95_ms", "archive_encode_p95_ms", "archive_decode_p95_ms",
                     "random_seek_p95_ms", "cpu_seconds_per_query", "peak_rss_bytes"):
            gate(name, None if a[name] is None or b[name] is None else b[name] <= a[name] * 1.10 + 1e-12,
                 f"candidate={b[name]}, baseline={a[name]}, maximum regression=10%")
        for name in ("ocr_cer", "speech_wer"):
            gate(name, b[name] <= a[name], f"candidate={b[name]}, baseline={a[name]}; no error-rate regression")
        for name in ("recall_at_1", "recall_at_3", "recall_at_5", "mrr"):
            gate(name, b[name] >= a[name], f"candidate={b[name]}, baseline={a[name]}; no retrieval regression")
        if profile in ("cpu", "codec"):
            name = "cpu_seconds_per_recorded_hour" if profile == "cpu" else "retained_bytes_per_recorded_hour"
            ratio = .50 if profile == "cpu" else .80
            gate(name, None if a[name] == 0 else b[name] <= a[name] * ratio,
                 f"candidate={b[name]}, baseline={a[name]}, maximum candidate/baseline={ratio}")
        if profile != "cpu":
            gate("cpu_seconds_per_recorded_hour", b["cpu_seconds_per_recorded_hour"] <= a["cpu_seconds_per_recorded_hour"] * 1.10,
                 "Maximum CPU regression=10%")
        for name in ("retained_bytes_per_recorded_hour", "index_bytes", "model_bytes"):
            gate(name, b[name] <= a[name] * 1.10, "Maximum unrelated storage regression=10%")
        if old_input["energy_scope"] == new_input["energy_scope"] == "whole_system":
            gate("measured_energy", b["energy_joules_per_recorded_hour"] <= a["energy_joules_per_recorded_hour"] * 1.10,
                 "Maximum measured whole-system energy regression=10%")
        gate("backlog_recovery", b["processed_items_per_second"] >= a["processed_items_per_second"] * .90,
             "Completed-work rate must retain at least 90% of baseline; recording/backlog coverage is separately required")
        all_states = [issue["status"] for issue in issues] + [item["status"] for item in gates]
        state = "failed" if "failed" in all_states else "incomplete" if "incomplete" in all_states else "passed"
        states.append(state)
        result["pairs"].append({"baseline_id": old["id"], "candidate_id": current["id"], "status": state,
                                "gates": gates, "issues": issues,
                                "soft_cpu_goal_met": b["app_cpu_percent_one_core"] <= 20})
    result["status"] = "failed" if "failed" in states else "incomplete" if "incomplete" in states else "passed"
    result["stability"] = {"pass_at_1": states[0] == "passed", "pass_at_3": "passed" in states[:3],
                           "pass_power_3": states[:3] == ["passed"] * 3,
                           "passing_runs": states.count("passed"), "observed_runs": len(states)}
    energy_inputs = base["input"]["runs"] + new["input"]["runs"]
    if all(row["energy_scope"] == "whole_system" and row["energy_joules"] is not None for row in energy_inputs):
        result["energy_comparison"] = "measured_whole_system"
        result["energy_ratios"] = [None if a["energy_joules"] == 0 else b["energy_joules"] / a["energy_joules"]
                                   for a, b in zip(base["input"]["runs"], new["input"]["runs"])]
    result["limitations"] = ["passed means the declared measured comparison gates passed, not an installation or release approval.",
                            "pass_at_3 means at least one of the first three passed; promotion requires every pair to pass.",
                            "The 20%-of-one-core CPU target is reported separately as a soft goal."]
    return result


def _selected(rows: Any, key: str, variant: str | None) -> list[dict]:
    chosen = [row for row in items(rows, "native rows") if isinstance(row, dict) and row.get(key) == variant]
    if not chosen:
        raise ValidationError(f"Native variant unavailable: {variant}")
    return chosen


def _mean(values: list[float]) -> float:
    return sum(number(v, "native metric") for v in items(values, "native metrics")) / len(values)


def import_native(path: Path, kind: str, variant: str | None) -> dict:
    """Import known authored native export formats without promoting their limited scope."""
    raw = read_json(path)
    if kind in ("ocr", "codec", "recall") and not isinstance(raw, dict):
        raise ValidationError("Native export requires an object")
    metrics: dict[str, Any] = {"capture_to_search_p95_ms": None, "foreground_p95_ms": None,
                               "energy_joules_per_recorded_hour": None, "cpu_seconds_per_recorded_hour": None,
                               "retained_bytes_per_recorded_hour": None, "incorrect_sources": None,
                               "critical_token_errors": None, "wrong_navigation": None}
    scope = ""
    if kind == "ocr":
        rows = items(raw.get("samples"), "OCR samples")
        if any(not isinstance(row.get(variant), dict) for row in rows):
            raise ValidationError("OCR variant unavailable in some fixtures")
        total_characters = sum(len(text(row.get("expected"), "OCR expected")) for row in rows)
        metrics["ocr_cer"] = sum(number(row[variant].get("characterEdits"), "character edits") for row in rows) / total_characters
        times = [value for row in rows for value in (row[variant].get("milliseconds") if isinstance(row[variant].get("milliseconds"), list)
                                                     else [row[variant].get("milliseconds")])]
        if all(value is not None for value in times):
            metrics["ocr_operation_p95_ms"] = percentile(times, 95)
        scope = "Sparse authored 4K OCR scenes, operation timing only; no critical-token oracle or continuous recording coverage."
    elif kind == "whisper":
        rows = [row for batch in items(raw, "Whisper batches") for row in batch.get("measurements", [])]
        chosen = _selected(rows, "backend_configuration", variant)
        metrics["speech_wer"] = _mean([row["reference_word_error_rate"] for row in chosen])
        metrics["inference_process_cpu_seconds"] = sum(number(row["inference_process_cpu_seconds"], "inference CPU") for row in chosen)
        metrics["inference_p95_ms"] = percentile([row["inference_seconds"] * 1000 for row in chosen], 95)
        scope = "Authored speech fixture only; CPU time excludes shared helper energy; requested GPU use is not proof of GPU execution."
    elif kind == "speech":
        chosen = _selected(raw, "backend", variant)
        metrics["speech_wer"] = _mean([row["reference_word_error_rate"] for row in chosen])
        metrics["inference_p95_ms"] = percentile([row["transcription_seconds"] * 1000 for row in chosen], 95)
        scope = "Authored speech batch, excludes asset installation; app memory is not Apple Speech helper memory."
    elif kind == "codec":
        chosen = _selected(raw.get("candidates"), "candidate", variant)
        metrics["encoded_bytes"] = sum(number(row["bytes"], "encoded bytes", integer=True) for row in chosen)
        metrics["decode_p95_ms"] = percentile([row["decode_seconds"] * 1000 for row in chosen], 95)
        metrics["absolute_decoded_frame_delta"] = sum(abs(row["frame_delta"]) for row in chosen)
        scope = "Authored audio codec sample only; frame count and file bytes do not establish speech accuracy, listening quality or seeking."
    elif kind == "cancellation":
        metrics["cancellation_p95_ms"] = percentile([row["cancellation_join_seconds"] * 1000 for row in items(raw, "cancellation rows")], 95)
        scope = "Native cancellation join only; exact inference sampling phase and foreground interaction latency unverified."
    elif kind == "recall":
        if raw.get("kind") != "authored-corpus-ranking-results" or raw.get("complete") is not True:
            raise ValidationError("Completed authored recall result required")
        if variant not in raw.get("metrics", {}):
            raise ValidationError("Recall variant unavailable")
        mean = raw["metrics"][variant]["mean"]
        for name, native_name in (("recall_at_1", "recallAt1"), ("recall_at_3", "recallAt3"),
                                  ("recall_at_5", "recallAt5"), ("mrr", "reciprocalRank")):
            metrics[name] = number(mean[native_name], native_name)
        timings = [sample for values in raw["latencyMs"].get(variant, {}).values() for sample in values]
        metrics["ranking_mixed_initial_warm_p95_ms"] = percentile(timings, 95) if timings else None
        scope = "Eight authored screens; retained v1 Q11 oracle ambiguity remains unchanged. Ranking timing excludes UI/media and cannot prove production scale."
    else:
        raise ValidationError("Unsupported native export kind")
    return {"schema_version": SCHEMA_VERSION, "kind": "retrace-performance-scorecard", "scope": "scoped-native-import",
            "acceptance_eligible": False, "acceptance": "unaccepted", "native_kind": kind, "variant": variant,
            "artifact": {"name": path.name, "sha256": hashlib.sha256(read_bytes(path)).hexdigest()},
            "metrics": metrics, "limitations": [scope, "Missing measurements are unavailable, never zero or a passing gate.",
                                                  "Existing native fixture bytes are imported unchanged; this is not a representative run."]}


def render_markdown(report: dict) -> str:
    """Render a readable scorecard without turning absent evidence into a score."""
    lines = ["# Retrace performance report", "", f"Schema: {SCHEMA_VERSION}",
             f"Scope: {report.get('scope', 'matched comparison')}",
             f"Status: {report.get('status', report.get('acceptance', 'unaccepted'))}", ""]
    if report.get("identity"):
        lines.extend(["Pinned conditions:", "", "```json", json.dumps(report["identity"], indent=2, ensure_ascii=False), "```", ""])
    metrics_sets = [(row["id"], row["metrics"]) for row in report.get("runs", [])]
    if "metrics" in report:
        metrics_sets.append(("Scoped measurements", report["metrics"]))
    for label, metrics in metrics_sets:
        lines.extend([f"## {label}", "", "| Measure | Value |", "| --- | ---: |"])
        for name, value in metrics.items():
            lines.append(f"| {name} | {'unavailable' if value is None else format(value, '.8g')} |")
        lines.append("")
    for row in report.get("runs", []):
        lines.extend(f"- {row['id']}: {issue['status']} — {issue['reason']}" for issue in row["issues"])
    for pair in report.get("pairs", []):
        lines.extend([f"## {pair['candidate_id']}: {pair['status']}", ""])
        lines.extend(f"- {gate['name']}: {gate['status']} — {gate['detail']}" for gate in pair["gates"])
        lines.extend(f"- {issue['side']}: {issue['reason']}" for issue in pair["issues"])
        lines.append("")
    for key in ("reasons", "limitations"):
        lines.extend(f"- {entry}" for entry in report.get(key, []))
    if "stability" in report:
        lines.extend(["", "Stability: " + json.dumps(report["stability"], sort_keys=True)])
        lines.append("Energy comparison: " + report["energy_comparison"])
    return "\n".join(lines) + "\n"


def _write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def write_report(output: Path, report: dict) -> None:
    """Reserve a private new directory; JSON is the atomic final completion marker."""
    encoded = json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False).encode() + b"\n"
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    _write_private(output / "report.md", render_markdown(report).encode())
    _write_private(output / ".report.json.partial", encoded)
    os.rename(output / ".report.json.partial", output / "report.json")
    fd = os.open(output, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_command(spec: dict) -> None:
    """Reject ambiguous commands before creating a scratch directory or launching work."""
    if not isinstance(spec, dict):
        raise ValidationError("Command must be an object")
    identifier = spec.get("id")
    if not isinstance(identifier, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", identifier) is None:
        raise ValidationError("Command id must be a simple unique path component")
    for arg in items(spec.get("argv"), "argv"):
        text(arg, "argument")
    if number(spec.get("timeout_seconds"), "command timeout", positive=True) > 3600:
        raise ValidationError("Command timeout exceeds one hour")


def verify_pins(pins: list[dict]) -> list[dict]:
    """Stream hashes of explicit immutable authored inputs, including large local models."""
    seen = set()
    for pin in items(pins, "pins"):
        if not isinstance(pin, dict):
            raise ValidationError("Pin must be an object")
        path = Path(text(pin.get("path"), "pin path"))
        if not path.is_absolute() or path.is_symlink() or str(path) in seen:
            raise ValidationError("Pins require distinct absolute nonsymlink file paths")
        seen.add(str(path))
        if pin.get("role") not in ("source", "corpus", "model", "workload", "configuration", "oracle"):
            raise ValidationError("Unknown pin role")
        expected = sha256(pin.get("sha256"), "pinned SHA256")
        result = hashlib.sha256()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise ValidationError("Pins must name regular files")
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                result.update(block)
            after = os.fstat(stream.fileno())
        if before.st_size != after.st_size or before.st_mtime_ns != after.st_mtime_ns or result.hexdigest() != expected:
            raise ValidationError(f"Pinned input changed: {path.name}")
    return pins


class ExecutionInterruption:
    """Latch CLI termination without interrupting owned-child cleanup or receipt writes."""

    def __init__(self) -> None:
        self.signum: int | None = None
        self.previous: dict[int, Any] = {}

    def request(self, signum: int, _frame: Any) -> None:
        if self.signum is None:
            self.signum = signum

    def __enter__(self) -> ExecutionInterruption:
        for signum in (signal.SIGTERM, signal.SIGINT):
            self.previous[signum] = signal.signal(signum, self.request)
        return self

    def __exit__(self, *_exception: Any) -> None:
        for signum, previous in self.previous.items():
            signal.signal(signum, previous)


def execute_command(spec: dict, scratch: Path, interruption: ExecutionInterruption | None = None) -> dict:
    """Run one explicit argv without a shell, with isolated HOME and joined cancellation.

The specified executable is trusted authored benchmark code, not a sandbox. CPU
receipts cover reaped child work, never the running Retrace application.
"""
    validate_command(spec)
    identifier = spec["id"]
    argv = spec["argv"]
    args = [text(arg, "argument").replace("{scratch}", str(scratch.resolve())) for arg in argv]
    timeout = number(spec.get("timeout_seconds"), "command timeout", positive=True)
    if timeout > 3600:
        raise ValidationError("Command timeout exceeds one hour")
    scratch = scratch.resolve(strict=True)
    home = scratch / "home"
    home.mkdir(mode=0o700, exist_ok=True)
    environment = {key: os.environ[key] for key in ("PATH", "DEVELOPER_DIR", "SDKROOT", "LANG") if key in os.environ}
    environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), TMPDIR=str(scratch),
                       RETRACE_TEST_DISABLE_FILE_LOGGING="1", HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                       PYTHONHASHSEED="0", LC_ALL="C")
    log = scratch / f"{identifier}.log"
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started, timed_out = time.monotonic(), False
    with os.fdopen(fd, "wb") as stream:
        process = subprocess.Popen(args, cwd=scratch, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while interruption is None or interruption.signum is None:
                remaining = timeout - (time.monotonic() - started)
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    process.wait(timeout=min(remaining, .05))
                    break
                except subprocess.TimeoutExpired:
                    continue
        finally:
            # Terminate inherited process-group descendants and reap the owned leader.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    elapsed = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {"id": identifier, "argv": args, "exit_code": process.returncode, "timed_out": timed_out,
            "interrupted_signal": interruption.signum if interruption else None,
            "elapsed_seconds": elapsed, "child_process_cpu_seconds": max(0, after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime),
            "cpu_scope": "reaped child CPU only; descendants not reaped by their parent may be missing; not Retrace recording",
            "output_sha256": hashlib.sha256(read_bytes(log)).hexdigest()}


def run_plan(plan: dict, scratch: Path, interruption: ExecutionInterruption | None = None) -> dict:
    """Execute a pinned authored plan sequentially; execution receipts alone cannot pass gates."""
    if not isinstance(plan, dict) or plan.get("schema_version") != SCHEMA_VERSION or plan.get("kind") != "retrace-performance-run-plan":
        raise ValidationError("Versioned authored run plan required")
    commands = items(plan.get("commands"), "commands")
    if len(commands) > 32:
        raise ValidationError("Too many commands")
    for spec in commands:
        validate_command(spec)
    if len({spec["id"] for spec in commands}) != len(commands):
        raise ValidationError("Command ids must be unique")
    pins = verify_pins(plan.get("pins"))
    scratch.mkdir(mode=0o700, exist_ok=False)
    started_at = datetime.now(timezone.utc).isoformat()
    receipts = []
    for spec in commands:
        if interruption and interruption.signum is not None:
            break
        receipt = execute_command(spec, scratch, interruption)
        receipts.append(receipt)
        if receipt["exit_code"] != 0 or receipt["timed_out"] or receipt["interrupted_signal"] is not None:
            break
    pin_error = None
    if interruption and interruption.signum is not None:
        pin_error = "Post-run pin verification not completed because execution was interrupted"
    else:
        try:
            verify_pins(pins)
        except (ValidationError, OSError) as error:
            pin_error = str(error)
    report = {"schema_version": SCHEMA_VERSION, "kind": "retrace-benchmark-execution", "scope": "authored-command-run",
              "acceptance_eligible": False, "acceptance": "unaccepted", "plan_sha256": digest(plan),
              "commands": receipts, "completed": (interruption is None or interruption.signum is None) and pin_error is None and len(receipts) == len(commands) and all(row["exit_code"] == 0 for row in receipts),
              "verified_pins": pins, "pin_error": pin_error,
              "interrupted_signal": interruption.signum if interruption else None,
              "runner_sha256": hashlib.sha256(read_bytes(Path(__file__))).hexdigest(),
              "environment": {"os": platform.platform(), "machine": platform.machine(), "python": platform.python_version(),
                              "logical_cores": os.cpu_count()},
              "started_at_utc": started_at,
              "limitations": ["Authored command receipts are not continuous capture measurements or installed acceptance.",
                              "Commands are trusted code; isolation of HOME is not a security sandbox."]}
    write_report(scratch / "receipt", report)
    return report


def self_test(scratch: Path, interruption: ExecutionInterruption | None = None) -> dict:
    """Execute three actual authored child workloads and verify their deterministic result."""
    program = "import hashlib,json; print(json.dumps({'sha256':hashlib.sha256(b'Retrace authored runner self-test').hexdigest(),'sum':sum(i*i for i in range(10000))},sort_keys=True))"
    plan = {"schema_version": SCHEMA_VERSION, "kind": "retrace-performance-run-plan",
            "pins": [{"role": "source", "path": str(Path(__file__).resolve()),
                      "sha256": hashlib.sha256(read_bytes(Path(__file__))).hexdigest()}], "commands": [
        {"id": f"authored-{i}", "argv": [sys.executable, "-c", program], "timeout_seconds": 5} for i in range(3)]}
    report = run_plan(plan, scratch, interruption)
    if report["interrupted_signal"] is not None:
        return report
    expected = {"sha256": hashlib.sha256(b"Retrace authored runner self-test").hexdigest(), "sum": 333283335000}
    if not report["completed"] or any(read_json(scratch / f"authored-{i}.log") != expected for i in range(3)):
        raise ValidationError("Authored subprocess verification failed")
    report["scope"] = "runner-self-test"
    report["self_test_verified"] = True
    write_report(scratch / "self-test-report", report)
    return report


def main(argv: list[str] | None = None) -> int:
    """Offline CLI: collect measured inputs, compare, import existing exports, or run authored commands."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    collect = commands.add_parser("collect", help="Validate a measured session JSON")
    collect.add_argument("--input", type=Path, required=True)
    collect.add_argument("--output", type=Path, required=True)
    compare = commands.add_parser("compare", help="Compare three or more matched representative runs")
    compare.add_argument("--baseline", type=Path, required=True)
    compare.add_argument("--candidate", type=Path, required=True)
    compare.add_argument("--profile", choices=("cpu", "codec", "regression"), default="regression")
    compare.add_argument("--output", type=Path, required=True)
    native = commands.add_parser("import-native", help="Import an explicitly scoped native export")
    native.add_argument("--input", type=Path, required=True)
    native.add_argument("--kind", choices=("ocr", "whisper", "speech", "codec", "cancellation", "recall"), required=True)
    native.add_argument("--variant")
    native.add_argument("--output", type=Path, required=True)
    run = commands.add_parser("run", help="Execute an explicit authored argv plan sequentially")
    run.add_argument("--plan", type=Path, required=True)
    run.add_argument("--scratch", type=Path, required=True)
    self_check = commands.add_parser("self-test", help="Run three small actual child processes")
    self_check.add_argument("--scratch", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "collect":
            report = collect_session(read_json(args.input))
            report["artifact"] = {"name": args.input.name, "sha256": hashlib.sha256(read_bytes(args.input)).hexdigest()}
            write_report(args.output, report)
        elif args.command == "compare":
            report = compare_reports(read_json(args.baseline), read_json(args.candidate), args.profile)
            write_report(args.output, report)
        elif args.command == "import-native":
            report = import_native(args.input, args.kind, args.variant)
            write_report(args.output, report)
        elif args.command == "run":
            with ExecutionInterruption() as interruption:
                report = run_plan(read_json(args.plan), args.scratch, interruption)
        else:
            with ExecutionInterruption() as interruption:
                report = self_test(args.scratch, interruption)
        print(json.dumps({key: report[key] for key in ("kind", "scope", "status", "completed", "acceptance_eligible") if key in report}))
        if report.get("interrupted_signal") is not None:
            return 128 + report["interrupted_signal"]
        if report.get("status", "passed") != "passed" or report.get("completed") is False:
            return 1
        return 0
    except (ValidationError, OSError, KeyError, TypeError) as error:
        print(f"benchmark: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
