"""One process-wide bounded Torch policy, before either lazy model path starts."""

import os
import threading

_lock = threading.Lock()
_configured = False


def configure_torch_runtime():
    global _configured
    with _lock:
        if _configured:
            return
        os.environ["OMP_NUM_THREADS"] = "2"
        import torch

        torch.set_num_threads(2)
        torch.set_num_interop_threads(1)
        _configured = True
