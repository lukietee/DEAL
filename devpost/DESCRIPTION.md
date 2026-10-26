## Inspiration
Buying something used from a stranger is stressful. You don't know what it's really worth. Sellers stretch the truth about condition ("new tires last month"). Surprise fees show up at the end ("plus $20 for gas"). And Marketplace meetups have a whole scam genre built on fake "payment sent" screenshots. Most people just aren't trained negotiators, and nobody pulls out a laptop mid-haggle to research prices. I wanted a coach that's right there with you, and that keeps you from paying more than you agreed to.

## What it does
**DEAL is an AI negotiation copilot that coaches you live through Ray-Ban Meta Display glasses and makes sure you pay exactly what you agreed.**

- **Just start talking.** Tap *Start listening*, with no forms and no prep. DEAL transcribes the conversation on-device, works out who said each line, and detects the product, the asking price and what the seller is claiming about condition.
- **Live market research.** As soon as the product is known, three AI agents search the web in parallel: comparable listings, known issues and wear, and fair price and leverage. They bring back a fair price range, sources and photos in about 20 seconds.
- **A coach in your glasses.** After every line, a 3–6 word cue appears on your Ray-Ban Meta Display ("Hold the tire point", "Above fair range. Counter lower."), with a status color and offer vs. target. Your phone shows three ready-to-say phrases backed by the research ("I've seen similar ones go for $590 to $725 around here. Would you do $520?").
- **Condition check.** Snap a photo of the item. DEAL compares it with the listing's claims and flags mismatches ("Listing: new tires · Seen: worn → ask $40 off").
- **Agreement-locked checkout.** When you shake on a price, both sides confirm on their phones and the agreement is sealed with a SHA-256 fingerprint. The seller's phone becomes a payment terminal that can only charge that exact amount. Any extra line item, like a surprise "$20 gas fee", is blocked until the buyer approves it. Both phones then show *Payment verified* before the item changes hands, so a fake screenshot doesn't work.
- **Every deal, remembered.** Each conversation is saved to History with a summary, offer timeline, savings and blocked charges, plus a one-tap dispute pack (transcript, agreement and receipt).

## How I built it
- **iOS app (SwiftUI):** buyer and seller modes in one app; Apple's Speech framework for on-device transcription; camera and PhotosPicker for listing screenshots and condition photos; a custom design system.
- **Glasses:** Meta's Wearables Device Access Toolkit (`MWDATDisplay`) draws the cue card on the Ray-Ban Meta Display. The phone's teleprompter mirrors every cue as a fallback.
- **Backend (Node + TypeScript + Fastify):** holds all API keys and runs the AI, the agreement fingerprinting, the deterministic charge-mismatch rules and payments.
- **Claude:**
  - *Haiku* for live cues, speaker detection, product detection, suggested phrases and summaries.
  - *Sonnet* for drafting the agreement, reading listings (text, screenshots, or links via web fetch) and comparing condition photos.
  - *Opus* with web search for the research agents. I pull og:images from the result pages for photo thumbnails.
  - Every model output is validated with zod and retried once if invalid.
- **Payments:** Stripe test mode. A simulated tap triggers a real PaymentIntent for the exact locked amount.
- **Tests:** about 150 backend tests and end-to-end XCUITests that drive both the buyer and seller flows.

## Challenges I ran into
- **Venue Wi-Fi blocked device-to-device traffic,** so the phone couldn't reach the backend. I switched to a phone hotspot and baked the backend URL into device builds so nothing needs typing on stage.
- **The glasses display only renders white and grey text.** I encode the status color as a small bright dot and keep every cue to a few words so it can be read at a glance.
- **Facebook blocks automated reading of listing links.** DEAL never scrapes. Instead, Claude reads a pasted listing or a screenshot, and gives a clear message when a link can't be read.
- **Real time vs. thorough.** Cues have to land in about a second, but research takes about 20. I split them: cues run per line on a fast model, research and product detection run in the background, and everything streams into the UI as it arrives.
- **One mic, two people.** I let Claude infer the speaker from context, with a manual override.

## Accomplishments that I'm proud of
- A negotiation can start with zero setup. You talk, and the app works out the product, the price and the claims, then pulls market research for it.
- The agreement lock: a checkout that cannot charge more than what both people agreed to, and that tells you why when someone tries.
- Research that changes what you say: the suggested phrases quote real comparable prices found seconds earlier.

## What I learned
- Short beats smart on a heads-up display. The best cue is 3–6 words.
- Separating "fast and good enough" (cues) from "slow and thorough" (research) is what makes a live AI experience feel instant.
- Trust features (fingerprints, blocked charges, verification on both phones) matter as much as the AI coaching for people meeting strangers.

## What's next for DEAL
- Real Tap to Pay on iPhone through Stripe Terminal instead of the simulated tap.
- Glasses-native capture: use the glasses' microphone and camera for hands-free listening and condition checks.
- Personal coaching over time from your negotiation history.
- More scenarios: car dealerships, pawn shops, rent and salary negotiations.

## Built With
swift · swiftui · meta-wearables-device-access-toolkit · ray-ban-meta · apple-speech · node.js · typescript · fastify · claude · anthropic-api · stripe · zod · xcodegen
