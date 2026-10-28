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

# Footer on every posted body so readers know Claude wrote it, not the gh user.
SIG=$'\n\n~ Claude'

# --- Build the batched payload -------------------------------------------------
# Anchored comments (have path + line) become inline comments. Anchor-less notes
# are folded into the review body under "General notes" so none are dropped.
build_payload() {
  jq --arg event "$EVENT" --arg sig "$SIG" '
    def nonempty: (.body // "" | gsub("^\\s+|\\s+$";"")) != "";
    (.comments // []) as $all
    | [ $all[] | select(.path and .line and nonempty)
        | { path, line, side: (.side // "RIGHT"), body: (.body + $sig) }
          + ( if .start_line
              then { start_line, start_side: (.start_side // (.side // "RIGHT")) }
              else {} end ) ] as $inline
    | [ $all[] | select(((.path and .line) | not) and nonempty)
        | "- **" + (.path // "general") + "**: " + .body ] as $orphans
    | ((.summary // "") | gsub("^\\s+|\\s+$";"")) as $summary
    | ( if ($orphans | length) > 0
        then $summary + "\n\n### General notes\n" + ($orphans | join("\n"))
        else $summary end | gsub("^\\s+|\\s+$";"") ) as $body
    | { event: $event, body: (if $body == "" then $body else $body + $sig end) }
      + ( if ($inline | length) > 0 then { comments: $inline } else {} end )
  ' <<<"$RAW"
}

# Fallback: render every inline comment into the body as text, so the review
# still lands if GitHub rejects an anchor (e.g. a line not in the diff).
build_body_only() {
  jq --arg event "$EVENT" --arg sig "$SIG" '
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
                    else "" end ) | gsub("^\\s+|\\s+$";"") ) + $sig }
  ' <<<"$RAW"
}

ERR_FILE="$(mktemp -t rib_gh_err.XXXXXX)"
trap 'rm -f "$ERR_FILE"' EXIT

# --- Validate anchors against the PR diff --------------------------------------
# One bad anchor makes GitHub reject the whole batch, which would push every
# comment into the body. Check each anchor against the diff hunks first and
# demote only the bad ones to general notes.
validate_anchors() {
  local files
  files="$(gh api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/files" \
             --jq '.[] | {filename, patch}' 2>"$ERR_FILE")" || {
    log "warning: could not list PR files ($(cat "$ERR_FILE")); skipping anchor check."
    return 0
  }
  RAW="$(python3 -I -c '
import json, re, sys

raw = json.loads(sys.argv[1])
dec, text, i, valid = json.JSONDecoder(), sys.argv[2], 0, {}
while i < len(text):
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text):
        break
    f, i = dec.raw_decode(text, i)
    right, left, old, new = set(), set(), 0, 0
    for line in (f.get("patch") or "").split("\n"):
        m = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
        if m:
            old, new = int(m[1]), int(m[2])
        elif line.startswith("+"):
            right.add(new); new += 1
        elif line.startswith("-"):
            left.add(old); old += 1
        elif not line.startswith("\\"):
            right.add(new); left.add(old); new += 1; old += 1
    valid[f["filename"]] = {"RIGHT": right, "LEFT": left}

for c in raw.get("comments", []):
    if not (c.get("path") and c.get("line")):
        continue
    ok = valid.get(c["path"], {}).get(c.get("side", "RIGHT"), set())
    start = c.get("start_line")
    if all(n in ok for n in ([c["line"]] + ([start] if start else []))):
        continue
    where = "L%s" % (start or c["line"]) + ("-L%s" % c["line"] if start else "")
    print("demoted %s %s: not in the diff" % (c["path"], where), file=sys.stderr)
    c["body"] = where + ": " + c["body"]
    c.pop("line"); c.pop("start_line", None)
print(json.dumps(raw))
' "$RAW" "$files")"
}

if command -v gh >/dev/null 2>&1; then
  validate_anchors
else
  log "warning: gh not found; skipping anchor check."
fi

PAYLOAD="$(build_payload)"
N_INLINE="$(jq '(.comments // []) | length' <<<"$PAYLOAD")"

if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN -- would POST to $ENDPOINT"
  jq . <<<"$PAYLOAD"
  jq -e '.replies and (.replies|length>0)' <<<"$RAW" >/dev/null 2>&1 \
    && { log "would also post replies:"; jq --arg sig "$SIG" '.replies | map(.body += $sig)' <<<"$RAW" >&2; }
  exit 0
fi

# --- Post the review (via gh; see header note on graphite) ---------------------
post() { gh api "$ENDPOINT" --method POST --input - <<<"$1"; }

if post "$PAYLOAD" >/dev/null 2>"$ERR_FILE"; then
  log "Posted review with $N_INLINE inline comment(s), event=$EVENT."
else
  log "Batched review rejected ($(cat "$ERR_FILE")); folding comments into the body."
  post "$(build_body_only)" >/dev/null 2>"$ERR_FILE" || die "failed to post review: $(cat "$ERR_FILE")"
  log "Posted review (fallback: comments in body), event=$EVENT."
fi

# --- Replies to existing threads ----------------------------------------------
# Each reply is sent as a JSON payload so multi-line bodies and code blocks
# keep their newlines.
N_REPLIES="$(jq '(.replies // []) | length' <<<"$RAW")"
for ((i = 0; i < N_REPLIES; i++)); do
  CID="$(jq -r --argjson i "$i" '.replies[$i] | select(.in_reply_to and .body) | .in_reply_to' <<<"$RAW")"
  [ -n "$CID" ] || continue
  if jq -c --argjson i "$i" --arg sig "$SIG" '{body: (.replies[$i].body + $sig)}' <<<"$RAW" \
      | gh api "repos/$OWNER/$REPO/pulls/$NUMBER/comments/$CID/replies" \
          --method POST --input - >/dev/null 2>"$ERR_FILE"; then
    log "Posted reply to comment $CID."
  else
    log "warning: reply to comment $CID failed ($(cat "$ERR_FILE"))."
  fi
done

# --- Optionally open the PR to keep reviewing (graphite preferred) -------------
if [ "$OPEN" -eq 1 ]; then
  if command -v gt >/dev/null 2>&1; then
    log "Opening in Graphite's review UI ..."
    gt pr >/dev/null 2>&1 || gh pr view "$NUMBER" --repo "$OWNER/$REPO" --web
  else
    gh pr view "$NUMBER" --repo "$OWNER/$REPO" --web
  fi
fi