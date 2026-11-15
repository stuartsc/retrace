"""Bounded third-pass policy; original quality result is always retained."""

import math
import re


def needs_repair(result, average_logprob=None):
    return (
        result.get("unplacedWords", 0) > 0
        or not result.get("text", "").strip()
        or (
            isinstance(average_logprob, (float, int))
            and math.isfinite(average_logprob)
            and average_logprob < -1.0
        )
    )


def accept_repair(original, candidate, original_score=None, candidate_score=None):
    before, after = original.get("text", ""), candidate.get("text", "")
    if not after.strip() or candidate.get("unplacedWords", 0) > original.get(
        "unplacedWords", 0
    ):
        return False
    if not before.strip():
        return True
    # Model confidence is not evidence that a changed number/negation is correct.
    critical = r"\d+(?:[.,]\d+)*|\b(?:no|not|never|without|cannot|can't|don't|didn't)\b"
    if re.findall(critical, before.lower()) != re.findall(critical, after.lower()):
        return False
    if len(after.split()) < 0.8 * len(before.split()):
        return False
    if candidate.get("unplacedWords", 0) < original.get("unplacedWords", 0):
        return True
    return (
        isinstance(original_score, (float, int))
        and isinstance(candidate_score, (float, int))
        and math.isfinite(candidate_score)
        and candidate_score > original_score + 0.1
    )
