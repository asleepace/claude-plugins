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
# One gh call (~1s). gh's built-in -q prints base, url and title on the first
# three lines and the multi-line body after them, so no jq is needed.
PR_BASE_REF=""
PR_URL=""
PR_TITLE=""
PR_BODY=""
if command -v gh >/dev/null 2>&1; then
    PR_META=$(gh pr view --json baseRefName,url,title,body -q '.baseRefName, .url, .title, .body' 2>/dev/null || true)
    if [ -n "$PR_META" ]; then
        PR_BASE_REF=$(printf '%s\n' "$PR_META" | sed -n 1p)
        PR_URL=$(printf '%s\n' "$PR_META" | sed -n 2p)
        PR_TITLE=$(printf '%s\n' "$PR_META" | sed -n 3p)
        PR_BODY=$(printf '%s\n' "$PR_META" | sed -n '4,$p')
    fi
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
        # Regex pass over added lines so the model can skip hunting for these.
        # Prints "<severity> <path>:<line> <check>: <line text>".
        HITS=$(git diff -U0 "$BASE_SHA"..HEAD -- "${INCLUDED[@]}" 2>/dev/null | perl -ne '
            if (/^\+\+\+ b\/(.*)$/) { $f = $1; next }
            if (/^@@ -\S+ \+(\d+)/) { $n = $1; next }
            next unless /^\+/ && !/^\+\+\+ /;
            my $t = substr($_, 1); chomp $t;
            my @c = (
                ["high",   "Conflict marker",      qr/^(<{7}|={7}|>{7})( |$)/],
                ["high",   "Possible secret",      qr/AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|\bsk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----/],
                ["medium", "Focused/skipped test", qr/\b(it|test|describe)\.(only|skip)\(|\b(fit|fdescribe|xit|xdescribe)\(/],
                ["medium", "Debugger statement",   qr/^\s*debugger\b/],
                ["medium", "Bare ts-ignore",       qr/\@ts-(ignore|expect-error)\s*(\*\/)?\s*$/],
                ["medium", "Any cast",             qr/\bas (any|unknown as)\b/],
                ["medium", "Empty catch",          qr/catch\s*(\([^)]*\))?\s*\{\s*\}/],
                ["low",    "Debug print",          qr/\bconsole\.(log|debug)\(|\bdbg!\(|\bfmt\.Println\(/],
                ["low",    "TODO marker",          qr/\b(TODO|FIXME|XXX|HACK)\b/],
                ["low",    "Unexplained eslint-disable", qr/eslint-disable(?!.*--)/],
            );
            for my $x (@c) { print "$x->[0] $f:$n $x->[1]: " . substr($t =~ s/^\s+//r, 0, 160) . "\n" if $t =~ $x->[2] }
            $n++;
        ')
        SECRET_FILES=$(printf '%s\n' "${INCLUDED[@]}" | grep -E '(^|/)\.env(\.|$)|\.(pem|key|p12)$' | grep -vE '\.env\.(example|sample|template)$' || true)
        if [ -n "$SECRET_FILES" ]; then
            HITS=$(printf '%s\n' "$HITS"; printf '%s\n' "$SECRET_FILES" | sed 's/^/high /; s/$/ Committed secret file: whole file/')
        fi
        echo ""
        echo "=== MECHANICAL HITS === (regex candidates on added lines; confirm in DIFFS)"
        printf '%s\n' "${HITS:-<none>}" | awk 'NF>0'

        echo ""
        echo "=== DIFFS ==="
        git diff "$BASE_SHA"..HEAD -- "${INCLUDED[@]}" 2>/dev/null || true
    fi
fi