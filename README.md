# DEAL

**An AI negotiation copilot that coaches you live through Ray-Ban Meta Display glasses, and makes sure you pay exactly what you agreed.**

Buying something used from a stranger is stressful. You don't know what it's worth, sellers stretch the truth about condition, surprise fees show up at the end ("plus $20 for gas"), and in-person meetups have a whole scam genre built on fake "payment sent" screenshots. DEAL listens to the conversation, researches the item in seconds, puts a short cue in your glasses after every line, and locks checkout to the price you both agreed on.

Built with **NVIDIA Nemotron on Nebius Token Factory** and **Tavily**.

## What it does

- **Just start talking.** Tap *Start listening*. DEAL transcribes on-device, works out who said each line, and detects the product, the asking price and the seller's condition claims.
- **Live market research.** Once the product is known, three research agents (comparable listings, known issues, fair price) search the web with Tavily in parallel and come back with a fair price range, sources and photos in a few seconds.
- **A coach in your glasses.** After every line, a 3–6 word cue appears on the Ray-Ban Meta Display ("Hold the tire point", "Above fair range. Counter lower."), with a status dot and offer vs. target. While the agents work, the glasses show a research strip that fills in as each one finishes. The phone shows three ready-to-say phrases backed by the research.
- **Look mode.** Look at a product (say, a Weeknd *Starboy* vinyl) and DEAL highlights it in green with its market price above it. It only highlights what you dwell on, so it isn't noisy. Neural Band gestures: pinch for details, swipe through pages, back to dismiss, hold the capture button to start a negotiation.
- **Condition check.** Snap a photo; DEAL compares it with the listing's claims and flags mismatches ("Listing: new tires · Seen: worn → ask $40 off").
- **Agreement-locked checkout.** Both sides confirm the deal on their phones; it's sealed with a SHA-256 fingerprint. The seller's phone becomes a payment terminal that can only charge that exact amount. Any extra line item, like a surprise gas fee, is blocked until the buyer approves it, and both phones show *Payment verified* before the item changes hands.
- **Every deal, remembered.** History keeps each conversation with a summary, offer timeline, savings, blocked charges and a one-tap dispute pack.

## How it uses NVIDIA Nemotron, Nebius Token Factory and Tavily

Every AI call in real mode goes to an NVIDIA Nemotron model through Nebius Token Factory's OpenAI-compatible API ([`backend/src/nebius.ts`](backend/src/nebius.ts)). Each call uses the model that fits its latency and accuracy needs. Thinking is switched off (`chat_template_kwargs.enable_thinking=false`) everywhere except the agreement, which is what makes even Ultra fast enough to coach a live conversation.

| Feature | Model | Measured latency |
|---|---|---|
| Live cue + who said it (every line) | `nvidia/Nemotron-3-Ultra-550b-a55b`, thinking off | ~1.0 s median |
| Product / price / claims detection, end-of-chat summary | `nvidia/Nemotron-3_5-Lightning` | 0.5–0.8 s |
| Suggested phrases, Look price synthesis | `nvidia/Nemotron-3_5-Lightning` | ~0.7 s |
| Research agent synthesis (summary, price range, glasses headline) | `nvidia/nemotron-3-super-120b-a12b` | 3–4 s per agent |
| Agreement draft (gets locked and paid) | `nvidia/Nemotron-3-Ultra-550b-a55b`, **thinking on** | ~5.5 s |
| Listing screenshots, condition photos, Look identify | `nvidia/Nemotron-3.5-Super-VL` | 1.5–8 s |

**Tavily** powers all web research ([`backend/src/tavily.ts`](backend/src/tavily.ts)): each of the three research agents runs 2–3 targeted searches in parallel (advanced depth where prices matter), Nemotron Super reads the top results and writes the summary, price range and a ≤24-character headline for the glasses. Look mode's price check is one Tavily search plus a Lightning synthesis, cached per item. A full research run takes about 3.5–11 s, down from 15–25 s with the previous web-search setup.

Details, model choices and the measurements behind them: [`backend/README.md`](backend/README.md).

## Architecture

```
 Ray-Ban Meta Display ◄── cues, research strip, Look card ──┐
 (camera, Neural Band) ── frames, gestures ───────────────► │
                                                    iPhone app (SwiftUI)
                                                    Buyer / Seller modes,
                                                    on-device speech, Vision
                                                            │  HTTPS
                                                            ▼
                                                 Backend (Node + Fastify)
                                     ┌──────────────┬───────┴────────┬──────────────┐
                                     ▼              ▼                ▼              ▼
                              Nebius Token     Tavily search    Stripe (test)   Supabase
                              Factory:                                          (optional)
                              NVIDIA Nemotron
```

- **iOS app** (`ios/`): SwiftUI, buyer and seller modes in one app. Apple Speech for on-device transcription, Apple Vision for Look mode's dwell detection and tracking, and the Meta Wearables Device Access Toolkit for the glasses display, camera and Neural Band input.
- **Backend** (`backend/`): Node 24, TypeScript, Fastify, zod. Holds every API key; runs the AI, the agreement fingerprinting, deterministic charge-mismatch rules and payments. Every model output is validated with zod and retried once if invalid.
- **Payments**: Stripe test mode; the simulated tap creates a real PaymentIntent for the exact locked amount.

## Run it

### Backend

Requires Node 24.

```bash
cd backend
npm install
cp .env.example .env
npm run dev          # http://localhost:3000
```

With no keys, it runs in **mock mode**: deterministic demo content, no network calls. For the real thing, set these in `backend/.env`:

```
MOCK_MODE=false
NEBIUS_API_KEY=...        # https://tokenfactory.nebius.com/project/api-keys
TAVILY_API_KEY=tvly-...   # https://app.tavily.com
STRIPE_SECRET_KEY=sk_test_...   # optional; without it payments are simulated
```

`GET /health` shows which provider and models are active. `npm test` runs the backend suite (205 tests).

### iOS app

Requires a Mac with Xcode (iOS 17.2+ target) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd ios && xcodegen
open DEAL.xcodeproj
```

1. Choose your signing team on the **DEAL** target.
2. Run on the Simulator (it uses `http://localhost:3000`), or on an iPhone with the backend URL set in Settings (the gear on the first screen) to your Mac's LAN address or an ngrok URL.
3. No glasses? Settings → Glasses → **Mock glasses (phone preview)** shows exactly what the glasses would display. Look mode falls back to the iPhone camera.

Real glasses need a Ray-Ban Meta Display with Developer Mode on and the Meta AI app (see [`ios/README.md`](ios/README.md)).

### Try the flagship demo

A Facebook Marketplace road bike meetup, $650 asking: research finds comparable listings, the coach pushes on worn tires, you settle at $520, the seller tries to add a $20 "gas fee", DEAL blocks it, and both phones show *Payment verified*.

```bash
cd backend && npm run demo:marketplace   # mock mode, drives the whole flow over the API
```

In the app: **I'm Buying → Start Negotiation → Use demo values → Start Session → Play script** (enable *Demo shortcuts* in Settings).

## Repository layout

```
backend/    Node + TypeScript API: AI (Nemotron / Claude fallback), research, Look, agreements, payments
ios/        SwiftUI app (XcodeGen project), glasses integration, UI tests
content/    Demo scripts, listings, comparables and negotiation tactics
supabase/   Optional Postgres schema
devpost/    Submission write-up and screenshots
DEAL_Concept.md   Product spec and data model
```

## License

[MIT](LICENSE)
