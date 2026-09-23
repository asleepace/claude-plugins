#!/usr/bin/env bash
# Post a batched code review to a GitHub PR from a findings file.
#
# Usage:
#   submit_review.sh <findings.json> [--dry-run] [--event EVENT] [--open] [--no-open]
#   cat findings.json | submit_review.sh - [--dry-run]
#
# About the tooling choice (graphite vs gh):
#   Posting inline review comments, ```suggestion blocks, and thread replies is
#   only possible through GitHub's review API. The Graphite CLI (gt) manages
#   stacks and PR create/submit/checkout, but it has no command to post review
#   feedback -- Graphite's own docs tell you to leave comments on GitHub, and it
#   two-way-syncs them into the Graphite UI. So the submission always goes through
#   `gh`. Where the graphite-vs-gh choice is real is *opening* the PR to keep
#   reviewing: with --open we prefer `gt pr` (Graphite's review surface) when gt
#   is installed, and fall back to `gh pr view --web` otherwise.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

FINDINGS=""
DRY_RUN=0
EVENT_OVERRIDE=""
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --open)    OPEN=1 ;;
    --no-open) OPEN=0 ;;
    --event=*) EVENT_OVERRIDE="${arg#*=}" ;;
    --event)   die "use --event=EVENT (e.g. --event=COMMENT)" ;;
    -*)        die "unknown flag: $arg" ;;
    *)         FINDINGS="$arg" ;;
  esac
done
[ -n "$FINDINGS" ] || die "missing findings file (or '-' for stdin)."

command -v jq >/dev/null 2>&1 || die "jq is required to build the review payload. Install it (e.g. 'brew install jq')."
if [ "$DRY_RUN" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required and must be authenticated (gh auth status)."
fi

RAW="$( [ "$FINDINGS" = "-" ] && cat || cat "$FINDINGS" )"
echo "$RAW" | jq empty 2>/dev/null || die "findings is not valid JSON."

OWNER="$(jq -r '.pr.owner // empty' <<<"$RAW")"
REPO="$(jq -r '.pr.repo // empty'  <<<"$RAW")"
NUMBER="$(jq -r '.pr.number // empty' <<<"$RAW")"
[ -n "$OWNER" ] && [ -n "$REPO" ] && [ -n "$NUMBER" ] \
  || die "findings.pr must include owner, repo, and number."

EVENT="${EVENT_OVERRIDE:-$(jq -r '.event // "COMMENT"' <<<"$RAW")}"
ENDPOINT="repos/$OWNER/$REPO/pulls/$NUMBER/reviews"

# --- Build the batched payload -------------------------------------------------
# Anchored comments (have path + line) become inline comments. Anchor-less notes
# are folded into the review body under "General notes" so none are dropped.
build_payload() {
  jq --arg event "$EVENT" '
    def nonempty: (.body // "" | gsub("^\\s+|\\s+$";"")) != "";
    (.comments // []) as $all
    | [ $all[] | select(.path and .line and nonempty)
        | { path, line, side: (.side // "RIGHT"), body }
          + ( if .start_line
              then { start_line, start_side: (.start_side // (.side // "RIGHT")) }
              else {} end ) ] as $inline
    | [ $all[] | select(((.path and .line) | not) and nonempty)
        | "- **" + (.path // "general") + "**: " + .body ] as $orphans
    | ((.summary // "") | gsub("^\\s+|\\s+$";"")) as $summary
    | ( if ($orphans | length) > 0
        then $summary + "\n\n### General notes\n" + ($orphans | join("\n"))
        else $summary end | gsub("^\\s+|\\s+$";"") ) as $body
    | { event: $event, body: $body }
      + ( if ($inline | length) > 0 then { comments: $inline } else {} end )
  ' <<<"$RAW"
}

# Fallback: render every inline comment into the body as text, so the review
# still lands if GitHub rejects an anchor (e.g. a line not in the diff).
build_body_only() {
  jq --arg event "$EVENT" '
    def nonempty: (.body // "" | gsub("^\\s+|\\s+$";"")) != "";
    ((.summary // "") | gsub("^\\s+|\\s+$";"")) as $summary
    | [ (.comments // [])[] | select(nonempty)
        | ( if .path and .line
            then "**`" + .path + "` L"
                 + ((.start_line // .line) | tostring)
                 + (if .start_line then "-L" + (.line|tostring) else "" end) + "**\n\n"
            else "" end ) + .body ] as $blocks
    | { event: $event,
        body: ( $summary
                + ( if ($blocks|length) > 0
                    then "\n\n### Inline comments\n\n" + ($blocks | join("\n\n---\n\n"))
                    else "" end ) | gsub("^\\s+|\\s+$";"") ) }
  ' <<<"$RAW"
}

PAYLOAD="$(build_payload)"
N_INLINE="$(jq '(.comments // []) | length' <<<"$PAYLOAD")"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN -- would POST to $ENDPOINT"
  jq . <<<"$PAYLOAD"
  jq -e '.replies and (.replies|length>0)' <<<"$RAW" >/dev/null 2>&1 \
    && { log "would also post replies:"; jq '.replies' <<<"$RAW" >&2; }
  exit 0
fi

# --- Post the review (via gh; see header note on graphite) ---------------------
post() { gh api "$ENDPOINT" --method POST --input - <<<"$1"; }

if post "$PAYLOAD" >/dev/null 2>/tmp/rib_gh_err; then
  log "Posted review with $N_INLINE inline comment(s), event=$EVENT."
else
  log "Batched review rejected ($(cat /tmp/rib_gh_err)); folding comments into the body."
  post "$(build_body_only)" >/dev/null || die "failed to post review: $(cat /tmp/rib_gh_err)"
  log "Posted review (fallback: comments in body), event=$EVENT."
fi

# --- Replies to existing threads ----------------------------------------------
while IFS=$'\t' read -r CID BODY; do
  [ -n "$CID" ] || continue
  if gh api "repos/$OWNER/$REPO/pulls/$NUMBER/comments/$CID/replies" \
        --method POST -f "body=$BODY" >/dev/null 2>/tmp/rib_gh_err; then
    log "Posted reply to comment $CID."
  else
    log "warning: reply to comment $CID failed ($(cat /tmp/rib_gh_err))."
  fi
done < <(jq -r '(.replies // [])[] | select(.in_reply_to and .body)
                | "\(.in_reply_to)\t\(.body|gsub("\n";" "))"' <<<"$RAW")

# --- Optionally open the PR to keep reviewing (graphite preferred) -------------
if [ "$OPEN" -eq 1 ]; then
  if command -v gt >/dev/null 2>&1; then
    log "Opening in Graphite's review UI ..."
    gt pr >/dev/null 2>&1 || gh pr view "$NUMBER" --repo "$OWNER/$REPO" --web
  else
    gh pr view "$NUMBER" --repo "$OWNER/$REPO" --web
  fi
fi