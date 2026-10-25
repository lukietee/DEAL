# DEAL iOS app

One SwiftUI app with two modes (Buyer and Seller), iOS 17.2+, bundle id `com.lucas.deal`. The
Xcode project is generated from `project.yml` by XcodeGen. Don't hand-edit `DEAL.xcodeproj`.

## Run it

1. Install Xcode and the iOS platform, then point `xcode-select` at it (this Mac: `/Applications/Xcode-27.1.0.app`, already selected).
2. `brew install xcodegen`
3. `cd ios && xcodegen` (this generates `DEAL.xcodeproj` and `DEAL/Info.plist`).
4. `open DEAL.xcodeproj`. Xcode resolves the Supabase and Meta Wearables (`meta-wearables-dat-ios` 1.0.1) Swift packages on first open.
5. Select the **DEAL** target, open **Signing & Capabilities**, and choose your **Team**. If the bundle id is taken, change it to something unique.
6. Start the backend: `cd backend && npm run dev`. It runs in mock mode, and no keys are needed.
7. Run on the **Simulator**. The default backend URL is `http://localhost:3000`.
   - **On an iPhone:** open the gear icon on the mode picker and set the Backend URL to your ngrok https URL or to `http://<Mac LAN IP>:3000`. Then tap **Test connection**.
8. CLI build check: `xcodebuild -project DEAL.xcodeproj -scheme DEAL -destination 'generic/platform=iOS Simulator' build`

### Two-phone demo (or Simulator + iPhone)
- **Buyer:** I'm Buying → B1 Home → **Start Negotiation** → B2 (Use demo values, Start Session). A join code and QR appear.
- **Seller:** I'm Selling → S1, then scan the QR or type the code → S2.
- **Buyer:** B3, then **Play script**. The `car_accord` script plays through the backend, and the cues, offers and terms update live.
- **Buyer:** **Lock Deal** → B4 → **Confirm**. **Seller:** S3 → **Confirm**. The agreement locks and the seller's phone becomes the S4 terminal.
- **Seller:** **+ Add line item** (protection package, $1,200). The request is **blocked**, the terminal shows "Waiting for buyer approval", and the buyer gets B5.
- **Buyer:** **Reject**. **Seller:** **Tap to Pay** (simulated animation, then `POST /payment-requests/:id/pay`). Both phones show the receipt (B6 / S5).
- **Buyer:** **Done** → B1 (totals now include the deal) → **Purchase History** → the deal → Deal Detail → **Export Dispute Pack**.

## Layout

```
ios/
├── project.yml                 XcodeGen spec (Info.plist keys, Supabase SPM, ATS local networking)
├── DEAL/
│   ├── App/                    DEALApp (entry + RootView), AppModel, ModePickerView, SettingsView
│   ├── Buyer/                  BuyerFlowView (router), BuyerHomeView (B1), NewNegotiationView (B2), LiveSessionView (B3 + Fix a term),
│   │                           AgreementReviewView (B4, reused for S3), ChargeAlertView (B5), ReceiptView (B6, reused for S5),
│   │                           PurchaseHistoryView (B7 list + DealDetailView + dispute pack export)
│   ├── Seller/                 SellerFlowView (router + S2 SellerLiveView), JoinSessionView (S1), QRScannerView, TerminalView (S4)
│   ├── Shared/                 Models (Section 6 / backend/src/types.ts), Money (cents ↔ $), APIClient (12.5),
│   │                           SessionLogic (pure derived state: phases, terminal state, cues, line items),
│   │                           HistoryLogic (B1/B7: purchases, totals, offer timeline, key cues),
│   │                           SessionStore, SessionSync (protocol + polling), SupabaseRealtimeSessionSync,
│   │                           Config, AppSettings, Components, PlatformCompat
│   ├── Speech/                 SpeechTranscriber protocol + AppleSpeechTranscriber (SFSpeechRecognizer)
│   └── Glasses/                GlassesDisplay protocol, PhoneTeleprompterDisplay, GlassesFanOut, TeleprompterView,
│                               MetaGlassesDisplay (Meta Wearables SDK, no SwiftUI import), MetaGlassesUI (SwiftUI bits)
└── DEALUITests/               XCUITest smoke tests for the buyer and seller flows (needs the backend running)
```

## How it works

- **All writes go through the backend** (`APIClient`, Section 12.5). The app holds no secret keys.
- **Sync:** `SessionSync` keeps `GET /sessions/:id` state fresh on both phones.
  - **Default:** `PollingSessionSync`, every 1 s. It works with the backend's in-memory mock mode, which has no Supabase.
  - **Realtime:** if you fill in the Supabase URL and **anon** key in Settings, `SupabaseRealtimeSessionSync` subscribes to changes on `events`, `agreements`, `payment_requests`, `receipts` and `sessions`, filtered by session. Each change triggers a refetch of `GET /sessions/:id`, so there is one decode path. A 5 s safety poll also runs.
- **Money:** integer cents everywhere. `Money.format` is the only cents-to-dollars conversion, and `Money.parseDollars` parses typed input.
- **Seller terminal:** the amount is always `agreement.total` and can't be edited. **Tap to Pay** posts line items that mirror the agreement: `items[0]` carries the price, the other items are $0, then the fees. The backend approves the request and the app pays it. **Add line item** posts the same lines plus the extra one, the backend blocks it, and the terminal waits. If the buyer approved an amendment, Tap to Pay charges the already-approved request.
- **Glasses:** `AppModel.glasses` is a `GlassesFanOut`: every cue goes to the `PhoneTeleprompterDisplay` (always on, fallback + projector mirror) **and** to `MetaGlassesDisplay` (Ray-Ban Meta Display, when connected). B3's "ON GLASSES" card mirrors the teleprompter's `currentCue`. A blocked charge overrides the coaching cue with a red alert. See "Meta Ray-Ban Display glasses" below.
- **Buyer home and history:** B1 is the root of buyer mode. B2 and B7 push on top of it. While a session runs it takes over the screen; **Home** (top left) steps back to B1 without ending it, and the **Active session** card resumes it. If this phone has no session, the card offers the newest unpaid backend session from the last 6 hours, so a relaunch can re-attach. Totals and history come from `GET /sessions` (`final_price`, `savings`, `blocked_total`, `paid_at`); a purchase is a session with status `paid`. Deal Detail loads `GET /sessions/:id` and `GET /sessions/:id/dispute-pack`. The pack is pretty-printed into a temp `DEAL-dispute-pack-<id>.json` and shared with `ShareLink`. B6 **Done** returns the buyer to B1, and S5 **Done** still goes to the mode picker.
- **Live mic:** turn off Scripted mode in B3, choose who is speaking, and tap the mic. Each phrase (split at pauses) is posted to `POST /sessions/:id/events`. You can also type lines.

## Meta Ray-Ban Display glasses

DEAL draws its cue card on the glasses with Meta's Wearables Device Access Toolkit (`MWDATCore` +
`MWDATDisplay` 1.0.1, plus `MWDATMockDevice` for the debug preview). Each cue is one card: a colored
status dot and status word (GOOD / CAREFUL / WARNING / ALERT), the 3–6 word cue, the optional detail
line, and "Offer $X  Target $Y". The display only has white and grey text, so the status color is a
small bright dot image. DEAL sends only when the cue changes, at most about 3 times a second. Every send
replaces the whole screen.

### One-time setup (Lucas, on the phone and glasses)
1. **Meta AI app** v292 or newer, signed in, with the **Ray-Ban Meta Display** paired and connected. Glasses firmware **v128 or newer**. Update both from Meta AI if needed.
2. **Turn on Developer Mode:** Meta AI → **Settings → App Info**, tap the **version number 5 times**, then turn on the Developer Mode toggle that appears. With Developer Mode on, no app ID or token is needed.
3. Build DEAL to the iPhone with your **Team** set (Signing & Capabilities, or `DEVELOPMENT_TEAM` in `project.yml`). Only real hardware works for this. The Simulator can't reach the glasses.
4. In DEAL, tap **Connect glasses** under the mode picker, or go to Settings → Glasses → **Connect glasses**. Meta AI opens and asks you to allow DEAL. Approve it, and Meta AI sends you back to DEAL through `deal://`. Allow the Bluetooth and Local Network prompts.
5. The status changes to **Glasses connected**, and the glasses show a "Glasses connected" card. Settings → **Send test cue** sends a sample cue to the glasses and the teleprompter.
6. After the first connect, DEAL reconnects by itself at launch. **Disconnect glasses** turns this off.

**Without Developer Mode** (not needed for the hackathon): register the app in the Wearables Developer
Center and set `META_APP_ID` and `CLIENT_TOKEN` in the DEAL target's build settings, along with `DEVELOPMENT_TEAM`.
Do that locally or in Xcode and don't commit real values. The `project.yml` defaults are empty.

### Behaviour
- **Phone always on:** the teleprompter gets every cue, whatever state the glasses are in.
- **Back gesture or dropped link:** when the display stops, DEAL reattaches with backoff (1, 2, 3, 4, 4 s). After 5 failures in a row it shows **Failed**, and you tap Connect again. If the glasses are idle, a new cue also brings DEAL back.
- **Idle sleep:** the display sleeps after about 25 s without changes. The next cue is a new send.
- **Info.plist** (generated from `project.yml`):
  - the `deal` URL scheme
  - the `MWDAT` dict (AppLinkURLScheme `deal://`, MetaAppID / ClientToken / TeamID from build settings)
  - background modes: `processing`, `bluetooth-central`, `bluetooth-peripheral`, `external-accessory`
  - the `com.meta.ar.wearable` accessory protocol
  - Bluetooth and Local Network usage strings
  - Bonjour `_bonjour._tcp`
  - `DEAL.entitlements` has the keychain access group that the SDK uses for its registration token.
- The SDK is configured lazily, the first time you connect, so a fresh install or a UI test run never sees the Bluetooth prompts.

### Mock glasses in the Simulator (debug builds)
- Settings → Glasses → **Mock glasses (phone preview)**, or launch with the `-DEALMockGlasses` argument (Xcode scheme → Run → Arguments).
- DEAL pairs a simulated Meta Ray-Ban Display through MockDeviceKit and runs the **real** Display session against it.
- A 240×240 floating preview, bottom-right, shows exactly what the glasses would display. Play a script in B3 to watch cues change.
- Verified in the iPhone 18 Pro Simulator: it connects, and the standby card and a cue card both render.

## UI smoke tests

`DEALUITests` drives one phone through the real UI and plays the other phone over the HTTP API. Start the
backend first (`cd backend && npm run dev`), then:

```
xcodebuild test -project DEAL.xcodeproj -scheme DEAL -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

- `testBuyerFlow`: mode picker → B1 → Start Negotiation → B2 (demo values) → join QR → B3 with Play script → Lock Deal → B4 Confirm → (API: seller confirms, adds the $1,200 protection package) → B5 → Reject → (API: agreed charge + pay) → B6 → Done → B1 → Purchase History (B7) → the new deal's Deal Detail → Export Dispute Pack (share sheet).
- `testSellerFlow`: (API: create session) → S1 type code → (API: play script with 250 ms spacing, draft, buyer confirms) → S2 → S3 Confirm → S4 → Add line item → "Waiting for buyer approval" with $35,800.00 → (API: buyer rejects) → Tap to Pay → S5.
- Every step attaches a screenshot to the `.xcresult`. Export them with `xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path <dir>`.
- With Xcode 27.1, `xcodebuild test` sometimes keeps running after it prints `Test Suite 'All tests' passed`. When that happens, the results are already final and you can stop it.

## Verification status

### With Xcode 27.1 (iOS 27.1 SDK)

| Check | Result |
|---|---|
| `xcodegen` generates the project and `Info.plist` | ✅ |
| Supabase SPM package resolves (`supabase-swift` 2.55.4) | ✅ |
| `xcodebuild build` for the iOS Simulator | ✅ 0 errors, 0 warnings (after removing a no-op `@preconcurrency` in `QRScannerView`) |
| `xcodebuild build` for a generic iOS device, `CODE_SIGNING_ALLOWED=NO` | ✅ |
| `DEALUITests` on the iPhone 18 Pro Simulator (iOS 27.1) against the mock backend | ✅ both pass (buyer about 2 min, which is real script pacing; seller about 35 s) |
| `DEALUITests` with B1 Home and B7 History / Deal Detail / dispute pack share, iPhone 17e Simulator | ✅ both pass (buyer 162 s, seller 34 s) |

| Meta glasses: `MWDAT` 1.0.1 resolves, app builds; MockDeviceKit display session connects in the Simulator and renders the standby and cue cards | ✅ (screenshots checked by hand; not an automated test, because the live preview keeps XCUITest from ever seeing the app idle) |

**Still not verified:**
- Real Ray-Ban Meta Display hardware: registration through Meta AI, the `deal://` callback, Bluetooth/Wi-Fi link, back-gesture reattach, ~25 s sleep, battery over a 5+ minute session.
- Signing and running on a physical iPhone. It needs a Team (`DEVELOPMENT_TEAM` in `project.yml`, or Signing & Capabilities in Xcode).
- Camera QR scanning, the mic/speech permission flow and SFSpeechRecognizer behavior. The Simulator has no camera, and the tests use typed join codes and scripted mode.
- Haptics and idle-timer behavior
- Realtime against a real Supabase project. The tests use the default 1 s polling.

### Before Xcode was installed

Xcode isn't installed (Command Line Tools only, Swift 6.3, macOS SDK only), so there was no iOS SDK, Simulator or `xcodebuild`. Checks run so far:

| Check | Result |
|---|---|
| **Every** app source, `swiftc -typecheck`, macOS 14 target, Swift 5 and Swift 6 language modes | ✅ clean |
| **Every** app source, `swiftc -typecheck`, **Mac Catalyst** target (`arm64-apple-ios17.0-macabi`, iOS UIKit/SwiftUI from the macOS SDK's iOSSupport). This exercises the `#if os(iOS)` branches (QR scanner, AVAudioSession, fullScreenCover, keyboard types) | ✅ clean (Swift 5 and 6) |
| `SupabaseRealtimeSessionSync.swift` compiled against the real `supabase-swift` 2.55.4 via SwiftPM (macOS) | ✅ builds, runs, no warnings |
| JSON decoding + pure logic: 95 assertions against **real backend responses** captured in mock mode (session, join, list, comparables, events, script run, agreement draft/locked, blocked/rejected/approved/amended payment requests, receipt, 409 errors) plus tolerance cases | ✅ all pass |
| Live smoke test: `APIClient` drove the whole 12.6 demo flow against a running mock backend (create → join → comparables → play script → 409 on replay → event → fix term → draft → confirm ×2 → blocked → reject → agreed charge → pay → receipt summary) | ✅ all pass (108 total assertions) |
| `project.yml` YAML parses | ✅ |

Catalyst typechecking turned out to be a good proxy. The first real iOS build had no errors.
