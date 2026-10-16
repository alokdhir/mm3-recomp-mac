#!/usr/bin/env bash
# Keep our changes to the pinned upstream submodules as patch files.
#
#   scripts/patches.sh save    write patches/<name>.patch from the working trees
#   scripts/patches.sh apply   apply patches/<name>.patch to clean submodules
#
# The submodules stay at their pinned upstream commits; the port's edits to
# them live here, so a fresh clone reproduces them and an upstream bump is a
# rebase of a readable diff.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULES=(
    "mm3-recomp:third_party/mm3-recomp"
    "xboxrecomp:third_party/mm3-recomp/tools/xboxrecomp"
)

case "${1:-}" in
save)
    for m in "${MODULES[@]}"; do
        name="${m%%:*}" dir="$ROOT/${m#*:}"
        git -C "$dir" add -N . >/dev/null
        git -C "$dir" diff --binary HEAD -- . ':(exclude)tools/xboxrecomp' ':(exclude)game_files' \
            > "$ROOT/patches/$name.patch"
        git -C "$dir" reset -q
        echo "patches/$name.patch: $(grep -c '^diff --git' "$ROOT/patches/$name.patch") files"
    done
    ;;
apply)
    for m in "${MODULES[@]}"; do
        name="${m%%:*}" dir="$ROOT/${m#*:}" patch="$ROOT/patches/$name.patch"
        [ -s "$patch" ] || continue
        if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
            echo "$name: already applied"
        else
            git -C "$dir" apply "$patch"
            echo "$name: applied"
        fi
    done
    ;;
*)
    echo "usage: $0 save|apply" >&2
    exit 2
    ;;
esac
