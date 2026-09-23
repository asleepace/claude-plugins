#!/usr/bin/env bash
# Resolve a PR reference, fetch its head ref, and create an isolated
# detached-HEAD worktree so a review never touches the user's working tree.
#
# Usage:
#   setup_worktree.sh <pr-ref> [worktree-dir]
#
#   <pr-ref>       A PR URL (https://github.com/OWNER/REPO/pull/N),
#                  a bare number (N, resolved against the current repo),
#                  or anything `gh pr view` accepts.
#   [worktree-dir] Optional explicit path for the worktree. Defaults to a
#                  sibling dir: <repo>-review-worktrees/pr-<N>.
#
# Emits a single line of JSON on stdout with the fields the rest of the
# workflow needs. All human-facing logging goes to stderr so stdout stays
# clean for machine parsing.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

command -v gh  >/dev/null 2>&1 || die "gh (GitHub CLI) is required and must be authenticated (gh auth status)."
command -v git >/dev/null 2>&1 || die "git is required."

PR_REF="${1:-}"
[ -n "$PR_REF" ] || die "missing PR reference. Pass a URL or number."
WT_OVERRIDE="${2:-}"

# Resolve the PR via gh. When PR_REF is a URL, gh infers the repo; when it is a
# bare number, gh uses the repo of the current directory.
log "Resolving PR $PR_REF ..."
PR_JSON="$(gh pr view "$PR_REF" \
  --json number,headRefName,headRefOid,baseRefName,url,title,state 2>/dev/null)" \
  || die "could not resolve PR '$PR_REF'. If you passed a bare number, run this from inside the repo."

# Pull fields out of the gh JSON without assuming jq is installed.
read -r NUMBER BASE_REF HEAD_SHA URL <<EOF
$(python3 - "$PR_JSON" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
print(d["number"], d["baseRefName"], d["headRefOid"], d["url"])
PY
)
EOF

# Owner/repo come straight from the canonical PR url, which is unambiguous even
# for cross-fork PRs (the url always points at the base repo).
read -r OWNER REPO <<EOF
$(python3 - "$URL" <<'PY'
import re, sys
m = re.search(r"github\.com/([^/]+)/([^/]+)/pull/\d+", sys.argv[1])
if not m:
    sys.exit("could not parse owner/repo from url: " + sys.argv[1])
print(m.group(1), m.group(2))
PY
)
EOF

TITLE="$(python3 - "$PR_JSON" <<'PY'
import json, sys
print(json.loads(sys.argv[1])["title"])
PY
)"

# We host the worktree inside a local checkout of the repo. Assume the current
# directory is inside that checkout (true when run from the monorepo).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository. cd into a local checkout of $OWNER/$REPO first."

# GitHub exposes every PR head at refs/pull/<N>/head. Fetching that ref works
# for same-repo and fork PRs alike and needs no local branch, so it can't
# collide with the user's branches.
log "Fetching PR head (pull/$NUMBER/head) ..."
git -C "$REPO_ROOT" fetch --quiet origin "pull/$NUMBER/head"
FETCHED_SHA="$(git -C "$REPO_ROOT" rev-parse FETCH_HEAD)"
[ -n "$HEAD_SHA" ] || HEAD_SHA="$FETCHED_SHA"

# Make sure the base branch is present locally so the review can diff against it.
log "Fetching base ref ($BASE_REF) ..."
git -C "$REPO_ROOT" fetch --quiet origin "$BASE_REF" || \
  log "warning: could not fetch base ref '$BASE_REF'; diff base may be stale."

if [ -n "$WT_OVERRIDE" ]; then
  WT_DIR="$WT_OVERRIDE"
else
  WT_DIR="$(dirname "$REPO_ROOT")/$(basename "$REPO_ROOT")-review-worktrees/pr-$NUMBER"
fi

mkdir -p "$(dirname "$WT_DIR")"

if git -C "$REPO_ROOT" worktree list --porcelain | grep -qxF "worktree $WT_DIR"; then
  log "Worktree already exists at $WT_DIR; reusing and moving it to the PR head."
  git -C "$WT_DIR" checkout --quiet --detach "$FETCHED_SHA"
else
  log "Creating worktree at $WT_DIR (detached at PR head) ..."
  git -C "$REPO_ROOT" worktree add --quiet --detach "$WT_DIR" "$FETCHED_SHA"
fi

# Diff base: the merge-base of the PR head and the base branch, so the review
# sees exactly what the PR adds (three-dot semantics) and nothing from unrelated
# movement on the base branch.
DIFF_BASE="origin/$BASE_REF"

python3 - "$OWNER" "$REPO" "$NUMBER" "$BASE_REF" "$HEAD_SHA" "$WT_DIR" "$URL" "$TITLE" "$DIFF_BASE" "$REPO_ROOT" <<'PY'
import json, sys
keys = ["owner","repo","number","base_ref","head_sha","worktree",
        "url","title","diff_base","repo_root"]
vals = sys.argv[1:]
d = dict(zip(keys, vals))
d["number"] = int(d["number"])
print(json.dumps(d))
PY

log "Worktree ready: $WT_DIR"