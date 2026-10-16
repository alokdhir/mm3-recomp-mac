#!/usr/bin/env bash
# Build Midtown Madness 3 for Apple Silicon from your own disc.
#
#   scripts/setup.sh --iso "/path/to/Midtown Madness 3.iso"   first run
#   scripts/setup.sh                                            rebuild
#   scripts/setup.sh --force --iso ...                          re-extract and regenerate
#
# Steps, each skipped when already done (--force redoes extraction and
# generation): toolchain check, Python venv with the pinned disassembler,
# submodules and the port's patches, disc check and extraction to game_files/,
# recompilation to build/gen, and the arm64 build in build/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ISO="" FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
    --iso) ISO="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null || { echo "missing $1 ($2)" >&2; exit 1; }; }

step "toolchain"
[ "$(uname -sm)" = "Darwin arm64" ] || { echo "Apple Silicon macOS only" >&2; exit 1; }
need clang "xcode-select --install"
need cmake "brew install cmake"
need ninja "brew install ninja"
need python3 "brew install python"
# The Metal shader compiler comes with Xcode (newer Xcodes download it as a
# separate component), not with the command line tools alone.
TOOLCHAINS=Metal xcrun -sdk macosx metal --version >/dev/null 2>&1 || {
    echo "missing the Metal compiler: install Xcode, then run" >&2
    echo "    xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || {
    echo "python3 is too old ($(python3 --version)); brew install python" >&2; exit 1; }

step "python environment"
if [ ! -x "$ROOT/.venv/bin/python" ]; then
    python3 -m venv "$ROOT/.venv"
fi
# Capstone 5.0.7 is the disassembler the translation was verified with.
"$ROOT/.venv/bin/python" -c 'import capstone, sys; sys.exit(capstone.__version__ != "5.0.7")' 2>/dev/null ||
    "$ROOT/.venv/bin/python" -m pip install --quiet --disable-pip-version-check capstone==5.0.7
PY="$ROOT/.venv/bin/python"

step "sources"
git -C "$ROOT" submodule update --init --recursive
"$ROOT/scripts/patches.sh" apply

UPSTREAM="$ROOT/third_party/mm3-recomp"
GAME="$ROOT/game_files"
GEN="$ROOT/build/gen"

step "game files"
if [ -n "$ISO" ] && { [ $FORCE = 1 ] || [ ! -f "$GAME/default.xbe" ]; }; then
    "$PY" -I "$UPSTREAM/scripts/extract_disc.py" "$ISO" --out "$GAME"
elif [ ! -f "$GAME/default.xbe" ]; then
    echo "no game files: run with --iso <your Midtown Madness 3 disc image>" >&2
    exit 1
else
    echo "using $GAME"
fi
# The upstream scripts and runtime look for game_files/ beside themselves.
ln -sfn "$GAME" "$UPSTREAM/game_files"

step "recompilation"
if [ $FORCE = 1 ] || [ ! -f "$GEN/recomp_funcs.h" ]; then
    rm -rf "$GEN"
    "$PY" "$UPSTREAM/scripts/generate_mm3.py" --out "$GEN"
else
    echo "using $GEN"
fi

step "build"
cmake -S "$ROOT" -B "$ROOT/build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
ninja -C "$ROOT/build" mm3_recomp mm3_app

echo
echo "built $ROOT/build/Midtown Madness 3.app"
echo "play:  open \"$ROOT/build/Midtown Madness 3.app\""
echo "  or, with the log in this terminal, from $ROOT:"
echo "       ./build/third_party/mm3-recomp/mm3_recomp"
