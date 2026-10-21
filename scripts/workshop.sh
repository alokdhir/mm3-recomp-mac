#!/bin/bash
# Car Workshop on the Mac: the extra-car editor (mm3-car-tools car-mods)
# on this repo's game_files. Its Save & Apply installs into game_files; when
# the window closes, changed game data is copied into the installed app
# (Contents/Resources/game_files) and the app re-signed.
#
#   scripts/workshop.sh            uses /Applications/Midtown Madness 3.app
#   APP=/path/to.app scripts/workshop.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP=${APP:-/Applications/Midtown Madness 3.app}
PY=$(command -v python3)
"$PY" -c 'import tkinter' 2>/dev/null || { echo "python3 has no Tk: brew install python-tk"; exit 1; }
if pgrep -x mm3_recomp >/dev/null; then
    echo "Quit the game first: Save & Apply rewrites its car data."
    exit 1
fi
STATE="$ROOT/game_files/.mm3-car-mods/state.json"
before=$(stat -f %m "$STATE" 2>/dev/null || echo 0)
(cd third_party/mm3-recomp/tools/car-tools/car-mods && "$PY" editor.py --game-dir "$ROOT/game_files" "$@")
after=$(stat -f %m "$STATE" 2>/dev/null || echo 0)
if [ "$after" != "$before" ] && [ -d "$APP/Contents/Resources/game_files" ]; then
    echo "Copying the applied car data into $APP"
    rsync -a --exclude .mm3-car-mods --exclude default_analysis.json \
        "$ROOT/game_files/" "$APP/Contents/Resources/game_files/"
    codesign --force --sign - "$APP"
else
    echo "Nothing applied; the app is unchanged."
fi
