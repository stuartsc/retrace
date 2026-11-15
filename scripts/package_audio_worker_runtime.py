"""Copy the bounded Python worker sources into an uninstalled application bundle."""

import argparse
import hashlib
import json
from pathlib import Path


def package(bundle: Path, source: Path) -> dict:
    bundle = bundle.absolute()
    if bundle.suffix != ".app" or not bundle.is_dir():
        raise ValueError("Expected a staged application bundle")
    for path in (bundle, *bundle.parents):
        if path.is_symlink():
            raise ValueError("Bundle ancestry must not contain symbolic links")
    if bundle.is_relative_to(Path("/Applications")):
        raise ValueError("Refuse to mutate an installed application")
    destination = bundle / "Contents/Resources/AudioWorker"
    for path in (destination, destination.parent, destination.parent.parent):
        if path.is_symlink():
            raise ValueError("Resource path must not contain symbolic links")
    if destination.exists():
        raise ValueError("Worker resources already exist; use a fresh staged bundle")
    files = []
    for name in ("audio_worker", "retrace_companion"):
        folder = source / name
        if folder.is_symlink() or not folder.is_dir():
            raise ValueError("Missing worker source directory")
        for path in sorted(folder.iterdir()):
            if path.suffix not in (".py", ".json"):
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError("Worker input must be a regular file")
            files.append(path)
    if not any(path == source / "retrace_companion/local_job.py" for path in files):
        raise ValueError("Missing local execution entry point")
    manifest = {}
    destination.mkdir(parents=True)
    for path in files:
        relative = path.relative_to(source)
        target = destination / relative
        target.parent.mkdir(exist_ok=True)
        data = path.read_bytes()
        target.write_bytes(data)
        manifest[str(relative)] = hashlib.sha256(data).hexdigest()
    (destination / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n"
    )
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    arguments = parser.parse_args()
    manifest = package(arguments.bundle, Path(__file__).resolve().parent)
    print(f"Packaged {len(manifest)} audio worker inputs")
