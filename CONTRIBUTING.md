# Contributing

Set up with `./scripts/bootstrap`, then run `./scripts/dev`; see the [README](README.md#quick-start). The built-in backend ships only in release builds (`scripts/bundle.sh release`); in development, `./scripts/dev` runs `backend/` and connects the app to it. Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Layout
- `app/` — Swift 6.2 editor. Read `app/AGENTS.md` before changing it: no main-thread file I/O, one undo step per user intent, `AppTheme` tokens, `L10n` copy, MCP end-to-end checks for tool changes.
- `backend/` — FastAPI core plus adapters. See `backend/README.md`.
- `protocol/` — the contract. Change `openapi.yaml` and `fixtures/` together; both sides test against them.

## Add a provider
Copy `backend/adapters/_template`, implement it, and make its conformance suite pass. The editor needs no change: models appear through `/v1/capabilities`.

## Localization
After changing UI copy, run `scripts/localization/sync.sh` (needs Node.js). A new language is one complete `<locale>.lproj` directory with `Localizable.strings` and `InfoPlist.strings`, and must pass `node scripts/localization/check.mjs --require-complete`.

## Checks
Run from the repository root. `rebrand.py` needs Python 3.10 or later; macOS's `python3` is 3.9, so run it through uv.
```bash
(cd backend && uv run pytest)
uvx --with pytest pytest scripts -q
uv run --no-project --python 3.12 scripts/rebrand.py --check --check-vendors
node scripts/localization/check.mjs
(cd app && swift build && swift test)
```

## Commits and pull requests
Titles use `[category] Imperative summary`, for example `[fix] Prevent stale export completion`. Keep commits focused. Fill in every section of the pull request template.
