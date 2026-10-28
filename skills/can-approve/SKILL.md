---
name: can-approve
description: Use when the user invokes /can-approve, or asks "can I approve this PR", "is this good to approve", "is this ready to merge", "final check before approving", or wants a last sanity pass on a PR (or a range of stacked PRs) that has already been through review rounds. Read-only; never posts to GitHub.
argument-hint: <pr-ref | A..B> [more refs]
---

# Can Approve

A final gate for PRs that are already mostly vetted. The question is narrow: **is anything still standing between this PR and an approval?** It is not a fresh deep review. Assume earlier review rounds did their job; look for what they left open and for anything new since.

Read-only. Never approve, comment, or push. The user decides.

## What counts

**Blocks approval:**
- The PR doesn't do what it sets out to do, or encodes the wrong business rule (see Step 3). This is a high finding.
- An unresolved review thread, or a reviewer ask in the conversation or a review body, that the code has not addressed. See "Addressed" below. Only asks from someone other than an owner count. See "Owners" below.
- A `CHANGES_REQUESTED` review that no later review from the same person has replaced.
- A **confirmed** high or medium finding from the quick pass (see Step 3).
- `mergeable: CONFLICTING`.

**Never blocks** (don't report as blockers, don't lower the verdict):
- CI status: failing, pending, or slow tests and checks. CI gates the merge by itself. At most, add one line under Notes naming the failing checks. This wins even when a reviewer labels a CI-only comment "blocking".
- The PR title or description being out of date with the code. It stops mattering once merged. Don't mention it in Notes either.
- Size and shape: diff length, file count, number of commits. Don't mention these anywhere.
- An owner's own open threads (notes to self, to-dos after a takeover). List them under Notes as pending author work.
- Anything already discussed and knowingly accepted by the author and a reviewer.
- Style, naming, or nits.
- Missing symbols that a PR lower in the same stack provides. The stack merges together.

**Owners** are `META`'s `author`, plus anyone who has since taken the PR over. A takeover is a `CONVERSATION` comment saying so ("I'm taking over this PR"), or someone else authoring the recent commits and replying to review threads as the author. Commit co-authors alone don't make someone an owner. The user running this skill is never an owner, unless they wrote the PR.

**Addressed** means one of these is true:
- A commit authored after the comment changes the lines or behaviour it asked about. `COMMITS` shows authored dates, and each review in `REVIEWS` shows the commit it was made on.
- The thread is resolved, or the author replied with a reason and the reviewer did not push back.
- The comment is a non-blocking note, question, or nit and has an answer.

A reply like "not verified yet" or "I'll follow up" to a **blocking** ask is not addressed. A reply like that to a non-blocking note goes under Notes as a follow-up, not a blocker. These rules apply the same way to review threads, review bodies, and top-level conversation comments.

## Workflow

Run all commands from inside a checkout of the PR's repo. `gh` must be authenticated.

**1. Resolve the PRs.** Refs can be URLs, numbers, or a range `A..B` (bottom..top of a stack):

```bash
bash scripts/resolve_prs.sh <refs...>
```

This prints PR numbers, bottom of the stack first. For more than one PR, review each one in that order. Use one subagent per PR if subagents are available. Each PR's review sees only its own diff.

**2. Gather state** per PR:

```bash
bash scripts/pr_state.sh <number>
```

This prints `META` (including `author` and `approved_by`, every approval that wasn't dismissed), `BODY`, `COMMITS` (with author logins), `REVIEWS`, `THREADS` (resolved as one-liners, unresolved in full), `CONVERSATION` (with comment links), `CHECKS`, `FILES`, and `DIFF`. Work from this output. Fetch more only for what it cuts: a truncated body, a resolved thread you need in full, or the rest of a diff marked `DIFF_TRUNCATED`.

**3. Intent check.** Work out what the PR is meant to do, then check that it does it. This is the most important part of the pass.

- Read `BODY`, the title, and the commit messages in `COMMITS`. If the branch name, title, body, or commits name a Linear issue (like `ABC-123`), read it with the Linear tools. Follow a linked spec (Whimsical, Notion, Docs) only when the ticket and the code seem to disagree. A product spec beats the PR description.
- For a stacked PR, skim its neighbours' titles. Something that looks missing may be handled in another PR of the stack.
- Write down the intent in one or two sentences, and the business rules it must follow, such as roles, permissions, plans, limits, states, and timing. Don't invent rules the sources don't support.
- Trace each rule through the diff. A rule with no code path behind it, or code that encodes the wrong rule (wrong role, wrong plan, off-by-one against the spec), is a high finding. Cite where the rule came from. If the rule is only your inference, make it a low finding.
- Changes the intent doesn't explain (unrelated refactors, debug leftovers) are low findings. They become medium only when users would notice the change.

**Context.** Read `REVIEWS` for the user's own last review (`gh api user --jq .login` gives the user). If they've reviewed before, focus the quick pass on what changed since that review's commit. Code the user already reviewed doesn't need a second look for low findings. If the PR is already approved (`approved_by` isn't `none`), only high findings can block.

**4. Quick pass.** Check the diff against the High, Medium, and Low risk lists in the **quick-review** skill's "What to look for" section. Use only those three lists. Ignore its General list and its output format; missing tests are covered by the score. Only high and medium findings can block, along with the high findings from the intent check. Before counting one:

- Re-read the real code at the PR head, not only the diff hunk: run `git fetch origin pull/<N>/head` once, then `git show "<head_sha>:<path>"` (`head_sha` is in `META`; keep the quotes, zsh reads `$sha:s…` as a history modifier). For a stacked PR, when a symbol seems missing, check the **top** PR's `head_sha` before you flag it.
- Keep the finding only if you can name the concrete input or state that goes wrong. If you can't, change it to low or drop it.
- If a reviewer already raised the same point and it was settled, drop it.

**5. Judge the comments** with the "Owners" and "Addressed" rules. Every unaddressed blocking ask from someone other than an owner is a blocker. Link it. An owner's own open threads go under Notes as pending author work.

**6. Score and write the verdict.**

## Confidence score

This scores how safe the PR is to merge, assuming its stack merges with it. Start at 100 and subtract:

| Signal | Penalty |
|---|---|
| Each blocker | −25 |
| Each low finding or open non-blocking follow-up | −3 (max −15) |
| Intent comes only from the title and diff, or the sources disagree | −10 |
| A business rule from the intent check has no test that would catch it breaking | −5 each (max −15) |
| Touches migrations, auth/permissions, payments, data deletion, or shared infra config | −10 |
| Commits authored after the latest review by someone other than an owner, not counting restacks or generated-only changes (locales, lockfiles) | −5 |

Keep each deduction practical: it names something the author or reviewer can act on or check. Size and shape never cost points.

Clamp to 0–100. Bands: 🟢 90–100, 🟡 70–89, 🔴 0–69. A blocked PR can still score high if the fix is small. The score is about risk, the verdict is about readiness.

## Output

For each PR, emit this block. No preamble.

```
# Can Approve · [#<N> <title>](<url>)
## <🟢 ✅ APPROVABLE | 🔴 ⛔ BLOCKED>
- <band-emoji> Merge confidence: `<score>/100`
- 💬 Threads: `<unresolved>` unresolved · `<resolved>` resolved
- 🎯 Intent: <✅ matches | ⚠️ gap: <one line>> (<source: ticket, spec, PR body, or title only>)
- 🔍 Quick pass: 🔴 `<h>` · 🟡 `<m>` · ⚪ `<l>`

> <One or two plain sentences on what this PR does, for someone who has never seen the code. No file names, no jargon.>

### Blockers
1. 🔴 **<short title>**: <one sentence>. [link](<thread, comment, or file url>)

### Notes
- ⚪ <non-blocking follow-up, low finding, pending author work, or CI note, one line each, with a link when there is one>

### Confidence
| Deduction | Points |
|---|---|
| <what applied, specific to this PR> | −<n> |
```

- Omit `Blockers` when the PR is approvable. Omit `Notes` when there is nothing to add. Under `Confidence`, write "No deductions" when nothing applied.
- File links: `<url-without-/pull/N>/blob/<head_sha>/<path>#L<line>`.

**Every run** ends with a verdict table after the per-PR blocks, even for a single PR. It has one row per PR.

```
| PR | Verdict | Confidence | Link |
|---|---|---|---|
| #<N> <short title> | ✅ / ⛔ | `<score>` | <full PR url, bare> |
```

For a range or multi-PR run, put this above the table:

```
# Stack Verdict
## <🟢 ✅ APPROVABLE | 🔴 ⛔ BLOCKED>   Grade `<A–F>` · Score `<score>/100`
```

and this below it:

```
> <One or two plain sentences on what the stack delivers as a whole.>
```

- In the table, `<short title>` is 2–5 words. Put the PR url in the Link column as bare text, not a markdown link, so terminals print the whole address.
- The stack is APPROVABLE only if every PR is.
- Stack score: the mean of the PR scores, capped at the lowest PR score + 10.
- Grade from the stack score: A ≥ 90, B ≥ 80, C ≥ 70, D ≥ 60, F below 60.

## Guardrails

- Don't run tests, lint, typecheck, or builds. Don't wait on CI.
- Don't check out branches in the user's working tree. Read the code with `git show "<head_sha>:<path>"`.
- Never post, approve, or request changes on GitHub.
