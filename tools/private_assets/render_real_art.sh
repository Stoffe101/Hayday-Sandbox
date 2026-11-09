#!/usr/bin/env bash
# Render the REAL app with the user's installed private pack (user://asset_packs)
# under Xvfb and write the screenshots to the PRIVATE root — never artifacts/ or
# the repository (they show original art; see docs/PRIVATE_ASSETS.md).
#   tools/private_assets/render_real_art.sh [scenarios] [WxH:scale ...]
# Env: HAYDAY_PRIVATE_ASSETS (default ~/hayday-sandbox-private-assets or /root/...),
#      LAYOUT (default <root>/layouts/real_art_test.hdlayout), OUT (default <root>/screens),
#      TAG (file name prefix), SELECT (items for the "selection" scenario, a+b+c),
#      EXTRA_ARGS (more capture options, e.g. --outline-all).
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT="${HAYDAY_PRIVATE_ASSETS:-}"
if [ -z "$ROOT" ]; then
  for c in "$HOME/hayday-sandbox-private-assets" /root/hayday-sandbox-private-assets; do
    [ -d "$c" ] && ROOT="$c" && break
  done
fi
[ -n "$ROOT" ] || { echo "no private root (set HAYDAY_PRIVATE_ASSETS)"; exit 2; }
OUT="${OUT:-$ROOT/screens}"
LAYOUT="${LAYOUT:-$ROOT/layouts/real_art_test.hdlayout}"
REPO="$(pwd -P)"
case "$(cd "$(dirname "$OUT")" 2>/dev/null && pwd -P || echo "$OUT")/" in
  "$REPO"/*) echo "refusing to write private screenshots inside the repository: $OUT"; exit 2 ;;
esac
mkdir -p "$OUT"
SCEN="${1:-overview,zoomed,place_valid,selection,search,asset_manager}"; shift || true
[ "$#" -gt 0 ] && CONFIGS=("$@") || CONFIGS=(1920x1080:1 2560x1440:1.25 3440x1440:1 3840x2160:2)
SELECT="${SELECT:-field+apple_tree+bakery+feed_mill+dairy+sugar_mill+popcorn_pot+chicken_coop+cow_pasture+fence}"
GODOT="${GODOT:-godot}"
fail=0
for cfg in "${CONFIGS[@]}"; do
  res="${cfg%%:*}"; scale="${cfg##*:}"
  log=$(timeout 900 xvfb-run -a -s "-screen 0 ${res}x24" "$GODOT" --path . --rendering-driver opengl3 --audio-driver Dummy \
        -- --capture --real-art --open="$LAYOUT" --out="$OUT" --scale="$scale" --scenarios="$SCEN" \
        --tag="${TAG:-real_}" --select-items="$SELECT" ${EXTRA_ARGS:-} 2>&1 || true)
  echo "$log" | grep -E "^(SHOT|FAIL|EXPORT)|SCRIPT ERROR|ERROR:" || true
  if echo "$log" | grep -qE "^FAIL|SCRIPT ERROR"; then fail=1; fi
done
exit $fail
