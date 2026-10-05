#!/bin/bash
# Build a relocatable backend runtime: uv-managed CPython 3.12 plus the locked backend and adapters.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:?usage: build_backend_runtime.sh <out dir>}"
UV="${UV:-uv}"
PY_VERSION="${LENORA_PYTHON_VERSION:-3.12}"
command -v "$UV" >/dev/null || { echo "!! uv is required (https://docs.astral.sh/uv/)" >&2; exit 1; }
# Needs uv >= 0.7 for `python find --managed-python`.

"$UV" python install "$PY_VERSION"
PY_BIN="$("$UV" python find --managed-python "$PY_VERSION")"
PY_HOME="$(cd "$(dirname "$PY_BIN")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$PY_HOME" "$STAGE/python"
PY="$STAGE/python/bin/python3"
STDLIB="$("$PY" -I -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')"
SITE="$("$PY" -I -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
rm -rf "$STDLIB"/{test,idlelib,tkinter,turtledemo,ensurepip} "$STAGE/python/lib"/{tcl*,tk*,itcl*} "$STAGE/python/share"
rm -rf "$SITE"/pip "$SITE"/pip-*.dist-info

(cd "$ROOT/backend" && "$UV" export --frozen --no-dev --all-packages --no-emit-workspace -o "$STAGE/requirements.txt" >/dev/null)
"$UV" pip install --python "$PY" --target "$SITE" --require-hashes --no-deps --compile-bytecode -r "$STAGE/requirements.txt"
"$UV" pip install --python "$PY" --target "$SITE" --no-deps --compile-bytecode \
  "$ROOT/backend" "$ROOT/backend/adapters/cloudinary" "$ROOT/backend/adapters/openai"

mkdir -p "$STAGE/LICENSES/CPython"
cp "$STDLIB/LICENSE.txt" "$STAGE/LICENSES/CPython/LICENSE.txt"
"$PY" -I - "$STAGE/LICENSES" "$ROOT/backend/uv.lock" "$STAGE/MANIFEST.json" <<'PY'
import hashlib, json, platform, sys
from importlib.metadata import distributions
from pathlib import Path
licenses, lock, manifest = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
packages = {}
for dist in distributions():
    name = dist.metadata["Name"]
    packages[name] = dist.version
    target = licenses / name
    target.mkdir(parents=True, exist_ok=True)
    files = [f for f in (dist.files or []) if any(k in f.name.upper() for k in ("LICENSE", "LICENCE", "COPYING", "NOTICE"))]
    for f in files:
        (target / f.name).write_bytes(Path(dist.locate_file(f)).read_bytes())
    if not files and (expr := dist.metadata.get("License-Expression") or dist.metadata.get("License")):
        (target / "LICENSE-METADATA.txt").write_text(expr + "\n")
manifest.write_text(json.dumps({
    "python": platform.python_version(),
    "uvLockSha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
    "packages": dict(sorted(packages.items())),
}, indent=2) + "\n")
PY

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ditto "$STAGE" "$OUT"
rm -f "$OUT/requirements.txt"
echo "==> Backend runtime at $OUT"
