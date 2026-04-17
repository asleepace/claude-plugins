#!/usr/bin/env bash
# quick-review-state.sh
# Gathers git state for the /quick-review slash command.
# Emits sectioned plain text on stdout. Fails soft — always prints something.
#
# Usage: quick-review-state.sh [base-branch-override]

set -uo pipefail

OVERRIDE="${1:-}"

# ---------- helpers ----------

# Filter empty lines, count the rest. Handles empty string → 0 cleanly.
count_lines() {
    printf '%s\n' "$1" | awk 'NF>0' | wc -l | tr -d ' '
}

# ---------- current branch ----------
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "UNKNOWN")
HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")

# ---------- normalize remote URL for file links ----------
# git@github.com:owner/repo.git   → https://github.com/owner/repo
# ssh://git@github.com/owner/repo → https://github.com/owner/repo
# https://github.com/owner/repo.git → https://github.com/owner/repo
normalize_remote() {
    local url="$1"
    [ -z "$url" ] && return
    url="${url%.git}"
    case "$url" in
        git@*)
            url="${url#git@}"
            url="${url/:/\/}"
            echo "https://$url"
            ;;
        ssh://git@*)
            echo "https://${url#ssh://git@}"
            ;;
        http://*|https://*)
            echo "$url"
            ;;
        *)
            echo ""
            ;;
    esac
}

REPO_URL=$(normalize_remote "$(git remote get-url origin 2>/dev/null || true)")

# ---------- PR metadata (base + url + title + body), fetched once up top ----------
# Four gh calls rather than one with jq post-processing — keeps things simple
# and avoids jq dependency. Each call is ~300ms; total overhead ~1-1.5s when
# an open PR exists. No PR → all four return empty, no delay.
PR_BASE_REF=""
PR_URL=""
PR_TITLE=""
PR_BODY=""
if command -v gh >/dev/null 2>&1; then
    PR_BASE_REF=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)
    PR_URL=$(gh pr view --json url -q .url 2>/dev/null || true)
    PR_TITLE=$(gh pr view --json title -q .title 2>/dev/null || true)
    PR_BODY=$(gh pr view --json body -q .body 2>/dev/null || true)
fi

# ---------- resolve base branch ----------
# Each candidate is validated with rev-parse before being returned.
# Fall through on failure instead of returning an unresolvable ref.
try_ref() {
    if git rev-parse --verify --quiet "$1" >/dev/null 2>&1; then
        echo "$1"
        return 0
    fi
    return 1
}

resolve_base() {
    local default b

    # 1. Explicit override from $ARGUMENTS. Try as-given, then with origin/ prefix.
    if [ -n "$OVERRIDE" ]; then
        try_ref "$OVERRIDE" && return
        case "$OVERRIDE" in
            */*) : ;;  # already namespaced, no origin/ variant to try
            *)   try_ref "origin/$OVERRIDE" && return ;;
        esac
        # Override given but unresolvable — fall through to auto-detect.
    fi

    # 2. Open PR's base (the real answer for PR reviews).
    if [ -n "$PR_BASE_REF" ]; then
        try_ref "origin/$PR_BASE_REF" && return
        try_ref "$PR_BASE_REF" && return
    fi

    # 3. Remote HEAD (default branch).
    default=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$default" ]; then
        try_ref "$default" && return
    fi

    # 4. Last-resort guesses.
    for b in origin/main origin/master main master; do
        try_ref "$b" && return
    done

    echo ""
}

BASE=$(resolve_base)

# ---------- merge-base ----------
BASE_SHA=""
if [ -n "$BASE" ]; then
    BASE_SHA=$(git merge-base HEAD "$BASE" 2>/dev/null || true)
fi

# ---------- diff info ----------
DIFF_STAT=""
FILES_LIST=""
FILES_COUNT=0
TOTAL_LINES=0
RECENT=""

if [ -n "$BASE_SHA" ]; then
    DIFF_STAT=$(git diff --stat "$BASE_SHA"..HEAD 2>/dev/null || true)
    # numstat format: <added>\t<deleted>\t<path>  (binary files show "-" for counts)
    FILES_LIST=$(git diff --numstat "$BASE_SHA"..HEAD 2>/dev/null || true)
    FILES_COUNT=$(count_lines "$FILES_LIST")
    TOTAL_LINES=$(printf '%s\n' "$FILES_LIST" | awk '{added+=$1; deleted+=$2} END {print (added+deleted)+0}')
    RECENT=$(git log --oneline "$BASE_SHA"..HEAD 2>/dev/null || true)
fi

# ---------- uncommitted / staged (out of scope, count only) ----------
UNCOMMITTED=$(git status --short 2>/dev/null || true)
UNCOMMITTED_COUNT=$(count_lines "$UNCOMMITTED")

# ---------- strategy recommendation ----------
if [ -z "$BASE_SHA" ]; then
    STRATEGY="no-base"
elif [ "$FILES_COUNT" -eq 0 ]; then
    STRATEGY="empty"
elif [ "$FILES_COUNT" -ge 30 ] || [ "$TOTAL_LINES" -ge 2000 ]; then
    STRATEGY="chunked"
elif [ "$FILES_COUNT" -ge 10 ] || [ "$TOTAL_LINES" -ge 500 ]; then
    STRATEGY="per-file"
else
    STRATEGY="inline"
fi

# ---------- output ----------
cat <<EOF
=== BRANCH ===
$BRANCH

=== REPO ===
url: ${REPO_URL:-<none>}
head_sha: ${HEAD_SHA:-<none>}
pr_url: ${PR_URL:-<none>}

=== BASE ===
ref: ${BASE:-<unresolved>}
sha: ${BASE_SHA:-<unresolved>}

=== COMMITS ON BRANCH ===
$RECENT

=== DIFF STAT ===
$DIFF_STAT

=== FILES (added	deleted	path) ===
$FILES_LIST

=== TOTALS ===
files: $FILES_COUNT
lines: $TOTAL_LINES

=== UNCOMMITTED (out of scope) ===
count: $UNCOMMITTED_COUNT
$UNCOMMITTED

=== STRATEGY ===
$STRATEGY
EOF

# ---------- PR context (only if an open PR was found) ----------
if [ -n "$PR_TITLE" ] || [ -n "$PR_BODY" ]; then
    cat <<EOF

=== PR CONTEXT ===
title: ${PR_TITLE:-<empty>}
url: ${PR_URL:-<none>}
body:
${PR_BODY:-<empty>}
EOF
fi

# ---------- per-file diffs ----------
# Dump every file's diff in one go so Claude doesn't have to make N git calls.
# Skip known-noisy lockfiles — they're reviewable from the file list alone
# (flag if manifest changed without lockfile updating, or vice versa).

should_skip_diff() {
    case "$1" in
        # Lockfiles — large, mechanical, manifest-driven
        *package-lock.json|*yarn.lock|*pnpm-lock.yaml|\
        *Cargo.lock|*Gemfile.lock|*go.sum|\
        *poetry.lock|*Pipfile.lock|*composer.lock) return 0 ;;
        # Locale / i18n files — generated from __() calls in code
        *intl_gettext.rb|*intl_messages.json|*intl_yaml.yml|\
        *.pot|*.po|*.mo) return 0 ;;
        # SVG icons — path data, not meaningfully diff-reviewable
        *.svg) return 0 ;;
    esac
    return 1
}

if [ -n "$BASE_SHA" ] && [ "$FILES_COUNT" -gt 0 ]; then
    INCLUDED=()
    SKIPPED=()
    while IFS=$'\t' read -r added deleted path; do
        [ -z "$path" ] && continue
        if should_skip_diff "$path"; then
            SKIPPED+=("$path")
        else
            INCLUDED+=("$path")
        fi
    done < <(printf '%s\n' "$FILES_LIST")

    if [ "${#SKIPPED[@]}" -gt 0 ]; then
        echo ""
        echo "=== SKIPPED (diff omitted — lockfile, locale, or SVG) ==="
        printf '%s\n' "${SKIPPED[@]}"
    fi

    if [ "${#INCLUDED[@]}" -gt 0 ]; then
        echo ""
        echo "=== DIFFS ==="
        git diff "$BASE_SHA"..HEAD -- "${INCLUDED[@]}" 2>/dev/null || true
    fi
fi
