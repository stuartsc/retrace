"""One process-wide bounded Torch policy, before either lazy model path starts."""

import os
import threading

_lock = threading.Lock()
_configured = False


def configure_torch_runtime(threads=2):
    if type(threads) is not int or not 1 <= threads <= 4:
        raise ValueError("invalid_thread_budget")
    global _configured
    with _lock:
        if _configured:
            return
        os.environ["OMP_NUM_THREADS"] = str(threads)
        import torch

        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)
        _configured = True
