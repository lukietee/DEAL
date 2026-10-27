# DEAL backend

Node 24 + TypeScript + Fastify. It holds every API key and runs the AI cues, agreement drafting, SHA-256 fingerprinting, the deterministic mismatch check and Stripe test payments. The contract is Section 12.5 of `../DEAL_Concept.md`. **All money is integer cents.**

## Run (mock mode, no keys)

```bash
cd backend
npm install
cp .env.example .env        # optional; with no .env, MOCK_MODE defaults to true
npm run dev                 # http://0.0.0.0:3000 (reachable from an iPhone on LAN / ngrok)
npm run demo:marketplace    # in a second terminal: the flagship Marketplace bike meetup with curl + jq
npm run demo                # the car flow (12.6)
```

Other scripts:

| Command | What it does |
|---|---|
| `npm test` | vitest: fingerprint, mismatch rules (match / extra fee / changed amount / tampered), mock extraction, full HTTP flow, auto sessions (detection, speaker "auto", `/end`, history) |
| `npm run build` | `tsc` typecheck (src + tests), then emit `dist/` |
| `npm start` | run the built server (`node dist/server.js`) |
| `bash scripts/demo.sh http://<host>:3000` | run the car demo against another URL (`INTERVAL_MS=…` changes the script speed) |
| `bash scripts/demo-marketplace.sh http://<host>:3100` | run the Marketplace demo (mock mode: in real mode its Facebook link is a 422 by design): parse listing, session with listing, condition check, bike script, lock $520, **$20 gas fee blocked**, reject, pay $520, dispute pack |

For the phone: `ngrok http 3000`, then put the https URL in the iOS `BACKEND_URL`.

## Modes

Each dependency is chosen on its own:

| Env | Empty / default | Set |
|---|---|---|
| `MOCK_MODE` | `true`: cues come from the content scripts' `expected` (matched on line text); free-typed lines use a regex/keyword fallback built on `content/tactics.json`. The agreement comes from the script's `expected_agreement`, or is assembled from extracted terms. The mismatch explanation is a template. | `false`: NVIDIA Nemotron on Nebius Token Factory, or Claude (see **AI provider** below). Output is validated with zod, with one retry on invalid JSON. If the model still fails on a cue, detection, the summary, the agreement or the mismatch sentence, that call falls back (Nemotron → Claude when its key is set → mock), so the conversation never stalls. Listing parse failures return 422 and condition-check failures return 502 instead (nothing canned in real mode). The cue model sees the session's live research (finished agents' summaries, price ranges and top sources), not the illustrative comparables. |
| `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` | in-memory store (lost on restart) | Supabase via the service-role key. Run `../supabase/schema.sql` in the SQL editor first. |
| `STRIPE_SECRET_KEY` | fake receipt (`pi_mock_…`, `mock: true`) | Stripe **test mode only** (`sk_test_…` is required). A PaymentIntent is created and confirmed server-side with `pm_card_visa`. |

`MOCK_MODE=false` with neither `NEBIUS_API_KEY` nor `ANTHROPIC_API_KEY` logs a warning and uses the mock AI. `GET /health` shows what is active.

### AI provider: NVIDIA Nemotron on Nebius Token Factory (`src/ai/nemotron.ts`, `src/nebius.ts`)

Real mode uses **Nemotron** when `NEBIUS_API_KEY` is set, unless `AI_PROVIDER=claude`; **Claude** (`src/ai/index.ts`) when only
`ANTHROPIC_API_KEY` is set. With both keys, Nemotron does the work and Claude is the per-call backup. `GET /health` reports
`ai` (`nemotron` | `claude` | `mock`), `provider` (`nebius` | `anthropic` | `null`) and `models` (which model does each call, plus `backup`).

Every call is one OpenAI-compatible chat completion (plain `fetch`, JSON mode, `chat_template_kwargs.enable_thinking=false`
unless noted), with the same prompts and zod schemas as the Claude path. Each call goes to the Nemotron model that fits it:

| Call | Model (env, default) | Why | Measured (real, Token Factory) |
|---|---|---|---|
| Live cue + speaker "auto" (every line) | `NEMOTRON_CUE_MODEL`, `nvidia/Nemotron-3-Ultra-550b-a55b`, thinking off | Scored on the bike script against its expected cues: Lightning got 0/19 offers right (it converted cents twice) and 8/19 colours; Ultra gets 18/19 and 13/19 and is still fast | median ~1.0 s, max 1.4 s (25 lines) |
| Product detection, session summary | `NEMOTRON_FAST_MODEL`, `nvidia/Nemotron-3_5-Lightning` | Background / end-of-session, simple extraction; Lightning gets them right | 0.45–0.7 s |
| Agreement draft | `NEMOTRON_REASONING_MODEL`, `nvidia/Nemotron-3-Ultra-550b-a55b`, **thinking on** | It gets locked, fingerprinted and paid. Thinking (≈1.9k reasoning tokens) costs ~4 s more than off (1.2 s) and adds the open questions the buyer should confirm | ~5.5 s |
| Mismatch sentence | `NEMOTRON_REASONING_MODEL`, thinking off | One sentence citing the contradicting line | ~0.7 s |
| Listing from pasted text or a fetched page; condition check from a typed observation | `NEMOTRON_MODEL`, `nvidia/nemotron-3-super-120b-a12b` | Long-ish text in, structured listing out | 0.9–2 s |
| Listing screenshot, condition-check photo | `NEMOTRON_VISION_MODEL`, `nvidia/Nemotron-3.5-Super-VL` | Vision | photo 2.7–4.8 s, screenshot ~7.8 s |

Nemotron-specific handling: the cue prompt gets `NEMOTRON_CUE_NOTES` (cents scale with examples, the asking price counts as a
seller offer, the colour rule spelled out, imperative cue examples). Two deterministic guards run on every Nemotron cue: an amount
more than 20× the session's price that is plausible ÷100 is scaled back (double-converted cents), and a standing offer above
`max_budget` is always red. A leaked `<think>` block is stripped before JSON is parsed; `extractJson` tolerates prose and fences.

Env: `NEBIUS_API_KEY`, `NEBIUS_BASE_URL` (default `https://api.tokenfactory.nebius.com/v1`), `AI_PROVIDER` (`claude` forces
Claude; `nebius` / empty = Nemotron when its key is set), `NEMOTRON_CUE_MODEL`, `NEMOTRON_FAST_MODEL`, `NEMOTRON_MODEL`,
`NEMOTRON_REASONING_MODEL`, `NEMOTRON_VISION_MODEL`. Claude path: `ANTHROPIC_API_KEY`, `CUE_MODEL`, `AGREEMENT_MODEL`.

Content comes from `../content` at runtime (override with `CONTENT_DIR`). No placeholder content was needed. If a file were missing, the loader would also look in `src/mock/content/` (last-resort placeholders), which does not exist today.

## API (12.5 plus additions)

| Method & path | Body | Returns |
|---|---|---|
| `GET /health` *(added)* | | `{ok, mock_mode, ai, store, payments, models, scripts, time}` |
| `POST /sessions` | `{category?, item?, asking_price?, target_price?, max_budget?, style?, listing?, auto?}` (all optional) | `Session` (201). With an `item`: the set-up flow, unchanged (`auto: false`, `detected: true`, `category` normalised, e.g. `"Pawn Shop"` → `pawn_shop`, `style` defaults to `firm`). With no `item` (missing or empty): an **auto session** (see below). The optional `listing` (a `Listing`) is stored as `session.listing`. Every session also has `condition_checks: ConditionCheck[]` |
| `POST /sessions/join` | `{join_code}` (case-insensitive) | `Session` |
| `GET /sessions` | | `Session[]` (live, ended and paid; newest first), each with `final_price, paid_at, blocked_total, savings`. `final_price` = receipt amount, else `summary.final_price`, else a locked agreement's total. `savings` = `asking_price − (receipt amount or summary.final_price)`, `null` when either is unknown |
| `GET /sessions/:id` | | `{session, events, agreement, payment_requests, receipt, script}` |
| `DELETE /sessions` *(added)* | | `{deleted: true}`. Settings → "Delete all sessions" |
| `POST /sessions/:id/events` | `{speaker: "buyer"\|"seller"\|"auto", text}` | `Event` (201). With `"auto"` the backend decides who spoke; the stored `speaker` is always `buyer` or `seller` |
| `POST /sessions/:id/end` *(added)* | | `Session` (200). Ends the conversation, with or without a payment: stops a playing script, sets `ended_at`, `status: "ended"` (unless already `paid`) and writes `summary`. Idempotent: a second call returns the stored summary |
| `POST /sessions/:id/script/play` | `{script_id, interval_ms?}` | `{started: true, script_id, line_count}`. 409 if already playing. Progress is in `GET /sessions/:id` → `script` |
| `PATCH /sessions/:id/terms` | `{term_id, correction: {label?, amount?, type?, removed?}}` | `{terms: Term[]}` |
| `POST /sessions/:id/agreement` | | `Agreement` (201, draft). 409 if already locked |
| `POST /agreements/:id/confirm` | `{role}` | `Agreement`. Locked + fingerprinted when both have confirmed |
| `POST /sessions/:id/payment-requests` | `{line_items: [{label, amount}]}` | `PaymentRequest` (201): `approved` or `blocked`. 409 if the agreement isn't locked |
| `POST /payment-requests/:id/decision` | `{decision: "approve"\|"reject"}` | `PaymentRequest`. Only allowed on `blocked` requests |
| `POST /payment-requests/:id/pay` | | `Receipt` (201). Only allowed on `approved` requests; re-checks first |
| `GET /sessions/:id/dispute-pack` | | JSON evidence pack |
| `POST /listings/parse` *(marketplace)* | `{url?, text?, image_base64?}` (at least one) | `Listing` (200). See below |
| `POST /sessions/:id/condition-check` *(marketplace)* | `{observation?, image_base64?}` (at least one) | `{discrepancies: Discrepancy[], event: Event}` (201). 409 if the session has no `listing`. Real mode: 502 `{error}` if the model fails |
| `POST /research/preview` *(added, B2 market check)* | `{item, category?, asking_price?}` (`asking_price` in cents; `category` defaults to `marketplace`) | `{summary: string\|null, price_low: number\|null, price_high: number\|null, sources: [{title, url, price, note, image_url}]}` (cents). Blocking. Real mode runs the "comparable listings" research agent (3 Tavily searches + one Nemotron synthesis, ~3.5 s; ~15–25 s on the Claude fallback) plus og:image lookups; a failed agent returns nulls and any search hits. Mock mode returns `content/comparables/<category>.json` in this shape after ~1.5 s |
| `POST /look/identify` *(added, Look mode)* | `{image_base64, hint?}` (JPEG crop from the glasses, ≤ 768 px; a `data:` prefix is fine) | `{is_product: bool, name: string\|null, category: string\|null, confidence: 0…1}`. Real mode: one `NEMOTRON_VISION_MODEL` call (~1.5 s; `CUE_MODEL` on the Claude fallback), zod-validated with one retry; strict about `is_product` (people, hands, walls, generic furniture, screens and blurry frames are `false`, and so is anything it can only name generically); 502 `{error}` if the model fails. Mock mode always returns The Weeknd – Starboy (2×LP vinyl), `category: "vinyl"`, `confidence: 0.92` |
| `POST /look/price` *(added, Look mode)* | `{name, category?}` | `{name, price_low: number\|null, price_high: number\|null, summary, source_count}` (cents; `summary` is one short line like `"Used $22–30 · new $35"`). Real mode: one Tavily search, then `NEMOTRON_FAST_MODEL` reads the snippets (~1–3 s; Claude fallback: `CUE_MODEL` with at most 2 web searches, ~4–5 s); 502 `{error}` on failure. Cached in memory per normalized name for 30 min (failures aren't cached), and concurrent requests for the same name share one call. Mock mode: Starboy is $25–35 used, other names get a stable demo range, after ~0.3 s |
| `GET /comparables/:category` *(added)* | | `content/comparables/<category>.json` |
| `GET /scripts` *(added)* | | `{scripts: ["car_accord", "marketplace_bike", "pawn_guitar"]}` |

`Event` has a new field `kind`: `"speech"` for transcript lines, or `"condition_check"` for the event a condition check inserts. The request body limit is 12 MB, so base64 photos fit. Downscale on the phone first, because Claude takes at most 5 MB per image.

Errors are `{error, details?}` with status 400 (validation), 404, 409 (state conflict), 422 (real mode: listing couldn't be read) or 502 (real mode: condition model failed).

### Live research, suggested phrases and Look: Tavily + Nemotron (`src/research.ts`, `src/look.ts`)

Real mode picks the provider with the same rule as the core AI (`researchProvider`; `GET /health` → `research`):
`nemotron` when `NEBIUS_API_KEY` and `TAVILY_API_KEY` are set unless `AI_PROVIDER=claude`, else `claude` when
`ANTHROPIC_API_KEY` is set, else `mock`. A mock core AI keeps research on mock.

- **Research agents** (`GET /sessions/:id` → `research.agents`). When the item is known, three agents run in parallel:
  comparable listings, known issues & wear, fair price & leverage. Each one:
  1. plans 2–3 templated queries from the item name (comps 3, issues 2, price 2), e.g. `"Trek Domane AL 2 road bike sold listings eBay"`;
  2. runs them on **Tavily** in parallel (`search_depth: advanced` for comps and price, whose snippets carry the prices;
     `basic` for issues; comps also asks for `include_images`). `status` goes `searching` → `reading` as results land,
     `queries` and `sources` fill live, `activity` says what it's doing;
  3. sends the top 10 deduped results (by Tavily score) to one **`NEMOTRON_MODEL`** call (JSON mode, thinking off), which writes
     `summary`, `headline` (≤ 24 chars for the glasses strip; `agentHeadline` falls back to the price range or the summary),
     `price_low` / `price_high` and per-source `price` / `note`. Same zod schema as the Claude path, retried once on invalid JSON.
     Sources the model names that Tavily didn't return are dropped;
  4. fills thumbnails from the pages' og:image (fetched while the model writes), else from Tavily's images (comps).

  Measured: all three done in ~3.5–7 s (Claude + web_search took 15–25 s). Credits per session: comps 6 + issues 2 + price 4 = 12.
  A failing agent (every search failed, or the model failed twice) ends in `status: "error"`; the others carry on.
- **Suggested phrases** (`GET /sessions/:id` → `suggestions`) after every line: `NEMOTRON_FAST_MODEL` in JSON mode (~0.7 s),
  grounded in the finished agents' summaries; template phrases if the model fails.
- **Look mode.** Identify: `NEMOTRON_VISION_MODEL` with the strict `is_product` prompt (no JSON mode: the VL model answers ~2× faster
  without it). Price: one Tavily search (`"<name> price used sold"`, advanced, 2 credits), then `NEMOTRON_FAST_MODEL` reads the snippets;
  `source_count` is capped by the results. Cache and in-flight dedupe are unchanged, so a cached name costs no credits.

The Claude path (`client`) is unchanged and stays the fallback. Mock mode is unchanged and deterministic.

### Auto sessions: "Start listening" with no setup (`src/auto.ts`)

The buyer can tap **Start listening** without entering anything. `POST /sessions {}` (no `item`) returns a session with
`auto: true`, `detected: false`, `item: ""`, `category: "other"`, `asking_price`/`target_price`/`max_budget: null` and
`style: "friendly"`. No research runs yet. (`auto: true` together with an `item` gives an auto session whose item is already
known: research starts at once and detection only fills a null asking price. A `listing` with no `item` uses the listing title.)

New `Session` fields (every session; sessions stored before these existed read as `auto: false, detected: true, ended_at: null, summary: null`):

```ts
auto: boolean; detected: boolean; ended_at: string | null; summary: SessionSummary | null;
asking_price: number | null; target_price: number | null; max_budget: number | null;   // cents
status: "live" | "agreement_draft" | "locked" | "paid" | "ended";
SessionSummary = { outcome: "deal" | "no_deal" | "undecided", final_price: number | null /* cents, set only for "deal" */,
                   headline: string /* <= 12 words */, key_points: string[] /* <= 4 */ }
```

- **Speaker "auto".** Post lines with `speaker: "auto"` (one microphone). Real mode: the cue model returns an extra
  `speaker` field in the same call (no extra latency). Mock mode, and when the model omits it: a verbatim script line takes
  its script speaker; otherwise "I'll take", "would you do", "can you do", "I can pay", "I'll give", "still available" → buyer;
  "I'm asking", "firm", "lowest I", "selling" → seller; otherwise the opposite of the previous line (the first line is the buyer).
- **Product detection.** After each event in an auto session, while `detected` is false, while the item is still the
  placeholder, or while `asking_price` is null (up to 40 lines), a detection step reads the transcript and extracts
  `{item, category, asking_price, condition_claims}`. Real mode: `CUE_MODEL`, a small zod-validated JSON prompt, run after the
  event is saved and serialised per session (it does not delay the cue; a queued run absorbs later lines). Mock mode: regexes
  ("is the X still available", "selling/this/the/my X for $N", "$N for the X", "X, $N", "asking 220"), run before the event
  response returns. A buyer's "$150 for the bike?" names the item but is never taken as the asking price.
- **When the item is found:** `item`, `category` (normalised to `car | pawn_shop | marketplace | electronics | other`),
  `asking_price` (if heard), `detected: true`, and, when the seller made condition claims ("barely used", "like new", …) and
  there is no listing, `listing = {source: "other", title: item, category: "marketplace", condition_claims, asking_price,
  description: "Heard in conversation: …"}`, so condition checks work too. Then the research agents start and suggested phrases refresh.
- **No product after 3 lines:** `item: "Item from conversation"`, `detected: true`, `category: "other"`. Detection keeps
  running and a real item named later replaces it (and restarts research). Mock mode starts its demo research on the
  placeholder; real mode waits for a real item name, so no web searches are spent on the placeholder.
- **Null target / max.** The cue prompt and suggested phrases never invent the buyer's budget. With no target/max the cue
  status is judged against the live research fair range (low end and below green, inside yellow, above the high end red), and
  phrases anchor on that range or ask questions instead of naming a number. Mock cues do the same.
- **`POST /sessions/:id/end`.** Real mode: `CUE_MODEL` summarises the transcript plus agreement, receipt and research range.
  Mock mode: a template (receipt → deal at the paid amount; locked agreement → deal at its total; "deal / I'll take it /
  sounds good" with a standing offer → deal at that offer; "no thanks / I'll pass" → no_deal; otherwise undecided). A receipt
  always forces `outcome: "deal"` and `final_price` = receipt amount. Headline is cut to 12 words, key points to 4.
- **Supabase.** New columns `sessions.auto`, `detected`, `ended_at`, `summary jsonb`; the price columns are nullable and the
  status check allows `'ended'`. `schema.sql` applies all of this idempotently.

### Marketplace: listings and condition checks (`src/listing.ts`)

```ts
Listing = { title: string, asking_price: number /* cents */, category: "marketplace", condition_claims: string[],
            description: string, location?: string, seller_name?: string,
            source: "facebook_marketplace" | "other", url?: string }
Discrepancy = { claim: string /* one of condition_claims */, observed: string, suggested_discount: number /* cents */,
                cue: string /* 3–6 words */ }
ConditionCheck = { id, at, observation: string | null, had_image: boolean, discrepancies: Discrepancy[], event_id }
```

- **`POST /listings/parse`.** We never scrape Facebook. In mock mode the endpoint always returns `content/listings/marketplace_bike.json`, with your `url` copied in when you send one. In real mode the model reads the pasted `text` (Nemotron: `NEMOTRON_MODEL`; Claude: `AGREEMENT_MODEL`) and/or the screenshot (`image_base64`, vision: `NEMOTRON_VISION_MODEL`; a `data:image/...;base64,` prefix is fine). The output is zod-validated, with one retry. A request with **only** a `url`: on Nemotron the server fetches the page itself (`fetchListingPage`: http(s) only, no internal hosts, 8 s timeout, HTML/text only) and passes the title, meta tags, JSON-LD and visible text to `NEMOTRON_MODEL`; facebook.com links are rejected at once without a fetch (login wall). On Claude, the server-side `web_fetch` tool reads it (max 2 fetches). A facebook.com URL forces `source: "facebook_marketplace"`. Real mode never returns the canned listing: if the link can't be read (Facebook, login wall, fetch error, not a listing, no title or price), the response is **422** `{"error": "Couldn't read that link. Paste the listing text or a screenshot instead."}`; a failed text/screenshot parse is 422 `{"error": "Couldn't read that listing. Paste the full listing text or a clearer screenshot."}`.
- **`POST /sessions/:id/condition-check`.** This compares the observation and/or photo with `session.listing.condition_claims`. Mock mode uses keyword rules: tires → "new tires last month", $40, cue "Tires worn: ask $40 off". Scratches, rust, shifting and frame damage are covered too. A photo alone, or an unrecognised observation, gets the canned tires result. "Looks great / matches the listing" gets `[]`. In real mode the model does the comparison (Nemotron: `NEMOTRON_VISION_MODEL` for a photo, `NEMOTRON_MODEL` for a typed observation; Claude: `AGREEMENT_MODEL` with vision), the output is zod-validated, and only claims the listing actually made are kept. If the model fails, the response is 502 `{error}` (no canned result).
- **How it reaches the glasses.** The check inserts a normal `Event` with `kind: "condition_check"` and `speaker: "buyer"`. Its `text` is "Condition check: …", `tactic` is `undisclosed_condition`, `cue` is the first discrepancy's cue, and `cue_detail` is `Listing says "<claim>"` (or "N issues, ask $X off"). `status_color` is yellow, or red when the standing offer is above max, or green when nothing is wrong. The standing offer and terms stay unchanged. The phones already show the latest event's cue, so this cue reaches the glasses and teleprompter over the same path (Realtime on `events`) with no new subscription. The check is also appended to `session.condition_checks`.
- **Dispute pack.** It now has `listing` (or `null`) and `condition_discrepancies: [{claim, observed, suggested_discount, cue, checked_at, event_id}]`. The condition-check events are added to `transcript_excerpts`.
- **Supabase.** New columns: `sessions.listing jsonb`, `sessions.condition_checks jsonb` and `events.kind text`. `schema.sql` adds them idempotently.

### Mismatch rule (`src/mismatch.ts`)
1. The recomputed fingerprint must equal `agreement.fingerprint`. Otherwise the reason is `fingerprint_mismatch`.
2. `sum(line_items) === agreement.total`. Otherwise `amount_mismatch`.
3. Each label must equal an agreement `items[]` string or `fees[].label` (trimmed, case-insensitive). Otherwise `unmatched_line_items`. Following the content convention, `items[0]` must be charged at `price`, other items at 0, and fees at their agreed amount. Otherwise `line_item_amount_mismatch`.
4. When the request is blocked, the AI (or a template) writes one sentence citing the transcript line that set the agreed total, with its time.

### Approving a changed charge
`decision: "approve"` amends the agreement to match the request. The main-item line becomes `price`, other charged lines become fees noted "added at checkout, approved by buyer", and `total` becomes the request sum. It then sets `buyer_confirmed_at = now`, bumps `version`, appends to `amendments[]`, re-fingerprints and marks the request `approved`.

### Fingerprint (`src/fingerprint.ts`)
SHA-256 hex over canonical JSON (keys sorted recursively, arrays in order, no whitespace) of `{session_id, price, items, fees, total, buyer_confirmed_at, seller_confirmed_at}`. Timestamps are normalised to ISO `…Z` first, so the hash survives a Postgres round trip.
