"""Explicit private companion transport/worker. Neither mode starts automatically."""

import argparse
import os
from pathlib import Path

from .server import make_server
from .worker import run_worker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["serve", "worker"])
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--outlook", type=Path, default=Path.home() / "outlook")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9013)
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.mode == "worker":
        run_worker(args.root, args.outlook, args.once)
    else:
        server = make_server(
            (args.bind, args.port), args.root, os.environ.get("RETRACE_COMPANION_TOKEN")
        )
        try:
            server.serve_forever()
        finally:
            server.server_close()
            server.companion_queue.close()


if __name__ == "__main__":
    main()
