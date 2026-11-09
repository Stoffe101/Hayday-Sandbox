#!/usr/bin/env bash
# Visual tests: render the real app under Xvfb (software OpenGL) at several
# resolutions / UI scales and save screenshots to artifacts/screens/.
# Usage: tools/ci/visual_tests.sh [scenarios] [WxH:scale ...]
set -euo pipefail
cd "$(dirname "$0")/../.."
SCEN="${1:-all}"; shift || true
[ "$#" -gt 0 ] && CONFIGS=("$@") || CONFIGS=(1920x1080:1 2560x1440:1.25 3440x1440:1 3840x2160:2)
OUT="artifacts/screens"; mkdir -p "$OUT"; touch artifacts/.gdignore
GODOT="${GODOT:-godot}"
# Each run gets a fresh, isolated user-data folder (XDG_DATA_HOME), so runs are
# deterministic and the real data folder — layouts, settings and any private
# asset packs in user://asset_packs — is never touched or shown in screenshots.
DATA_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hayday-vt.XXXXXX")"
trap 'rm -rf "$DATA_ROOT"' EXIT
fail=0
for cfg in "${CONFIGS[@]}"; do
  res="${cfg%%:*}"; scale="${cfg##*:}"
  rm -rf "$DATA_ROOT/data"; mkdir -p "$DATA_ROOT/data"
  log=$(XDG_DATA_HOME="$DATA_ROOT/data" timeout 600 xvfb-run -a -s "-screen 0 ${res}x24" "$GODOT" --path . --rendering-driver opengl3 --audio-driver Dummy \
        -- --capture --out="$OUT" --scale="$scale" --scenarios="$SCEN" 2>&1 || true)
  echo "$log" | grep -E "^(SHOT|FAIL|EXPORT)|SCRIPT ERROR" || true
  if echo "$log" | grep -qE "^FAIL|SCRIPT ERROR"; then fail=1; fi
done
exit $fail
