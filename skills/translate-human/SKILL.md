---
name: translate-human
description: Translate AI-generated text from a coding session into clear, human-sounding PR descriptions and code review comments. Use this skill whenever the user invokes /translate-human, or asks to rewrite, humanize, clean up, or "translate" AI-written text for a pull request description or a code review comment, including when they paste AI output and want it to read like a real person wrote it. It handles both PR descriptions (condense implementation detail into a high-level overview a non-technical product manager could follow) and code review comments (warm, encouraging tone with (suggestion)/(question)/(nit) tags for non-blocking notes). Trigger even when the user does not say the word "skill", any request to make AI coding text read as natural, concise, human writing should use this.
---

# Translate Human

Turn AI-generated coding text into writing that sounds like a real, thoughtful engineer wrote it. The AI voice tends to be wordy, hedge-y, and full of tells (em dashes, semicolons, "furthermore", inline code jammed into sentences). This skill strips that away and reshapes the text for its actual audience. USe ASD-STE100 Simplified Technical English.

## Step 1: Identify the mode

There are two modes. Figure out which one applies from context before rewriting.

- **Code review comment** — feedback pointed at a specific piece of code. Usually short, reacts to a diff or snippet, phrased as an observation or request. Cues: the user pasted a diff/snippet, mentioned "review", "comment", "PR feedback", or the text critiques specific lines.
- **PR description** — explains a whole change set. Usually longer, has an overall narrative, may already have sections. Cues: the user mentioned "PR description", "pull request", "summary of this PR", or the text describes what a branch does as a whole.

If genuinely ambiguous, make your best guess from length and shape (short + code-local = review comment; broad + narrative = PR description) and note the assumption in one line. Only ask if you truly cannot tell.

The text to translate is usually either pasted by the user or the most recent relevant AI output in the current session. If it is not obvious which text they mean, ask which block they want translated.

## Step 2: Apply the universal rules (both modes)

These apply to every translation regardless of mode:

1. **Plain, concise English sentences.** Short sentences. One idea each. Cut anything that does not change the meaning. If a sentence can be deleted without loss, delete it.
2. **Move code out of prose.** Inline code that is a real example or snippet gets pulled into its own fenced code block. Keep inline code only for short references like a single variable, function, or file name (`userId`, `parseWall()`, `config.ts`). A rule of thumb: if it would be more than a few tokens or shows *how* to do something, it belongs in a block.
3. **Remove extraneous context.** Keep the primary message on point. Drop throat-clearing ("It's worth noting that", "As you can see"), restated background the reader already has, and padding that does not advance the point.
4. **Strip the AI tells from prose.** This applies to the human-readable text, NOT to code (code keeps its semicolons, and any punctuation, untouched).
   - No em dashes. Rewrite into two sentences or use a comma.
   - No semicolons in prose. Split into separate sentences.
   - Avoid filler and stock AI phrasing: "furthermore", "moreover", "additionally" pile-ups, "leverage" (use "use"), "utilize" (use "use"), "delve", "robust/seamless/comprehensive" as filler, "It's not just X, it's Y", "not only X but also Y", and heavy hedging ("it might potentially be beneficial to possibly").
   - Prefer active voice and direct verbs.

## Step 3: Apply the mode-specific rules

### Code review comments

Tone is the point here. Keep it warm, collaborative, and encouraging. You are a teammate, not a gatekeeper.

- **Speak as a team.** Use "we" and "let's" rather than "you". "We could pull this into a helper" reads better than "You should extract a helper".
- **Frame as options, not orders.** Use phrasing like "could also", "one option is", and "this is a good idea, we could improve it by also...". Lead with what is good before suggesting a change when it fits naturally.
- **Keep locality.** A comment should stay attached to the specific code it is about. If the input covers several spots, split it into separate per-location comments rather than one big block. Do not merge feedback about different lines into a single paragraph.
- **Leave a code suggestion when it helps.** If you are proposing a concrete change, show it in a fenced code block (or a GitHub-style ```suggestion block if the user works in GitHub) so the author can apply it directly. A worked example beats a description.

**Non-blocking tags.** Prefix non-blocking comments with a lightweight tag so the author knows how much weight to give them:

- `(suggestion)` — cleanup or improvement that does not affect functionality
- `(question)` — a clarifying question, not a request for change
- `(nit)` — a tiny personal preference. Use sparingly. If most comments are nits, the review loses signal.

Blocking or functional feedback needs no tag, its importance is clear from the content.

**Example**

Input (AI voice):
> This function could potentially be refactored to improve readability; furthermore, it might be beneficial to leverage a dedicated helper — for instance, you could extract the validation logic into a separate utility function such as `validateInput()`.

Output (translated):
> (suggestion) The validation logic here is doing a lot. We could pull it into a small helper to keep this function focused. Something like:
> ```ts
> function validateInput(payload: Payload): Result {
>   // validation moves here
> }
> ```
> Not blocking, just an idea for readability.

### PR descriptions

The audience is broad. Write so a non-technical product manager could read the top and understand what shipped and why, then let engineers dig into detail below. Condense the low-level implementation detail into a high-level overview rather than listing every function that changed.

Use this structure:

```markdown
## Summary
[2-4 plain sentences. What changed and why it matters, in terms a PM would understand. No jargon, no function names.]

## What changed
[A short, high-level bullet list of the user-facing or behavioral changes. Group related work. Still readable by a non-engineer.]

## Technical notes (optional)
[Only if there is detail worth keeping for reviewers. Keep it brief and skimmable. This is where implementation specifics live if they must be recorded at all.]

## Testing
[How it was verified, in one or two lines.]
```

Fold the implementation minutiae up into the overview. If the input is a wall of "changed X in file Y, updated Z helper", collapse that into what it accomplishes. A reviewer can read the diff for the line-by-line.

**Example**

Input (AI voice, low-level):
> This PR refactors the `arcade-realtime` Durable Object to introduce a nonce-based replay protection mechanism; furthermore, it adds an HMAC token validation layer in `session.ts` and wires Redis-backed rate limiting into the `onMessage` handler — additionally, the `verifyToken()` utility was extracted and unit tested.

Output (translated):
> ## Summary
> This tightens security on Arcade multiplayer sessions so players cannot cheat by replaying or forging game messages. It closes a gap where a manipulated client could send fake actions.
>
> ## What changed
> - Game messages are now signed and verified, so forged actions get rejected.
> - Each message can only be used once, which blocks replay attempts.
> - Added rate limiting so a single client cannot flood a session.
>
> ## Technical notes
> HMAC token validation and nonce tracking live in the realtime Durable Object. Rate limiting is Redis-backed. Token verification was extracted into a tested helper.
>
> ## Testing
> Unit tests cover token verification. Verified replay and flood attempts are rejected in a local session.

## Final check before returning

- Did any em dash or prose semicolon survive? Remove it.
- Is any real code example still stuck inline in a sentence? Move it to a block.
- For a review comment: is the tone warm, does it use "we", and is each comment local to its code?
- For a PR description: could a non-technical PM read the Summary and get it?
- Is anything left that does not earn its place? Cut it.

Return only the translated text, ready to paste. Do not wrap it in commentary about what you changed unless the user asks.
