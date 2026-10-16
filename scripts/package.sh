#!/usr/bin/env bash
# Package the game for another Apple Silicon Mac: one self-contained app with
# the game data inside it (Contents/Resources/game_files, the only place the
# app looks; it writes nothing there), signed again over the data.
#
#   scripts/package.sh            -> build/dist/Midtown Madness 3.app  and  .zip
#
# The data is yours, from your disc: this is for your own machines, not for
# sharing. On the other Mac the app is unsigned by Apple: if macOS refuses to
# open it, use System Settings > Privacy & Security > Open Anyway, or run
#   xattr -dr com.apple.quarantine "Midtown Madness 3.app"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/build/dist"
OUT="$DIST/Midtown Madness 3.app"

[ -f "$ROOT/game_files/default.xbe" ] || { echo "no game_files: run scripts/setup.sh first" >&2; exit 1; }
ninja -C "$ROOT/build" mm3_app
rm -rf "$OUT" "$DIST/Midtown Madness 3" "$DIST/Midtown Madness 3.zip"
mkdir -p "$DIST"
ditto "$ROOT/build/Midtown Madness 3.app" "$OUT"
rm -f "$OUT/Contents/Resources/game_files"     # the build tree's link: real files instead
# The game's files as the disc has them, plus the DSP programs it saved.
rsync -a --exclude 'default_analysis.json' "$ROOT/game_files/" "$OUT/Contents/Resources/game_files/"
codesign --force --sign - "$OUT"
codesign --verify --deep --strict "$OUT"
# Only libraries every Mac has: anything else (Homebrew's, say) is missing on
# the Mac this goes to and the game dies at launch.
EXTRA=$(otool -L "$OUT/Contents/MacOS/mm3_recomp" | tail -n +2 |
        awk '{print $1}' | grep -v -E '^(/System/Library/|/usr/lib/)' || true)
[ -z "$EXTRA" ] || { echo "the game links libraries other Macs lack:" >&2; echo "$EXTRA" >&2; exit 1; }
echo "minimum macOS: $(otool -l "$OUT/Contents/MacOS/mm3_recomp" |
    awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
( cd "$DIST" && ditto -c -k --keepParent "Midtown Madness 3.app" "Midtown Madness 3.zip" )
du -sh "$OUT" "$DIST/Midtown Madness 3.zip"
echo "copy $DIST/Midtown Madness 3.zip to the other Mac, unzip, drag the app to Applications"
