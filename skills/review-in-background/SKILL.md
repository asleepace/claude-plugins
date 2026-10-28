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
is the plumbing between them and GitHub, plus two checks of your own. First,
work out what the PR is meant to do and whether the code does it (Steps 1c and
2b). That is the most important part of the review. Second, verify each finding
is true before it is posted (Step 3).

## Prerequisites

- `gh` (GitHub CLI), authenticated — check with `gh auth status`. All GitHub
  reads and writes go through it.
- `git` and `python3`.
- **Run every `gh` call, and the setup and submit scripts, with the sandbox
  disabled.** Inside the sandbox `gh` fails TLS with
  `x509: OSStatus -26276`.
- The command is run from inside a local checkout of the PR's repo (needed to
  host the worktree). For the Mozart monorepo, run it from anywhere inside your
  mozart checkout.

If `gh` is missing or unauthenticated, stop and tell the user, rather than
half-finishing a review that can't be posted.

## Workflow

### Step 1 — Set up the worktree

Run the setup script with the PR reference the user gave you (a URL like
`https://github.com/padlet/mozart/pull/61808`, or a bare number if you're already
in the repo). Name the temp files after the PR number (`<N>`) so two reviews can
run at once:

```bash
bash scripts/setup_worktree.sh "<pr-ref>" > /tmp/rib_<N>_meta.json
cat /tmp/rib_<N>_meta.json
```

It fetches the PR head via `refs/pull/<N>/head` (works for forks too, and can't
collide with local branches), pins it at `refs/rib/pr-<N>`, creates a
detached-HEAD worktree in a sibling `<repo>-review-worktrees/pr-<N>` directory,
and prints JSON:

```json
{"owner":"padlet","repo":"mozart","number":61808,"base_ref":"main",
 "head_sha":"…","worktree":"…/mozart-review-worktrees/pr-61808",
 "url":"…","title":"…","diff_base":"origin/main","repo_root":"…",
 "review_ref":"refs/rib/pr-61808"}
```

Read these values — you'll need `worktree`, `diff_base`, `owner`, `repo`,
`number`, `repo_root`, and `review_ref` for the rest of the run. The ref lets you
read the PR with `git show "${REF}:path"` after the worktree is gone (brace the
variable, zsh eats `$REF:s`).

### Step 1b — Work out which pass this is

How much to post depends on where the PR is in review. Gather the PR's state
with `/can-approve`'s script, so both skills read a PR the same way:

```bash
gh api user --jq .login    # the user, "<me>" below
bash ~/.claude/skills/can-approve/scripts/pr_state.sh <N> > /tmp/rib_<N>_state.txt
```

It prints these sections:

- `META`: includes `author`, `review_decision`, `approved_by` (every approval
  that wasn't dismissed, not only each reviewer's latest), `head_sha`, and
  `mergeable`.
- `BODY`.
- `COMMITS`: authored date and author logins.
- `REVIEWS`: the latest review per author, with the commit it was made on.
- `THREADS`: resolved threads as one-liners, unresolved threads in full with
  timestamps.
- `CONVERSATION`: top-level comments, without bots.
- `CHECKS`, `FILES`, and `DIFF`.

Work from this file for the rest of the run. Fetch more only for what it cuts.
`my_last` below is the `@<me>` line in `REVIEWS` and its commit. If no such line
exists, the user hasn't reviewed the PR. `REVIEWS` shortens the hash to 10
characters, and `git fetch` needs the full one, so expand it with
`gh api repos/<owner>/<repo>/commits/<short> --jq .sha`.

**Who owns the PR.** Use the "Owners" rule in `~/.claude/skills/can-approve/SKILL.md`:
the author, plus anyone who has clearly taken the PR over.

Pick one mode:

- **First pass.** Nobody has approved and the user hasn't reviewed it yet.
  Review the whole diff. Nits, suggestions, and questions are all fair game.
- **Follow-up.** The user has reviewed before, and nobody has approved. Focus
  on what changed since `my_last.sha` (Step 2). Check whether the user's open
  threads were addressed. Don't raise new nits on code the user already
  reviewed.
- **Already approved.** `approved_by` isn't `none`, or `review_decision` is
  `APPROVED`.
  The user's own approval counts. Post only **major** issues: wrong
  business logic, obvious bugs, crashes, data loss, security holes, or broken
  contracts with other code, or code that doesn't do what the PR sets out to
  do (Step 2b). Drop nits, suggestions, and questions from the posted review.
  List them for the user in the report back instead, so nothing is lost.

Say which mode you picked, and why, in the report back.

**Sort the open asks.** For each unresolved thread in `THREADS`, each
`CHANGES_REQUESTED` review in `REVIEWS`, and each ask in `CONVERSATION`, apply
the "What counts", "Owners", and "Addressed" rules from `~/.claude/skills/can-approve/SKILL.md`
(read those sections). Then sort what is still open:

- **Blocking reviewer ask.** Left by anyone other than an owner, and not
  addressed. Only these stop the ready-to-approve gate in Step 3.
- **Pending author work.** Left by an owner on their own PR, such as a note
  to self or a to-do after a takeover. It never blocks the gate. List it in the
  report back so the user knows the owner has more changes coming.
- **Addressed.** A commit authored after the comment changes what it asked
  about. Compare the comment's timestamp with the dates in `COMMITS`, then read
  the code at `head_sha` to confirm. Treat it as closed even if nobody resolved
  the thread. Mention it in the report back so the user can resolve it.

### Step 1c — Establish the PR's intent

Before reading the code closely, work out what the PR is supposed to do and
the business rules it has to follow. Gather it from every source available:

- **The PR itself:** `META`, `BODY`, and `COMMITS` in the state file. Read the
  title, the description, the branch name, and the commit messages.
- **Linked tickets.** Look for Linear IDs (like `ABC-123`) in the branch name,
  title, body, and commits. Read each issue and its comments with the Linear
  tools. The ticket usually says what problem is being solved, and for whom.
- **Linked specs and threads.** Follow Whimsical, Notion, Google Docs, and Slack
  links in the PR body or ticket, using whatever tools are connected. A product
  spec beats the PR description when the two disagree.
- **The stack.** If the PR is part of a Graphite stack (a "Stack" section in the
  body, or a base branch that isn't the default branch), skim the PRs below
  and above it. Something that looks missing may be handled in a neighbor.
- **Earlier discussion.** Read review threads and conversation comments. Scope
  changes and decisions often happen there.

Write down, for yourself:

1. **Intent:** one or two sentences on what the PR should achieve, and why.
2. **Business rules:** the concrete behaviors it must have, and must not
   break. Include edge cases the ticket or spec names, such as roles,
   permissions, plans, limits, states, and timing.
3. **Out of scope:** what the PR says it doesn't do.
4. **Confidence:** where the intent came from. If all you have is the title
   and the diff, say so. Don't invent business rules the sources don't
   support.

If the sources contradict each other, or there is nothing beyond a one-line
title, note it. An unclear intent is itself worth a `(question)` on a first
pass.

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

In **follow-up** and **already approved** mode, also get the changes since the
user's last review:

```bash
git fetch origin <my_last.sha> && git merge-base --is-ancestor <my_last.sha> HEAD \
  && git diff <my_last.sha>..HEAD
```

If that fails, the branch was rebased or restacked since. Use
`git range-diff <diff_base>...<my_last.sha> <diff_base>...HEAD` to see what
changed, or fall back to the full diff. Either way, tell `/code-review` which
parts are new so it focuses there. It still reads the full diff for context.

Now invoke **`/code-review`** on this worktree / diff. Follow that command's own
workflow; do not reinvent review logic here. If `/code-review` supports running as
a background task or subagent, prefer that so the main session stays responsive —
but running it inline in the worktree is fine too.

Always pass an explicit target and effort level. Without a target `/code-review`
re-derives its scope and can review the user's live checkout instead. Without a
level it silently reuses the last one typed. Use the level the user asked for,
or `medium` by default:

```
/code-review medium PR #<N> — review `git diff <diff_base>...HEAD` inside the
worktree <worktree> (head <head_sha>). Do not review the main checkout.
Intent: <intent>. Business rules it must follow: <rules>. Flag code that
breaks one of these rules as a correctness bug.
```

Whatever form `/code-review` returns its results in (chat output, a file, a
structured list), your task is to **normalize them into the findings schema below**.

### Step 2b — Check the changes against the intent

`/code-review` hunts for bugs line by line. It won't reliably tell whether the PR
as a whole does what it set out to do. Do that yourself, against the notes from
Step 1c:

- **Does it do the thing?** Trace each business rule through the code: the
  entry point, the branch that handles it, and what the user ends up seeing or
  getting. A rule with no code path behind it is a gap.
- **Edge cases named in the sources.** Check each role, state, limit, or timing
  case the ticket or spec names. These are the ones most often left out.
- **Does it do something else?** Changes that the intent doesn't explain:
  unrelated refactors, behavior changes outside the stated scope, or
  leftover debug code. Scope creep is a `(question)`, not a blocker, unless
  it changes behavior users would notice.
- **Does it fight the business logic?** Code that works but encodes the wrong
  rule. For example, the wrong role gets access, the wrong plan gets the
  feature, or a limit is off by one against the spec.
- **Tests.** Is each business rule pinned by a test that would fail if the rule
  broke? A missing test for a stated rule is a `(suggestion)`.

Add each gap or mismatch to the findings, anchored on the most relevant line,
or as a general note when no single line fits. Cite the source of the rule
("the ticket says…", "the spec's 'Host leaves' section says…") so the author
can check it. A real mismatch with the intent or business logic counts as
**major** in every mode, including after approval.

### Step 3 — Double-check every finding before posting

`/code-review` findings are claims, not facts. A wrong comment on a teammate's PR
costs more than a missing one, so verify each finding yourself at the PR head
before translating it. Read code from the worktree or `review_ref`.

For each finding, check every factual claim in it:

- **Code claims.** Re-read the cited lines and the code they call. Confirm the
  branch, value, or call path really behaves as described.
- **Dependency behavior.** If the finding depends on how a library behaves (what
  it raises, exits, retries, or returns), read that library's source under
  `deps/` or `node_modules/`. Don't trust recall.
- **"Before vs after" claims.** If the finding says the PR makes something worse
  than today, check what today actually is. Look for comments, git history, or
  removed code that describe the old behavior.
- **Rule or convention claims.** If the finding cites an AGENTS.md rule, grep for
  precedent. A pattern the codebase already uses widely is not a violation.
- **Intent and business-rule claims.** Re-read the ticket, spec, or comment
  the rule came from. Confirm it says what the finding says, and that a later
  comment or a neighboring PR in the stack didn't change or cover it. If the
  rule is only your inference, make the finding a `(question)`.
- **Config and infra claims.** Check config files. For bucket, DNS, or service
  settings, use read-only commands (`gcloud ... describe`, `curl -I`) when
  available. Say "unverified" rather than guess.
- **Anchor.** Confirm the path and line are part of the PR diff. The submit
  script also checks this and moves a bad anchor to the general notes, so the
  other comments stay inline.
- **Already raised.** Check `THREADS`, `REVIEWS`, and `CONVERSATION` in
  `/tmp/rib_<N>_state.txt` for the same point, from any reviewer or bot. To
  reply on a thread, use the number after `#discussion_r` in its URL as
  `in_reply_to`.

Then classify each finding:

- **Confirmed** — post as is.
- **Overstated** — keep the true part and reword the rest. Lower the severity or
  turn it into a `(question)` if the remaining point is a judgement call.
- **Wrong** — drop it.
- **Duplicate** — someone already raised it. Drop it. If we have something to
  add, put it in `replies` on that thread instead of opening a new one.

Then filter by the mode from Step 1b:

- **Follow-up:** drop new nits on lines the user already reviewed.
- **Already approved:** keep only major issues, posted without a
  `(suggestion)`/`(question)`/`(nit)` tag. Hold back everything else for the
  report back.

**Nothing major, nothing posted (every mode).** A major issue is wrong business
logic, a mismatch with the intent, an obvious bug, a crash, data loss, a
security hole, or a broken contract with other code. Minor findings only get
posted when at least one major issue is going up with them. If no major issue
survives, skip Steps 4–6, clean up (Step 7), and report in the terminal. Which
report depends on the ready-to-approve gate:

- **Gate passes:** no blocking reviewer ask is still open (Step 1b, "Sort the
  open asks"), and `mergeable` isn't `CONFLICTING`. Report "Ready to approve".
  Pending author work, CI status, and an out-of-date title or description
  never hold the gate.
- **Gate held:** report "Not ready yet", and link what is holding it.

Keep a one-line note of what you checked for each finding. You'll use it in the
report back. If most findings turn out wrong, tell the user before posting
anything.

### Step 4 — Humanize each finding with `/translate-human`

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

### Step 5 — Assemble the findings file

Write the normalized, translated result to `/tmp/rib_<N>_findings.json` using this
schema:

```json
{
  "pr": {"owner": "padlet", "repo": "mozart", "number": 61808},
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

### Step 6 — Preview, then submit

First do a dry run so you (and, when it matters, the user) can see exactly what
will land on the PR:

```bash
bash scripts/submit_review.sh /tmp/rib_<N>_findings.json --dry-run
```

Then post it as a single batched review:

```bash
bash scripts/submit_review.sh /tmp/rib_<N>_findings.json
```

Batching into one review means the author gets one notification and the comments
arrive together. Before posting (and in `--dry-run`), the script checks each
anchor against the PR's diff hunks. Any comment whose line isn't in the diff
moves to "General notes" with its line number, and the script prints a
`demoted …` line for it. If GitHub still rejects the batch, the script falls
back to a review whose body carries every comment as text, so nothing is
dropped. It reports what it did. It needs `jq`, `python3` and `gh`.

Both scripts append a `~ Claude` footer to the review body,
every inline comment, and every reply. Don't add your own signature.

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

### Step 7 — Clean up

Once the review is posted, remove the worktree and the pinned ref so neither
accumulates:

```bash
bash scripts/cleanup_worktree.sh "<worktree>" "<repo_root>" "<review_ref>"
```

Leave them in place only if the user wants to inspect the checkout afterward, or
asks for follow-up replies that still need to read the code. Delete the ref once
those are done. Only delete the ref this run created, never other `refs/rib/*`
refs.

## Follow-ups on posted threads

To correct, withdraw, or answer one of our comments after the review is posted,
use the helper instead of hand-written `gh api` calls. Write the reply through
`/translate-human` first, save it to a file, and dry-run before posting:

```bash
bash scripts/reply_resolve.sh "<pr-url>" <comment-id> --body-file reply.md --resolve --dry-run
bash scripts/reply_resolve.sh "<pr-url>" <comment-id> --body-file reply.md --resolve
```

- `<comment-id>` is the number after `#discussion_r` in a comment link. Any
  comment in the thread works, including a reply.
- Leave out `--resolve` to reply and keep the thread open, for example when the
  correction narrows a point that still stands.
- Pass `--resolve` with no `--body-file` to resolve without replying.
- Only resolve our own threads, never another reviewer's.

## Reporting back

Close with a short, plain-English summary: the PR title and link, the intent in
one line and where it came from, whether the code matches it, the mode from
Step 1b, how many inline comments and general notes were posted, the review
event used, any minor findings held back, how many findings were dropped or
reworded in Step 3 (and why, in a line each), and confirmation that the
worktree and ref were cleaned up. Keep it short — the detail is on the PR now.

When the ready-to-approve gate passed and nothing was posted, lead with:

```
✅ Ready to approve: <PR title> (<url>)
```

Then give the intent line and the mode, then any minor notes you held back, as
a short list the user can choose to raise themselves. End with the cleanup
confirmation.

When nothing major was posted but the gate didn't pass, lead with
`⏸️ Not ready yet: <PR title> (<url>)` and link each blocking reviewer ask.

In every report, also list, when present:

- **Pending author work:** the owner's own open threads, linked, one line
  each.
- **Addressed but unresolved:** threads a later commit fixed that nobody has
  resolved yet, so the user can resolve them.
- **CI:** one line naming any failing checks from `CHECKS`. This is
  information only, never a blocker.

In both cases, the report ends with a confidence score. It goes in the terminal
only, never on the PR. Put the score on one line, then a table with one row per
deduction that applied, biggest first:

```
<band> Confidence: <score>/100

| Deduction | Points |
|---|---|
| <what applied, specific to this PR> | −<n> |
| … | … |
```

If nothing was deducted, write "No deductions" in place of the table.

Keep each row practical. It names something the author or reviewer can act on
or check, such as a missing test, an open issue, or a claim to confirm. Leave out
size and shape signals like diff length or file count.

It scores how safe the PR is to merge as it stands now. Start at 100 and
subtract:

| Signal | Penalty |
|---|---|
| Each major issue posted | −25 |
| Each minor finding, posted or held back | −3 (max −15) |
| Intent comes only from the title and diff, or the sources disagree | −10 |
| A business rule from Step 1c has no test that would catch it breaking | −5 each (max −15) |
| Touches migrations, auth/permissions, payments, data deletion, or shared infra config | −10 |
| A finding you couldn't verify and marked "unverified" | −5 each |

Clamp to 0–100. Bands: 🟢 90–100, 🟡 70–89, 🔴 0–69. A ready-to-approve PR can
still land in 🟡, for example a large migration with thin tests. The score is
about risk, and the verdict is about readiness.

## When something goes wrong

- **`/code-review` found nothing.** Don't post an empty review. Report "Ready to
  approve" or "Not ready yet", following the gate in Step 3, and still clean up
  the worktree and ref. The same applies when Step 3 drops every finding.
- **A PR line won't anchor.** The script demotes that comment to a general note.
  Mention any `demoted …` lines in your summary, and say so if the whole review
  fell back to body-only.
- **Cross-fork PR.** The `refs/pull/<N>/head` fetch already handles this; no
  special action needed.
- **Not inside the repo / bare number can't resolve.** Ask the user to run it from
  inside a checkout of the target repo, or to pass the full PR URL.