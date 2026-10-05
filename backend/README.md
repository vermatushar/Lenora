# lenora-backend

The reference backend for the [Lenora Backend Protocol](../protocol/README.md). FastAPI core, plus adapters discovered through the `lenora.adapters` entry-point group.

## Run locally

```bash
uv sync
uv run lenora-backend          # reads ../.env in development
```

`LENORA_ENV=development` (default) reads `.env`, binds `127.0.0.1:8787` and serves `/docs`. `LENORA_ENV=production` reads only the process environment, binds `0.0.0.0:$PORT`, logs JSON and has no `/docs`. Both refuse to start without `LENORA_TOKEN`.

## Configuration

| Variable | Required | Default |
|---|---|---|
| `LENORA_TOKEN` | yes | — |
| `LENORA_ENV` | no | `development` |
| `PORT` / `LENORA_PORT` | production | 8787 in development |
| `LENORA_PROVIDER_TIMEOUT_SECONDS` | no | 60 |
| `LENORA_CLOUDINARY_CLOUD_NAME`, `_API_KEY`, `_API_SECRET` | to enable Cloudinary | — |
| `LENORA_CLOUDINARY_ON_THE_FLY_VIDEO_MAX_BYTES` | no | 41943040 |
| `LENORA_CLOUDINARY_IMAGE_GENERATION`, `_IMAGE_TO_VIDEO` | no | `auto` |
| `LENORA_DATA_DIR` | no | `.data` |
| `LENORA_CLOUDINARY_DAILY_CREDIT_BUDGET` | no | unlimited |
| `LENORA_CLOUDINARY_COST_IMAGE_GENERATION`, `_COST_IMAGE_TO_VIDEO_PER_SECOND` | no | `1.0` |
| `LENORA_OPENAI_API_KEY` (or `OPENAI_API_KEY`) | to enable OpenAI | — |
| `LENORA_OPENAI_DAILY_BUDGET_USD` | no | 5.0 (`0` = no cap) |
| `LENORA_OPENAI_SPEECH_MODEL`, `_REWRITE_MODEL` | no | `gpt-4o-mini-tts`, `gpt-5.4-mini` |
| `LENORA_FORWARDED_ALLOW_IPS` | behind a proxy | `*` in the Docker image |

An adapter with missing settings is disabled. `GET /v1/health` (with the token) shows why.

- `LENORA_PORT=0` binds an OS-assigned port. The backend prints `LENORA_READY port=<n>` to stdout once startup finishes; logs go to stderr.
- `LENORA_PARENT_PID` makes the backend shut down when that process exits. The app sets it for its built-in backend.
- Only one backend may use a data directory; a second exits with code 3.

Stored results (OpenAI voiceovers and rewrites) are served from `/v1/results/{id}` on the backend's own origin and expire after 24 hours.

## Deploy

`docker build -t lenora-backend backend` and run it with `LENORA_TOKEN` and the adapter keys in the platform's environment. Idempotency keys live in memory, so run a single instance. Mount a volume at `/data` to keep chain jobs, learned add-on state, stored results and `openai.key` across restarts.

Result URLs (`/v1/results/{id}`) are built from the request's scheme and `Host` header. Behind a TLS-terminating proxy, `LENORA_FORWARDED_ALLOW_IPS` must cover the proxy's address so uvicorn trusts `X-Forwarded-Proto` and `X-Forwarded-For`; the Docker image defaults it to `*`, so narrow it if the container is reachable without the proxy. uvicorn ignores `X-Forwarded-Host`, so the proxy must pass the client's original `Host` header through unchanged.

## Write an adapter

Copy `adapters/_template` and follow its README. `lenora_backend.testing.conformance.AdapterConformance` checks your adapter against the protocol rules.

## Test

```bash
uv run pytest                 # unit, contract, conformance (mocked)
uv run pytest -m live         # real providers; needs keys
```
