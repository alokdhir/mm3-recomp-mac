#!/usr/bin/env bash
# Package the game for another Apple Silicon Mac: a folder holding the app and
# the game data beside it (the app finds game_files/ next to itself; the
# data stays outside the signed bundle because the game writes into it).
#
#   scripts/package.sh            -> build/dist/Midtown Madness 3/  and  .zip
#
# The data is yours, from your disc: this is for your own machines, not for
# sharing. On the other Mac the app is unsigned by Apple: if macOS refuses to
# open it, use System Settings > Privacy & Security > Open Anyway, or run
#   xattr -dr com.apple.quarantine "Midtown Madness 3"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/build/dist"
OUT="$DIST/Midtown Madness 3"

[ -f "$ROOT/game_files/default.xbe" ] || { echo "no game_files: run scripts/setup.sh first" >&2; exit 1; }
ninja -C "$ROOT/build" mm3_app
rm -rf "$OUT" "$DIST/Midtown Madness 3.zip"
mkdir -p "$OUT"
ditto "$ROOT/build/Midtown Madness 3.app" "$OUT/Midtown Madness 3.app"
# The game's files as the disc has them, plus the DSP programs it saved.
rsync -a --exclude 'default_analysis.json' "$ROOT/game_files/" "$OUT/game_files/"
codesign --verify --deep "$OUT/Midtown Madness 3.app"
# Only libraries every Mac has: anything else (Homebrew's, say) is missing on
# the Mac this goes to and the game dies at launch.
EXTRA=$(otool -L "$OUT/Midtown Madness 3.app/Contents/MacOS/mm3_recomp" | tail -n +2 |
        awk '{print $1}' | grep -v -E '^(/System/Library/|/usr/lib/)' || true)
[ -z "$EXTRA" ] || { echo "the game links libraries other Macs lack:" >&2; echo "$EXTRA" >&2; exit 1; }
echo "minimum macOS: $(otool -l "$OUT/Midtown Madness 3.app/Contents/MacOS/mm3_recomp" |
    awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
( cd "$DIST" && ditto -c -k --keepParent "Midtown Madness 3" "Midtown Madness 3.zip" )
du -sh "$OUT" "$DIST/Midtown Madness 3.zip"
echo "copy $DIST/Midtown Madness 3.zip to the other Mac, unzip, open the app"
