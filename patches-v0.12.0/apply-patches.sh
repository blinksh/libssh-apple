#!/bin/bash
#
# Apply Blink/Apple patches to a clean libssh checkout (0.12.0 series).
#
# These patches are git-format-patch style, so we use `git am` instead of
# `git apply` — each patch becomes a real commit on the current branch with
# its original author, date, and message preserved.
#
# Usage:
#   cd libssh                                   # must be at submodule root
#   git checkout -b blink-libssh-v0.12.0 libssh-0.12.0
#   ../patches-v0.12.0/apply-patches.sh         # applies all patches in order
#   ../patches-v0.12.0/apply-patches.sh --dry   # dry run, test applicability only
#
# Patches are applied in numeric order (0001, 0002, ...). If a patch fails,
# resolve the conflict, `git add` the fixed files, and run `git am --continue`.
# Then re-run this script with the remaining patches if needed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRY_RUN=0

if [[ "${1:-}" == "--dry" ]]; then
    DRY_RUN=1
    echo "=== DRY RUN - testing patch applicability ==="
fi

# Numeric-ordered format-patch files (00NN-*.patch). Non-numbered .patch files
# in this directory (e.g. experimental migrations) are intentionally excluded.
shopt -s nullglob
PATCHES=("$SCRIPT_DIR"/[0-9][0-9][0-9][0-9]-*.patch)
shopt -u nullglob

if [[ ${#PATCHES[@]} -eq 0 ]]; then
    echo "No patches found in $SCRIPT_DIR" >&2
    exit 1
fi

FAILED=0
for patch in "${PATCHES[@]}"; do
    name="$(basename "$patch")"

    if [[ $DRY_RUN -eq 1 ]]; then
        if git apply --check "$patch" 2>/dev/null; then
            echo "OK    $name"
        else
            echo "FAIL  $name (conflicts detected)"
            FAILED=1
        fi
    else
        echo "Applying $name ..."
        if ! git am --keep-cr "$patch"; then
            echo ""
            echo "  Patch $name failed to apply cleanly."
            echo "  Resolve conflicts, 'git add' the fixed files, then:"
            echo "    git am --continue"
            echo "  or abort with:"
            echo "    git am --abort"
            exit 1
        fi
    fi
done

if [[ $DRY_RUN -eq 1 && $FAILED -eq 1 ]]; then
    echo ""
    echo "Some patches have conflicts. They will need manual resolution."
    exit 1
fi

if [[ $DRY_RUN -eq 0 ]]; then
    echo ""
    echo "All patches applied successfully."
fi
