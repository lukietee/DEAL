# DEAL backend

Node 24 + TypeScript + Fastify. It holds every API key and runs the AI cues, agreement drafting, SHA-256 fingerprinting, the deterministic mismatch check and Stripe test payments. The contract is Section 12.5 of `../DEAL_Visa_CalHacks_Concept.md`. **All money is integer cents.**

## Run (mock mode, no keys)

```bash
cd backend
npm install
cp .env.example .env        # optional; with no .env, MOCK_MODE defaults to true
npm run dev                 # http://0.0.0.0:3000 (reachable from an iPhone on LAN / ngrok)
npm run demo                # in a second terminal: the full 12.6 flow with curl + jq
```

Other scripts:

| Command | What it does |
|---|---|
| `npm test` | vitest: fingerprint, mismatch rules (match / extra fee / changed amount / tampered), mock extraction, full HTTP flow |
| `npm run build` | `tsc` typecheck (src + tests), then emit `dist/` |
| `npm start` | run the built server (`node dist/server.js`) |
| `bash scripts/demo.sh http://<host>:3000` | run the demo against another URL (`INTERVAL_MS=…` changes the script speed) |

For the phone: `ngrok http 3000`, then put the https URL in the iOS `BACKEND_URL`.

## Modes

Each dependency is chosen on its own:

| Env | Empty / default | Set |
|---|---|---|
| `MOCK_MODE` | `true`: cues come from the content scripts' `expected` (matched on line text); free-typed lines use a regex/keyword fallback built on `content/tactics.json`. The agreement comes from the script's `expected_agreement`, or is assembled from extracted terms. The mismatch explanation is a template. | `false`: Claude (`CUE_MODEL` for cues, `AGREEMENT_MODEL` for the agreement and the mismatch sentence). Output is validated with zod, with one retry on invalid JSON. If Claude still fails, it falls back to the mock for that call, so the demo never stalls. |
| `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` | in-memory store (lost on restart) | Supabase via the service-role key. Run `../supabase/schema.sql` in the SQL editor first. |
| `STRIPE_SECRET_KEY` | fake receipt (`pi_mock_…`, `mock: true`) | Stripe **test mode only** (`sk_test_…` is required). A PaymentIntent is created and confirmed server-side with `pm_card_visa`. |

`MOCK_MODE=false` without `ANTHROPIC_API_KEY` logs a warning and uses the mock AI. `GET /health` shows what is active.

Content comes from `../content` at runtime (override with `CONTENT_DIR`). No placeholder content was needed. If a file were missing, the loader would also look in `src/mock/content/` (last-resort placeholders), which does not exist today.

## API (12.5 plus additions)

| Method & path | Body | Returns |
|---|---|---|
| `GET /health` *(added)* | | `{ok, mock_mode, ai, store, payments, models, scripts, time}` |
| `POST /sessions` | `{category, item, asking_price, target_price, max_budget, style}` | `Session` (201). `category` is normalised (`"Pawn Shop"` → `pawn_shop`) |
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
| `GET /comparables/:category` *(added)* | | `content/comparables/<category>.json` |
| `GET /scripts` *(added)* | | `{scripts: ["car_accord", "pawn_guitar"]}` |

Errors are `{error, details?}` with status 400 (validation), 404 or 409 (state conflict).

### Mismatch rule (`src/mismatch.ts`)
1. The recomputed fingerprint must equal `agreement.fingerprint`. Otherwise the reason is `fingerprint_mismatch`.
2. `sum(line_items) === agreement.total`. Otherwise `amount_mismatch`.
3. Each label must equal an agreement `items[]` string or `fees[].label` (trimmed, case-insensitive). Otherwise `unmatched_line_items`. Following the content convention, `items[0]` must be charged at `price`, other items at 0, and fees at their agreed amount. Otherwise `line_item_amount_mismatch`.
4. When the request is blocked, the AI (or a template) writes one sentence citing the transcript line that set the agreed total, with its time.

### Approving a changed charge
`decision: "approve"` amends the agreement to match the request. The main-item line becomes `price`, other charged lines become fees noted "added at checkout, approved by buyer", and `total` becomes the request sum. It then sets `buyer_confirmed_at = now`, bumps `version`, appends to `amendments[]`, re-fingerprints and marks the request `approved`.

### Fingerprint (`src/fingerprint.ts`)
SHA-256 hex over canonical JSON (keys sorted recursively, arrays in order, no whitespace) of `{session_id, price, items, fees, total, buyer_confirmed_at, seller_confirmed_at}`. Timestamps are normalised to ISO `…Z` first, so the hash survives a Postgres round trip.
