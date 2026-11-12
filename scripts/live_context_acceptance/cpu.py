#!/usr/bin/env python3
"""Bounded, opt-in macOS CPU observations; no application or OS mutations."""

from __future__ import annotations

import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import resource
import stat
import struct
import subprocess
import sys
import time
import uuid

SCHEMA = 2
MAX_PIDS = 65_536
MAX_RECORDS = 256
MAX_ARTIFACT_BYTES = 32 * 1024 * 1024
MAX_PS_PIDS = 32
MAX_PS_BYTES = 8192
PS_DEADLINE_NS = 500_000_000
GROUPS = ("retrace", "speech_helpers", "shared_speech", "shared_audio", "shared_ane")
SHARED_GROUPS = GROUPS[2:]
SPEECH_NAMES = {
    "localspeechrecognition",
    "speechrecognitiond",
    "corespeechxpc",
    "speechrecognition",
    "com.apple.speechrecognitioncore.speechrecognitiond",
    "speechrecognitioncore",
}
SHARED_NAMES = {
    "corespeechd": "shared_speech",
    "siriactionsd": "shared_speech",
    "assistantd": "shared_speech",
    "coreaudiod": "shared_audio",
    "anecompilerservice": "shared_ane",
    "aned": "shared_ane",
    "aneuserd": "shared_ane",
}
REQUIRED_ATTESTATIONS = (
    "matched_configuration_verified",
    "environment_matched",
    "other_speech_clients_quiet",
    "helper_inventory_verified",
    "no_sampling_invisible_helper_lifetimes",
    "no_unrelated_heavy_work",
    "measurement_protocol_verified",
)
PS_ROW = re.compile(
    r"\s*(\d+)\s+(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+"
    r"(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+"
    r"(\d{2}):(\d{2}):(\d{2})\s+(\d{4})\s+(\d{1,12}):([0-5]\d)\.(\d{2})\s*"
)


def parse_ps_counters(output: bytes, expected_pids: set[int]) -> dict[int, dict]:
    """Parse only PID, UTC birth second and cumulative CPU centiseconds."""
    if len(output) > MAX_PS_BYTES:
        raise ValueError("Bounded helper CPU output exceeded its capacity.")
    result = {}
    months = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()
    for line in output.decode("ascii").splitlines():
        if not line.strip():
            continue
        match = PS_ROW.fullmatch(line)
        if match is None:
            raise ValueError("Unexpected fixed-field helper CPU output.")
        (
            pid_text,
            weekday,
            month,
            day,
            hour,
            minute,
            second,
            year,
            minutes,
            seconds,
            cents,
        ) = match.groups()
        pid = int(pid_text)
        if pid not in expected_pids or pid in result:
            raise ValueError("Unexpected or duplicate helper PID.")
        birth = datetime(
            int(year),
            months.index(month) + 1,
            int(day),
            int(hour),
            int(minute),
            int(second),
            tzinfo=timezone.utc,
        )
        if weekday != "Mon Tue Wed Thu Fri Sat Sun".split()[birth.weekday()]:
            raise ValueError("Inconsistent helper birth timestamp.")
        result[pid] = {
            "start": integer(int(birth.timestamp()), "helper birth second", 1),
            "cpu_ns": integer(
                (int(minutes) * 60_000 + int(seconds) * 1000 + int(cents) * 10)
                * 1_000_000,
                "helper cumulative CPU",
            ),
            "identity_source": "ps_lstart_utc_seconds",
            "identity_resolution_ns": 1_000_000_000,
            "counter_source": "ps_time_centiseconds",
            "cpu_display_quantum_ns": 10_000_000,
        }
    return result


def read_ps_counters(pids: list[int], timeout: float) -> dict[int, dict]:
    if (
        not 1 <= len(pids) <= MAX_PS_PIDS
        or len(set(pids)) != len(pids)
        or any(type(pid) is not int or not 1 <= pid <= 2**31 - 1 for pid in pids)
        or not 0 < timeout <= PS_DEADLINE_NS / 1e9
    ):
        raise ValueError("Invalid bounded helper CPU request.")
    completed = subprocess.run(
        [
            "/bin/ps",
            "-p",
            ",".join(str(pid) for pid in sorted(pids)),
            "-o",
            "pid=",
            "-o",
            "lstart=",
            "-o",
            "time=",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env={"LC_ALL": "C", "TZ": "UTC"},
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise ValueError("Bounded helper CPU query failed.")
    return parse_ps_counters(completed.stdout, set(pids))


def classify(path: str, executable: str) -> str | None:
    """Only the exact requested app and named Apple system helpers are retained."""
    if path == executable:
        return "retrace"
    if not path.startswith(("/System/", "/usr/libexec/", "/usr/sbin/")):
        return None
    name = Path(path).name.lower()
    if name in SPEECH_NAMES:
        return "speech_helpers"
    return SHARED_NAMES.get(name)


class RUsageV2(ctypes.Structure):
    # SDK sys/resource.h rusage_info_v2. CPU fields are nanoseconds; start is opaque.
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "user",
            "system",
            "pkg_idle",
            "interrupt",
            "pageins",
            "wired",
            "resident",
            "footprint",
            "start",
            "exit",
            "child_user",
            "child_system",
            "child_pkg_idle",
            "child_interrupt",
            "child_pageins",
            "child_elapsed",
            "disk_read",
            "disk_write",
        )
    ]


class MacProcesses:
    def __init__(self, executable: str):
        if sys.platform != "darwin":
            raise ValueError(
                "Collection requires macOS; reporting and tests are portable."
            )
        self.executable = executable
        self.lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.lib.proc_listallpids.restype = ctypes.c_int
        self.lib.proc_pidpath.argtypes = [
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
        ]
        self.lib.proc_pidpath.restype = ctypes.c_int
        self.lib.proc_pid_rusage.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        self.lib.proc_pid_rusage.restype = ctypes.c_int

    def sample(self) -> dict:
        began = time.monotonic_ns()
        pids = (ctypes.c_int * MAX_PIDS)()
        count = self.lib.proc_listallpids(pids, ctypes.sizeof(pids))
        if count <= 0 or count >= MAX_PIDS:
            raise ValueError(
                "Process enumeration failed or exceeded its fixed capacity."
            )
        records, failures, unknown_paths = [], [], 0
        fallback = []
        for pid in pids[:count]:
            if pid <= 0:
                continue
            path_buffer = ctypes.create_string_buffer(4096)
            if self.lib.proc_pidpath(pid, path_buffer, len(path_buffer)) <= 0:
                unknown_paths += 1
                continue
            path = os.fsdecode(path_buffer.value)
            group = classify(path, self.executable)
            if group is None:
                continue
            usage = RUsageV2()
            if self.lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
                if group != "retrace" and len(fallback) < MAX_PS_PIDS:
                    fallback.append({"pid": pid, "group": group, "path": path})
                else:
                    failures.append(
                        {"pid": pid, "group": group, "reason": "rusage_unavailable"}
                    )
                continue
            second_path = ctypes.create_string_buffer(4096)
            if (
                self.lib.proc_pidpath(pid, second_path, len(second_path)) <= 0
                or second_path.value != path_buffer.value
            ):
                failures.append(
                    {
                        "pid": pid,
                        "group": group,
                        "reason": "identity_changed_during_read",
                    }
                )
                continue
            records.append(
                {
                    "pid": pid,
                    "start": usage.start,
                    "group": group,
                    "name": Path(path).name,
                    "cpu_ns": usage.user + usage.system,
                    "image_uuid": bytes(usage.ri_uuid).hex(),
                    "identity_source": "rusage_start_abstime",
                    "counter_source": "proc_pid_rusage",
                    "cpu_display_quantum_ns": 0,
                }
            )
            if len(records) > MAX_RECORDS:
                raise ValueError(
                    "Selected process inventory exceeded its fixed capacity."
                )
        if fallback:
            extra_records, extra_failures = self.helper_fallback(
                fallback, began + PS_DEADLINE_NS
            )
            records.extend(extra_records)
            failures.extend(extra_failures)
        if len(records) + len(failures) > MAX_RECORDS:
            raise ValueError("Selected process inventory exceeded its fixed capacity.")
        ended = time.monotonic_ns()
        own_usage = resource.getrusage(resource.RUSAGE_SELF)
        child_usage = resource.getrusage(resource.RUSAGE_CHILDREN)
        return {
            "monotonic_ns": (began + ended) // 2,
            "scan_ns": ended - began,
            "records": records,
            "failures": failures,
            "unknown_paths": unknown_paths,
            "enumerated_processes": count,
            "collector_cpu_ns": int((own_usage.ru_utime + own_usage.ru_stime) * 1e9),
            "collector_child_cpu_ns": int(
                (child_usage.ru_utime + child_usage.ru_stime) * 1e9
            ),
            "load_average": list(os.getloadavg()),
        }

    def helper_fallback(
        self, candidates: list[dict], deadline_ns: int
    ) -> tuple[list, list]:
        """At most one fixed-field ps call; candidates already passed native path classification."""
        records, failures = [], []
        if any(
            candidate["group"] not in GROUPS[1:]
            or classify(candidate["path"], self.executable) != candidate["group"]
            for candidate in candidates
        ):
            raise ValueError("Fallback accepts only already-classified system helpers.")
        remaining = min(PS_DEADLINE_NS / 1e9, (deadline_ns - time.monotonic_ns()) / 1e9)
        try:
            counters = read_ps_counters(
                [candidate["pid"] for candidate in candidates], remaining
            )
        except (OSError, ValueError, subprocess.TimeoutExpired):
            counters = {}
        for candidate in candidates:
            pid, group = candidate["pid"], candidate["group"]
            counter = counters.get(pid)
            current_path = ctypes.create_string_buffer(4096)
            if counter is None:
                reason = "ps_counter_unavailable"
            elif (
                self.lib.proc_pidpath(pid, current_path, len(current_path)) <= 0
                or os.fsdecode(current_path.value) != candidate["path"]
            ):
                reason = "identity_changed_during_read"
            else:
                records.append(
                    {
                        "pid": pid,
                        "group": group,
                        "name": Path(candidate["path"]).name,
                        **counter,
                    }
                )
                continue
            failures.append({"pid": pid, "group": group, "reason": reason})
        return records, failures


def boot_session_identity() -> str:
    """Read the kernel's boot UUID; do not infer a boot from adjustable wall time."""
    if sys.platform != "darwin":
        raise ValueError("Collection requires macOS; reporting and tests are portable.")
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.sysctlbyname.argtypes = [
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    library.sysctlbyname.restype = ctypes.c_int
    value = ctypes.create_string_buffer(128)
    size = ctypes.c_size_t(len(value))
    if (
        library.sysctlbyname(
            b"kern.bootsessionuuid", value, ctypes.byref(size), None, 0
        )
        != 0
    ):
        raise OSError(
            ctypes.get_errno(), "Cannot establish the kernel boot-session identity."
        )
    if not 1 <= size.value <= len(value):
        raise ValueError("Invalid kernel boot-session identity length.")
    return canonical_uuid(value.raw[: size.value].rstrip(b"\0").decode("ascii").lower())


def canonical_uuid(value: object) -> str:
    if not isinstance(value, str) or len(value) != 36:
        raise ValueError("A canonical boot-session UUID is required.")
    parsed = uuid.UUID(value)
    if str(parsed) != value or parsed.int == 0:
        raise ValueError("A canonical, nonzero boot-session UUID is required.")
    return value


def integer(value: object, name: str, minimum: int = 0) -> int:
    if type(value) is not int or not minimum <= value <= 2**64 - 1:
        raise ValueError(f"Invalid {name}.")
    return value


def digest(value: object, name: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(c not in "0123456789abcdef" for c in value)
    ):
        raise ValueError(f"Invalid {name}; expected lowercase SHA-256.")
    return value


def file_digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def macho_uuids(path: Path) -> list[str]:
    """Read bounded LC_UUID commands without launching or executing the candidate."""
    with path.open("rb") as source:
        size = os.fstat(source.fileno()).st_size

        def read(offset: int, count: int) -> bytes:
            if offset < 0 or count < 0 or offset + count > size:
                raise ValueError("Truncated Mach-O executable.")
            source.seek(offset)
            value = source.read(count)
            if len(value) != count:
                raise ValueError("Executable changed while reading Mach-O identity.")
            return value

        magic = read(0, 4)
        fat = {
            b"\xca\xfe\xba\xbe": (">", False),
            b"\xbe\xba\xfe\xca": ("<", False),
            b"\xca\xfe\xba\xbf": (">", True),
            b"\xbf\xba\xfe\xca": ("<", True),
        }
        slices = [(0, size)]
        if magic in fat:
            endian, wide = fat[magic]
            count = struct.unpack(endian + "I", read(4, 4))[0]
            if not 1 <= count <= 32:
                raise ValueError("Invalid Mach-O architecture count.")
            slices = []
            for index in range(count):
                fields = struct.unpack(
                    endian + ("IIQQII" if wide else "IIIII"),
                    read(8 + index * (32 if wide else 20), 32 if wide else 20),
                )
                slices.append((fields[2], fields[3]))
        result = []
        for offset, slice_size in slices:
            thin = {
                b"\xcf\xfa\xed\xfe": ("<", 32),
                b"\xfe\xed\xfa\xcf": (">", 32),
                b"\xce\xfa\xed\xfe": ("<", 28),
                b"\xfe\xed\xfa\xce": (">", 28),
            }
            if read(offset, 4) not in thin:
                raise ValueError("Expected a Mach-O executable.")
            endian, header_size = thin[read(offset, 4)]
            command_count, command_size = struct.unpack(
                endian + "II", read(offset + 16, 8)
            )
            if not 1 <= command_count <= 4096 or command_size > 16 * 1024 * 1024:
                raise ValueError("Invalid Mach-O command bounds.")
            end = offset + header_size + command_size
            if end > offset + slice_size or end > size:
                raise ValueError("Mach-O commands exceed their architecture slice.")
            cursor = offset + header_size
            for _ in range(command_count):
                if cursor + 8 > end:
                    raise ValueError("Truncated Mach-O load command.")
                command, length = struct.unpack(endian + "II", read(cursor, 8))
                if length < 8 or cursor + length > end:
                    raise ValueError("Invalid Mach-O load command size.")
                if command == 0x1B:
                    if length != 24:
                        raise ValueError("Invalid Mach-O UUID command.")
                    result.append(read(cursor + 8, 16).hex())
                cursor += length
        if not result:
            raise ValueError("Executable has no Mach-O UUID.")
        return sorted(set(result))


def read_json(path: Path) -> dict:
    with path.open("rb") as source:
        data = source.read(MAX_ARTIFACT_BYTES + 1)
    if len(data) > MAX_ARTIFACT_BYTES:
        raise ValueError("Artifact exceeds 32 MiB.")
    result = json.loads(
        data,
        parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Nonfinite JSON.")),
    )
    if not isinstance(result, dict):
        raise ValueError("Expected a JSON object.")
    return result


def private_directory(path: Path) -> int:
    """Exclusively create a 0700 output directory and retain its opened identity."""
    path = path.absolute()
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.mkdir(path.name, 0o700, dir_fd=parent)
        opened = os.open(
            path.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
        )
    finally:
        os.close(parent)
    info = os.fstat(opened)
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        os.close(opened)
        raise ValueError(
            "Output directory must be owned by the current user with mode 0700."
        )
    return opened


def write_private_json(directory: int, name: str, value: dict) -> None:
    if Path(name).name != name or not name.endswith(".json"):
        raise ValueError("Artifact must be a simple JSON filename.")
    data = (
        json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n"
    ).encode()
    if len(data) > MAX_ARTIFACT_BYTES:
        raise ValueError("Artifact exceeds 32 MiB.")
    temporary = f".pending-{uuid.uuid4().hex}"
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=directory,
    )
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        # link is atomic and refuses an existing final pathname, unlike replace.
        os.link(
            temporary,
            name,
            src_dir_fd=directory,
            dst_dir_fd=directory,
            follow_symlinks=False,
        )
        os.fsync(directory)
    finally:
        os.unlink(temporary, dir_fd=directory)


def validate_run(run: dict) -> None:
    if run.get("schema") != SCHEMA or type(run.get("complete")) is not bool:
        raise ValueError("Unsupported or incomplete run envelope.")
    metadata = run.get("metadata", {})
    if not isinstance(metadata, dict):
        raise ValueError("Invalid metadata object.")
    for name in (
        "build_sha256",
        "build_sha256_after",
        "matched_config_sha256",
        "environment_sha256",
        "host_sha256",
    ):
        digest(metadata.get(name), name)
    canonical_uuid(metadata.get("boot_session_uuid"))
    if (
        not isinstance(metadata.get("clock_implementation"), str)
        or not 1 <= len(metadata["clock_implementation"]) <= 120
    ):
        raise ValueError("The monotonic clock implementation is required.")
    image_uuids = metadata.get("executable_uuids")
    if (
        not isinstance(image_uuids, list)
        or not 1 <= len(image_uuids) <= 32
        or any(
            not isinstance(value, str)
            or len(value) != 32
            or any(char not in "0123456789abcdef" for char in value)
            for value in image_uuids
        )
    ):
        raise ValueError("Invalid executable UUID inventory.")
    if metadata.get("arm") not in ("baseline", "enabled"):
        raise ValueError("Invalid run arm.")
    if integer(metadata.get("sequence"), "sequence", 1) > 4:
        raise ValueError("Sequence must be 1 through 4.")
    if not 1 <= integer(metadata.get("duration_seconds"), "duration", 1) <= 600:
        raise ValueError("Duration must be 1 through 600 seconds.")
    if not 1 <= integer(metadata.get("interval_seconds"), "interval", 1) <= 5:
        raise ValueError("Interval must be 1 through 5 seconds.")
    if (
        not isinstance(metadata.get("protocol_id"), str)
        or not 1 <= len(metadata["protocol_id"]) <= 80
    ):
        raise ValueError("Invalid protocol ID.")
    samples = run.get("samples")
    if not isinstance(samples, list) or not 2 <= len(samples) <= 602:
        raise ValueError("Expected 2 through 602 bounded samples.")
    previous = -1
    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError("Invalid sample object.")
        timestamp = integer(sample.get("monotonic_ns"), "sample timestamp")
        if timestamp <= previous:
            raise ValueError("Sample times must be strictly increasing.")
        previous = timestamp
        integer(sample.get("scan_ns"), "scan duration")
        integer(sample.get("collector_cpu_ns"), "collector CPU")
        integer(sample.get("collector_child_cpu_ns", 0), "collector child CPU")
        integer(sample.get("unknown_paths"), "unknown paths")
        if (
            not isinstance(sample.get("failures"), list)
            or len(sample["failures"]) > MAX_RECORDS
        ):
            raise ValueError("Invalid failure list.")
        records = sample.get("records")
        if not isinstance(records, list) or len(records) > MAX_RECORDS:
            raise ValueError("Invalid process records.")
        identities = set()
        for record in records:
            if not isinstance(record, dict):
                raise ValueError("Invalid process record object.")
            pid = integer(record.get("pid"), "PID", 1)
            integer(record.get("start"), "process start", 1)
            integer(record.get("cpu_ns"), "cumulative CPU")
            source = record.get("counter_source", "proc_pid_rusage")
            if source not in ("proc_pid_rusage", "ps_time_centiseconds"):
                raise ValueError("Unsupported CPU counter source.")
            if source == "ps_time_centiseconds" and (
                record.get("group") == "retrace"
                or record.get("identity_source") != "ps_lstart_utc_seconds"
                or record.get("identity_resolution_ns") != 1_000_000_000
                or record.get("cpu_display_quantum_ns") != 10_000_000
            ):
                raise ValueError("Invalid fixed-field helper CPU precision metadata.")
            if record.get("group") not in GROUPS or pid in identities:
                raise ValueError("Invalid group or duplicate process identity.")
            identities.add(pid)


def summarize(run: dict) -> dict:
    validate_run(run)
    samples, metadata = run["samples"], run["metadata"]
    elapsed_ns = samples[-1]["monotonic_ns"] - samples[0]["monotonic_ns"]
    cpu = dict.fromkeys(GROUPS, 0)
    covered_ns = dict.fromkeys(GROUPS, 0)
    issues = set()
    transitions = []
    previous_by_identity = {}
    series_groups = {}
    invalid_series = set()
    counter_sources = set()
    display_quanta = dict.fromkeys(GROUPS, 0)
    if not run["complete"]:
        issues.add("collection_incomplete")
    if metadata["build_sha256"] != metadata["build_sha256_after"]:
        issues.add("executable_changed_during_collection")
    for sample in samples:
        if sample["unknown_paths"]:
            issues.add("unclassified_processes_could_hide_helpers")
        if sample["failures"]:
            issues.add("selected_process_cpu_unavailable")
        if sum(record["group"] == "retrace" for record in sample["records"]) != 1:
            issues.add("expected_exactly_one_retrace_process")
        for record in sample["records"]:
            source = record.get("counter_source", "proc_pid_rusage")
            counter_sources.add(source)
            if source == "ps_time_centiseconds":
                issues.add("coarse_process_birth_identity")
                issues.add("quantized_helper_cpu_observations")
                display_quanta[record["group"]] = 10_000_000
            identity = (record["pid"], record["start"])
            previous = previous_by_identity.get(identity)
            if previous is not None and (
                record["cpu_ns"] < previous["cpu_ns"]
                or record["group"] != previous["group"]
                or source != previous.get("counter_source", "proc_pid_rusage")
            ):
                invalid_series.add(identity)
                issues.add("process_counter_reset_or_identity_changed")
            previous_by_identity[identity] = record
            series_groups.setdefault(identity, set()).add(record["group"])
            if (
                record["group"] == "retrace"
                and record.get("image_uuid") not in metadata["executable_uuids"]
            ):
                issues.add("running_image_does_not_match_executable")
        if sample["scan_ns"] > metadata["interval_seconds"] * 1e9 * 0.1:
            issues.add("process_scan_exceeds_ten_percent_of_interval")
    for before, after in zip(samples, samples[1:]):
        interval_ns = after["monotonic_ns"] - before["monotonic_ns"]
        if interval_ns > metadata["interval_seconds"] * 1.5e9:
            issues.add("sampling_gap_or_sleep")
        left = {(row["pid"], row["start"]): row for row in before["records"]}
        right = {(row["pid"], row["start"]): row for row in after["records"]}
        incomplete_groups = set()
        for identity in left.keys() ^ right.keys():
            row = left.get(identity, right.get(identity))
            incomplete_groups.add(row["group"])
            transitions.append(
                {
                    "pid": identity[0],
                    "start": identity[1],
                    "group": row["group"],
                    "kind": "appeared" if identity in right else "disappeared",
                    "at_monotonic_ns": after["monotonic_ns"],
                }
            )
            issues.add("process_lifetime_not_fully_observed")
        for identity in left.keys() & right.keys():
            a, b = left[identity], right[identity]
            if identity in invalid_series:
                # Once a cumulative counter regresses, neither a low sample nor
                # its rebound is trustworthy. Exclude the entire process series,
                # including deltas before the regression; preserve other processes.
                incomplete_groups.update((a["group"], b["group"]))
                continue
            cpu[a["group"]] += b["cpu_ns"] - a["cpu_ns"]
        for group in GROUPS:
            if group not in incomplete_groups:
                covered_ns[group] += interval_ns
    elapsed = elapsed_ns / 1e9
    if elapsed < metadata["duration_seconds"] * 0.95:
        issues.add("observation_shorter_than_requested")
    percentages = {group: 100 * value / elapsed_ns for group, value in cpu.items()}
    app_speech = percentages["retrace"] + percentages["speech_helpers"]
    collector_delta = samples[-1]["collector_cpu_ns"] - samples[0]["collector_cpu_ns"]
    if collector_delta < 0:
        issues.add("collector_counter_reset")
    child_delta = samples[-1].get("collector_child_cpu_ns", 0) - samples[0].get(
        "collector_child_cpu_ns", 0
    )
    if child_delta < 0:
        issues.add("collector_child_counter_reset")
    return {
        "schema": SCHEMA,
        "metadata": metadata,
        "elapsed_seconds": elapsed,
        "observation_start_monotonic_ns": samples[0]["monotonic_ns"]
        - samples[0]["scan_ns"] // 2,
        "observation_end_monotonic_ns": samples[-1]["monotonic_ns"]
        + (samples[-1]["scan_ns"] + 1) // 2,
        "observed_cpu_seconds": {key: value / 1e9 for key, value in cpu.items()},
        "cpu_counter_sources": sorted(counter_sources),
        "cpu_display_quantum_ns_by_group": display_quanta,
        "excluded_cpu_series": [
            {
                "pid": pid,
                "start": start,
                "groups": sorted(series_groups[(pid, start)]),
                "cpu_seconds": None,
                "reason": "counter_regression_or_identity_change",
            }
            for pid, start in sorted(invalid_series)
        ],
        "one_core_average_percent": percentages,
        "retrace_plus_speech_percent": app_speech,
        "including_all_shared_services_percent": app_speech
        + sum(percentages[g] for g in SHARED_GROUPS),
        "collector_one_core_percent": 100 * max(0, collector_delta) / elapsed_ns,
        "collector_child_one_core_percent": 100 * max(0, child_delta) / elapsed_ns,
        "stable_inventory_interval_fraction": {
            g: covered_ns[g] / elapsed_ns for g in GROUPS
        },
        "transitions": transitions,
        "coverage_issues": sorted(issues),
        "limits": [
            "CPU totals are partial observations; missing process CPU is unknown.",
            "Quantized fallback CPU is an estimate, not a strict lower bound; birth identity is only second-resolution.",
            "An entire process series with a regressing counter is excluded; its CPU is unknown.",
            "Short-lived processes wholly between samples are not observable.",
            "Known helper names are an inventory, not proof of exclusive attribution.",
            "Shared service CPU includes other clients; it is reported separately.",
            "Load average is context, not whole-host CPU or ANE energy.",
        ],
    }


def compare(runs: list[dict], attestation: dict) -> dict:
    if len(runs) != 4:
        raise ValueError("Comparison requires exactly four A-B-B-A runs.")
    reports = sorted(
        (summarize(run) for run in runs),
        key=lambda report: report["metadata"]["sequence"],
    )
    issues = set()
    if [r["metadata"]["sequence"] for r in reports] != [1, 2, 3, 4]:
        issues.add("sequence_is_not_1_2_3_4")
    if [r["metadata"]["arm"] for r in reports] != [
        "baseline",
        "enabled",
        "enabled",
        "baseline",
    ]:
        issues.add("arms_are_not_A_B_B_A")
    for field in (
        "build_sha256",
        "matched_config_sha256",
        "environment_sha256",
        "host_sha256",
        "protocol_id",
        "duration_seconds",
        "interval_seconds",
        "os_version",
        "boot_session_uuid",
        "clock_implementation",
    ):
        if len({report["metadata"].get(field) for report in reports}) != 1:
            issues.add(f"mismatched_{field}")
    for before, after in zip(reports, reports[1:]):
        if (
            after["observation_start_monotonic_ns"]
            <= before["observation_end_monotonic_ns"]
        ):
            issues.add("run_intervals_overlap_or_are_out_of_sequence")
    for report in reports:
        issues.update(report["coverage_issues"])
        if report["elapsed_seconds"] < 300:
            issues.add("acceptance_requires_at_least_300_seconds_per_arm")
    for field in REQUIRED_ATTESTATIONS:
        if attestation.get(field) is not True:
            issues.add(f"unverified_{field}")
    if attestation.get("shared_services_attribution") != "unambiguous":
        issues.add("shared_service_attribution_ambiguous_or_unknown")
    baseline = [r for r in reports if r["metadata"]["arm"] == "baseline"]
    enabled = [r for r in reports if r["metadata"]["arm"] == "enabled"]
    if len(baseline) != 2 or len(enabled) != 2:
        raise ValueError("Exactly two baseline and two enabled arms are required.")

    def weighted(group: list[dict], field: str) -> float:
        return sum(r[field] * r["elapsed_seconds"] for r in group) / sum(
            r["elapsed_seconds"] for r in group
        )

    core_delta = weighted(enabled, "retrace_plus_speech_percent") - weighted(
        baseline, "retrace_plus_speech_percent"
    )
    inclusive_delta = weighted(
        enabled, "including_all_shared_services_percent"
    ) - weighted(baseline, "including_all_shared_services_percent")
    # A fall in unrelated shared work must not cancel an increase in app/helper work.
    conservative_delta = max(core_delta, inclusive_delta)
    status = (
        "inconclusive"
        if issues
        else ("within_target" if conservative_delta <= 5 else "exceeds_target")
    )
    return {
        "schema": SCHEMA,
        "cpu_status": status,
        "additional_one_core_percentage_points": core_delta,
        "additional_including_shared_percentage_points": inclusive_delta,
        "conservative_additional_percentage_points": conservative_delta,
        "target_percentage_points": 5,
        "issues": sorted(issues),
        "operator_attestation": attestation,
        "runs": reports,
        "physical_acknowledgement": "not_measured",
        "foreground_p95": "not_measured",
        "overall_acceptance": "not_established",
    }


def collect(args: argparse.Namespace) -> int:
    executable = args.executable.resolve(strict=True)
    if not executable.is_file():
        raise ValueError("Executable must be a regular file.")
    initial_hash = file_digest(executable)
    if args.build_sha256 and initial_hash != args.build_sha256:
        raise ValueError("Executable does not match the expected build hash.")
    metadata = {
        "arm": args.arm,
        "sequence": args.sequence,
        "duration_seconds": args.seconds,
        "interval_seconds": args.interval,
        "protocol_id": args.protocol_id,
        "matched_config_sha256": digest(
            args.matched_config_sha256, "configuration digest"
        ),
        "environment_sha256": digest(args.environment_sha256, "environment digest"),
        "build_sha256": initial_hash,
        "build_sha256_after": initial_hash,
        "executable_uuids": macho_uuids(executable),
        "host_sha256": hashlib.sha256(platform.node().encode()).hexdigest(),
        "boot_session_uuid": boot_session_identity(),
        "clock_implementation": time.get_clock_info("monotonic").implementation,
        "os_version": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "started_unix_ns_for_identification_only": time.time_ns(),
    }
    backend = MacProcesses(str(executable))
    directory = private_directory(args.output)
    run = {"schema": SCHEMA, "complete": False, "metadata": metadata, "samples": []}
    try:
        run["samples"].append(backend.sample())
        deadline_ns = run["samples"][0]["monotonic_ns"] + args.seconds * 1_000_000_000
        while run["samples"][-1]["monotonic_ns"] < deadline_ns:
            remaining = max(0, (deadline_ns - time.monotonic_ns()) / 1e9)
            time.sleep(min(args.interval, remaining))
            run["samples"].append(backend.sample())
        run["complete"] = True
    except (KeyboardInterrupt, OSError, ValueError) as error:
        run["collection_error"] = type(error).__name__
    finally:
        try:
            metadata["build_sha256_after"] = file_digest(executable)
        except OSError:
            run["complete"] = False
            run["collection_error"] = "executable_unavailable_after_collection"
        try:
            write_private_json(directory, "run.json", run)
            if len(run["samples"]) >= 2:
                write_private_json(directory, "summary.json", summarize(run))
        finally:
            os.close(directory)
    print(f"Saved private observation: {args.output / 'run.json'}")
    return 0 if run["complete"] else 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser(
        "collect", help="Explicitly observe CPU; never changes app settings."
    )
    capture.add_argument(
        "--executable",
        type=Path,
        default=Path("/Applications/Retrace.app/Contents/MacOS/Retrace"),
    )
    capture.add_argument("--build-sha256")
    capture.add_argument("--arm", choices=("baseline", "enabled"), required=True)
    capture.add_argument("--sequence", type=int, choices=range(1, 5), required=True)
    capture.add_argument("--seconds", type=int, choices=range(1, 601), default=300)
    capture.add_argument("--interval", type=int, choices=range(1, 6), default=1)
    capture.add_argument("--protocol-id", required=True)
    capture.add_argument("--matched-config-sha256", required=True)
    capture.add_argument("--environment-sha256", required=True)
    capture.add_argument("--output", type=Path, required=True)
    report = commands.add_parser(
        "compare",
        help="Report matched observations without inventing latency evidence.",
    )
    report.add_argument("runs", type=Path, nargs=4)
    report.add_argument("--attestation", type=Path, required=True)
    report.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "collect":
            if not 1 <= len(args.protocol_id) <= 80:
                raise ValueError("Protocol ID must contain 1 through 80 characters.")
            return collect(args)
        result = compare(
            [read_json(path) for path in args.runs], read_json(args.attestation)
        )
        directory = private_directory(args.output)
        try:
            write_private_json(directory, "comparison.json", result)
        finally:
            os.close(directory)
        print(
            f"CPU: {result['cpu_status']}; additional observed one-core percentage points: "
            f"{result['conservative_additional_percentage_points']:.3f}"
        )
        return 0 if result["cpu_status"] == "within_target" else 2
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
