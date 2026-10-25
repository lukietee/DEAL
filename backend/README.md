# DEAL backend

Node 24 + TypeScript + Fastify. It holds every API key and runs the AI cues, agreement drafting, SHA-256 fingerprinting, the deterministic mismatch check and Stripe test payments. The contract is Section 12.5 of `../DEAL_Visa_CalHacks_Concept.md`. **All money is integer cents.**

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
| `npm test` | vitest: fingerprint, mismatch rules (match / extra fee / changed amount / tampered), mock extraction, full HTTP flow |
| `npm run build` | `tsc` typecheck (src + tests), then emit `dist/` |
| `npm start` | run the built server (`node dist/server.js`) |
| `bash scripts/demo.sh http://<host>:3000` | run the car demo against another URL (`INTERVAL_MS=…` changes the script speed) |
| `bash scripts/demo-marketplace.sh http://<host>:3100` | run the Marketplace demo: parse listing, session with listing, condition check, bike script, lock $520, **$20 gas fee blocked**, reject, pay $520, dispute pack |

For the phone: `ngrok http 3000`, then put the https URL in the iOS `BACKEND_URL`.

## Modes

Each dependency is chosen on its own:

| Env | Empty / default | Set |
|---|---|---|
| `MOCK_MODE` | `true`: cues come from the content scripts' `expected` (matched on line text); free-typed lines use a regex/keyword fallback built on `content/tactics.json`. The agreement comes from the script's `expected_agreement`, or is assembled from extracted terms. The mismatch explanation is a template. | `false`: Claude (`CUE_MODEL` for cues, `AGREEMENT_MODEL` for the agreement and the mismatch sentence). Output is validated with zod, with one retry on invalid JSON. If Claude still fails on a cue, the agreement or the mismatch sentence, it falls back to the mock for that call, so the conversation never stalls. Listing parse failures return 422 and condition-check failures return 502 instead (nothing canned in real mode). The cue model sees the session's live research (finished agents' summaries, price ranges and top sources), not the illustrative comparables. |
| `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` | in-memory store (lost on restart) | Supabase via the service-role key. Run `../supabase/schema.sql` in the SQL editor first. |
| `STRIPE_SECRET_KEY` | fake receipt (`pi_mock_…`, `mock: true`) | Stripe **test mode only** (`sk_test_…` is required). A PaymentIntent is created and confirmed server-side with `pm_card_visa`. |

`MOCK_MODE=false` without `ANTHROPIC_API_KEY` logs a warning and uses the mock AI. `GET /health` shows what is active.

Content comes from `../content` at runtime (override with `CONTENT_DIR`). No placeholder content was needed. If a file were missing, the loader would also look in `src/mock/content/` (last-resort placeholders), which does not exist today.

## API (12.5 plus additions)

| Method & path | Body | Returns |
|---|---|---|
| `GET /health` *(added)* | | `{ok, mock_mode, ai, store, payments, models, scripts, time}` |
| `POST /sessions` | `{category, item, asking_price, target_price, max_budget, style, listing?}` | `Session` (201). `category` is normalised (`"Pawn Shop"` → `pawn_shop`). The optional `listing` (a `Listing`) is stored as `session.listing`. Every session also has `condition_checks: ConditionCheck[]` |
| `POST /sessions/join` | `{join_code}` (case-insensitive) | `Session` |
| `GET /sessions` | | `Session[]`, each with `final_price, paid_at, blocked_total, savings` |
| `GET /sessions/:id` | | `{session, events, agreement, payment_requests, receipt, script}` |
| `DELETE /sessions` *(added)* | | `{deleted: true}`. Settings → "Delete all sessions" |
| `POST /sessions/:id/events` | `{speaker, text}` | `Event` (201) |
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
| `POST /research/preview` *(added, B2 market check)* | `{item, category?, asking_price?}` (`asking_price` in cents; `category` defaults to `marketplace`) | `{summary: string\|null, price_low: number\|null, price_high: number\|null, sources: [{title, url, price, note, image_url}]}` (cents). Blocking. Real mode runs one "comparable listings" web-search agent plus og:image lookups (~15–25 s); a failed agent returns nulls. Mock mode returns `content/comparables/<category>.json` in this shape after ~1.5 s |
| `GET /comparables/:category` *(added)* | | `content/comparables/<category>.json` |
| `GET /scripts` *(added)* | | `{scripts: ["car_accord", "marketplace_bike", "pawn_guitar"]}` |

`Event` has a new field `kind`: `"speech"` for transcript lines, or `"condition_check"` for the event a condition check inserts. The request body limit is 12 MB, so base64 photos fit. Downscale on the phone first, because Claude takes at most 5 MB per image.

Errors are `{error, details?}` with status 400 (validation), 404, 409 (state conflict), 422 (real mode: listing couldn't be read) or 502 (real mode: condition model failed).

### Marketplace: listings and condition checks (`src/listing.ts`)

```ts
Listing = { title: string, asking_price: number /* cents */, category: "marketplace", condition_claims: string[],
            description: string, location?: string, seller_name?: string,
            source: "facebook_marketplace" | "other", url?: string }
Discrepancy = { claim: string /* one of condition_claims */, observed: string, suggested_discount: number /* cents */,
                cue: string /* 3–6 words */ }
ConditionCheck = { id, at, observation: string | null, had_image: boolean, discrepancies: Discrepancy[], event_id }
```

- **`POST /listings/parse`.** We never scrape Facebook. In mock mode the endpoint always returns `content/listings/marketplace_bike.json`, with your `url` copied in when you send one. In real mode, `AGREEMENT_MODEL` reads the pasted `text` and/or the screenshot (`image_base64`, vision; a `data:image/...;base64,` prefix is fine). The output is zod-validated, with one retry. A request with **only** a `url` is read by Claude with the server-side `web_fetch` tool (max 2 fetches; we never fetch the page ourselves). A facebook.com URL forces `source: "facebook_marketplace"`. Real mode never returns the canned listing: if the link can't be read (Facebook is blocked by web_fetch / login wall, fetch error, no title or price), the response is **422** `{"error": "Couldn't read that link. Paste the listing text or a screenshot instead."}`; a failed text/screenshot parse is 422 `{"error": "Couldn't read that listing. Paste the full listing text or a clearer screenshot."}`.
- **`POST /sessions/:id/condition-check`.** This compares the observation and/or photo with `session.listing.condition_claims`. Mock mode uses keyword rules: tires → "new tires last month", $40, cue "Tires worn: ask $40 off". Scratches, rust, shifting and frame damage are covered too. A photo alone, or an unrecognised observation, gets the canned tires result. "Looks great / matches the listing" gets `[]`. In real mode, Claude (vision) does the comparison, the output is zod-validated, and only claims the listing actually made are kept. If the model fails, the response is 502 `{error}` (no canned result).
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
