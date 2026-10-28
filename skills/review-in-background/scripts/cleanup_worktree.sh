#!/usr/bin/env bash
# Remove a review worktree and its pinned head ref once the review is done.
#
# Usage: cleanup_worktree.sh <worktree-dir> [repo-root] [review-ref]
#
#   [repo-root]   The checkout that hosts the worktree (`repo_root` from setup).
#   [review-ref]  The ref setup pinned (`review_ref`, e.g. refs/rib/pr-123).
#                 Only refs under refs/rib/ are deleted.
#
# Uses --force because a detached review worktree may hold fetched objects that
# git considers "modified" relative to no branch; there is nothing to preserve.
set -euo pipefail

WT_DIR="${1:-}"
REPO_ROOT="${2:-}"
REVIEW_REF="${3:-}"
[ -n "$WT_DIR" ] || { echo "usage: cleanup_worktree.sh <worktree-dir> [repo-root] [review-ref]" >&2; exit 1; }

if [ -d "$WT_DIR" ]; then
  # Run the removal from the worktree's own directory so git can find the repo.
  git -C "$WT_DIR" worktree remove --force "$WT_DIR" 2>/dev/null \
    || git ${REPO_ROOT:+-C "$REPO_ROOT"} worktree remove --force "$WT_DIR"
  echo "Removed worktree $WT_DIR"
else
  echo "nothing to clean up: $WT_DIR does not exist." >&2
fi
if [ -n "$REPO_ROOT" ]; then
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
fi

if [ -n "$REVIEW_REF" ]; then
  case "$REVIEW_REF" in
    refs/rib/*) ;;
    *) echo "refusing to delete $REVIEW_REF: not under refs/rib/" >&2; exit 1 ;;
  esac
  [ -n "$REPO_ROOT" ] || { echo "review-ref needs repo-root" >&2; exit 1; }
  if git -C "$REPO_ROOT" show-ref --verify --quiet "$REVIEW_REF"; then
    git -C "$REPO_ROOT" update-ref -d "$REVIEW_REF"
    echo "Deleted $REVIEW_REF"
  fi
fi
