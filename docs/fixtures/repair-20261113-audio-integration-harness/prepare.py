#!/usr/bin/env python3
"""Recreate the ignored harness from tracked, pinned recipe files; never compile."""
import hashlib
import json
from pathlib import Path
import shutil
import runpy
import subprocess

RECIPE = Path(__file__).resolve().parent
ROOT = RECIPE.parents[2]
DESTINATION = ROOT / ".audio-integration-validation"


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def main():
    snapshot = json.loads((RECIPE / "source-inputs.json").read_text())
    if (DESTINATION / ".build").exists():
        raise RuntimeError("Existing harness build state: do not rewrite a potentially active package")
    if not (ROOT / "Package.resolved").exists():
        shutil.copyfile(RECIPE / "Package.resolved", ROOT / "Package.resolved")
    for entry in snapshot["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise RuntimeError("Input must stay inside the production worktree")
        if digest(ROOT / relative) != entry["sha256"]:
            raise RuntimeError("Pinned production input changed: " + str(relative))
    if digest(RECIPE / "run.py") != snapshot["runnerSHA256"]:
        raise RuntimeError("Tracked runner no longer matches its reviewed hash")
    if digest(RECIPE / "Package.swift") != snapshot["harnessPackageSHA256"]:
        raise RuntimeError("Tracked package manifest hash mismatch")
    DESTINATION.mkdir(exist_ok=True)
    for name in snapshot["copiedPaths"]:
        target = DESTINATION / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, target)
    for name in ("Package.swift", "Package.resolved", "run.py"):
        shutil.copyfile(RECIPE / name, DESTINATION / name)
    snapshot["productionRoot"] = str(ROOT.resolve())
    snapshot["checkoutCommitAtPreparation"] = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    (DESTINATION / "source-inputs.json").write_text(json.dumps(snapshot, indent=2) + "\n")
    verified = runpy.run_path(str(DESTINATION / "run.py"))["verify"]()
    print(json.dumps({"verified": verified, "compilationAttempted": False}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
