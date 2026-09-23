#!/usr/bin/env bash
# Expand PR references into an ordered list of PR numbers, bottom of stack first.
#
# Usage:
#   resolve_prs.sh <ref> [<ref> ...]
#
#   <ref>  A PR URL, a bare number, or a range "A..B" (numbers or URLs).
#          A range walks down from B through each PR's base branch until it
#          reaches A, so it covers every PR stacked between them.
#
# Prints one PR number per line on stdout. Logs go to stderr.
set -euo pipefail

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required."
[ $# -gt 0 ] || die "pass at least one PR reference."

num_of() { gh pr view "$1" --json number -q .number 2>/dev/null || die "could not resolve PR '$1'."; }

expand_range() {
  local lo hi cur base next chain=""
  lo="$(num_of "$1")"
  hi="$(num_of "$2")"
  cur="$hi"
  while :; do
    chain="$cur $chain"
    [ "$cur" = "$lo" ] && break
    base="$(gh pr view "$cur" --json baseRefName -q .baseRefName)"
    # Prefer the open PR for that branch; a reused branch name can have old merged ones.
    next="$(gh pr list --head "$base" --state open --json number -q '.[0].number' 2>/dev/null || true)"
    [ -n "$next" ] || next="$(gh pr list --head "$base" --state all --json number -q '.[0].number' 2>/dev/null || true)"
    [ -n "$next" ] || die "walked from #$hi down to base '$base' without reaching #$lo. Is #$lo below #$hi in the stack?"
    cur="$next"
  done
  printf '%s\n' $chain
}

for ref in "$@"; do
  case "$ref" in
    *..*) expand_range "${ref%%..*}" "${ref##*..}" ;;
    *)    num_of "$ref" ;;
  esac
done | awk '!seen[$0]++'
