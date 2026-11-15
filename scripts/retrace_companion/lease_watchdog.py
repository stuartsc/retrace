"""Independent lease monitor; never imports or shares an inference runtime/GIL."""

import argparse
import os
import signal
import sqlite3
import time
from .execution import permitted


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--owner", type=int, required=True)
    parser.add_argument("--ready", type=int, required=True)
    args = parser.parse_args()
    if args.owner <= 1 or os.getppid() != args.owner:
        raise SystemExit(2)

    def stop():
        try:
            os.killpg(args.owner, signal.SIGKILL)
        except ProcessLookupError:
            pass

    try:
        db = sqlite3.connect(f"file:{args.database}?mode=ro", uri=True, timeout=1)
        if not permitted(db, args.job):
            stop()
            return
        os.write(args.ready, b"1")
        os.close(args.ready)
        while os.getppid() == args.owner:
            if not permitted(db, args.job):
                stop()
                return
            time.sleep(0.1)
        # The direct model owner exited; any orphaned decoder must also stop.
        stop()
    except BaseException:
        stop()
        raise


if __name__ == "__main__":
    main()
