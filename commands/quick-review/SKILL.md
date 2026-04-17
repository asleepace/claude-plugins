---
name: quick-review
description: Fast sanity-check review of this branch vs its PR base. Use when the user asks for a "quick review", "self-review", "pre-push check", "sanity check the branch", or any lightweight review of the current branch before opening or merging a PR.
argument-hint: [base-branch]
allowed-tools: Bash(~/.claude/commands/quick-review/scripts/quick-review-state.sh:*), Bash(git:*), Read, Grep, Glob
---

# Quick review

Fast first-pass review of this branch vs its PR base. Catches common sloppy errors before a slower reviewer sees them. This is **not** a substitute for deep review.

## Git state + diffs

!`~/.claude/commands/quick-review/scripts/quick-review-state.sh $ARGUMENTS`

## How to use the output above

The script has already resolved the base branch, computed the merge-base SHA, listed every changed file, and dumped every non-lockfile diff in `=== DIFFS ===`. **Read diffs from that section — do not call `git diff` per file.**

**If `=== PR CONTEXT ===` is present**, read the `title` and `body` first. They state what the PR is supposed to do. Use this as the intent baseline when reviewing: every claim in the body should be backed by a matching change in the diff, and every substantive change in the diff should be plausibly covered by the stated intent. Section-less "fix typo" PRs won't have much intent to check; feature PRs with bulleted descriptions give you a lot to cross-reference. If `PR CONTEXT` is absent (no open PR, or no `gh` installed), skip the intent check and review the diff on its own merits.

**Handle `STRATEGY` first:**

- `empty` — no commits on this branch vs the base. Emit just the header block with all counts at 0, Grade `pass`, and a one-line Summary ("No commits on this branch vs `<base>`."). Stop.
- `no-base` — base couldn't be resolved. Report that and ask the user to pass a base branch explicitly. Stop.
- `inline` / `per-file` / `chunked` — review using the DIFFS section. For `chunked`, read full post-change files (`Read` the working-tree path) when diff context isn't enough. If subagents are available for `chunked`, parallelize per file and merge findings.

**Uncommitted changes:** if `UNCOMMITTED count` > 0, mention it in Summary as "N uncommitted/staged file(s) not reviewed." Do not review those files.

**Files in `SKIPPED`** fall into three categories; the label on the SKIPPED section header names them. Handle each differently:

- **Lockfiles** (`package-lock.json`, `yarn.lock`, etc.) — cross-check against `FILES`. If the lockfile changed but no manifest (`package.json`, `Cargo.toml`, etc.) did, or vice versa, flag as a correctness issue.
- **Locales** (`intl_gettext.rb`, `intl_messages.json`, `intl_yaml.yml`, `.pot`, `.po`, `.mo`) — auto-generated from `__()` / `p__()` calls in code. Don't review their content. A string-extraction mismatch (e.g. new `__('...')` in code but no matching locale entry) is usually caught by the build, so ignore unless a code file in `FILES` obviously touches user-facing strings and there's no matching locale entry.
- **SVGs** (`*.svg`) — icon/asset files. Don't attempt to review path data. New SVG files are fine to acknowledge in `General` if there are many; otherwise ignore.

## What to look for and how to classify severity

Focus on things linters and typecheckers miss. Don't repeat what a configured linter would catch.

**High risk** (any of these → `Grade: fail`)
- Leaked secrets: API keys, tokens, passwords, private keys, key-like patterns (`AKIA…`, `ghp_…`, `sk-…`, `xoxb-…`, `Bearer …`), committed `.env`/`.pem`/`.key`
- Merge conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
- Missing `await` on promise-returning calls where the error would silently swallow
- Null/undefined deref without guard on an input path that can realistically be nullish
- Off-by-one on a loop that touches real data
- Copy-paste bugs — near-identical blocks where only one var changed and the divergence looks incomplete
- SQL/shell/HTML injection from unescaped input
- `==` / `!=` in a security- or type-sensitive comparison

**Medium risk**
- `.only`, `.skip`, `fit`, `fdescribe`, `test.only`, `it.only` left in tests (CI will silently skip other tests)
- New `any` / `as any` / `as unknown as X` in non-trivial code
- `@ts-ignore` / `@ts-expect-error` without an explanatory comment
- Non-null assertions (`!.`) on values that could legitimately be null
- New network/DB/fs calls with no error handling at all
- Empty `catch (e) {}` (the trailing "is this intentional?" case)
- Errors logged but not propagated where the caller needs to know
- `debugger;` statements
- Lockfile / manifest desync
- Early `return`/`throw` inside `finally`

**Low risk**
- `console.log`, `console.debug`, `print(`, `dbg!`, `fmt.Println` added in this diff
- Commented-out code blocks
- New `TODO` / `FIXME` / `XXX` / `HACK` markers
- Stray `// eslint-disable*` without justification
- Unreachable code after `return`/`throw`
- Unused imports/vars added
- Stale code comments that no longer match the code they annotate
- Committed build artifacts, `.DS_Store`, large binaries
- Implicit `any` in new function params

**General** (not tied to a specific file — use the `General` entry in the output)
- Missing tests for new functionality
- Inconsistent patterns across changed files (multiple error-handling styles, mixed naming)
- New public API without docs/types
- Schema/migration without corresponding model change, or vice versa
- Config change without code change, or vice versa
- **Intent alignment** (only when `PR CONTEXT` is present):
  - Scope creep: substantive changes in the diff that aren't mentioned or implied by the PR title/body
  - Missing implementation: items the body claims to add/fix/change that aren't actually present in the diff
  - Unchecked checklist items (`- [ ]`) that appear to still be required by the code (e.g., "Tests added" unchecked but no test files in diff)
  - Type/scope mismatch: conventional-commit prefix says `refactor:` or `chore:` but the diff adds new behavior, or `feat:` with no user-facing change

## Output format

Emit exactly this structure. No preamble, no trailing comments.

```
# Quick Review
- Branch: [<BRANCH>](<branch-link>)
- 🔴 High Risk: `<count>`
- 🟡 Medium Risk: `<count>`
- ⚪ Low Risk: `<count>`
- <grade-emoji> Grade: `<pass|fail>`

1. [General](#)
  - 🔴 (high) **<Issue title>**: one-sentence description

2. [<path>](<file-link>)
  - 🔴 (high) `line <N>` **<Issue title>**: one-sentence description
  - 🟡 (medium) `line <N>` **<Issue title>**: one-sentence description

3. [<path>](<file-link>)
  - ⚪ (low) `line <N>` **<Issue title>**: one-sentence description

## Summary

<substantive observations — architectural notes, cross-file patterns, missing test coverage, risky scope creep. One or two short paragraphs. If nothing to say, one sentence.>
```

**Constructing `<branch-link>`:**
- If `REPO pr_url` is a real URL: use it directly (clicks through to the PR).
- Else if `REPO url` is a real URL: `<url>/tree/<BRANCH>`.
- Else: use the branch name as a plain reference: `[<BRANCH>](#)`.

**Constructing `<file-link>`:**
- If `REPO url` from the state output is a real URL: `<url>/blob/<head_sha>/<path>` — e.g. `https://github.com/owner/repo/blob/abc123/src/foo.ts`
- If `REPO url` is `<none>`: use the path as a plain relative link: `[<path>](<path>)`

**Rules:**
- Numbering is sequential from 1. If there are no `General` issues, skip that entry and start file numbering at 1.
- Order entries: `General` first (if present), then files with at least one high-risk issue, then medium-only, then low-only. Alphabetical within tiers.
- Within a file, order bullets: high → medium → low.
- `Grade: fail` if High Risk count ≥ 1. Otherwise `pass`.
- `<grade-emoji>`: ✅ when Grade is `pass`, ❌ when Grade is `fail`. Placed before the word "Grade" on the header line.
- Counts (`<count>`) and the grade value are wrapped in backticks so they render as inline code — visual separation from the label.
- Each bullet: ``<badge> (severity) `line <N>` **<Issue title>**: <description>``. The `` `line <N>` `` chunk is omitted for `General` entries and for file-wide observations that don't have a specific line. `<Issue title>` is a 2-5 word category tag like "Missing await", "Copy-paste bug", "Console.log leftover", "Empty catch", "Architecture drift". Follow with a colon, then one sentence of context.
- Badges: 🔴 for high, 🟡 for medium, ⚪ for low.
- If nothing notable turns up, emit the header with all counts at 0, Grade `pass`, no numbered list, and a one-sentence Summary.

## Guardrails

- Don't run tests, lint, typecheck, or build.
- Don't rewrite the code.
- Be terse. Signal, not reassurance.
- Don't re-fetch diffs already in the script output.
- Summary is for observations that don't fit in per-file bullets, not for recapping the review or offering encouragement.
