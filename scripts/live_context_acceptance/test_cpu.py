"""Offline tests. They never enumerate processes or change Retrace settings."""

import ctypes
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

import cpu


def record(pid=42, start=100, group="retrace", cpu_ns=0):
    return {
        "pid": pid,
        "start": start,
        "group": group,
        "name": "fixture",
        "cpu_ns": cpu_ns,
        "image_uuid": "c" * 32,
    }


def run(arm="baseline", sequence=1, percentage=10, shared_percentage=0):
    samples = []
    run_origin = (sequence - 1) * 400
    for second in range(301):
        samples.append(
            {
                "monotonic_ns": (run_origin + second + 1) * 1_000_000_000,
                "scan_ns": 1000,
                "records": [
                    record(cpu_ns=int(second * percentage * 10_000_000)),
                    record(43, 200, "speech_helpers", 0),
                    record(
                        44,
                        300,
                        "shared_audio",
                        int(second * shared_percentage * 10_000_000),
                    ),
                ],
                "failures": [],
                "unknown_paths": 0,
                "collector_cpu_ns": second * 1000,
            }
        )
    return {
        "schema": cpu.SCHEMA,
        "complete": True,
        "metadata": {
            "arm": arm,
            "sequence": sequence,
            "duration_seconds": 300,
            "interval_seconds": 1,
            "protocol_id": "authored-fixture",
            "matched_config_sha256": "a" * 64,
            "environment_sha256": "b" * 64,
            "build_sha256": "c" * 64,
            "build_sha256_after": "c" * 64,
            "host_sha256": "d" * 64,
            "os_version": "26.1",
            "executable_uuids": ["c" * 32],
            "boot_session_uuid": "11111111-2222-4333-8444-555555555555",
            "clock_implementation": "authored-monotonic-clock",
        },
        "samples": samples,
    }


def matched_runs(enabled_percentage=14):
    return [
        run("baseline", 1),
        run("enabled", 2, enabled_percentage),
        run("enabled", 3, enabled_percentage),
        run("baseline", 4),
    ]


def attest():
    return {
        **dict.fromkeys(cpu.REQUIRED_ATTESTATIONS, True),
        "shared_services_attribution": "unambiguous",
    }


class CPUAggregationTests(unittest.TestCase):
    def test_collector_child_cpu_is_reported_separately(self):
        fixture = run()
        for index, sample in enumerate(fixture["samples"]):
            sample["collector_child_cpu_ns"] = index * 1_000_000
        report = cpu.summarize(fixture)
        self.assertAlmostEqual(report["collector_child_one_core_percent"], 0.1)
        self.assertEqual(report["one_core_average_percent"]["retrace"], 10)

    def test_cumulative_counters_use_elapsed_time_and_one_core_denominator(self):
        report = cpu.summarize(run(percentage=125))
        self.assertEqual(report["elapsed_seconds"], 300)
        self.assertEqual(report["one_core_average_percent"]["retrace"], 125)
        self.assertEqual(report["observed_cpu_seconds"]["retrace"], 375)
        self.assertFalse(report["coverage_issues"])

    def test_pid_reuse_is_not_treated_as_one_process(self):
        fixture = run()
        for sample in fixture["samples"][151:]:
            sample["records"][0]["start"] = 101
            sample["records"][0]["cpu_ns"] -= 15_000_000_000
        report = cpu.summarize(fixture)
        self.assertIn("process_lifetime_not_fully_observed", report["coverage_issues"])
        self.assertEqual(len(report["transitions"]), 2)
        self.assertLess(report["stable_inventory_interval_fraction"]["retrace"], 1)

    def test_new_and_exited_helpers_do_not_invent_unobserved_cpu(self):
        fixture = run()
        fixture["samples"][151]["records"].append(
            record(99, 900, "speech_helpers", 80_000_000_000)
        )
        report = cpu.summarize(fixture)
        self.assertEqual(report["observed_cpu_seconds"]["speech_helpers"], 0)
        self.assertEqual(len(report["transitions"]), 2)

    def test_unreadable_identity_and_cpu_are_explicit(self):
        fixture = run()
        fixture["samples"][1]["unknown_paths"] = 1
        fixture["samples"][2]["failures"] = [{"pid": 99, "group": "speech_helpers"}]
        report = cpu.summarize(fixture)
        self.assertIn(
            "unclassified_processes_could_hide_helpers", report["coverage_issues"]
        )
        self.assertIn("selected_process_cpu_unavailable", report["coverage_issues"])

    def test_counter_decrease_and_rebound_excludes_the_unreliable_series(self):
        fixture = run()
        fixture["samples"][10]["records"][0]["cpu_ns"] = 0
        report = cpu.summarize(fixture)
        self.assertIn(
            "process_counter_reset_or_identity_changed", report["coverage_issues"]
        )
        self.assertEqual(report["observed_cpu_seconds"]["retrace"], 0)
        self.assertEqual(report["stable_inventory_interval_fraction"]["retrace"], 0)
        self.assertEqual(
            report["excluded_cpu_series"],
            [
                {
                    "pid": 42,
                    "start": 100,
                    "groups": ["retrace"],
                    "cpu_seconds": None,
                    "reason": "counter_regression_or_identity_change",
                }
            ],
        )

    def test_counter_reset_only_excludes_the_affected_process(self):
        fixture = run(shared_percentage=3)
        fixture["samples"][10]["records"][0]["cpu_ns"] = 0
        report = cpu.summarize(fixture)
        self.assertEqual(report["observed_cpu_seconds"]["retrace"], 0)
        self.assertEqual(report["observed_cpu_seconds"]["shared_audio"], 9)

    def test_counter_decrease_across_missing_sample_remains_unreliable(self):
        fixture = run()
        fixture["samples"][10]["records"].pop(0)
        fixture["samples"][11]["records"][0]["cpu_ns"] = 0
        report = cpu.summarize(fixture)
        self.assertEqual(report["observed_cpu_seconds"]["retrace"], 0)
        self.assertIn(
            "process_counter_reset_or_identity_changed", report["coverage_issues"]
        )

    def test_sampling_gap_or_sleep_does_not_pass(self):
        fixture = run()
        for sample in fixture["samples"][100:]:
            sample["monotonic_ns"] += 10_000_000_000
        self.assertIn(
            "sampling_gap_or_sleep", cpu.summarize(fixture)["coverage_issues"]
        )

    def test_missing_app_and_changed_binary_are_explicit(self):
        fixture = run()
        fixture["samples"][0]["records"] = []
        fixture["metadata"]["build_sha256_after"] = "e" * 64
        issues = cpu.summarize(fixture)["coverage_issues"]
        self.assertIn("expected_exactly_one_retrace_process", issues)
        self.assertIn("executable_changed_during_collection", issues)

    def test_disk_replacement_does_not_prove_running_build(self):
        fixture = run()
        fixture["samples"][0]["records"][0]["image_uuid"] = "e" * 32
        self.assertIn(
            "running_image_does_not_match_executable",
            cpu.summarize(fixture)["coverage_issues"],
        )

    def test_duplicate_identity_nonmonotonic_time_and_boolean_counter_rejected(self):
        fixture = run()
        fixture["samples"][0]["records"].append(record())
        with self.assertRaises(ValueError):
            cpu.summarize(fixture)
        fixture = run()
        fixture["samples"][1]["monotonic_ns"] = fixture["samples"][0]["monotonic_ns"]
        with self.assertRaises(ValueError):
            cpu.summarize(fixture)
        fixture = run()
        fixture["samples"][0]["records"][0]["cpu_ns"] = True
        with self.assertRaises(ValueError):
            cpu.summarize(fixture)


class CPUComparisonTests(unittest.TestCase):
    def test_quantized_helper_observations_never_establish_acceptance(self):
        fixtures = matched_runs()
        for fixture in fixtures:
            for sample in fixture["samples"]:
                row = sample["records"][2]
                row.update(
                    {
                        "identity_source": "ps_lstart_utc_seconds",
                        "identity_resolution_ns": 1_000_000_000,
                        "counter_source": "ps_time_centiseconds",
                        "cpu_display_quantum_ns": 10_000_000,
                    }
                )
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["cpu_status"], "inconclusive")
        self.assertIn("coarse_process_birth_identity", result["issues"])
        self.assertIn("quantized_helper_cpu_observations", result["issues"])
        self.assertEqual(
            result["runs"][0]["cpu_display_quantum_ns_by_group"]["shared_audio"],
            10_000_000,
        )

    def test_matched_complete_arms_and_explicit_attestations_only_cover_cpu(self):
        result = cpu.compare(matched_runs(), attest())
        self.assertEqual(result["cpu_status"], "within_target")
        self.assertEqual(result["conservative_additional_percentage_points"], 4)
        self.assertEqual(result["overall_acceptance"], "not_established")
        self.assertEqual(result["physical_acknowledgement"], "not_measured")

    def test_above_five_percentage_points_exceeds_cpu_target(self):
        result = cpu.compare(matched_runs(15.1), attest())
        self.assertEqual(result["cpu_status"], "exceeds_target")

    def test_shared_usage_decline_cannot_hide_app_regression(self):
        fixtures = matched_runs(16)
        for index in (0, 3):
            fixtures[index] = run("baseline", index + 1, 10, 20)
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["additional_including_shared_percentage_points"], -14)
        self.assertEqual(result["conservative_additional_percentage_points"], 6)
        self.assertEqual(result["cpu_status"], "exceeds_target")

    def test_shared_increase_is_included_conservatively(self):
        fixtures = matched_runs()
        for index in (1, 2):
            fixtures[index] = run("enabled", index + 1, 14, 3)
        self.assertEqual(
            cpu.compare(fixtures, attest())[
                "conservative_additional_percentage_points"
            ],
            7,
        )

    def test_ambiguous_attribution_and_absent_attestation_never_pass(self):
        self.assertEqual(cpu.compare(matched_runs(), {})["cpu_status"], "inconclusive")
        evidence = attest()
        evidence["shared_services_attribution"] = "ambiguous"
        self.assertEqual(
            cpu.compare(matched_runs(), evidence)["cpu_status"], "inconclusive"
        )

    def test_mismatched_build_configuration_and_order_never_pass(self):
        for field in (
            "build_sha256",
            "matched_config_sha256",
            "environment_sha256",
            "host_sha256",
        ):
            fixtures = matched_runs()
            fixtures[1]["metadata"][field] = "f" * 64
            self.assertEqual(
                cpu.compare(fixtures, attest())["cpu_status"], "inconclusive"
            )
        fixtures = matched_runs()
        fixtures[1]["metadata"]["sequence"] = 4
        self.assertEqual(cpu.compare(fixtures, attest())["cpu_status"], "inconclusive")

    def test_incomplete_collection_never_passes_even_with_attestations(self):
        fixtures = matched_runs()
        fixtures[1]["complete"] = False
        self.assertEqual(cpu.compare(fixtures, attest())["cpu_status"], "inconclusive")

    def test_identical_intervals_with_different_sequence_labels_never_pass(self):
        fixtures = matched_runs()
        for fixture in fixtures:
            delta = fixture["samples"][0]["monotonic_ns"] - 1_000_000_000
            for sample in fixture["samples"]:
                sample["monotonic_ns"] -= delta
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["cpu_status"], "inconclusive")
        self.assertIn("run_intervals_overlap_or_are_out_of_sequence", result["issues"])

    def test_sequence_labels_cannot_reorder_actual_observations(self):
        fixtures = matched_runs()
        for sample in fixtures[1]["samples"]:
            sample["monotonic_ns"] += 400_000_000_000
        for sample in fixtures[2]["samples"]:
            sample["monotonic_ns"] -= 400_000_000_000
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["cpu_status"], "inconclusive")
        self.assertIn("run_intervals_overlap_or_are_out_of_sequence", result["issues"])

    def test_scan_overlap_is_rejected_even_when_midpoints_are_ordered(self):
        fixtures = matched_runs()
        delta = (
            fixtures[1]["samples"][0]["monotonic_ns"]
            - fixtures[0]["samples"][-1]["monotonic_ns"]
            - 1
        )
        for sample in fixtures[1]["samples"]:
            sample["monotonic_ns"] -= delta
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["cpu_status"], "inconclusive")
        self.assertIn("run_intervals_overlap_or_are_out_of_sequence", result["issues"])

    def test_cross_boot_runs_with_ordered_monotonic_values_never_pass(self):
        fixtures = matched_runs()
        fixtures[2]["metadata"]["boot_session_uuid"] = (
            "22222222-3333-4444-8555-666666666666"
        )
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["cpu_status"], "inconclusive")
        self.assertIn("mismatched_boot_session_uuid", result["issues"])

    def test_missing_or_invalid_boot_identity_is_rejected(self):
        for boot_identity in (None, "", "not-a-uuid"):
            fixtures = matched_runs()
            fixtures[1]["metadata"]["boot_session_uuid"] = boot_identity
            with self.assertRaises(ValueError):
                cpu.compare(fixtures, attest())

    def test_different_monotonic_clock_implementations_never_pass(self):
        fixtures = matched_runs()
        fixtures[2]["metadata"]["clock_implementation"] = "different-monotonic-clock"
        result = cpu.compare(fixtures, attest())
        self.assertEqual(result["cpu_status"], "inconclusive")
        self.assertIn("mismatched_clock_implementation", result["issues"])

    def test_input_path_order_does_not_relabel_observation_sequence(self):
        fixtures = matched_runs()
        self.assertEqual(
            cpu.compare(list(reversed(fixtures)), attest())["cpu_status"],
            "within_target",
        )

    def test_weighted_run_duration_is_used(self):
        fixtures = matched_runs(14)
        fixtures[2] = run("enabled", 3, 12)
        for sample in fixtures[2]["samples"]:
            sample["monotonic_ns"] *= 2
            for row in sample["records"]:
                row["cpu_ns"] *= 2
        # A duration mismatch makes acceptance inconclusive, but the observed estimate is weighted.
        fixtures[2]["metadata"]["duration_seconds"] = 600
        result = cpu.compare(fixtures, attest())
        self.assertAlmostEqual(result["additional_one_core_percentage_points"], 8 / 3)
        self.assertEqual(result["cpu_status"], "inconclusive")


class ArtifactAndInventoryTests(unittest.TestCase):
    def test_boot_identity_reads_kernel_uuid_without_a_write_request(self):
        kernel_value = b"ABCDEF01-2345-4678-89AB-CDEF01234567\0"

        def native_read(name, destination, size, replacement, replacement_size):
            self.assertEqual(name, b"kern.bootsessionuuid")
            self.assertIsNone(replacement)
            self.assertEqual(replacement_size, 0)
            ctypes.memmove(destination, kernel_value, len(kernel_value))
            ctypes.cast(size, ctypes.POINTER(ctypes.c_size_t)).contents.value = len(
                kernel_value
            )
            return 0

        library = Mock()
        library.sysctlbyname.side_effect = native_read
        with (
            patch.object(cpu.sys, "platform", "darwin"),
            patch.object(cpu.ctypes, "CDLL", return_value=library),
        ):
            self.assertEqual(
                cpu.boot_session_identity(), "abcdef01-2345-4678-89ab-cdef01234567"
            )

    def test_unavailable_kernel_boot_identity_fails_without_a_wall_clock_fallback(self):
        library = Mock()
        library.sysctlbyname.return_value = -1
        with (
            patch.object(cpu.sys, "platform", "darwin"),
            patch.object(cpu.ctypes, "CDLL", return_value=library),
        ):
            with self.assertRaises(OSError):
                cpu.boot_session_identity()

    def test_macho_uuid_parser_reads_thin_and_fat_slices_and_rejects_truncation(self):
        header = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0)
        image = header + struct.pack("<II", 0x1B, 24) + bytes.fromhex("a" * 32)
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "Retrace"
            target.write_bytes(image)
            self.assertEqual(cpu.macho_uuids(target), ["a" * 32])
            target.write_bytes(
                struct.pack(">IIIIIII", 0xCAFEBABE, 1, 0x100000C, 0, 28, len(image), 0)
                + image
            )
            self.assertEqual(cpu.macho_uuids(target), ["a" * 32])
            target.write_bytes(image[:-1])
            with self.assertRaises(ValueError):
                cpu.macho_uuids(target)

    def test_only_exact_app_and_system_helpers_are_classified(self):
        executable = "/Applications/Retrace.app/Contents/MacOS/Retrace"
        self.assertEqual(cpu.classify(executable, executable), "retrace")
        self.assertIsNone(cpu.classify("/private/tmp/Retrace", executable))
        self.assertIsNone(
            cpu.classify("/Users/alice/localspeechrecognition", executable)
        )
        self.assertEqual(
            cpu.classify("/System/Library/XPCServices/CoreSpeechXPC", executable),
            "speech_helpers",
        )
        self.assertEqual(
            cpu.classify("/usr/sbin/coreaudiod", executable), "shared_audio"
        )

    def test_native_rusage_layout_matches_v2_sdk(self):
        self.assertEqual(ctypes.sizeof(cpu.RUsageV2), 160)
        self.assertEqual(cpu.RUsageV2.user.offset, 16)
        self.assertEqual(cpu.RUsageV2.start.offset, 80)

    def test_private_atomic_no_overwrite_artifact(self):
        with tempfile.TemporaryDirectory() as root:
            destination = Path(root) / "run"
            descriptor = cpu.private_directory(destination)
            try:
                cpu.write_private_json(descriptor, "run.json", {"value": 1})
                with self.assertRaises(FileExistsError):
                    cpu.write_private_json(descriptor, "run.json", {"value": 2})
                with self.assertRaises(ValueError):
                    cpu.write_private_json(descriptor, "../escape.json", {})
                self.assertEqual(
                    json.loads((destination / "run.json").read_text()), {"value": 1}
                )
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
                self.assertEqual(
                    stat.S_IMODE((destination / "run.json").stat().st_mode), 0o600
                )
                self.assertEqual(
                    sorted(path.name for path in destination.iterdir()), ["run.json"]
                )
            finally:
                os.close(descriptor)
            with self.assertRaises(FileExistsError):
                cpu.private_directory(destination)

    def test_artifact_parser_rejects_nonfinite_or_oversized_content(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "invalid.json"
            target.write_text('{"bad": NaN}')
            with self.assertRaises(ValueError):
                cpu.read_json(target)
            target.write_bytes(b" " * (cpu.MAX_ARTIFACT_BYTES + 1))
            with self.assertRaises(ValueError):
                cpu.read_json(target)


class HelperCPUFallbackTests(unittest.TestCase):
    OUTPUT = (
        b" 459 Thu Oct 15 22:10:21 2026 1260:38.13\n"
        b" 568 Thu Oct 15 22:10:22 2026 0:00.38\n"
    )

    def test_fixed_fields_preserve_birth_identity_and_cpu_quantization(self):
        result = cpu.parse_ps_counters(self.OUTPUT, {459, 568})
        self.assertEqual(result[459]["start"], 1792102221)
        self.assertEqual(result[459]["cpu_ns"], 75_638_130_000_000)
        self.assertEqual(result[568]["cpu_ns"], 380_000_000)
        self.assertEqual(result[459]["identity_resolution_ns"], 1_000_000_000)
        self.assertEqual(result[459]["cpu_display_quantum_ns"], 10_000_000)

    def test_rejects_unexpected_duplicate_malformed_and_excess_output(self):
        invalid = [
            self.OUTPUT,
            self.OUTPUT.splitlines()[0] + b"\n" + self.OUTPUT.splitlines()[0],
            self.OUTPUT.splitlines()[0].replace(b"38.13", b"98.13"),
            self.OUTPUT.splitlines()[0].replace(b"Thu", b"Fri"),
            b"x" * (cpu.MAX_PS_BYTES + 1),
        ]
        for value in invalid:
            with self.assertRaises(ValueError):
                cpu.parse_ps_counters(value, {459})

    def test_one_bounded_absolute_command_has_no_shell_argv_environment_or_paths(self):
        completed = subprocess.CompletedProcess([], 0, self.OUTPUT)
        with patch.object(cpu.subprocess, "run", return_value=completed) as invoke:
            self.assertEqual(set(cpu.read_ps_counters([568, 459], 0.25)), {459, 568})
        invoke.assert_called_once_with(
            ["/bin/ps", "-p", "459,568", "-o", "pid=", "-o", "lstart=", "-o", "time="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"LC_ALL": "C", "TZ": "UTC"},
            timeout=0.25,
            check=False,
        )

    def test_bad_pid_or_exhausted_deadline_never_launches_ps(self):
        with patch.object(cpu.subprocess, "run") as invoke:
            for pids, deadline in [
                ([], 0.1),
                ([459, 459], 0.1),
                (["459;id"], 0.1),
                ([459], 0),
                ([459], 0.6),
                (list(range(1, 34)), 0.1),
            ]:
                with self.assertRaises(ValueError):
                    cpu.read_ps_counters(pids, deadline)
            invoke.assert_not_called()

    def backend(self, returned_path):
        backend = object.__new__(cpu.MacProcesses)
        backend.executable = "/Applications/Retrace.app/Contents/MacOS/Retrace"
        backend.lib = Mock()

        def path_read(_pid, destination, _capacity):
            ctypes.memmove(destination, returned_path + b"\0", len(returned_path) + 1)
            return len(returned_path)

        backend.lib.proc_pidpath.side_effect = path_read
        return backend

    def test_only_classified_helper_with_unchanged_path_is_retained(self):
        backend = self.backend(b"/usr/sbin/coreaudiod")
        candidate = {
            "pid": 459,
            "group": "shared_audio",
            "path": "/usr/sbin/coreaudiod",
        }
        counters = cpu.parse_ps_counters(self.OUTPUT.splitlines()[0], {459})
        with patch.object(cpu, "read_ps_counters", return_value=counters) as read:
            rows, failures = backend.helper_fallback(
                [candidate], time.monotonic_ns() + cpu.PS_DEADLINE_NS
            )
        read.assert_called_once()
        self.assertFalse(failures)
        self.assertEqual(rows[0]["pid"], 459)
        self.assertNotIn("path", rows[0])
        backend.lib.proc_pidpath.side_effect = self.backend(
            b"/private/tmp/replaced"
        ).lib.proc_pidpath.side_effect
        with patch.object(cpu, "read_ps_counters", return_value=counters):
            rows, failures = backend.helper_fallback(
                [candidate], time.monotonic_ns() + cpu.PS_DEADLINE_NS
            )
        self.assertFalse(rows)
        self.assertEqual(failures[0]["reason"], "identity_changed_during_read")

    def test_unclassified_or_app_candidate_cannot_enter_fallback(self):
        backend = self.backend(b"/usr/sbin/coreaudiod")
        for group, path in [
            ("retrace", backend.executable),
            ("shared_audio", "/private/tmp/coreaudiod"),
        ]:
            with patch.object(cpu, "read_ps_counters") as read:
                with self.assertRaises(ValueError):
                    backend.helper_fallback(
                        [{"pid": 459, "group": group, "path": path}],
                        time.monotonic_ns(),
                    )
                read.assert_not_called()

    def test_timeout_and_missing_pid_keep_failure_visible(self):
        backend = self.backend(b"/usr/sbin/coreaudiod")
        candidate = {
            "pid": 459,
            "group": "shared_audio",
            "path": "/usr/sbin/coreaudiod",
        }
        for failure in (
            subprocess.TimeoutExpired("/bin/ps", 0.25),
            ValueError("missing"),
        ):
            with patch.object(cpu, "read_ps_counters", side_effect=failure):
                rows, failures = backend.helper_fallback(
                    [candidate], time.monotonic_ns() + cpu.PS_DEADLINE_NS
                )
            self.assertFalse(rows)
            self.assertEqual(failures[0]["reason"], "ps_counter_unavailable")


if __name__ == "__main__":
    unittest.main()
