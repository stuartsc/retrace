"""Versioned immutable audio jobs. No access to Retrace or FuseIntel databases.

The request filename is SHA-256 of its exact JSON bytes. Media objects are named
by SHA-256 too. Sample ranges are ordered, 16 kHz mono, and gap-free; a recording
gap starts a new job. AAC padding outside a requested range is never analyzed.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import stat
import subprocess
import tempfile
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

RATE = 16_000
MAX_SAMPLES = RATE * 120
MAX_MEDIA_BYTES = 16 * 1024 * 1024
MAX_REQUEST_BYTES = 64 * 1024
MAX_RESULT_BYTES = 2 * 1024 * 1024
HEX = re.compile(r"[0-9a-f]{64}\Z")


class JobError(ValueError):
    """Content-free failure category suitable for a durable retry receipt."""


def integer(value: Any, minimum: int, maximum: int) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise JobError("invalid_integer")
    return value


def digest(value: Any) -> str:
    if not isinstance(value, str) or HEX.fullmatch(value) is None:
        raise JobError("invalid_digest")
    return value


def _object(value: Any, keys: set[str]) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise JobError("invalid_shape")
    return value


@dataclass(frozen=True)
class MediaRange:
    sha256: str
    byte_count: int
    offset: int
    count: int
    start_ms: int
    media_id: str


@dataclass(frozen=True)
class Job:
    identifier: str
    store_id: str
    source: str
    generation: int
    start_ms: int
    media: tuple[MediaRange, ...]

    @property
    def sample_count(self) -> int:
        return sum(item.count for item in self.media)

    @property
    def end_ms(self) -> int:
        return self.start_ms + self.sample_count * 1000 // RATE

    @classmethod
    def parse(cls, value: Any, identifier: str) -> Job:
        obj = _object(
            value,
            {
                "version",
                "storeID",
                "source",
                "generation",
                "startMilliseconds",
                "media",
            },
        )
        integer(obj["version"], 1, 1)
        if not isinstance(obj["storeID"], str):
            raise JobError("invalid_store")
        try:
            store_id = str(uuid.UUID(obj["storeID"]))
        except ValueError as error:
            raise JobError("invalid_store") from error
        if obj["source"] not in ("microphone", "system"):
            raise JobError("invalid_source")
        start = integer(obj["startMilliseconds"], 1, 253_402_300_000_000)
        generation = integer(obj["generation"], 1, 2**63 - 1)
        entries = obj["media"]
        if not isinstance(entries, list) or not 1 <= len(entries) <= 32:
            raise JobError("media_limit")
        ranges: list[MediaRange] = []
        identities: dict[str, tuple[MediaRange, int]] = {}
        object_sizes: dict[str, int] = {}
        count = 0
        for entry in entries:
            row = _object(
                entry,
                {
                    "sha256",
                    "byteCount",
                    "offsetSamples",
                    "countSamples",
                    "startMilliseconds",
                    "mediaID",
                },
            )
            item = MediaRange(
                digest(row["sha256"]),
                integer(row["byteCount"], 1, MAX_MEDIA_BYTES),
                integer(row["offsetSamples"], 0, MAX_SAMPLES),
                integer(row["countSamples"], 1, MAX_SAMPLES),
                integer(row["startMilliseconds"], start, 253_402_300_000_000),
                digest(row["mediaID"]),
            )
            if (
                item.offset + item.count > MAX_SAMPLES
                or count + item.count > MAX_SAMPLES
            ):
                raise JobError("sample_limit")
            if item.start_ms != start + count * 1000 // RATE:
                raise JobError("discontinuous_samples")
            previous = identities.get(item.media_id)
            if previous is not None:
                first, first_position = previous
                if (
                    item.sha256 != first.sha256
                    or item.byte_count != first.byte_count
                    or item.offset - first.offset != count - first_position
                ):
                    raise JobError("source_range_conflict")
            else:
                identities[item.media_id] = (item, count)
            if object_sizes.setdefault(item.sha256, item.byte_count) != item.byte_count:
                raise JobError("source_range_conflict")
            count += item.count
            ranges.append(item)
        return cls(
            digest(identifier),
            store_id,
            obj["source"],
            generation,
            start,
            tuple(ranges),
        )


def _reject_constant(_: str) -> None:
    raise JobError("nonfinite_json")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise JobError("duplicate_key")
        result[key] = value
    return result


def load_job(path: Path) -> Job:
    if not path.name.endswith(".job.json"):
        raise JobError("invalid_request_name")
    identifier = digest(path.name.removesuffix(".job.json"))
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as reader:
        if not stat.S_ISREG(os.fstat(reader.fileno()).st_mode):
            raise JobError("not_regular_request")
        data = reader.read(MAX_REQUEST_BYTES + 1)
    if len(data) > MAX_REQUEST_BYTES:
        raise JobError("request_limit")
    if hashlib.sha256(data).hexdigest() != identifier:
        raise JobError("request_digest")
    try:
        value = json.loads(
            data, parse_constant=_reject_constant, object_pairs_hook=_unique_object
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise JobError("invalid_json") from error
    return Job.parse(value, identifier)


def _decode_media(
    item: MediaRange, media_root: Path, temporary: Path, ffmpeg: str
) -> Path:
    source = media_root / (item.sha256 + ".m4a")
    try:
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as error:
        raise JobError("media_unavailable") from error
    with os.fdopen(fd, "rb") as reader:
        metadata = os.fstat(reader.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != item.byte_count:
            raise JobError("media_size")
        data = reader.read(MAX_MEDIA_BYTES + 1)
        if (
            len(data) != item.byte_count
            or hashlib.sha256(data).hexdigest() != item.sha256
        ):
            raise JobError("media_digest")
    # Decode a private snapshot of the exact verified bytes. Holding the original
    # descriptor alone cannot prevent another writer changing the same inode.
    with tempfile.TemporaryFile(dir=temporary) as snapshot:
        snapshot.write(data)
        snapshot.flush()
        snapshot.seek(0)
        del data
        output = temporary / (item.sha256 + ".wav")
        try:
            subprocess.run(
                [
                    ffmpeg,
                    "-nostdin",
                    "-v",
                    "error",
                    "-protocol_whitelist",
                    "file,pipe,fd",
                    "-f",
                    "mov",
                    "-i",
                    f"/dev/fd/{snapshot.fileno()}",
                    "-map",
                    "0:a:0",
                    "-vn",
                    "-sn",
                    "-dn",
                    "-t",
                    "120.25",
                    "-ac",
                    "1",
                    "-ar",
                    str(RATE),
                    "-c:a",
                    "pcm_s16le",
                    "-y",
                    str(output),
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                pass_fds=(snapshot.fileno(),),
                check=True,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise JobError("decode_failed") from error
        if output.stat().st_size > (MAX_SAMPLES + RATE) * 2 + 4096:
            raise JobError("decoded_limit")
        return output


def decode_window(
    job: Job, media_root: Path, destination: Path, *, ffmpeg: str = "ffmpeg"
) -> None:
    """Decode immutable objects once and copy only requested native sample ranges."""
    with tempfile.TemporaryDirectory(prefix="retrace-window-") as temporary:
        decoded: dict[str, Path] = {}
        try:
            with wave.open(str(destination), "wb") as writer:
                writer.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
                for item in job.media:
                    if item.sha256 not in decoded:
                        decoded[item.sha256] = _decode_media(
                            item, media_root, Path(temporary), ffmpeg
                        )
                    with wave.open(str(decoded[item.sha256]), "rb") as reader:
                        if (
                            reader.getparams()[:3] != (1, 2, RATE)
                            or reader.getnframes() < item.offset + item.count
                        ):
                            raise JobError("decoded_range_unavailable")
                        reader.setpos(item.offset)
                        data = reader.readframes(item.count)
                        if len(data) != item.count * 2:
                            raise JobError("decoded_range_unavailable")
                        writer.writeframes(data)
        except (OSError, wave.Error) as error:
            raise JobError("window_write_failed") from error


def load_result(path: Path, job: Job) -> dict[str, Any]:
    """An existing path is never evidence that its result is complete or belongs to this job."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as reader:
            if not stat.S_ISREG(os.fstat(reader.fileno()).st_mode):
                raise JobError("invalid_existing_result")
            data = reader.read(MAX_RESULT_BYTES + 1)
        if len(data) > MAX_RESULT_BYTES:
            raise JobError("result_limit")
        value = json.loads(
            data, parse_constant=_reject_constant, object_pairs_hook=_unique_object
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise JobError("invalid_existing_result") from error
    validate_result(value, job)
    return value


def validate_result(value: Any, job: Job) -> None:
    expected = {
        "version": 1,
        "jobID": job.identifier,
        "storeID": job.store_id,
        "generation": job.generation,
        "source": job.source,
        "status": "complete",
        "startMilliseconds": job.start_ms,
        "endMilliseconds": job.end_ms,
        "sampleCount": job.sample_count,
        "automaticNamesCalibrated": False,
    }
    if not isinstance(value, dict) or any(
        type(value.get(k)) is not type(v) or value.get(k) != v
        for k, v in expected.items()
    ):
        raise JobError("result_identity")

    def text(item: Any, limit: int, *, label: bool = False) -> str:
        if not isinstance(item, str) or len(item) > limit:
            raise JobError("invalid_result_text")
        try:
            if len(item.encode("utf-8")) > limit:
                raise JobError("invalid_result_text")
        except UnicodeEncodeError as error:
            raise JobError("invalid_result_text") from error
        if label and (not item.strip() or any(ord(char) < 32 for char in item)):
            raise JobError("invalid_result_label")
        return item

    text(value.get("text"), 128 * 1024)
    required = set(expected) | {
        "text",
        "segments",
        "models",
        "language",
        "unplacedWords",
        "voiceReferenceCount",
        "processingSeconds",
        "totalSeconds",
        "processPeakResidentBytes",
    }
    _object(value, required)
    if value["models"] != json.loads(
        Path(__file__).with_name("runtime-pins.json").read_text()
    ):
        raise JobError("result_model_provenance")
    if value["language"] is not None:
        language = text(value["language"], 32, label=True)
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", language) is None:
            raise JobError("invalid_result_language")
    integer(value["unplacedWords"], 0, 4096)
    integer(value["voiceReferenceCount"], 0, 1_000_000)
    integer(value["processPeakResidentBytes"], 1, 2**50)
    for key in ("totalSeconds", "processingSeconds"):
        duration = value[key]
        if (
            type(duration) not in (float, int)
            or not 0 <= duration <= 7200
            or not math.isfinite(duration)
        ):
            raise JobError("invalid_result_duration")
    if value["processingSeconds"] > value["totalSeconds"]:
        raise JobError("invalid_result_duration")
    segments = value.get("segments")
    if not isinstance(segments, list) or len(segments) > 4096:
        raise JobError("invalid_result_segments")
    previous = -1.0
    text_bytes = 0
    for row in segments:
        _object(
            row,
            {
                "start",
                "end",
                "text",
                "speakerID",
                "speakerLabel",
                "speakerStatus",
                "candidateName",
                "personID",
                "similarity",
            },
        )
        start, end = row.get("start"), row.get("end")
        if (
            type(start) not in (int, float)
            or type(end) not in (int, float)
            or not 0 <= start < end <= job.sample_count / RATE
            or start < previous
            or not math.isfinite(start)
            or not math.isfinite(end)
        ):
            raise JobError("invalid_result_timing")
        previous = start
        text_bytes += len(text(row["text"], 128 * 1024, label=True).encode("utf-8"))
        if text_bytes > 128 * 1024:
            raise JobError("result_limit")
        status = row["speakerStatus"]
        if status not in ("unknown", "overlap", "suggested"):
            raise JobError("uncalibrated_speaker_name")
        speaker_id = text(row["speakerID"], 160, label=True)
        label = text(row["speakerLabel"], 256, label=True)
        cluster = re.fullmatch(
            re.escape(job.identifier) + r":cluster:([A-Za-z0-9_-]{1,64})", speaker_id
        )
        if cluster:
            if label != "Speaker " + cluster.group(1) or status == "overlap":
                raise JobError("invalid_result_speaker")
        elif speaker_id == job.identifier + ":state:overlap":
            if (
                status != "overlap"
                or label != "Overlapping voices"
                or row["similarity"] is not None
            ):
                raise JobError("invalid_result_speaker")
        elif speaker_id == job.identifier + ":state:unknown":
            if (
                status != "unknown"
                or label != "Unknown speaker"
                or row["similarity"] is not None
            ):
                raise JobError("invalid_result_speaker")
        else:
            raise JobError("invalid_result_speaker")
        score = row["similarity"]
        if score is not None and (
            type(score) not in (float, int)
            or not -1 <= score <= 1
            or not math.isfinite(score)
        ):
            raise JobError("invalid_similarity")
        if status == "suggested":
            if cluster is None or score is None:
                raise JobError("invalid_result_speaker")
            text(row["candidateName"], 256, label=True)
            text(row["personID"], 128, label=True)
        elif row["candidateName"] is not None or row["personID"] is not None:
            raise JobError("invalid_result_speaker")


def initialize_directory(directory: Path) -> None:
    """Create private directories and durably publish each new parent entry."""
    # macOS /var and /tmp are system symlinks. Canonicalize the caller-owned
    # parent, then walk/create its children without following replacement links.
    path = directory.parent.resolve() / directory.name
    fd = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            if component in (".", ".."):
                raise JobError("invalid_directory")
            created = False
            try:
                os.mkdir(component, 0o700, dir_fd=fd)
                created = True
            except FileExistsError:
                pass
            child = os.open(
                component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd
            )
            try:
                if created:
                    os.fsync(child)
                    os.fsync(fd)
            except BaseException:
                os.close(child)
                raise
            os.close(fd)
            fd = child
    finally:
        os.close(fd)


def publish_result(directory: Path, identifier: str, result: dict[str, Any]) -> None:
    """Atomic, durable, idempotent publication. A differing result is never overwritten."""
    digest(identifier)
    if result.get("version") != 1 or result.get("jobID") != identifier:
        raise JobError("result_identity")
    data = json.dumps(
        result, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode()
    if len(data) > MAX_RESULT_BYTES:
        raise JobError("result_limit")
    directory = directory.parent.resolve() / directory.name
    initialize_directory(directory)
    destination = directory / (identifier + ".json")
    with tempfile.NamedTemporaryFile(
        dir=directory, prefix=".result-", delete=False
    ) as writer:
        temporary = Path(writer.name)
        try:
            writer.write(data)
            writer.flush()
            os.fsync(writer.fileno())
            try:
                os.link(temporary, destination, follow_symlinks=False)
            except FileExistsError:
                fd = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as existing:
                    if (
                        not stat.S_ISREG(os.fstat(existing.fileno()).st_mode)
                        or existing.read(MAX_RESULT_BYTES + 1) != data
                    ):
                        raise JobError("result_conflict")
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            temporary.unlink(missing_ok=True)
