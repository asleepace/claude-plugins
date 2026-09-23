---
name: second-look
description: Use when the user invokes /second-look, or asks to "step back", "rethink this", "is there a simpler way", "what would you do differently", or wants alternative approaches, simplifications, or tradeoffs for a PR, a stack of PRs, a technical spec, or a design. Exploratory and read-only; not a bug review.
argument-hint: <pr-ref | A..B | spec path or URL | pasted text>
---

# Second Look

Step back from the work and ask: **is there a cheaper, simpler, or safer way to reach the same end state?** You are looking for small tweaks with big payoffs, like one shift in approach that deletes a whole class of code or errors. This is not a bug review.

"The current approach holds up" is a valid result. Don't invent ideas to fill the table.

Read-only. Don't edit code, post comments, or check out branches.

## Workflow

**1. Load the input.**
- **PR or stack:** `bash scripts/resolve_prs.sh <refs...>` prints PR numbers, bottom of the stack first. For each one, run `gh pr view <N> --json title,body,url,baseRefName,headRefOid` and `gh pr diff <N> --name-only`. Read the non-test, non-generated files first, and read tests only when you need them. For a range, treat the whole stack as the unit, because the biggest wins often cross PR lines.
- **Single PR inside a stack:** if its base is not the default branch, review only that PR. Say in the header that it is part of a stack, and that `A..B` widens the scope.
- **Spec or design:** read the file, URL, or pasted text.
- **Discussion:** for a PR, read all three sources, because rejected ideas usually sit in review comments:
  `gh api repos/<o>/<r>/issues/<N>/comments --paginate`, `gh api repos/<o>/<r>/pulls/<N>/comments --paginate`, and `gh api repos/<o>/<r>/pulls/<N>/reviews --paginate`. For a spec, read its alternatives or open-questions section. You need this in step 5.

**2. Write down the end state and check the premise.** In 1–3 sentences, say what the work has to achieve and which constraints are fixed (user-facing behaviour, data, deadlines). Every idea must reach this same end state. An idea that shrinks the end state is allowed only when it says so plainly in its Tradeoff.

Then check the stated problem against the code at the head. For a stack, `git diff origin/<base> <headRefOid> -- <path>` shows whether the stack changed a neighbouring file. If the problem the PR or spec describes doesn't happen in the code, that is usually the strongest idea you will find.

**3. Read past the diff.** Look at the callers, the neighbouring modules, and the helpers that already exist. The best simplifications usually sit next to the change, not inside it. Read code at the PR head with `git fetch origin pull/<N>/head`, then `git show "<headRefOid>:<path>"`.

**4. Brainstorm. Don't score yet.** Write at least 8 raw ideas. Cover every lens below at least once, and make at least one idea bold (a different design, not a tweak):

| Lens | Ask |
|---|---|
| Delete | What if this code, state, or step didn't exist at all? |
| Reuse | Does something in the codebase or a dependency already do this? |
| Invariants | Can a type, a constraint, or a data shape make the bad state impossible instead of checked for? |
| DRY | Which logic is repeated in two or more places and could have one owner? |
| Move it | Would this be simpler in a different layer, service, or owner? |
| Re-scope | Is there a smaller end state that gives 90% of the value? |
| Sequence | Would splitting, merging, or reordering the PRs or phases cut risk or rework? |
| Bold | How would you build this from scratch knowing what we know now? |

**5. Score each idea** on a 1–5 scale:
- **Reward:** how much it simplifies, removes error cases, deletes code, or speeds up delivery.
- **Cost:** the effort, plus the churn and risk, plus what you give up.
- **Confidence:** how sure you are that the reward is real. Base it on code you read, not a guess.
- **Net** = Reward − Cost.

Then filter:
- Drop ideas with Net < 1.
- Drop ideas the discussion already rejected, unless the reason no longer holds. If it no longer holds, keep the idea and cite the code that disproves the reason.
- If the rejection was a **product** decision, not an engineering one, keep the idea only when it cites the exact code that contradicts the reason given. Name who has to agree again in its Tradeoff.
- **Wildcard:** from the dropped ideas, keep the one with the highest Reward if its Reward is 4 or more. Mark its row 🃏.

Sort the rows by Net, then by Confidence. Keep at most 6. The 🃏 row goes last, outside the 6, and is not counted in the dropped total.

An idea that only matters if another idea is rejected starts its Idea cell with `(if #N rejected)`.

## Output

No preamble.

```
# Second Look · <target: PR #N, stack #A..#B, or spec name>
> End state: <one sentence from step 2>

| # | Idea | Gain | Tradeoff | Source | Reward | Cost | Net | Conf |
|---|---|---|---|---|---|---|---|---|
| 1 | <3–8 words> | <≤15 words> | <≤15 words> | <file or module> | `4` | `1` | `+3` | `4` |
| 🃏 | <bold idea> | … | … | … | `5` | `5` | `0` | `2` |

## Recommendation
<2–4 sentences. Name the one idea with the best payoff, why it wins, and the first concrete step. If no idea cleared the bar: "The current approach holds up.", then name the idea that came closest and what stopped it.>

<N> other ideas were dropped as low payoff or already settled.
```

- Gain and Tradeoff are 15 words or fewer each. Put the longer reasoning in the Recommendation.
- Source is the one file, module, or spec section the idea rests on, in plain text. Put line numbers and code in the Recommendation.
- If no row clears the bar and there is no wildcard, leave out the table and write only the Recommendation.

## Guardrails

- Don't run tests, builds, or linters.
- Don't list bugs, style points, or nits. Those belong to `/code-review` and `/quick-review`.
- Every idea must name something you read in the code or the spec. An idea you can't tie to a real file or section doesn't go in.
