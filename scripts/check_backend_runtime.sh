#!/bin/bash
# Verify a built backend runtime directory: imports, adapters, licenses, signatures, and a real ready line.
set -euo pipefail
DIR="${1:?usage: check_backend_runtime.sh <Backend dir>}"
PY="$DIR/python/bin/python3"
fail() { echo "!! $*" >&2; exit 1; }

[ -x "$PY" ] || fail "missing $PY"
"$PY" -I -B -c '
import lenora_backend, lenora_adapter_cloudinary, lenora_adapter_openai
from importlib.metadata import entry_points
names = {e.name for e in entry_points(group="lenora.adapters")}
assert {"cloudinary", "openai"} <= names, names
assert "template" not in names, names
' || fail "runtime imports or adapter entry points are wrong"

[ -f "$DIR/MANIFEST.json" ] || fail "missing MANIFEST.json"
[ -f "$DIR/LICENSES/CPython/LICENSE.txt" ] || fail "missing CPython license"
"$PY" -I -B - "$DIR/LICENSES" <<'PY' || fail "a bundled distribution has no license text"
import sys
from importlib.metadata import distributions
from pathlib import Path
root = Path(sys.argv[1])
missing = [d.metadata["Name"] for d in distributions() if not any((root / d.metadata["Name"]).glob("*"))]
assert not missing, missing
PY

while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    codesign --verify --strict "$f" 2>/dev/null || fail "unsigned Mach-O: ${f#$DIR/}"
  fi
done < <(find "$DIR" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)

DATA="$(mktemp -d)"
trap 'rm -rf "$DATA" "$DATA.log"; [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true' EXIT
exec 3< <(env -i PATH=/usr/bin:/bin HOME="$DATA" LENORA_ENV=production LENORA_HOST=127.0.0.1 LENORA_PORT=0 \
  LENORA_DATA_DIR="$DATA" LENORA_TOKEN="$(openssl rand -hex 32)" \
  "$PY" -I -B -m lenora_backend 2>"$DATA.log" & echo "PID $!"; wait)
read -r -u 3 _ PID
read -r -t 90 -u 3 LINE || { cat "$DATA.log" >&2; fail "runtime printed no ready line within 90 s"; }
[[ "$LINE" =~ ^LENORA_READY\ port=[0-9]{1,5}$ ]] || { cat "$DATA.log" >&2; fail "unexpected first line: $LINE"; }
echo "==> Backend runtime OK ($LINE)"
