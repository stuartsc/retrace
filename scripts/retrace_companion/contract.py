"""Bounded typed wire contracts. Evidence is data, never executable instructions."""

from __future__ import annotations

import hashlib
import json
import math
import uuid
import re
from typing import Any

MAX_JOB = 768 * 1024
MAX_RESULT = 2 * 1024 * 1024
MAX_OBJECT = 16 * 1024 * 1024


class CompanionError(ValueError):
    """Content-free failure category."""


def encode(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode()


def decode(data: bytes, maximum: int) -> Any:
    if len(data) > maximum:
        raise CompanionError("payload_limit")

    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise CompanionError("duplicate_key")
            value[key] = item
        return value

    try:
        return json.loads(
            data,
            object_pairs_hook=unique,
            parse_constant=lambda _: (_ for _ in ()).throw(
                CompanionError("nonfinite_json")
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CompanionError("invalid_json") from error


def text(value, maximum, allow_empty=False):
    if (
        not isinstance(value, str)
        or len(value.encode()) > maximum
        or "\0" in value
        or (not allow_empty and not value.strip())
    ):
        raise CompanionError("invalid_text")
    return value


def identifier(value):
    if not isinstance(value, str):
        raise CompanionError("invalid_uuid")
    try:
        return str(uuid.UUID(value))
    except ValueError as error:
        raise CompanionError("invalid_uuid") from error


def digest(value):
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(c not in "0123456789abcdef" for c in value)
    ):
        raise CompanionError("invalid_digest")
    return value


def integer(value, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise CompanionError("invalid_integer")
    return value


def timestamp(value):
    if (
        type(value) not in (int, float)
        or not math.isfinite(value)
        or not 0 < value < 253_402_300_000_000
    ):
        raise CompanionError("invalid_time")
    return value


def shape(value, required, optional=()):
    if (
        not isinstance(value, dict)
        or not set(required) <= set(value)
        or set(value) - set(required) - set(optional)
    ):
        raise CompanionError("invalid_shape")


def validate_reference(ref, store):
    shape(
        ref,
        {"sourceStoreID", "kind"},
        {"screen", "transcript", "v23Transcript", "media"},
    )
    if identifier(ref["sourceStoreID"]) != identifier(store):
        raise CompanionError("cross_store_reference")
    kind = ref["kind"]
    if kind not in {"screen", "transcript", "v23Transcript", "media"} or set(ref) != {
        "sourceStoreID",
        "kind",
        kind,
    }:
        raise CompanionError("invalid_reference")
    exact = ref[kind]
    if not isinstance(exact, dict):
        raise CompanionError("invalid_reference")
    if kind in {"screen", "transcript"}:
        if (
            identifier(exact.get("storeID")) != identifier(store)
            or exact.get("source") != "native"
        ):
            raise CompanionError("non_native_reference")
        if kind == "screen":
            shape(
                exact,
                {
                    "storeID",
                    "source",
                    "observationID",
                    "frameID",
                    "extractionRevision",
                    "blockIDs",
                },
            )
            identifier(exact.get("observationID"))
            integer(exact.get("extractionRevision"), 1, 2**63 - 1)
            frame = exact.get("frameID")
            if not isinstance(frame, dict):
                raise CompanionError("invalid_reference")
            integer(frame.get("value"), 1, 2**63 - 1)
            blocks = exact["blockIDs"]
            if (
                not isinstance(blocks, list)
                or len(blocks) > 256
                or any(type(item) is not int or item < 0 for item in blocks)
                or len(set(blocks)) != len(blocks)
            ):
                raise CompanionError("invalid_reference")
        else:
            shape(
                exact,
                {
                    "storeID",
                    "source",
                    "segmentID",
                    "transcriptRevision",
                    "startTime",
                    "endTime",
                },
            )
            text(exact.get("segmentID"), 128)
            integer(exact.get("transcriptRevision"), 1, 2**63 - 1)
            if (
                any(
                    type(exact[key]) not in (int, float)
                    or not math.isfinite(exact[key])
                    for key in ("startTime", "endTime")
                )
                or not 0 <= exact["startTime"] <= exact["endTime"]
            ):
                raise CompanionError("invalid_reference")
    elif kind == "v23Transcript":
        shape(exact, {"version", "nativeStoreID", "source", "rowID", "snapshotSHA256"})
        integer(exact["version"], 1, 1)
        integer(exact["rowID"], 1, 2**63 - 1)
        digest(exact["snapshotSHA256"])
        if identifier(exact["nativeStoreID"]) != identifier(store) or exact[
            "source"
        ] not in {"microphone", "system"}:
            raise CompanionError("non_native_reference")
    else:
        shape(
            exact,
            {
                "nativeStoreID",
                "source",
                "recordingGeneration",
                "continuityID",
                "sampleRate",
                "startSample",
                "endSample",
                "approximateOrigin",
                "timingPrecision",
            },
        )
        if (
            identifier(exact.get("nativeStoreID")) != identifier(store)
            or exact.get("source") != "microphone"
        ):
            raise CompanionError("non_native_reference")
        identifier(exact.get("recordingGeneration"))
        identifier(exact.get("continuityID"))
        integer(exact.get("sampleRate"), 16000, 16000)
        start = integer(exact.get("startSample"), 0, 2**63 - 1)
        integer(exact.get("endSample"), start + 1, min(2**63 - 1, start + 960000))
        timestamp(exact["approximateOrigin"])
        if exact["timingPrecision"] not in {"phraseAligned", "enclosingTimedSpan"}:
            raise CompanionError("invalid_reference")


def validate_job(job):
    shape(
        job, {"version", "kind", "sourceStoreID", "observedAt"}, {"context", "speaker"}
    )
    integer(job["version"], 1, 1)
    identifier(job["sourceStoreID"])
    timestamp(job["observedAt"])
    kind = job["kind"]
    if kind not in {"context", "speaker"} or set(job) != {
        "version",
        "kind",
        "sourceStoreID",
        "observedAt",
        kind,
    }:
        raise CompanionError("invalid_kind")
    if kind == "speaker":
        validate_speaker(job["speaker"], job["sourceStoreID"])
        return
    context = job["context"]
    shape(
        context,
        {
            "markerID",
            "markerRevision",
            "snapshotID",
            "query",
            "verbatimExplanation",
            "evidence",
            "developing",
            "incomplete",
        },
        {"expectedProposalHead"},
    )
    for key in ("markerID", "markerRevision", "snapshotID"):
        identifier(context[key])
    if "expectedProposalHead" in context:
        identifier(context["expectedProposalHead"])
    text(context["query"], 8192)
    text(context["verbatimExplanation"], 16384, True)
    if (
        type(context["developing"]) is not bool
        or type(context["incomplete"]) is not bool
    ):
        raise CompanionError("invalid_coverage")
    evidence = context["evidence"]
    if not isinstance(evidence, list) or len(evidence) > 256:
        raise CompanionError("evidence_limit")
    seen = set()
    total = 0
    for item in evidence:
        shape(
            item,
            {"id", "reference", "start", "end", "text"},
            {"appName", "windowTitle"},
        )
        item_id = text(item["id"], 160)
        if item_id in seen:
            raise CompanionError("duplicate_evidence")
        seen.add(item_id)
        if timestamp(item["start"]) > timestamp(item["end"]):
            raise CompanionError("invalid_interval")
        total += len(text(item["text"], 8192).encode())
        for label in ("appName", "windowTitle"):
            if label in item:
                text(item[label], 512, True)
        validate_reference(item["reference"], job["sourceStoreID"])
    if total > 512 * 1024:
        raise CompanionError("evidence_limit")


def validate_speaker(speaker, store):
    shape(
        speaker,
        {"sourceIdentity", "firstPassText", "firstPassReferences", "media"},
        {"firstPassSourceIdentity"},
    )
    identity = speaker["sourceIdentity"]
    shape(
        identity,
        {
            "recordingGeneration",
            "continuityID",
            "startSample",
            "sampleCount",
            "sampleRate",
            "approximateOrigin",
        },
    )
    identifier(identity["recordingGeneration"])
    identifier(identity["continuityID"])
    integer(identity["sampleRate"], 16000, 16000)
    start = integer(identity["startSample"], 0, 2**63 - 1)
    count = integer(identity["sampleCount"], 1, min(960000, 2**63 - 1 - start))
    timestamp(identity["approximateOrigin"])
    original = speaker.get("firstPassSourceIdentity")
    if original is not None:
        shape(original, set(identity))
        for key in (
            "recordingGeneration",
            "continuityID",
            "sampleRate",
            "approximateOrigin",
        ):
            if original[key] != identity[key]:
                raise CompanionError("first_pass_source_mismatch")
        original_start = integer(original["startSample"], 0, start)
        original_count = integer(
            original["sampleCount"], 1, min(960000, 2**63 - 1 - original_start)
        )
        if original_start + original_count < start + count:
            raise CompanionError("first_pass_source_mismatch")
    text(speaker["firstPassText"], 128 * 1024, True)
    references = speaker["firstPassReferences"]
    if not isinstance(references, list) or not 1 <= len(references) <= 1024:
        raise CompanionError("first_pass_reference_limit")
    row_ids = set()
    for reference in references:
        validate_reference(
            {
                "sourceStoreID": store,
                "kind": "v23Transcript",
                "v23Transcript": reference,
            },
            store,
        )
        if reference["source"] != "microphone" or reference["rowID"] in row_ids:
            raise CompanionError("invalid_first_pass_reference")
        row_ids.add(reference["rowID"])
    media = speaker["media"]
    if not isinstance(media, list) or not 1 <= len(media) <= 32:
        raise CompanionError("media_limit")
    cursor = start
    for item in media:
        shape(
            item,
            {
                "sha256",
                "byteCount",
                "mediaID",
                "offsetSamples",
                "countSamples",
                "sourceStartSample",
            },
        )
        digest(item["sha256"])
        digest(item["mediaID"])
        integer(item["byteCount"], 1, MAX_OBJECT)
        offset = integer(item["offsetSamples"], 0, 1920000)
        amount = integer(item["countSamples"], 1, 1920000 - offset)
        if item["sourceStartSample"] != cursor:
            raise CompanionError("discontinuous_source")
        cursor += amount
    if cursor != start + count:
        raise CompanionError("sample_count_mismatch")


def validate_result(result, job, job_id):
    shape(
        result,
        {"version", "jobID", "kind", "sourceStoreID"},
        {"contextProposal", "speakerEnrichment"},
    )
    if (
        result["version"] != 1
        or result["jobID"] != job_id
        or result["kind"] != job["kind"]
        or identifier(result["sourceStoreID"]) != identifier(job["sourceStoreID"])
    ):
        raise CompanionError("result_identity")
    if job["kind"] == "context":
        if set(result) != {
            "version",
            "jobID",
            "kind",
            "sourceStoreID",
            "contextProposal",
        }:
            raise CompanionError("invalid_result")
        proposal = result["contextProposal"]
        source = job["context"]
        shape(
            proposal,
            {
                "markerID",
                "markerRevision",
                "snapshotID",
                "ranges",
                "verbatimExplanation",
                "developing",
                "incomplete",
                "method",
            },
        )
        for field in (
            "markerID",
            "markerRevision",
            "snapshotID",
            "verbatimExplanation",
            "developing",
            "incomplete",
        ):
            if proposal[field] != source[field]:
                raise CompanionError("proposal_identity")
        if not isinstance(proposal["ranges"], list) or len(proposal["ranges"]) > 16:
            raise CompanionError("range_limit")
        evidence = {item["id"]: item for item in source["evidence"]}
        used = set()
        for item in proposal["ranges"]:
            shape(item, {"id", "start", "end", "explanation", "supportIDs", "score"})
            identifier(item["id"])
            text(item["explanation"], 4096)
            if not isinstance(item["supportIDs"], list) or len(item["supportIDs"]) != 1:
                raise CompanionError("invalid_support")
            support = evidence.get(item["supportIDs"][0])
            if (
                not support
                or support["id"] in used
                or item["start"] != support["start"]
                or item["end"] != support["end"]
            ):
                raise CompanionError("invalid_support")
            expected_explanation = (
                support["text"]
                if len(support["text"].encode()) <= 4096
                else "Local semantic ranking selected exact supporting evidence "
                + support["id"]
                + ". The complete excerpt is retained with the proposal."
            )
            if item["explanation"] != expected_explanation:
                raise CompanionError("invalid_explanation_dependency")
            used.add(support["id"])
            if (
                type(item["score"]) not in (float, int)
                or not math.isfinite(item["score"])
                or not 0 <= item["score"] <= 1
            ):
                raise CompanionError("invalid_score")
        text(proposal["method"], 256)
    else:
        if set(result) != {
            "version",
            "jobID",
            "kind",
            "sourceStoreID",
            "speakerEnrichment",
        }:
            raise CompanionError("invalid_result")
        enrichment = result["speakerEnrichment"]
        shape(
            enrichment,
            {
                "sourceIdentity",
                "firstPassSHA256",
                "enhancedText",
                "turns",
                "automaticNamesCalibrated",
                "modelFingerprint",
            },
        )
        if (
            enrichment["sourceIdentity"] != job["speaker"]["sourceIdentity"]
            or enrichment["firstPassSHA256"]
            != hashlib.sha256(job["speaker"]["firstPassText"].encode()).hexdigest()
        ):
            raise CompanionError("speaker_identity")
        # No held-out precision receipt exists for the retained Outlook matcher.
        if enrichment["automaticNamesCalibrated"] is not False:
            raise CompanionError("uncalibrated_name")
        text(enrichment["enhancedText"], 128 * 1024, True)
        digest(enrichment["modelFingerprint"])
        turns = enrichment["turns"]
        if not isinstance(turns, list) or len(turns) > 4096:
            raise CompanionError("turn_limit")
        previous = -1.0
        text_bytes = 0
        inference_id = None
        for turn in turns:
            shape(
                turn,
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
            if turn["speakerStatus"] not in {
                "unknown",
                "suggested",
                "overlap",
            }:
                raise CompanionError("uncalibrated_name")
            text(turn.get("speakerLabel"), 256)
            text(turn.get("text"), 128 * 1024)
            text_bytes += len(turn["text"].encode())
            if text_bytes > 128 * 1024:
                raise CompanionError("turn_limit")
            if not (
                type(turn.get("start")) in (float, int)
                and type(turn.get("end")) in (float, int)
                and 0
                <= turn["start"]
                < turn["end"]
                <= job["speaker"]["sourceIdentity"]["sampleCount"] / 16000
                and turn["start"] >= previous
            ):
                raise CompanionError("turn_timing")
            previous = turn["start"]
            speaker_id = text(turn["speakerID"], 160)
            match = re.fullmatch(
                r"([0-9a-f]{64}):(cluster|state):([A-Za-z0-9_-]{1,64})", speaker_id
            )
            if match is None or (inference_id is not None and inference_id != match[1]):
                raise CompanionError("speaker_identity")
            inference_id = match[1]
            status = turn["speakerStatus"]
            if match[2] == "cluster":
                if turn["speakerLabel"] != "Speaker " + match[3] or status == "overlap":
                    raise CompanionError("uncalibrated_name")
            elif (
                not (
                    (
                        match[3] == "unknown"
                        and status == "unknown"
                        and turn["speakerLabel"] == "Unknown speaker"
                    )
                    or (
                        match[3] == "overlap"
                        and status == "overlap"
                        and turn["speakerLabel"] == "Overlapping voices"
                    )
                )
                or turn["similarity"] is not None
            ):
                raise CompanionError("speaker_identity")
            score = turn["similarity"]
            if score is not None and (
                type(score) not in (float, int)
                or not math.isfinite(score)
                or not -1 <= score <= 1
            ):
                raise CompanionError("invalid_score")
            if status == "suggested":
                if match[2] != "cluster" or score is None:
                    raise CompanionError("speaker_identity")
                text(turn["candidateName"], 256)
                text(turn["personID"], 128)
            elif turn["candidateName"] is not None or turn["personID"] is not None:
                raise CompanionError("uncalibrated_name")
