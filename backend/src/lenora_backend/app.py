import asyncio
import logging
import os
import signal
from collections.abc import Callable
from contextlib import asynccontextmanager, suppress

import httpx
from fastapi import Depends, FastAPI

from lenora_backend import __version__
from lenora_backend.auth import require_token
from lenora_backend.errors import install_error_handlers
from lenora_backend.idempotency import IdempotencyStore
from lenora_backend.parent import watch_parent
from lenora_backend.registry import Registry
from lenora_backend.results import ResultStore
from lenora_backend.routes import assets, capabilities, health, jobs, results, uploads
from lenora_backend.settings import CoreSettings

HTTP_TIMEOUT = httpx.Timeout(connect=5.0, read=30.0, write=30.0, pool=5.0)
SWEEP_INTERVAL_SECONDS = 3600
log = logging.getLogger("lenora.results")


async def _sweep(store: ResultStore) -> None:
    try:
        await store.sweep()
    except OSError as error:
        log.warning("result sweep failed: %s", type(error).__name__)
    except Exception:
        # The hourly sweeper must outlive any single failure.
        log.exception("result sweep failed unexpectedly")


async def _sweep_hourly(store: ResultStore) -> None:
    while True:
        await asyncio.sleep(SWEEP_INTERVAL_SECONDS)
        await _sweep(store)


def create_app(settings: CoreSettings, load_registry: Callable[[httpx.AsyncClient], Registry] = Registry.load,
               on_ready: Callable[[], None] | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.results = ResultStore(settings.data_dir / "results")
        await _sweep(app.state.results)
        sweeper = asyncio.create_task(_sweep_hourly(app.state.results))
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, follow_redirects=False) as http:
            registry: Registry | None = None
            try:
                registry = app.state.registry = load_registry(http)
                await registry.start(settings.provider_timeout_seconds)
                watcher = None
                if settings.parent_pid is not None:
                    watcher = asyncio.create_task(
                        watch_parent(settings.parent_pid, lambda: os.kill(os.getpid(), signal.SIGTERM)))
                if on_ready is not None:
                    on_ready()
                try:
                    yield
                finally:
                    if watcher is not None:
                        watcher.cancel()
                        with suppress(asyncio.CancelledError):
                            await watcher
            finally:
                if registry is not None:
                    await registry.stop(settings.provider_timeout_seconds)
                sweeper.cancel()
                with suppress(asyncio.CancelledError):
                    await sweeper

    docs = "/docs" if settings.docs_enabled else None
    app = FastAPI(title="lenora-backend", version=__version__, lifespan=lifespan,
                  docs_url=docs, redoc_url=None, openapi_url="/openapi.json" if docs else None)
    app.state.settings = settings
    install_error_handlers(app)
    protected = [Depends(require_token)]
    app.include_router(health.router, prefix="/v1")
    app.include_router(capabilities.router, prefix="/v1", dependencies=protected)
    app.state.idempotency = IdempotencyStore()
    app.include_router(uploads.router, prefix="/v1", dependencies=protected)
    app.include_router(jobs.router, prefix="/v1", dependencies=protected)
    app.include_router(assets.router, prefix="/v1", dependencies=protected)
    app.include_router(results.router, prefix="/v1", dependencies=protected)
    return app
