#!/usr/bin/env bash
# Reply to a PR review thread and/or resolve it.
#
# Usage:
#   reply_resolve.sh <pr-url> <comment-id> [--body-file FILE|-] [--resolve] [--dry-run]
#
#   <pr-url>      https://github.com/OWNER/REPO/pull/N
#   <comment-id>  Numeric id of any comment in the thread (the `databaseId`, or
#                 the number after #discussion_r in a comment link).
#   --body-file   Markdown reply body, or `-` for stdin. Sent as JSON, so
#                 newlines and code blocks survive.
#   --resolve     Resolve the thread that holds <comment-id>.
#   --dry-run     Print what would happen; post nothing.
#
# Pass at least one of --body-file or --resolve. The reply posts before the
# resolve, so a failed reply leaves the thread open.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

PR_URL="${1:-}"
CID="${2:-}"
[ -n "$PR_URL" ] && [ -n "$CID" ] \
  || die "usage: reply_resolve.sh <pr-url> <comment-id> [--body-file FILE|-] [--resolve] [--dry-run]"
shift 2

BODY_FILE=""
RESOLVE=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --body-file) [ $# -ge 2 ] || die "--body-file needs a value"; BODY_FILE="$2"; shift 2 ;;
    --resolve)   RESOLVE=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    *)           die "unknown argument: $1" ;;
  esac
done
[ -n "$BODY_FILE" ] || [ "$RESOLVE" -eq 1 ] || die "nothing to do: pass --body-file and/or --resolve."
[[ "$CID" =~ ^[0-9]+$ ]] || die "comment-id must be numeric, got '$CID'."

[[ "$PR_URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]] \
  || die "could not parse owner/repo/number from '$PR_URL'."
OWNER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"
NUMBER="${BASH_REMATCH[3]}"

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required."
command -v jq >/dev/null 2>&1 || die "jq is required."

ERR_FILE="$(mktemp -t rib_gh_err.XXXXXX)"
trap 'rm -f "$ERR_FILE"' EXIT

BODY=""
if [ -n "$BODY_FILE" ]; then
  if [ "$BODY_FILE" = "-" ]; then BODY="$(cat)"; else BODY="$(cat "$BODY_FILE")"; fi
  [ -n "${BODY//[[:space:]]/}" ] || die "reply body is empty."
  # Footer so readers know Claude wrote it, not the gh user.
  BODY+=$'\n\n~ Claude'
fi

# Find the thread that holds the comment. Every comment in each thread is
# checked, so a reply's id works as well as the root's.
THREAD_ID=""
if [ "$RESOLVE" -eq 1 ]; then
  THREADS="$(gh api graphql --paginate \
    -F owner="$OWNER" -F repo="$REPO" -F number="$NUMBER" \
    -f query='query($owner:String!,$repo:String!,$number:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){pullRequest(number:$number){
        reviewThreads(first:100,after:$endCursor){
          pageInfo{hasNextPage endCursor}
          nodes{id isResolved comments(first:100){nodes{databaseId}}}}}}}' \
    --jq '.data.repository.pullRequest.reviewThreads.nodes[]' 2>"$ERR_FILE")" \
    || die "could not list review threads: $(cat "$ERR_FILE")"
  read -r THREAD_ID ALREADY < <(jq -r --argjson cid "$CID" \
    'select(any(.comments.nodes[]; .databaseId == $cid)) | "\(.id) \(.isResolved)"' <<<"$THREADS" | head -1) || true
  [ -n "$THREAD_ID" ] || die "no review thread on PR #$NUMBER holds comment $CID."
fi

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN -- $OWNER/$REPO#$NUMBER, comment $CID"
  [ -n "$BODY" ] && { log "would reply:"; jq -n --arg body "$BODY" '{body: $body}'; }
  [ -n "$THREAD_ID" ] && log "would resolve thread $THREAD_ID (already resolved: $ALREADY)"
  exit 0
fi

if [ -n "$BODY" ]; then
  URL="$(jq -n --arg body "$BODY" '{body: $body}' \
    | gh api "repos/$OWNER/$REPO/pulls/$NUMBER/comments/$CID/replies" \
        --method POST --input - --jq .html_url 2>"$ERR_FILE")" \
    || die "reply to comment $CID failed: $(cat "$ERR_FILE")"
  log "Posted reply: $URL"
fi

if [ -n "$THREAD_ID" ]; then
  if [ "$ALREADY" = "true" ]; then
    log "Thread $THREAD_ID was already resolved."
  else
    gh api graphql -F threadId="$THREAD_ID" \
      -f query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}' \
      --jq .data.resolveReviewThread.thread.isResolved >/dev/null 2>"$ERR_FILE" \
      || die "resolving thread $THREAD_ID failed: $(cat "$ERR_FILE")"
    log "Resolved thread $THREAD_ID."
  fi
fi
