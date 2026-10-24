# DEAL iOS app

One SwiftUI app with two modes (Buyer and Seller), iOS 17+, bundle id `com.lucas.deal`. The
Xcode project is generated from `project.yml` by XcodeGen. Don't hand-edit `DEAL.xcodeproj`.

## Run it (once Xcode is installed)

1. Install Xcode and the iOS platform, then run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
2. `brew install xcodegen`
3. `cd ios && xcodegen` (this generates `DEAL.xcodeproj` and `DEAL/Info.plist`).
4. `open DEAL.xcodeproj`. Xcode resolves the Supabase Swift package on first open.
5. Select the **DEAL** target, open **Signing & Capabilities**, and choose your **Team**. If the bundle id is taken, change it to something unique.
6. Start the backend: `cd backend && npm run dev`. It runs in mock mode, and no keys are needed.
7. Run on the **Simulator**. The default backend URL is `http://localhost:3000`.
   - **On an iPhone:** open the gear icon on the mode picker and set the Backend URL to your ngrok https URL or to `http://<Mac LAN IP>:3000`. Then tap **Test connection**.
8. CLI build check: `xcodebuild -project DEAL.xcodeproj -scheme DEAL -destination 'generic/platform=iOS Simulator' build`

### Two-phone demo (or Simulator + iPhone)
- **Buyer:** I'm Buying → B2 (Use demo values, Start Session). A join code and QR appear.
- **Seller:** I'm Selling → S1, then scan the QR or type the code → S2.
- **Buyer:** B3, then **Play script**. The `car_accord` script plays through the backend, and the cues, offers and terms update live.
- **Buyer:** **Lock Deal** → B4 → **Confirm**. **Seller:** S3 → **Confirm**. The agreement locks and the seller's phone becomes the S4 terminal.
- **Seller:** **+ Add line item** (protection package, $1,200). The request is **blocked**, the terminal shows "Waiting for buyer approval", and the buyer gets B5.
- **Buyer:** **Reject**. **Seller:** **Tap to Pay** (simulated animation, then `POST /payment-requests/:id/pay`). Both phones show the receipt (B6 / S5).

## Layout

```
ios/
├── project.yml                 XcodeGen spec (Info.plist keys, Supabase SPM, ATS local networking)
└── DEAL/
    ├── App/                    DEALApp (entry + RootView), AppModel, ModePickerView, SettingsView
    ├── Buyer/                  BuyerFlowView (router), NewNegotiationView (B2), LiveSessionView (B3 + Fix a term),
    │                           AgreementReviewView (B4, reused for S3), ChargeAlertView (B5), ReceiptView (B6, reused for S5)
    ├── Seller/                 SellerFlowView (router + S2 SellerLiveView), JoinSessionView (S1), QRScannerView, TerminalView (S4)
    ├── Shared/                 Models (Section 6 / backend/src/types.ts), Money (cents ↔ $), APIClient (12.5),
    │                           SessionLogic (pure derived state: phases, terminal state, cues, line items),
    │                           SessionStore, SessionSync (protocol + polling), SupabaseRealtimeSessionSync,
    │                           Config, AppSettings, Components, PlatformCompat
    ├── Speech/                 SpeechTranscriber protocol + AppleSpeechTranscriber (SFSpeechRecognizer)
    └── Glasses/                GlassesDisplay protocol + PhoneTeleprompterDisplay + TeleprompterView
```

## How it works

- **All writes go through the backend** (`APIClient`, Section 12.5). The app holds no secret keys.
- **Sync:** `SessionSync` keeps `GET /sessions/:id` state fresh on both phones.
  - **Default:** `PollingSessionSync`, every 1 s. It works with the backend's in-memory mock mode, which has no Supabase.
  - **Realtime:** if you fill in the Supabase URL and **anon** key in Settings, `SupabaseRealtimeSessionSync` subscribes to changes on `events`, `agreements`, `payment_requests`, `receipts` and `sessions`, filtered by session. Each change triggers a refetch of `GET /sessions/:id`, so there is one decode path. A 5 s safety poll also runs.
- **Money:** integer cents everywhere. `Money.format` is the only cents-to-dollars conversion, and `Money.parseDollars` parses typed input.
- **Seller terminal:** the amount is always `agreement.total` and can't be edited. **Tap to Pay** posts line items that mirror the agreement: `items[0]` carries the price, the other items are $0, then the fees. The backend approves the request and the app pays it. **Add line item** posts the same lines plus the extra one, the backend blocks it, and the terminal waits. If the buyer approved an amendment, Tap to Pay charges the already-approved request.
- **Glasses:** `AppModel.glasses` is the `PhoneTeleprompterDisplay` today. Tomorrow, `MetaGlassesDisplay` conforms to `GlassesDisplay` and gets swapped in. B3's "ON GLASSES" card mirrors `currentCue`. A blocked charge overrides the coaching cue with a red alert.
- **Live mic:** turn off Scripted mode in B3, choose who is speaking, and tap the mic. Each phrase (split at pauses) is posted to `POST /sessions/:id/events`. You can also type lines.

## Verification status (before Xcode was installed)

Xcode isn't installed (Command Line Tools only, Swift 6.3, macOS SDK only), so there was no iOS SDK, Simulator or `xcodebuild`. Checks run so far:

| Check | Result |
|---|---|
| **Every** app source, `swiftc -typecheck`, macOS 14 target, Swift 5 and Swift 6 language modes | ✅ clean |
| **Every** app source, `swiftc -typecheck`, **Mac Catalyst** target (`arm64-apple-ios17.0-macabi`, iOS UIKit/SwiftUI from the macOS SDK's iOSSupport). This exercises the `#if os(iOS)` branches (QR scanner, AVAudioSession, fullScreenCover, keyboard types) | ✅ clean (Swift 5 and 6) |
| `SupabaseRealtimeSessionSync.swift` compiled against the real `supabase-swift` 2.55.4 via SwiftPM (macOS) | ✅ builds, runs, no warnings |
| JSON decoding + pure logic: 95 assertions against **real backend responses** captured in mock mode (session, join, list, comparables, events, script run, agreement draft/locked, blocked/rejected/approved/amended payment requests, receipt, 409 errors) plus tolerance cases | ✅ all pass |
| Live smoke test: `APIClient` drove the whole 12.6 demo flow against a running mock backend (create → join → comparables → play script → 409 on replay → event → fix term → draft → confirm ×2 → blocked → reject → agreed charge → pay → receipt summary) | ✅ all pass (108 total assertions) |
| `project.yml` YAML parses | ✅ (not yet run through `xcodegen`) |

**Not verified yet (needs Xcode):**
- Real iOS SDK compile, `xcodegen` generation, signing, Info.plist output
- Runtime UI and layout on iPhone screens
- Camera QR scanning, the mic/speech permission flow and SFSpeechRecognizer behavior
- Haptics and idle-timer behavior
- Realtime against a real Supabase project

Catalyst typechecking is a close proxy for iOS, but it isn't identical.
