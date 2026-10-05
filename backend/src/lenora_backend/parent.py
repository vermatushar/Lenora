import asyncio
import logging
import os
from collections.abc import Callable

log = logging.getLogger("lenora.parent")


async def watch_parent(parent_pid: int, on_gone: Callable[[], None],
                       getppid: Callable[[], int] = os.getppid, interval: float = 2.0) -> None:
    """Calls on_gone once this process is no longer a child of parent_pid (the parent exited)."""
    while getppid() == parent_pid:
        await asyncio.sleep(interval)
    log.warning("parent process %d is gone; shutting down", parent_pid)
    on_gone()
