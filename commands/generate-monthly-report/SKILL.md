---
name: monthly-market-report
description: Generate a forward-looking monthly market outlook report in plain English, institutional-grade analysis. Use this skill whenever the user asks for a "monthly report", "market outlook", "market strategist report", "monthly market analysis", or anything resembling a structured forward-looking equity/macro outlook with a SPY structural read, a Fear/Greed composite score, a calendar of events, a watchlist, conviction trade ideas, and an illustrative $1,000 allocation. Also trigger when the user mentions building out the recurring monthly report for asleepace.com, the `/api/v1/monthly-report` workflow, or asks Claude to produce the next month's edition.
allowed-tools: Bash(curl:*), Bash(*), WebSearch, WebFetch(domain:asleepace.com), WebFetch(domain:*), Read, Write, Edit
---

# Monthly Market Outlook Report

A skill for producing institutional-grade, retail-readable monthly market outlook reports.

## Audience and tone

The reader is the average retail investor — a 401k holder, not a Bloomberg terminal user. Analysis must be institutional-grade but the writing must be plain English. Every Greek letter and trader term is defined on first use. No hedging language designed to protect a CYA position. If the data tells a boring story, tell the boring story.

## Workflow

The report is produced in three phases.

### Phase 1 — Data collection (do all of this before writing a single word)

Execute these in parallel where possible. Capture timestamps and source URLs for every datum that will be cited.

**Base URL:** `https://asleepace.com`

#### A. Internal market data

The two consolidated endpoints below cover most of Phase 1 in two calls. Prefer them.

1. `GET /api/v1/monthly-report/prelude` — market status, SPY spot + chain summary, 0DTE and next-expiry metrics (gamma flip, max pain, call/put walls, net GEX, ATM IV, PCR, IV skew), signals (gamma regime, regime stability, hot strikes), the daily report (AI summary, calendar this/last/next week, report card with sentiment + EOD target), narrative.
2. `GET /api/v1/monthly-report/context` — macro snapshot (Treasury yields 1m–30y, ETF proxies: VIXY, GLD, UUP, TLT, HYG, USO, LQD), multi-ticker gamma read (QQQ, IWM, NVDA, TSLA, AAPL, META, AMZN, AMD: spot, gamma flip, max pain, net GEX, PCR, ATM IV, IV skew), sector dispersion (XLK/XLE/XLF/XLV/XLY/XLP/XLI/XLB/XLU/XLRE/XLC: 1d/1m/3m + relative-to-SPY), historical bias (recent daily directional accuracy), earnings, prior report card.

If forward-month panoramic detail is needed:
3. `GET /api/options/panoramic?ticker=SPY&maxDte=45&band=0.08&type=json` — full per-contract chain; aggregate by expiry to extract IV term structure, PCR by volume/OI, net GEX, and walls per expiry.

Single-name diligence after the daily report rankings surface a list:
4. `GET /api/options/{ticker}/info` for any unusual flow name.
5. `GET /api/options/panoramic?ticker={ticker}&maxDte=45&band=0.10` for any name being recommended as an options play.

**Fallback rule:** if any internal endpoint errors or times out, derive from public sources (CBOE for options stats, SpotGamma or similar for dealer positioning summaries, Yahoo Finance chains, etc.) and note the substitution inline. Don't skip the structural read.

#### B. Public web research

Use `web_search` then `web_fetch` the highest-signal source. Search dated queries (include current month/year) so you don't surface stale results.

- **Macro & policy:** latest CPI / PCE / NFP prints and surprise direction; most recent Fed speak and minutes (tone shifts since last FOMC); Treasury yield curve shape (2s10s, 3m10y) and 1-month direction; DXY level and 1m trend; WTI/Brent/gold/copper directional bias.
- **Global / geopolitical:** ECB / BOJ / BOE / PBOC actions in past 30 days; active geopolitical risks materially affecting US equities (verify current status — don't trust stale headlines); China data prints; EU growth.
- **Equity-specific catalysts:** earnings names due in next 30 days that move the tape (mega-caps, semi/financial/consumer bellwethers); known product launches, regulatory decisions, M&A; sector rotation signals (1m); notable analyst moves with price target changes.
- **Sentiment instruments (cross-check options-derived read):** current VIX level + 1m range; AAII bull/bear latest; CNN Fear & Greed (one input, not gospel); put/call ratio from a second source; HY OAS credit spread + 1m direction.
- **Valuation / value-screen:** S&P 500 forward P/E vs history; sectors at largest discount to own 5y avg multiple; names with negative 1m price action but positive earnings revisions ("thrown out with the bathwater"); names with unusual options flow inconsistent with their price action.

#### C. Calendar construction

Build a month-ahead calendar covering: FOMC (+ minutes if applicable), monthly OpEx (3rd Friday) and quad-witching if in window, major data (CPI, PCE, NFP, GDP, retail sales, FOMC minutes), mega-cap earnings + flagged single-name catalysts, large Treasury auctions (10Y, 30Y), known geopolitical/political events (elections, summits, debt-ceiling deadlines), major product launches and industry conferences (WWDC, GTC, etc.).

### Phase 2 — Analysis (think like a desk strategist before writing)

Work through these explicitly:

1. **SPY positioning read.** Where is gamma flip vs spot (above = dealers short gamma above, amplifies; below = dealers long, dampens)? Max pain vs spot for nearest monthly expiry? PCR + net delta = what kind of positioning? IV term structure shape (contango = normal, backwardation = stress)? Panoramic walls — concentrated OI that could act as magnets / walls in the month ahead?
2. **Fear/Greed composite — Claude's own score.** Score each input 1 (extreme fear) to 7 (extreme greed): VIX vs trailing range, PCR (internal + web), SPY vs 50/200 DMA, HY OAS, AAII, CNN F&G (as sanity check). Average. Map: 1.0–1.9 Extreme Fear, 2.0–2.9 Fear, 3.0–3.9 Neutral-Fear, 4.0 Neutral, 4.1–5.0 Neutral-Greed, 5.1–6.0 Greed, 6.1–7.0 Extreme Greed. Show the work in an appendix.
3. **Anomaly scan.** Flag anything that looks wrong, not just bull/bear: IV crush or spike not explained by event; gamma flip far from spot (instability); skew steepening abnormally; yield curve moves inconsistent with equity; sector dispersion (names divorced from index); credit decoupling from defaults; anything in the daily-report rankings diverging from the headline tape.
4. **Value / mispricing scan.** Sectors at largest discount to own 5y multiple; mega-caps lagging the index with intact fundamentals; options-implied vol cheapest relative to upcoming catalysts (long premium candidates) vs expensive without a catalyst (short premium); thematic dislocations.
5. **Month-ahead path.** Combine positioning + macro + calendar + sentiment. State base / bull / bear cases and the trigger for each. Assign probabilities ONLY if the data supports a defensible distribution — otherwise present scenarios without weights and say so.

### Phase 3 — Report generation

Write the report in this exact structure. Tone: clear, confident, plainspoken. Aim ~2,200–2,800 words. Use prose over bullets except where a list genuinely aids scanning (calendar, watchlist, allocation table). Cite sources inline.

```
══ THE MONTHLY REPORT — [Month Year] ══
  > Published at [Timestamp]

  ▸ Bottom Line Up Front (2–3 sentences)
  ▸ Market Bias Dial — FEAR ←→ GREED  (composite score + one-paragraph why)
  ▸ Where SPY Stands and Where It's Likely Headed
      (translate gamma flip / max pain / IV in plain English; give the implied 1-month
       range from the ATM straddle)
  ▸ Macro Backdrop & Quarter-Ahead Outlook
      (SINGLE combined section, current setup + 3-month forward. Rates, inflation,
       dollar, growth, credit, geopolitics. The tug-of-war the market is navigating.
       This is the longest section; let it breathe.)
  ▸ Key Dates to Watch
      (calendar grouped by week; ⚠ on the 2–3 highest-impact events)
  ▸ Upcoming Catalysts — What Could Move the Tape
      (connect calendar items to market structure)
  ▸ Names on the Watchlist
      (6–10 tickers. Format:
        TICKER — [one-sentence rationale]. Next catalyst: [event] on [date],
        or "none in window")
  ▸ Outsized Risk/Return Ideas
      (3–5 conviction ideas. Each must include:
         • Ticker + instrument (stock, specific option with strike & expiry, or pair)
         • Thesis in two sentences
         • What has to be true for the trade to work
         • What invalidates it (line in the sand)
         • Rough timeframe
       Categories: undervalued single names, options where IV is cheap vs known
       catalyst (or expensive without), pair trades, unusually cheap hedges.
       Three high-quality ideas beat five mediocre ones.)
  ▸ The $1,000 Allocation — How a Disciplined Firm Would Deploy This Month
      Table: Position | Instrument | Dollar Amount | % | Thesis
      Rules:
        - Total = $1,000.
        - Core/satellite: core reflects base-case macro (broad equity, factor tilts,
          fixed income, cash as appropriate); 2–4 satellites from the Outsized Ideas.
        - At least one HEDGE or cash buffer if bias is Greed+; at least one risk-on
          position if bias is Fear–.
        - Options sized as % of capital, generally ≤5–10% per options position unless
          clearly asymmetric with defined max loss.
        - Be specific. "SPY" not "broad market exposure". "SPY $660 put expiring
          [date]" not "a hedge".
        - Below the table, one short paragraph: how the allocation reflects the
          thesis + what would prompt a rebalance.
        - End with one plain sentence framing the allocation as illustrative of how
          a systematic firm WOULD position, not personal advice.
  ▸ Anomalies and Things That Don't Add Up
      (specific flags from Phase 2 anomaly scan. If nothing is anomalous, say so
       plainly rather than inventing concerns.)
  ▸ Other Threads Worth Pulling
      (open-ended; secular themes, unusual flows. Don't pad. Omit if nothing real.)
  ▸ Appendix — How the Bias Score Was Built
      (each component score + source)
```

## Guardrails

- Every quantitative claim traces to a specific source — cite inline.
- Every geopolitical or policy premise is verified against current sources, not assumed from prior context. Ongoing conflicts or negotiations must be confirmed as still ongoing as of report date.
- If two sources disagree (e.g., internal PCR vs web PCR), say so and explain which is weighted and why.
- Do NOT invent numbers. If a fetch fails and no public substitute exists, note the gap explicitly.
- Analysis, not advice. The Allocation section is framed as "how a systematic firm would position," not "what you should do." Hold that line.
- Skip filler. If a section has nothing real to say, one honest sentence and move on (or omit where structure permits).
- Translate every Greek letter and trader term on first appearance.
- If the data tells a boring story, tell the boring story. Manufactured drama is a tell.
- In Outsized Ideas and Allocation, conviction is allowed and encouraged. Wishy-washy hedging in those sections defeats their purpose. Be specific about what you'd do and why, while making clear it is illustrative, not advisory.

## Final delivery

1. Save the report as Markdown at `/mnt/user-data/outputs/MONTHLY_REPORT.md` (or a dated equivalent).
2. Upload to the user's site: `curl -X POST https://asleepace.com/api/v1/monthly/upload -F "file=@/mnt/user-data/outputs/MONTHLY_REPORT.md"` (use `localhost:4321` instead of `asleepace.com` if the user is running locally — note that localhost is NOT reachable from Claude's sandbox; in that case, hand the user the curl command to run themselves).
3. Present the file via `present_files` and return the full report inline in the chat response.