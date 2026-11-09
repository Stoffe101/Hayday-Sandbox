#!/usr/bin/env bash
# Reproducible build: imports the project, exports the portable Windows app
# and a Linux verification build, then runs the in-app self-test against the
# EXPORTED Linux binary (proves data/art are packaged correctly).
#   tools/build/build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/../.."
MODE="${1:-release}"
GODOT="${GODOT:-godot}"
VER="$("$GODOT" --version | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?)\.stable.*/\1/')"
TPL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates/${VER}.stable"
if [ ! -f "$TPL_DIR/windows_release_x86_64.exe" ]; then
  echo "Downloading Godot $VER export templates…"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/t.tpz" "https://github.com/godotengine/godot/releases/download/${VER}-stable/Godot_v${VER}-stable_export_templates.tpz"
  mkdir -p "$TPL_DIR"; unzip -q "$tmp/t.tpz" -d "$tmp"; cp "$tmp/templates/"* "$TPL_DIR/"; rm -rf "$tmp"
fi
"$GODOT" --headless --path . --import >/dev/null 2>&1 || true
mkdir -p build/windows build/linux
"$GODOT" --headless --path . --export-$MODE "Windows Desktop" build/windows/HaydaySandbox.exe
"$GODOT" --headless --path . --export-$MODE "Linux (verification)" build/linux/HaydaySandbox.x86_64
# Portable bundle
cp README.md build/windows/README.md 2>/dev/null || true
mkdir -p build/windows/licenses
cp assets/ui/fonts/OFL.txt build/windows/licenses/Nunito-OFL.txt
cp assets/ui/LUCIDE_LICENSE.txt build/windows/licenses/Lucide-ISC.txt
cp LICENSE build/windows/licenses/HaydaySandbox-LICENSE.txt 2>/dev/null || true
cp docs/THIRD_PARTY_NOTICES.md build/windows/licenses/ 2>/dev/null || true
(cd build && rm -f HaydaySandbox-windows-x86_64.zip && zip -qr HaydaySandbox-windows-x86_64.zip windows)
file build/windows/HaydaySandbox.exe
ls -la build/windows build/*.zip
echo "Verifying exported Linux build with the in-app self-test…"
"./build/linux/HaydaySandbox.x86_64" --headless -- --selftest | tail -3
