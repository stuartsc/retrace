"""Word-level speaker attribution without claiming an uncalibrated identity."""

from __future__ import annotations

import math
import re
from typing import Any

from .contract import JobError, digest


def _time(value: Any) -> float:
    if (
        type(value) not in (float, int)
        or not 0 <= value <= 120
        or not math.isfinite(value)
    ):
        raise JobError("invalid_alignment_time")
    return float(value)


def _label(value: Any, maximum: int) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or len(value) > maximum
        or any(ord(c) < 32 for c in value)
    ):
        raise JobError("invalid_alignment_label")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError as error:
        raise JobError("invalid_alignment_label") from error
    return value


def align_words(
    words: list[dict[str, Any]], turns: list[dict[str, Any]], *, job_id: str
) -> list[dict[str, Any]]:
    digest(job_id)
    if (
        not isinstance(words, list)
        or not isinstance(turns, list)
        or len(words) > 4096
        or len(turns) > 4096
    ):
        raise JobError("alignment_limit")
    clusters: dict[str, dict[str, Any]] = {}
    for turn in turns:
        if not isinstance(turn, dict) or not {"start", "end", "cluster"}.issubset(turn):
            raise JobError("invalid_turn")
        start, end = _time(turn["start"]), _time(turn["end"])
        if start >= end:
            raise JobError("invalid_turn_range")
        cluster = _label(turn["cluster"], 64)
        if re.fullmatch(r"[a-zA-Z0-9_-]+", cluster) is None:
            raise JobError("invalid_cluster")
        person, candidate, score = (
            turn.get("personID"),
            turn.get("candidateName"),
            turn.get("score"),
        )
        if person is not None or candidate is not None:
            person, candidate = _label(person, 128), _label(candidate, 256)
        if score is not None and (
            type(score) not in (float, int)
            or not -1 <= score <= 1
            or not math.isfinite(score)
        ):
            raise JobError("invalid_similarity")
        value = clusters.setdefault(
            cluster,
            {"person": person, "candidate": candidate, "score": score, "ranges": []},
        )
        if (value["person"], value["candidate"]) != (person, candidate):
            raise JobError("inconsistent_speaker")
        value["ranges"].append((start, end))
        if score is not None:
            value["score"] = (
                min(score, value["score"]) if value["score"] is not None else score
            )
    if len(clusters) > 32:
        raise JobError("alignment_limit")
    for value in clusters.values():
        merged: list[tuple[float, float]] = []
        for start, end in sorted(value["ranges"]):
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
            else:
                merged.append((start, end))
        value["ranges"] = merged
    if (
        len(words) * sum(len(value["ranges"]) for value in clusters.values())
        > 2_000_000
    ):
        raise JobError("alignment_limit")

    segments: list[dict[str, Any]] = []
    previous_start = -1.0
    text_bytes = 0
    for word in words:
        if not isinstance(word, dict) or not {"start", "end", "text"}.issubset(word):
            raise JobError("invalid_word")
        start, end = _time(word["start"]), _time(word["end"])
        if start >= end or start < previous_start:
            raise JobError("invalid_word_range")
        previous_start = start
        text = _label(word["text"], 4096).strip()
        text_bytes += len(text.encode("utf-8"))
        if text_bytes > 128 * 1024:
            raise JobError("alignment_limit")
        ranked = sorted(
            (
                (
                    sum(
                        max(0.0, min(end, hi) - max(start, lo))
                        for lo, hi in value["ranges"]
                    ),
                    cluster,
                )
                for cluster, value in clusters.items()
            ),
            reverse=True,
        )
        ambiguous = len(ranked) > 1 and ranked[1][0] / (end - start) >= 0.15
        cluster = (
            ranked[0][1]
            if ranked and ranked[0][0] / (end - start) >= 0.6 and not ambiguous
            else None
        )
        value = clusters[cluster] if cluster else {}
        candidate, person = value.get("candidate"), value.get("person")
        status = (
            "suggested"
            if candidate and person
            else "overlap"
            if ambiguous
            else "unknown"
        )
        row = {
            "start": start,
            "end": end,
            "text": text,
            "speakerID": f"{job_id}:cluster:{cluster}"
            if cluster
            else f"{job_id}:state:{'overlap' if ambiguous else 'unknown'}",
            "speakerLabel": f"Speaker {cluster}"
            if cluster
            else "Overlapping voices"
            if ambiguous
            else "Unknown speaker",
            "speakerStatus": status,
            "candidateName": candidate,
            "personID": person,
            "similarity": value.get("score"),
        }
        if (
            segments
            and all(
                segments[-1][key] == row[key]
                for key in ("speakerID", "speakerStatus", "personID")
            )
            and 0 <= start - segments[-1]["end"] <= 0.8
        ):
            segments[-1]["text"] += " " + text
            segments[-1]["end"] = end
        else:
            segments.append(row)
    return segments
