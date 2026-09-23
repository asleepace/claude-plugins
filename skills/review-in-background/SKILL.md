---
name: review-in-background
description: Run an end-to-end code review of a GitHub PR in an isolated git worktree, then post the results back to the PR. Use whenever the user invokes /review-in-background, gives a PR URL or number and asks to "review it in the background", "review this PR without messing up my current work", "review and post comments to the PR", or otherwise wants a hands-off review that lands as GitHub comments. This skill is the glue that checks out the PR in a throwaway worktree, delegates the actual review to /code-review, humanizes the output with /translate-human, and submits inline comments, suggestions, and replies via the GitHub CLI. Trigger it for any request shaped like "review this PR and put the comments on GitHub", even if the user does not say the word "skill".
---

# Review in Background

Take a PR reference, review it without disturbing the user's working tree, and
post the review to GitHub. This skill does not itself decide what is good or bad
code, nor does it decide how to phrase feedback. It **orchestrates** three pieces:

1. **Worktree isolation** (this skill) — check the PR out in a detached worktree
   so the user's current branch, staged changes, and dev servers are untouched.
2. **`/code-review`** — the user's existing review logic. It produces the raw
   findings.
3. **`/translate-human`** — the user's existing humanizer. It rewrites each
   finding into warm, concise, correctly-tagged review prose.

Then this skill submits the result to the PR.

Keep that separation in mind: when in doubt about *what to flag* defer to
`/code-review`, and about *how to word it* defer to `/translate-human`. Your job
is the plumbing between them and GitHub.

## Prerequisites

- `gh` (GitHub CLI), authenticated — check with `gh auth status`. All GitHub
  reads and writes go through it.
- `git` and `python3`.
- The command is run from inside a local checkout of the PR's repo (needed to
  host the worktree). Any directory inside the checkout works.

If `gh` is missing or unauthenticated, stop and tell the user, rather than
half-finishing a review that can't be posted.

## Workflow

### Step 1 — Set up the worktree

Run the setup script with the PR reference the user gave you (a URL like
`https://github.com/acme/widgets/pull/1234`, or a bare number if you're already
in the repo):

```bash
bash scripts/setup_worktree.sh "<pr-ref>" > /tmp/rib_meta.json
cat /tmp/rib_meta.json
```

It fetches the PR head via `refs/pull/<N>/head` (works for forks too, and can't
collide with local branches), creates a detached-HEAD worktree in a sibling
`<repo>-review-worktrees/pr-<N>` directory, and prints JSON:

```json
{"owner":"acme","repo":"widgets","number":1234,"base_ref":"main",
 "head_sha":"…","worktree":"…/widgets-review-worktrees/pr-1234",
 "url":"…","title":"…","diff_base":"origin/main","repo_root":"…"}
```

Read these values — you'll need `worktree`, `diff_base`, `owner`, `repo`, and
`number` for the rest of the run.

### Step 2 — Run the code review in the worktree

Change into the worktree and run the user's review command there. The worktree is
what makes this "in the background": the review reads a checked-out copy of the PR
without touching the user's real working tree.

```bash
cd "<worktree>"
```

The relevant diff is everything the PR adds relative to its base:

```bash
git diff <diff_base>...HEAD
```

Now invoke **`/code-review`** on this worktree / diff. Follow that command's own
workflow; do not reinvent review logic here. If `/code-review` supports running as
a background task or subagent, prefer that so the main session stays responsive —
but running it inline in the worktree is fine too.

Whatever form `/code-review` returns its results in (chat output, a file, a
structured list), your task is to **normalize them into the findings schema below**.
You are reading its output and reshaping it; you are not second-guessing its
substance.

### Step 3 — Humanize each finding with `/translate-human`

For every finding that has body text, apply **`/translate-human`** in
**code-review-comment mode**. That skill already:

- rewrites AI-voice prose into warm, concise, teammate-toned English,
- uses "we"/"let's",
- adds `(suggestion)` / `(question)` / `(nit)` tags to non-blocking notes,
- and keeps code out of prose, in fenced blocks or ```suggestion blocks.

Let it do that work. Two things to preserve as you translate:

- **Keep the anchor.** The file path, line, and side that `/code-review` attached
  to a finding must survive translation untouched. Translate the prose, not the
  coordinates.
- **Keep suggestion blocks intact.** If a finding proposes a concrete change as a
  ```suggestion block, leave the block's contents exactly as-is; GitHub applies
  it verbatim.

If `/code-review` also produced an overall summary, translate that too — it
becomes the review's summary body. Aim for a couple of plain sentences a
non-blocking reader could skim.

### Step 4 — Assemble the findings file

Write the normalized, translated result to `/tmp/rib_findings.json` using this
schema:

```json
{
  "pr": {"owner": "acme", "repo": "widgets", "number": 1234},
  "summary": "Short, human overall summary (translated). Optional.",
  "event": "COMMENT",
  "comments": [
    {
      "path": "app/models/user_identity.rb",
      "line": 42,
      "side": "RIGHT",
      "body": "(suggestion) We could guard against the race here.\n```suggestion\n…\n```"
    },
    {
      "path": "app/foo.ts",
      "start_line": 40,
      "line": 44,
      "side": "RIGHT",
      "body": "(question) Is this branch still reachable after the refactor?"
    },
    {
      "body": "(nit) A few files import lodash directly; nothing blocking."
    }
  ],
  "replies": [
    {"in_reply_to": 123456789, "body": "Good catch — fixed in the latest push."}
  ]
}
```

Field notes:

- `pr` comes from Step 1's JSON. Always include all three fields.
- `event` defaults to **`COMMENT`**. Only use `REQUEST_CHANGES` or `APPROVE` if
  the user explicitly asked for it. A background skill should never silently
  approve or block a teammate's PR — that's a human decision.
- `line` is the line the comment attaches to on the **RIGHT** (new) side of the
  diff. Use `LEFT` for the old side. Add `start_line` for a multi-line range.
- A comment with **no `path`/`line`** is fine — the submit script folds it into
  the summary under "General notes" so it isn't lost. Use this for whole-PR
  observations that don't map to one line.
- `replies` is optional — only when `/code-review` is responding to existing
  review threads (use the numeric review-comment id from `gh api`).

### Step 5 — Preview, then submit

First do a dry run so you (and, when it matters, the user) can see exactly what
will land on the PR:

```bash
bash scripts/submit_review.sh /tmp/rib_findings.json --dry-run
```

Then post it as a single batched review:

```bash
bash scripts/submit_review.sh /tmp/rib_findings.json
```

Batching into one review means the author gets one notification and the comments
arrive together. If GitHub rejects an inline anchor (usually because a line isn't
part of the diff), the script automatically falls back to a review whose body
carries every comment as text — so nothing is dropped even when precise anchoring
fails. It reports what it did. It needs `jq` and `gh`.

**Graphite vs gh.** Posting inline comments, ```suggestion blocks, and thread
replies only exists through GitHub's review API, so the submission always uses
`gh`. The Graphite CLI (`gt`) manages stacks and PR create/checkout but has no
command to post review feedback — Graphite two-way-syncs comments from GitHub, so
they show up in the Graphite UI regardless. Where the choice is real is *opening*
the PR to keep reviewing: pass `--open` and the script prefers `gt pr` (Graphite's
review surface) when `gt` is installed, and falls back to `gh pr view --web`.

The user asked for automatic submission, so posting after the dry-run preview is
the default. If they said "just show me first" or "dry run only", stop after the
`--dry-run` and hand them the preview.

### Step 6 — Clean up

Once the review is posted, remove the worktree so it doesn't accumulate:

```bash
bash scripts/cleanup_worktree.sh "<worktree>"
```

Leave it in place only if the user wants to inspect the checkout afterward.

## Reporting back

Close with a short, plain-English summary: the PR title and link, how many inline
comments and general notes were posted, the review event used, and confirmation
that the worktree was cleaned up. One small paragraph — the detail is on the PR now.

## When something goes wrong

- **`/code-review` found nothing.** Don't post an empty review. Tell the user the
  PR looked clean and skip submission (still clean up the worktree).
- **A PR line won't anchor.** Trust the script's fallback; mention in your summary
  that some comments were folded into the body.
- **Cross-fork PR.** The `refs/pull/<N>/head` fetch already handles this; no
  special action needed.
- **Not inside the repo / bare number can't resolve.** Ask the user to run it from
  inside a checkout of the target repo, or to pass the full PR URL.