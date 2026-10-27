# DEAL — AI Negotiation Copilot with Agreement-Locked Checkout

**Builder:** Solo developer working with Claude Code subagents
**Status:** Concept locked. Building v1 tonight; glasses + Neural Band integration tomorrow.

> **▶ RESUMING WORK? Start at [Section 12: Build Handoff](#12-build-handoff-for-subagents).**
> It has the current status, setup checklist, folder layout, API spec, environment variables, and copy-paste prompts for each subagent.
> To resume in Claude Code, say: *"Read DEAL_Concept.md, check the Section 12 status and setup checklist, then spawn the subagents for the next phase."*

---

## 1. One-Liner

**DEAL is a copilot for Facebook Marketplace meetups. It coaches you on your glasses while you haggle with a stranger, catches anything that doesn't match the listing, locks the price you both agreed to, and turns the seller's phone into a terminal. Payment is verified on both phones before the item changes hands.**

Strangers haggle face to face every day with no protection. The listing says "like new", the seller says "another guy offered $700", and then it's "cash only, or just Zelle me". The deal ends with a screenshot that may be fake. DEAL replaces that with a coached negotiation, a locked agreement and a verified card payment.

The same core works for any face-to-face purchase: car dealerships, pawn shops, electronics, furniture. The category is a setting; the car is our 10-second "works anywhere" closer.

**Pitch to Visa:**
> "Peer-to-peer meetups are where in-person payments are least protected: fake 'payment sent' screenshots, Zelle scams, prices that change after a handshake. DEAL makes the negotiated agreement the payment rule and verifies the card payment on both phones before anything changes hands. That means safer buyers, sellers who actually get paid, and P2P volume moving onto the Visa network."

---

## 2. The Big Idea

Most shopping AI helps you *find* or *buy* things. DEAL protects the moments that go wrong between strangers: **inspecting, agreeing and paying**.

- **The listing becomes the checklist.** DEAL imports the Marketplace listing (link, pasted text or screenshot) and its condition claims ("new tires last month", "no scratches"). When what you see doesn't match, the glasses tell you what to ask for: **"Tires worn: ask $40 off."**
- **The negotiated agreement becomes the payment rule.** Once buyer and seller both confirm, the seller's phone (the terminal) can only charge that amount. "$20 for gas, I drove here" is **blocked** until the buyer explicitly approves it.
- **The payment is verified, not claimed.** Both phones show the same card payment and receipt before the item changes hands. There is no screenshot to fake, and there's no irreversible Zelle transfer to a stranger.

---

## 3. How It Works

### Step 1: Prepare
- Choose a category (marketplace, car, pawn shop, electronics, other).
- **Marketplace: import the listing** (Facebook Marketplace link, pasted text or screenshot). DEAL extracts the title, asking price and **condition claims**. We never scrape Facebook: a link alone gets the demo listing, while text or a screenshot is read by Claude.
- Enter the item, asking price, target price, and maximum budget.
- DEAL shows comparable market prices. For the demo, these are pre-loaded JSON per category.
- **At the meetup: condition check.** The buyer types what they see or snaps a photo. DEAL compares it to the listing's claims and puts a cue on the glasses ("Tires worn: ask $40 off").

### Step 2: Negotiate (glasses + buyer phone)
- The buyer's phone listens and transcribes the conversation.
- The AI tracks offers, add-ons, fees, and promises, and detects sales tactics.
- The glasses show **short, glanceable cues**: 3–6 words, a green/yellow/red status, and the current offer against the target.

**Tactic detection examples:**

| Seller says / does | Glasses show |
|---|---|
| "What monthly payment are you looking for?" | **Redirect to total price.** `$489/mo × 72 = $35,208` |
| "This price is only good today" | **Pressure tactic. You can walk.** |
| Bundles a trade-in with the new price | **Settle price first, trade-in separately** |
| Long pause after the buyer's offer | **Stay quiet** |
| Offer near a known comparable | **Mention the $340 comparable** |
| Fees not yet discussed | **Ask for the total, all fees included** |
| "Another guy offered $700, he's coming at 5" | **Unverified buyer. Hold your offer.** |
| "Cash only, or just Zelle me" | **Pay verified, not Zelle** |
| Item doesn't match the listing ("new tires" are worn) | **Tires worn: ask $40 off** |
| "$20 for gas, I drove here" after agreeing | **Agreed price stands. Decline.** (and blocked at the terminal) |

### Step 3: Lock the Deal
- Buyer and seller **both tap confirm** (each on their own phone).
- DEAL creates a timestamped **Deal Agreement**: final price, included items, fees, and the transcript lines each term came from.
- The agreement gets a **SHA-256 fingerprint**. If anything changes after confirmation, the fingerprint no longer matches and checkout is blocked.

### Step 4: Verified Checkout (seller's iPhone becomes the terminal)
- The seller's phone switches to a **Tap to Pay terminal**.
- **The amount comes from the agreement. The seller cannot type a different number.**
- If the seller adds anything (a "processing fee," a warranty, a protection package), the charge is **blocked**:
  - The buyer's glasses flash a warning.
  - The buyer's phone shows the extra charge next to the transcript line that contradicts it.
  - The charge only proceeds if the buyer approves the change on their own phone.
- The buyer taps their Visa card or phone, the payment completes, and both phones show the receipt.

**v1 (tonight):** a simulated tap screen running a real Stripe test-mode payment with a Visa test card. All payment logic is real; only the card-reading step is simulated.
**Later:** real Tap to Pay on iPhone via the Stripe Terminal iOS SDK, after Apple approves the entitlement.

### Step 5: Record
- Purchase history: item, seller, asking price, final price, offer timeline, key cues, receipt.
- **One-tap dispute evidence pack**: agreement, fingerprint, confirmations, transcript excerpts, receipt. Useful if a charge is ever disputed.

---

## 4. App Structure

**One SwiftUI app, two modes:**

| Buyer mode | Seller mode |
|---|---|
| Session setup | Joins session (QR code or code) |
| Live transcript, current offer, cue preview | Sees the agreement draft |
| Pushes cues to glasses | Confirms the agreement |
| Confirms agreement | Simulated Tap to Pay terminal (locked amount) |
| Approves or rejects any changed charge | Can attempt to add a line item (triggers block) |
| Purchase history + dispute pack | Receipt |

**Roles:**
- **Glasses:** display only. No input needed during a negotiation.
- **Phones:** every control (start, pause, end, confirm, approve).
- **Backend:** AI, agreement fingerprinting, mismatch checks, payments.

**Hardware notes:**
- Ray-Ban Meta Display glasses: available, charger on hand.
- Meta Neural Band: arriving tomorrow. Not required. The app is designed so the glasses only display; temple touchpad gestures (tap = dismiss, swipe = previous cue) are a bonus if the SDK passes them to the app.

### Screens

#### Start
**Mode picker:** two big buttons, **I'm Buying** and **I'm Selling**, plus a glasses-connected status dot.

#### Buyer mode

**B1. Home**
- **Start Negotiation** button
- Active session, if one is running
- Recent purchases
- Totals: amount spent and extra charges blocked

**B2. New Negotiation**
- Category picker (Car, Pawn Shop, Marketplace, Electronics, Other)
- Item name, asking price, target price, maximum budget
- Style: Polite / Firm / Aggressive
- **Comparable prices** card (3–4 hard-coded listings for the item)
- **Start Session** button → creates a **join code + QR code** for the seller

**B3. Live Session (main screen)**
```text
┌─────────────────────────────┐
│ 2023 Honda Accord    ● LIVE │
│ Asking $38,000 → Target $34,500
│                             │
│  Current offer:  $35,400    │
│  [██████████░░░] near target │
│                             │
│ ┌ ON GLASSES ─────────────┐ │
│ │ 🟡 Redirect to total price│ │
│ │ $489/mo × 72 = $35,208  │ │
│ └─────────────────────────┘ │
│                             │
│ Terms so far                │
│  • Price $35,400            │
│  • Doc fee $499 (?)         │
│  • Floor mats included      │
│                             │
│ Transcript                  │
│  Seller: What monthly...    │
│  You: I'm focused on the... │
│                             │
│ [Pause] [Fix a term] [Lock Deal]
└─────────────────────────────┘
```
- Current offer and progress toward target
- **The exact cue currently on the glasses**
- Terms extracted so far (price, fees, included items); uncertain ones marked "?"
- Scrolling live transcript
- **Pause**, **Fix a term** (correct an AI mistake), **Lock Deal**
- **Scripted mode** toggle (tonight): plays the sample conversation instead of using the mic

**B4. Agreement Review**
- Final price, included items, fees, total
- Each term links to its source transcript line
- Open questions flagged by the AI
- **Confirm** button + seller confirmation status (waiting / confirmed)
- After both confirm: "Agreement locked" badge with short fingerprint (e.g. `a3f9…c21`)

**B5. Charge Alert** (appears when the seller requests a different charge)
- Red banner: **"Charge blocked: $1,200 more than agreed"**
- Agreed total vs. requested total side by side, extra line item highlighted
- Contradicting transcript line with timestamp
- One-sentence AI explanation
- **Reject** (default) or **Approve change**

**B6. Receipt**
- Amount, merchant, time, Stripe test payment ID, agreement fingerprint
- Summary: *"Asked $38,000, paid $34,600, blocked $1,200"*

**B7. Purchase History → Deal Detail**
- List: item, final price, savings from asking price, date
- Deal Detail: offer timeline, key cues, agreement, receipt, **Export Dispute Pack**

#### Seller mode

**S1. Join Session:** scan the buyer's QR code or enter the join code.

**S2. Live View:** item, current offer, terms list. **No cues and no transcript** (coaching is private to the buyer).

**S3. Agreement Review:** same agreement as the buyer sees, with **Confirm**.

**S4. Tap to Pay Terminal**
```text
┌─────────────────────────────┐
│        DEAL Terminal        │
│                             │
│         $34,600.00          │
│   🔒 Locked to agreement    │
│                             │
│      ((( Tap to Pay )))     │
│                             │
│   [+ Add line item]         │
└─────────────────────────────┘
```
- Full-screen amount **from the agreement, not editable**
- **Add line item** → creates a payment request that is **blocked**; buyer sees B5; terminal shows "Waiting for buyer approval"
- When valid: simulated tap → Stripe test payment (Visa test card) → success animation

**S5. Receipt:** same payment confirmation as the buyer.

#### Settings
- Glasses connection + test-cue button (tomorrow)
- Backend URL (ngrok tonight)
- Delete all sessions

#### Screen schedule
- **Tonight:** Mode picker, B2, B3 (scripted mode), B4, B5, B6, S1–S5.
- **Tomorrow:** B1 totals, B7 + Deal Detail, dispute pack, glasses settings, live mic polish.

---

## 5. Visa Track Strategy

| Visa priority | How DEAL delivers it |
|---|---|
| **Generative AI** | Live tactic detection, term extraction from conversation, plain-English mismatch explanations |
| **Secure** | Payment can't exceed what both parties confirmed. Extra charges are blocked, not just flagged. |
| **Seamless** | One flow: negotiate → agree → pay → receipt |
| **Personalized** | Budget, target, and negotiation style shape every cue |
| **Trust for both sides** | Buyers are protected; merchants and the network get fewer disputes |
| **Verified P2P payment (scam prevention)** | Marketplace meetups move from cash, Zelle and "payment sent" screenshots to a card payment that both phones verify before the handoff. A fake screenshot can't fool a terminal, and the payment can't be sent first and then disappear. |

**The P2P story (lead with this).** Peer-to-peer marketplaces are huge and almost entirely unprotected at the moment of payment. Common scams include fake payment screenshots, overpayment and refund tricks, "send a deposit first", and price changes after a handshake. DEAL puts a card network transaction in the middle of a stranger-to-stranger deal. The seller sees verified funds, the buyer pays exactly the agreed amount, and the dispute pack holds the listing, the condition mismatches, the agreement fingerprint and the receipt if anything goes wrong later. That brings P2P volume onto Visa rails, which are safer than cash or push payments.

**Priorities, ranked:**
1. **Agreement-locked payment (essential).** If Visa's sandbox supports spending limits or merchant restrictions on a credential, tie them to the agreement. If not, enforce in the backend before the payment request is sent, and pitch the Visa-native version as the roadmap.
2. **Use Visa's own tools (high value).** Use Visa's developer sandbox if access is available; otherwise Stripe test mode with Visa test cards.
3. **Dispute evidence pack (differentiator).** Shows understanding of Visa's side of the business: disputes cost merchants and the network money. For meetups it also includes the listing and the condition discrepancies ("listing said new tires last month; tires were worn").
4. **Two-sided confirmation (trust).** Makes the agreement credible to merchants and answers "why would a seller use this?"
5. **Personalization (expected).** Covered by budget/target/style.

---

## 6. Tech Stack

| Layer | Choice | Notes |
|---|---|---|
| **iOS app** (Buyer + Seller modes) | **SwiftUI** | Native fits the Meta SDK and future Tap to Pay |
| **Speech to text** | **Apple Speech framework** (tonight) | Free, on-device, no key. Add **Deepgram** streaming later for buyer/seller speaker labels. |
| **Real-time sync + database** | **Supabase** (Postgres + Realtime, Swift SDK) | Keeps both phones in sync with no custom WebSocket server |
| **Backend** | **Node.js + TypeScript** (Fastify) | Holds all API keys. Claude calls, fingerprinting, mismatch checks, Stripe. |
| **AI: live cues** | **Claude Haiku 5.5** (`claude-haiku-5-5`) | Speed matters for live cues |
| **AI: agreement + mismatch** | **Claude Sonnet 5.5** (`claude-sonnet-5-5`) | Accuracy matters for the agreement |
| **Payments** | **Stripe test mode** + simulated tap screen | Swap in Visa sandbox if available. Later: Stripe Terminal iOS SDK for real Tap to Pay. |
| **Glasses** | **Meta wearables SDK for iOS** (tomorrow) | Fallback: phone teleprompter screen |
| **Comparables** | Hard-coded JSON per category | No live research pipeline |
| **Hosting** | Local + **ngrok** tonight; Railway or Render later | |

### Architecture

```text
Buyer iPhone (SwiftUI, Buyer mode)
  ├── mic ──► Apple Speech ──► transcript lines
  ├── live dashboard + confirm/approve buttons
  └── pushes cues ──► Ray-Ban Meta Display glasses
            │
            ▼
Backend (Node/TS)
  ├── transcript ──► Claude Haiku ──► {offer, tactic, cue, status}
  ├── confirm ──► Claude Sonnet ──► Deal Agreement + SHA-256 fingerprint
  ├── payment request check: amount and line items must match agreement
  └── Stripe test payment ──► receipt
            │
       Supabase (stores everything, syncs both phones live)
            │
            ▼
Seller iPhone (SwiftUI, Seller mode)
  ├── confirms agreement
  └── simulated Tap to Pay terminal (amount locked to agreement)
```

### Core Data Model

| Table | Key fields |
|---|---|
| `sessions` | id, category, item, asking_price, target_price, max_budget, style, status, join_code |
| `events` | id, session_id, speaker, text, timestamp, extracted_offer, tactic, cue, status_color |
| `agreements` | id, session_id, price, items[], fees[], source_event_ids[], buyer_confirmed_at, seller_confirmed_at, fingerprint |
| `payment_requests` | id, session_id, agreement_id, amount, line_items[], status (`pending` / `blocked` / `approved` / `paid`), mismatch_explanation |
| `receipts` | id, session_id, stripe_payment_id, amount, status, agreement_fingerprint, created_at |

### AI Output Contracts

> Examples below show dollars for readability. **In the API and database, all money is integer cents** (see 12.5).

**Live cue (Haiku), per transcript line:**
```json
{
  "current_offer": 34900,
  "offer_by": "seller",
  "new_terms": [{ "type": "fee", "label": "doc fee", "amount": 499 }],
  "tactic_detected": "monthly_payment_framing",
  "cue": "Redirect to total price",
  "status": "yellow"
}
```

**Agreement (Sonnet), on confirm:**
```json
{
  "price": 34600,
  "items": ["2023 Honda Accord EX", "floor mats"],
  "fees": [{ "label": "doc fee", "amount": 0, "note": "waived" }],
  "total": 34600,
  "source_event_ids": ["evt_41", "evt_47"],
  "open_questions": []
}
```

**Mismatch check (backend rule + Sonnet explanation):**
- **Rule (deterministic):** `payment_request.amount === agreement.total` and line items match. Also re-hash the agreement and compare to the stored fingerprint.
- **If either fails:** status = `blocked`; Sonnet writes a one-sentence explanation citing the source transcript line.
- Taxes and disclosed mandatory fees should be listed in the agreement so they don't trigger false blocks.

---

## 7. Demo Script (flagship: Facebook Marketplace bike meetup; car is the 10-second closer)

Script: `content/scripts/marketplace_bike.json`. Listing: `content/listings/marketplace_bike.json`. Run it end to end with `backend/scripts/demo-marketplace.sh`.

1. **Hook (10 s).** "You found a bike on Facebook Marketplace. You're meeting a stranger in a parking lot. They want cash or Zelle. What protects you?"
2. **Import the listing (buyer phone).** Paste the Marketplace link or a screenshot → **56cm Aluminum Road Bike, Shimano 105, $650**. Claims shown: *like new, new tires last month, no scratches, shifts perfectly.* Target $520, max $580. Comparables load.
3. **Meetup (judge plays the seller from a short script, improvising freely).** The glasses view is **mirrored to the projector** in a split screen: glasses view, buyer phone dashboard, live transcript.
4. **Condition check.** The buyer photographs the tires (or types "tires are worn"). The glasses show **"Tires worn: ask $40 off"** with *Listing says "new tires last month"*.
5. **Tactic moments.** "Another guy offered me $700 and he's coming at five" → **"Unverified buyer. Hold your offer."** Then "Cash only, or just Zelle me now" → **"Pay verified, not Zelle"**, with *Zelle and cash can't be reversed* on the second line.
6. **Deal.** The buyer uses the tires and the comparables. The price lands at **$520** with the pedals included and "no extra charges". Both phones confirm, and the agreement + fingerprint appear.
7. **The payoff.** The seller's phone becomes the terminal. They say "$20 for gas, I drove here" and add it. **Blocked.** The glasses flash red, and the buyer's phone shows *"This doesn't match what you agreed to at 2:14 PM ('Five-twenty, that's everything. No extra charges.')"*.
8. **Resolution.** The buyer rejects. The seller charges $520 → simulated tap → Stripe test payment → **the receipt appears on both phones before the bike changes hands.** No screenshot to fake.
9. **Close (car, 10 s).** Summary: *"Asked $650, paid $520, blocked $20."* Then cut to the car: *"Works anywhere you negotiate face to face."* The dealer tries a $1,200 protection package: **blocked**, *"Asked $38,000, paid $34,600, blocked $1,200."* (`car_accord` script + `demo.sh`.)

**Fallbacks:** recorded video of the full working flow; scripted conversation mode if live audio fails in a noisy venue; typed observation instead of a photo for the condition check; phone teleprompter if the glasses fail. Clearly label role-play, illustrative pricing and listings, and sandbox payments.

---

## 8. Build Plan

### Tonight (v1)
1. **Supabase tables + Node backend endpoints** (sessions, events, agreements, payment requests, receipts). ~1 hr
2. **Claude extraction** using a **scripted sample conversation** (no live audio yet): structured offers, tactics, cues. ~1–2 hrs
3. **SwiftUI app, both modes:** setup, live dashboard, join via code, agreement + two-sided confirmation. ~1–2 hrs
4. **Simulated terminal:** locked amount, blocked extra fee, buyer re-approval, Stripe test payment, receipt. ~2 hrs
5. **Live mic via Apple Speech**, if time allows.
6. **Request the Apple Tap to Pay entitlement tonight** in case it's approved in time.

### Tomorrow
1. Charge the Neural Band; integrate the Meta wearables SDK and push cues to the display.
2. Mirror the glasses view to a laptop for the projector.
3. Purchase history, summary screen, dispute evidence pack.
4. Ask Visa mentors about their APIs; swap in Visa sandbox if possible.
5. Real Tap to Pay if Apple approves.
6. Record the fallback demo video. Rehearse with someone playing the salesperson.

### Subagent Work Split (solo builder)
Parallel workstreams with clear boundaries:
- **Backend agent:** Node/TS server, Supabase schema, Claude prompts and output validation, fingerprinting, mismatch rule, Stripe.
- **iOS agent:** SwiftUI Buyer/Seller modes, Supabase Realtime, Apple Speech, simulated terminal UI.
- **Glasses agent (tomorrow):** Meta SDK integration, cue display, mirroring for the projector.
- **Content agent:** scripted demo conversations per category, tactic list, comparable price JSON.

Shared contract: the data model and AI output JSON in section 6. Define these first so agents can work independently.

### Cut (not building)
Full replay, insights dashboard, personalized coaching over time, live market research, document scanning, shareable summaries.

---

## 9. Risks and What to Verify First

| Risk | Check | Fallback |
|---|---|---|
| Meta SDK can't write to the display from a third-party app | Test in the first hour tomorrow | Even Realities G1 / Brilliant Labs Frame, or phone teleprompter |
| Display times out or drops during a session | 5+ minute continuous test | Wake display only on new cues |
| Touchpad gestures not passed to the app | Test with and without the band | All controls on phone (already the design) |
| Noisy venue breaks transcription | Test with a clip-on or directional mic | Scripted conversation mode |
| Apple Tap to Pay entitlement not approved in time | Request tonight | Simulated terminal (already the plan) |
| Visa sandbox lacks credential spending controls | Ask Visa mentors | Enforce in backend; pitch Visa-native version as roadmap |
| Glasses battery drain with always-on display | Measure during testing | Wake on new cues only |

---

## 10. Product Boundaries (for judge Q&A, not the pitch)

- The AI supports the buyer; it doesn't guarantee the lowest price.
- A discount from asking price isn't necessarily savings versus market value.
- A blocked charge is a prompt to clarify, not proof of misconduct.
- Seller participation is required for the integrated checkout.
- Payments run through an established, compliant processor; Visa is the card network.
- A payment confirmation doesn't guarantee delivery or item quality.
- Conversations are recorded or transcribed only with consent; users can delete sessions.
- DEAL never charges a card without explicit buyer approval.

---

## 11. Key Lines

- **Positioning:** DEAL turns high-stakes, in-person shopping into a guided, verifiable, securely completed purchase.
- **Hook:** "It coaches you through the negotiation, locks in what you agreed to, and won't let you get charged a dollar more."
- **Visa:** "The negotiated agreement becomes the payment rule."

---

## 12. Build Handoff (for Subagents)

### 12.1 Current Status (update this as work progresses)

| Item | Status |
|---|---|
| Concept, screens, stack, data model | ✅ Done (this doc) |
| macOS update | ✅ Done (macOS 27) |
| Xcode | ✅ Xcode 27.1 installed and selected; iOS 27.0 + 27.1 Simulator runtimes; `xcodegen` installed |
| Node.js | ✅ v24 installed |
| Disk space | ✅ ~769 GB free |
| API keys (Anthropic, Supabase, Stripe) | ❓ Unknown — check `backend/.env` |
| Marketplace flagship (content + backend) | ✅ Mock mode: `marketplace_bike` script (19 lines), canned listing, 4 new tactics, `seller_extra_fee_marketplace.json` ($20 gas fee → blocked). `POST /listings/parse`, `POST /sessions {listing}`, `POST /sessions/:id/condition-check`, dispute pack with listing + discrepancies. 118 tests pass; `scripts/demo-marketplace.sh` and `scripts/demo.sh` both pass end to end. The real Claude listing/vision paths are written but untested (no live key run). Supabase needs the new columns in `schema.sql` |
| Backend code | ✅ Mock mode done: 118 tests pass, `scripts/demo.sh` passes end to end. Real Claude/Supabase/Stripe paths untested (no keys); `schema.sql` not yet run in Supabase. Contract additions listed in `backend/README.md` |
| Content (scripts, comparables, tactics) | ✅ Done (`content/README.md` has conventions, incl. extra `cue_detail` field) |
| iOS app | ✅ Simulator / 🟡 device. `xcodegen` + `xcodebuild` build clean (0 warnings) for iOS Simulator and generic iOS device (unsigned); Supabase SPM 2.55.4 resolves. `DEALUITests` (XCUITest) runs the whole 12.6 flow on an iPhone 18 Pro Simulator vs the mock backend, both sides: buyer (mode picker, B1 Home, B2, B3 scripted, B4 draft and locked, B5 blocked $1,200, reject, B6, then B1 → B7 Purchase History → Deal Detail → Export Dispute Pack) and seller (S1 code entry, S2, S3, S4 terminal, add line item → waiting, buyer rejects, Tap to Pay, S5). Not yet run on a physical iPhone: needs a signing Team. Camera QR, live mic/speech and Supabase Realtime are untested. See `ios/README.md` |
| B1 Home + B7 History / Deal Detail | ✅ B1: Start Negotiation, active-session card (resume), recent purchases, totals (spent, extra charges blocked, saved). B7: list (item, final price, savings, date) → Deal Detail (offer timeline, key cues, agreement, blocked charges, receipt, **Export Dispute Pack** via ShareLink of `GET /sessions/:id/dispute-pack` JSON). Covered by `testBuyerFlow` |
| Glasses integration | 🟡 Built, untested on hardware. `MetaGlassesDisplay` (Meta Wearables DAT 1.0.1, `MWDATDisplay`) draws the cue card (status dot and word, cue, detail, offer and target) on the Ray-Ban Meta Display. `GlassesFanOut` also keeps the phone teleprompter on. **Connect glasses** is on the mode picker and in Settings. It reattaches after a back gesture or disconnect. The debug MockDeviceKit preview connects and renders cues in the Simulator. Not yet run on real glasses: needs Meta AI Developer Mode and a signed device build. Steps are in `ios/README.md` |
| Apple Tap to Pay entitlement | ❌ Not requested yet |

### 12.2 Setup Checklist (do after the macOS update)

1. [x] Install **Xcode** from the Mac App Store. Open it once; accept extra components and the **iOS platform**.
2. [ ] **Xcode → Settings → Accounts**: sign in with Apple ID.
3. [x] Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
4. [ ] Connect the iPhone to Xcode once, then **Settings → Privacy & Security → Developer Mode → On**.
5. [x] Install Homebrew if missing (check with `which brew`), then `brew install xcodegen`. XcodeGen generates the Xcode project from `ios/project.yml`, so agents never hand-edit `.pbxproj` files.
6. [ ] Create a **Supabase** project (free tier). Note the project URL, anon key, and service-role key.
7. [ ] Create a **Stripe** account; get the **test-mode** secret key (`sk_test_...`).
8. [ ] Get an **Anthropic API key**.
9. [ ] Fill in `backend/.env` (template in 12.4). **Never paste keys into chat.**
10. [ ] Request the **Apple Tap to Pay on iPhone entitlement** (needs paid Apple Developer account).
11. [ ] Install **ngrok** (`brew install ngrok`) so the iPhone can reach the local backend.

The backend and content work does **not** need Xcode or API keys: start them first (mock mode).

### 12.3 Folder Layout

```text
DEAL/
├── DEAL_Concept.md   # this doc: source of truth
├── backend/                        # Node.js + TypeScript (Fastify)
│   ├── src/
│   │   ├── server.ts               # Fastify app + routes
│   │   ├── routes/                 # sessions, events, agreements, payments
│   │   ├── ai/                     # Claude prompts + JSON validation (zod)
│   │   ├── mock/                   # mock extractions when MOCK_MODE=true
│   │   ├── payments/               # Stripe test-mode wrapper
│   │   ├── fingerprint.ts          # canonical JSON + SHA-256
│   │   └── mismatch.ts             # deterministic charge check
│   ├── test/                       # vitest tests
│   ├── .env.example
│   └── package.json
├── supabase/
│   └── schema.sql                  # tables from Section 6 + Realtime enabled
├── content/
│   ├── scripts/                    # scripted conversations per category (JSON)
│   ├── comparables/                # comparable prices per category (JSON)
│   └── tactics.json                # tactic id → detection hints → cue template
└── ios/
    ├── project.yml                 # XcodeGen spec
    └── DEAL/                       # SwiftUI sources
        ├── App/                    # entry point, mode picker
        ├── Buyer/                  # B1–B7
        ├── Seller/                 # S1–S5
        ├── Shared/                 # models (match Section 6), API client, Realtime
        ├── Speech/                 # Apple Speech wrapper
        └── Glasses/                # Meta SDK wrapper (tomorrow) + fallback
```

### 12.4 Environment Variables

**`backend/.env`**
```bash
PORT=3000
MOCK_MODE=true                      # true = no Anthropic calls; uses content/ + mock extractions
ANTHROPIC_API_KEY=
CUE_MODEL=claude-haiku-5-5
AGREEMENT_MODEL=claude-sonnet-5-5
SUPABASE_URL=
SUPABASE_SERVICE_ROLE_KEY=          # backend only, never in the iOS app
STRIPE_SECRET_KEY=sk_test_...       # test mode only
```

**iOS config (`ios/DEAL/Shared/Config.swift` or an `.xcconfig`)**
```text
BACKEND_URL      = https://<ngrok-subdomain>.ngrok-free.app
SUPABASE_URL     = <same project URL>
SUPABASE_ANON_KEY= <anon key, read-only use>
```

**Security note (hackathon tradeoff):** the iOS app only reads from Supabase (Realtime subscriptions); all writes go through the backend. Row-level security policies can allow anon reads for demo purposes. No secret keys in the app.

### 12.5 Backend API Spec (the contract between backend and iOS)

All bodies are JSON. Money is in **whole cents as integers** in the API and database (e.g. `3460000` = $34,600.00) to avoid float errors. Types match Section 6.

| Method & path | Body | Returns | Notes |
|---|---|---|---|
| `POST /listings/parse` | `{url?, text?, image_base64?}` (at least one) | `Listing` | Buyer B2 "Import listing". Mock: canned bike listing (keeps `url`). Real: `AGREEMENT_MODEL` reads text / screenshot (vision), zod-validated, retry once. **No scraping**: a bare URL gets the canned listing |
| `POST /sessions` | `{category, item, asking_price, target_price, max_budget, style, listing?}` | `Session` (incl. `join_code`, `listing`, `condition_checks`) | Buyer B2. `listing` stored as `session.listing` |
| `POST /sessions/join` | `{join_code}` | `Session` | Seller S1 |
| `GET /sessions` | — | `Session[]` with final price | B7 history |
| `GET /sessions/:id` | — | `{session, events, agreement, payment_requests, receipt}` | Full state |
| `POST /sessions/:id/events` | `{speaker: "buyer"\|"seller", text}` | `Event` with extraction | Live mic path; calls Haiku (or mock) |
| `POST /sessions/:id/script/play` | `{script_id, interval_ms?}` | `{started: true}` | Mock/scripted mode: inserts script lines as events on a timer |
| `PATCH /sessions/:id/terms` | `{term_id, correction}` | updated terms | B3 "Fix a term" |
| `POST /sessions/:id/agreement` | — | `Agreement` (draft) | Calls Sonnet (or mock) over events |
| `POST /agreements/:id/confirm` | `{role: "buyer"\|"seller"}` | `Agreement` | When both confirmed → compute + store `fingerprint`, lock |
| `POST /sessions/:id/payment-requests` | `{line_items: [{label, amount}]}` | `PaymentRequest` | Seller S4. Status `approved` if it matches, else `blocked` + explanation |
| `POST /payment-requests/:id/decision` | `{decision: "approve"\|"reject"}` | `PaymentRequest` | Buyer B5. Approve = buyer accepts the change (agreement amended, re-fingerprinted, re-confirmed by buyer) |
| `POST /payment-requests/:id/pay` | — | `Receipt` | Only if status `approved`. Creates + confirms a Stripe test PaymentIntent server-side with test payment method `pm_card_visa` |
| `POST /sessions/:id/condition-check` | `{observation?, image_base64?}` (at least one) | `{discrepancies: [{claim, observed, suggested_discount, cue}], event}` (201) | B3 "Check condition". Compares to `session.listing.condition_claims` (409 if no listing). Inserts an `Event` with `kind: "condition_check"` carrying the cue, so it reaches the glasses like any cue; appends to `session.condition_checks`. Mock: worn tires → $40 off → "Tires worn: ask $40 off" |
| `GET /sessions/:id/dispute-pack` | — | JSON (and later PDF) | Includes `listing` and `condition_discrepancies` when present |

**Marketplace types (money in cents):**
- `Listing = {title, asking_price, category: "marketplace", condition_claims: string[], description, location?, seller_name?, source: "facebook_marketplace" | "other", url?}`
- `Discrepancy = {claim, observed, suggested_discount, cue}`. `claim` is one of the listing's `condition_claims`, and `cue` is 3–6 words.
- `Event.kind` is `"speech"` (a transcript line) or `"condition_check"`.
- `Session.condition_checks` is `[{id, at, observation, had_image, discrepancies, event_id}]`.

**Realtime:** iOS subscribes to Supabase changes on `events`, `agreements`, `payment_requests`, `receipts` filtered by `session_id`. That is how the seller phone sees confirmations and the buyer phone sees blocked charges instantly.

**Mismatch rule (`mismatch.ts`, deterministic, unit-tested):**
1. Recompute the fingerprint of the stored agreement; must equal `agreement.fingerprint`.
2. Sum of `line_items` must equal `agreement.total`.
3. Every line item label must map to an agreement item/fee; any extra item → blocked.
4. If blocked, Sonnet (or mock) writes a one-sentence explanation citing the source event's text and timestamp.

**Fingerprint:** SHA-256 over canonical JSON (sorted keys) of `{session_id, price, items, fees, total, buyer_confirmed_at, seller_confirmed_at}`.

### 12.6 Definition of Done (v1 tonight)

- [ ] `npm run dev` in `backend/` starts the server with `MOCK_MODE=true` and no keys.
- [ ] `npm test` passes: fingerprint, mismatch rule (match, extra fee, changed amount, tampered agreement), and mock extraction.
- [ ] A curl/HTTP script (`backend/scripts/demo.sh` or `.http` file) runs the whole demo flow end to end: create session → play car script → draft agreement → both confirm → seller adds $1,200 protection package → **blocked** → buyer rejects → seller submits correct amount → pay → receipt.
- [ ] With real keys and `MOCK_MODE=false`, the same flow works using Claude and Stripe test mode.
- [ ] iOS (once Xcode is installed): mode picker, B2, B3 (scripted mode), B4, B5, B6, S1–S5 working across Simulator + iPhone via ngrok.

### 12.7 Subagent Prompts (copy-paste)

**Run order:**
- **Phase 1 (now, no Xcode needed, parallel):** Content agent + Backend agent.
- **Phase 2 (after Xcode installed):** iOS agent.
- **Phase 3 (tomorrow, after band is charged):** Glasses agent, then polish.

Each agent should read this whole document first and treat Sections 3, 4, 6, and 12 as the contract. If an agent needs to change the contract, it should update this document and say so.

---

**Content agent**
> Read `DEAL_Concept.md` (especially Sections 3, 6, 7, 12). Create everything in `content/`:
> 1. `content/scripts/car_accord.json`: the flagship demo conversation following Section 7 exactly (asking $38,000, target $34,500, monthly-payment tactic, lands at $34,600, both sides agree). 20–30 lines, each `{speaker, text, delay_ms}`. Also include, for each line, the expected extraction in the Section 6 "Live cue" JSON shape so the backend can use it in mock mode.
> 2. `content/scripts/pawn_guitar.json`: a shorter pawn shop purchase (buyer buying a used guitar), same format.
> 3. `content/scripts/seller_extra_fee.json`: the post-agreement line items the seller tries to add (the $1,200 protection package) and the corrected request.
> 4. `content/comparables/*.json`: 3–4 plausible comparable listings per category, clearly labeled illustrative.
> 5. `content/tactics.json`: at least 8 tactics, each `{id, name, detection_hints[], cue_template, status}`, including those in Section 3's table.
> Keep cues to 3–6 words. Mark all pricing as illustrative. Don't touch other folders.

---

**Backend agent**
> Read `DEAL_Concept.md` (especially Sections 6 and 12). Build `backend/` (Node 24, TypeScript, Fastify, zod, vitest) and `supabase/schema.sql` exactly per Sections 12.3–12.6.
> - Implement every endpoint in 12.5. Money in integer cents.
> - `MOCK_MODE=true` must work with **no API keys**: use `content/scripts/*.json` expected extractions instead of Claude, an in-memory store instead of Supabase when `SUPABASE_URL` is empty, and a fake receipt instead of Stripe when `STRIPE_SECRET_KEY` is empty.
> - Real mode: Claude via the official `@anthropic-ai/sdk` (`CUE_MODEL` for live cues, `AGREEMENT_MODEL` for agreement + mismatch explanation), validate all model output with zod and retry once on invalid JSON; Supabase via `@supabase/supabase-js` with the service-role key; Stripe test mode PaymentIntent with `pm_card_visa`.
> - `fingerprint.ts` and `mismatch.ts` are deterministic and fully unit-tested.
> - Write `.env.example` (12.4), a `README.md` with run steps, and the end-to-end demo script from 12.6.
> - If `content/` isn't ready yet, create a minimal placeholder car script and note it in the README.
> Finish by running `npm test` and the demo script in mock mode and reporting the output. Update the status table in 12.1.

---

**iOS agent** (after Xcode is installed)
> Read `DEAL_Concept.md` (Sections 3, 4 "Screens", 6, 12). Build the SwiftUI app in `ios/` using **XcodeGen** (`ios/project.yml`, iOS 17+ target, bundle id `com.lucas.deal`). Use the Supabase Swift SDK for Realtime reads only; all writes go through the backend API in 12.5.
> - Build tonight's screens from the "Screen schedule": mode picker, B2, B3 (with Scripted mode toggle calling `/script/play`), B4, B5, B6, S1–S5. Match the ASCII layouts.
> - Shared models must match Section 6 / 12.5 (money in integer cents, formatted as dollars in the UI).
> - Put backend URL and Supabase anon key in a config file per 12.4; no secret keys in the app.
> - Wrap Apple Speech (`SFSpeechRecognizer`) behind a protocol so live mic can replace scripted mode later.
> - Create a `GlassesDisplay` protocol with a `PhoneTeleprompterDisplay` fallback implementation; the Meta SDK implementation comes tomorrow.
> - Seller terminal: amount is read-only from the agreement; "Add line item" posts a payment request; "Tap to Pay" is simulated (animation) then calls `/pay`.
> Verify it builds with `xcodebuild` for the Simulator and report any errors. Update the status table in 12.1.

---

**Glasses agent** (tomorrow)
> Read `DEAL_Concept.md` (Sections 4, 9, 12). Research the current Meta wearables SDK for iOS and whether a third-party app can write to the Ray-Ban Meta Display. Report findings **before** writing code. If supported, implement `MetaGlassesDisplay` conforming to the existing `GlassesDisplay` protocol: show the cue (3–6 words), status color, and current offer vs target; update only when the cue changes. Add a laptop mirror view (simple web page or macOS window fed by the same events) for the projector. If unsupported, report options from Section 9's fallback column.

### 12.8 Open Questions

- Which API keys does Lucas already have?
- Can we get Visa developer sandbox access, and which Visa APIs are most worth using?
- iPhone iOS version (must be supported by the installed Xcode).
- Second iPhone available for the seller side at demo time, or Simulator only?
- Does the Meta SDK support display output from third-party apps? (Glasses agent finds out tomorrow.)
