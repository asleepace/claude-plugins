#!/usr/bin/env bash
# Dump everything /can-approve needs to judge one PR, as sectioned plain text.
# Read-only: nothing is checked out and nothing is posted.
#
# Usage:
#   pr_state.sh <pr-ref> [max-diff-lines]
#
#   <pr-ref>          A PR URL or number (anything `gh pr view` accepts).
#   [max-diff-lines]  Cap on the DIFF section (default 4000). Past the cap the
#                     diff is cut and DIFF_TRUNCATED says so.
set -uo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required."

REF="${1:-}"
[ -n "$REF" ] || die "pass a PR reference."
MAX_DIFF="${2:-4000}"

URL="$(gh pr view "$REF" --json url -q .url 2>/dev/null)" || die "could not resolve PR '$REF'."
OWNER="$(printf '%s' "$URL" | sed -E 's#https://github.com/([^/]+)/.*#\1#')"
REPO="$(printf '%s' "$URL" | sed -E 's#https://github.com/[^/]+/([^/]+)/.*#\1#')"
NUMBER="${URL##*/}"

echo "=== META ==="
gh pr view "$URL" --json number,title,url,state,isDraft,baseRefName,headRefName,headRefOid,mergeable,reviewDecision,additions,deletions,changedFiles \
  -q '"number: \(.number)\ntitle: \(.title)\nurl: \(.url)\nstate: \(.state)\ndraft: \(.isDraft)\nbase: \(.baseRefName)\nhead: \(.headRefName)\nhead_sha: \(.headRefOid)\nmergeable: \(.mergeable)\nreview_decision: \(.reviewDecision)\nsize: +\(.additions) -\(.deletions) in \(.changedFiles) files"'

echo
echo "=== COMMITS === (oldest first; authored date, since restacks reset committer dates)"
gh pr view "$URL" --json commits \
  -q '.commits[] | "\(.authoredDate) \(.oid[0:10]) \(.messageHeadline)"'

echo
echo "=== REVIEWS === (latest review per author)"
gh pr view "$URL" --json reviews \
  -q '[.reviews[] | select(.state != "PENDING")] | group_by(.author.login) | map(max_by(.submittedAt))[]
      | "\(.submittedAt) @\(.author.login) \(.state) on \(.commit.oid[0:10] // "?")" + (if (.body | length) > 0 then "\n    " + (.body | gsub("\n"; "\n    ") | .[0:5000]) else "" end)'

echo
echo "=== THREADS ==="
# shellcheck disable=SC2016
gh api graphql -F owner="$OWNER" -F repo="$REPO" -F number="$NUMBER" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes {
          isResolved isOutdated path line originalLine
          comments(first: 30) { nodes { author { login } createdAt body url } }
        }
      }
    }
  }
}' --jq '
  .data.repository.pullRequest.reviewThreads.nodes as $t
  | "resolved: \([$t[] | select(.isResolved)] | length)",
    "unresolved: \([$t[] | select(.isResolved | not)] | length)",
    "",
    "resolved threads (first and last comment):",
    ($t[] | select(.isResolved)
      | "  + \(.path):\(.line // .originalLine) @\(.comments.nodes[0].author.login): \(.comments.nodes[0].body | split("\n")[0] | .[0:200])"
        + (if (.comments.nodes | length) > 1 then "\n      last @\(.comments.nodes[-1].author.login): \(.comments.nodes[-1].body | split("\n")[0] | .[0:200])" else "" end)),
    "",
    "unresolved threads (full):",
    ($t[] | select(.isResolved | not)
      | "--- \(.path):\(.line // .originalLine)\(if .isOutdated then " (outdated)" else "" end) \(.comments.nodes[0].url)",
        (.comments.nodes[] | "  \(.createdAt) @\(.author.login): \(.body | gsub("\n"; "\n    ") | .[0:1500])"))'

echo
echo "=== CONVERSATION === (top-level PR comments, bots and Graphite stack comments excluded)"
gh api "repos/$OWNER/$REPO/issues/$NUMBER/comments" --paginate \
  --jq '.[] | select(.user.type != "Bot") | select(.body | test("stack-comment") | not) | "\(.created_at) @\(.user.login) \(.html_url)\n    \(.body | gsub("\n"; "\n    ") | .[0:1500])"'

echo
echo "=== CHECKS === (informational only, never a blocker)"
# gh pr checks exits non-zero whenever a check is failing or pending, so ignore its status.
CHECKS="$(gh pr checks "$URL" 2>/dev/null || true)"
if [ -n "$CHECKS" ]; then
  printf '%s\n' "$CHECKS" | awk -F'\t' '{print $2}' | sort | uniq -c | sed 's/^ */  /'
  printf '%s\n' "$CHECKS" | awk -F'\t' '$2 == "fail" {print "  failing: " $1}'
else
  echo "  <unavailable>"
fi

echo
echo "=== FILES ==="
gh pr diff "$URL" --name-only

echo
echo "=== DIFF === (lockfiles, generated locales, and SVGs omitted)"
DIFF="$(gh pr diff "$URL" | awk '
  /^diff --git / {
    skip = ($0 ~ /(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|mix\.lock|Cargo\.lock|poetry\.lock|\.svg|intl_gettext\.rb|intl_messages\.json|intl_yaml\.yml|\.pot|\.po|\.mo)( |$)/)
    if (skip) print "(omitted) " $0
  }
  !skip { print }
')"
LINES="$(printf '%s\n' "$DIFF" | wc -l | tr -d ' ')"
printf '%s\n' "$DIFF" | head -n "$MAX_DIFF"
if [ "$LINES" -gt "$MAX_DIFF" ]; then
  echo
  echo "DIFF_TRUNCATED: showed $MAX_DIFF of $LINES lines. Read the rest with: gh pr diff $URL"
fi
