import fcntl
import json
import logging
import socket
import sys
from pathlib import Path
from typing import TextIO

import uvicorn
from pydantic import ValidationError

from lenora_backend.app import create_app
from lenora_backend.settings import load_environment

LOCKED_EXIT_CODE = 3


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"level": record.levelname, "logger": record.name, "message": record.getMessage()})


def acquire_data_dir_lock(data_dir: Path) -> TextIO | None:
    data_dir.mkdir(parents=True, exist_ok=True)
    handle = open(data_dir / "backend.lock", "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def main() -> None:
    try:
        settings = load_environment()
        port = settings.bind_port
    except (ValidationError, ValueError) as error:
        names = {".".join(str(p) for p in e["loc"]) for e in error.errors()} if isinstance(error, ValidationError) else set()
        hint = "LENORA_TOKEN is missing or shorter than 32 characters. Run ./scripts/bootstrap." if "token" in names else str(error)
        print(f"lenora-backend: {hint}", file=sys.stderr)
        sys.exit(2)
    lock = acquire_data_dir_lock(settings.data_dir)
    if lock is None:
        print(f"lenora-backend: another backend is using {settings.data_dir}", file=sys.stderr)
        sys.exit(LOCKED_EXIT_CODE)
    handler = logging.StreamHandler()
    if settings.env == "production":
        handler.setFormatter(JsonFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[handler])
    host = settings.bind_host
    # Bind here so a port-0 request keeps the OS-assigned port from selection to serving.
    sock = socket.create_server((host, port), family=socket.AF_INET6 if ":" in host else socket.AF_INET)
    bound_port = sock.getsockname()[1]
    app = create_app(settings, on_ready=lambda: print(f"LENORA_READY port={bound_port}", flush=True))
    config = uvicorn.Config(app, proxy_headers=settings.env == "production",
                            forwarded_allow_ips=settings.forwarded_allow_ips, log_config=None)
    uvicorn.Server(config).run(sockets=[sock])


if __name__ == "__main__":
    main()
