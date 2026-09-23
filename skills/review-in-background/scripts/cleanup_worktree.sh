#!/usr/bin/env bash
# Remove a review worktree once its review has been posted.
#
# Usage: cleanup_worktree.sh <worktree-dir>
#
# Uses --force because a detached review worktree may hold fetched objects that
# git considers "modified" relative to no branch; there is nothing to preserve.
set -euo pipefail

WT_DIR="${1:-}"
[ -n "$WT_DIR" ] || { echo "usage: cleanup_worktree.sh <worktree-dir>" >&2; exit 1; }

if [ ! -d "$WT_DIR" ]; then
  echo "nothing to clean up: $WT_DIR does not exist." >&2
  exit 0
fi

# Run the removal from the worktree's own directory so git can find the repo.
git -C "$WT_DIR" worktree remove --force "$WT_DIR" 2>/dev/null \
  || git worktree remove --force "$WT_DIR"
git -C "$(dirname "$WT_DIR")" worktree prune 2>/dev/null || true
echo "Removed worktree $WT_DIR"