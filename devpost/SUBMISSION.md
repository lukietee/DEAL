# Devpost submission: copy and paste

Every answer is in its own block, so the copy button grabs exactly that answer. Devpost's long text fields accept Markdown.

---

## Project name

```
DEAL
```

## Elevator pitch / tagline (200 characters max)

```
An AI negotiation copilot that coaches you live through Ray-Ban Meta Display glasses, researches prices in seconds, and makes sure you pay exactly what you agreed.
```

---

## Inspiration

```markdown
Buying something used from a stranger is stressful. You don't know what it's really worth. Sellers stretch the truth about condition ("new tires last month"). Surprise fees show up at the end ("plus $20 for gas"). And Marketplace meetups have a whole scam genre built on fake "payment sent" screenshots. Most people aren't trained negotiators, and nobody pulls out a laptop mid-haggle to research prices. I wanted a coach that's right there with you, and that keeps you from paying more than you agreed to.
```

## What it does

```markdown
**DEAL is an AI negotiation copilot that coaches you live through Ray-Ban Meta Display glasses and makes sure you pay exactly what you agreed.**

- **Just start talking.** Tap *Start listening*, with no forms and no prep. DEAL transcribes the conversation on-device, works out who said each line, and detects the product, the asking price and what the seller claims about condition.
- **Live market research.** As soon as the product is known, three research agents (comparable listings, known issues, fair price) search the web with Tavily in parallel. Nemotron reads the results and returns a fair price range, sources and photos in a few seconds.
- **A coach in your glasses.** After every line, a 3–6 word cue appears on the Ray-Ban Meta Display ("Hold the tire point", "Above fair range. Counter lower."), with a status dot and offer vs. target. While the agents work, the glasses show a research strip that fills in as each one finishes. Your phone shows three ready-to-say phrases backed by the research ("I've seen similar ones go for $590 to $725 around here. Would you do $520?").
- **Look mode.** Look at a product and DEAL highlights it with its market price. It only highlights what you dwell on, so it isn't noisy. Neural Band gestures: pinch for details, swipe through pages, back to dismiss, hold the capture button to start a negotiation.
- **Condition check.** Snap a photo of the item. DEAL compares it with the listing's claims and flags mismatches ("Listing: new tires · Seen: worn → ask $40 off").
- **Agreement-locked checkout.** When you shake on a price, both sides confirm on their phones and the agreement is sealed with a SHA-256 fingerprint. The seller's phone becomes a payment terminal that can only charge that exact amount. Any extra line item, like a surprise "$20 gas fee", is blocked until the buyer approves it. Both phones then show *Payment verified* before the item changes hands, so a fake screenshot doesn't work.
- **Every deal, remembered.** Each conversation is saved to History with a summary, offer timeline, savings and blocked charges, plus a one-tap dispute pack (transcript, agreement and receipt).
```

## How we built it

```markdown
- **AI: NVIDIA Nemotron on Nebius Token Factory.** Every AI call in real mode goes to a Nemotron model through Token Factory's OpenAI-compatible API, and each call uses the model that fits its latency and accuracy needs:
  - *Nemotron 3 Ultra (550B-A55B), thinking off:* the live cue and speaker detection after every line (~1.0 s median).
  - *Nemotron 3 Ultra, thinking on:* the final agreement, the one output that gets locked and paid (~5.5 s).
  - *Nemotron 3.5 Lightning:* product, price and claims detection, suggested phrases, summaries and Look mode's price synthesis (0.5–0.8 s).
  - *Nemotron 3 Super (120B-A12B):* the research agents' synthesis and listing parsing (3–4 s per agent).
  - *Nemotron 3.5 Super VL:* listing screenshots, condition photos and identifying products in Look mode.
  - Every model output is validated with zod and retried once if invalid.
- **Web research: Tavily.** Each research agent runs 2–3 targeted Tavily searches in parallel (advanced depth where prices matter). Nemotron Super reads the top 10 deduplicated results and writes the summary, price range and a headline of 24 characters or less for the glasses. Look mode's price check is one Tavily search plus a Lightning synthesis, cached per item.
- **iOS app (SwiftUI):** buyer and seller modes in one app; Apple Speech for on-device transcription; Apple Vision for Look mode's dwell detection and tracking; camera and PhotosPicker for listing screenshots and condition photos; a custom design system.
- **Glasses:** Meta's Wearables Device Access Toolkit for the Ray-Ban Meta Display (cue card, research strip, Look card), the glasses camera and Neural Band input. The phone's teleprompter mirrors every cue as a fallback.
- **Backend (Node 24 + TypeScript + Fastify):** holds every API key and runs the AI, the agreement fingerprinting, the deterministic charge-mismatch rules and payments.
- **Payments:** Stripe test mode. A simulated tap creates a real PaymentIntent for the exact locked amount.
- **Tests:** 205 backend tests, plus end-to-end XCUITests that drive the buyer, seller and Look flows in the Simulator.
```

## Challenges we ran into

```markdown
- **Live means about one second.** A cue has to land before the other person's next sentence. I benchmarked the Nemotron models against a scripted negotiation with known correct cues. Lightning was the fastest but got 0 of 19 offer amounts right (it converted cents twice). Ultra got 18 of 19, and with thinking switched off it still answers in about 1.0 s median. I added two deterministic guards on every cue (money amounts and status colours) so a bad model output can't put a wrong number in front of the buyer.
- **Research was too slow.** My first research setup took 15–25 s, far too long for a conversation. Moving search to Tavily, running each agent's searches in parallel, and giving the synthesis to Nemotron Super brought a full research run down to about 3.5–11 s.
- **The glasses display only renders white and grey.** I encode the status colour as a small bright dot and keep every cue to a few words so it can be read at a glance.
- **The glasses can't pin graphics to objects in the world.** For Look mode, the green highlight and price window live on the phone's camera view, and the glasses get a compact card driven by Neural Band gestures.
- **Facebook blocks automated reading of listing links.** DEAL never scrapes. Nemotron reads a pasted listing or a screenshot instead, and the app gives a clear message when a link can't be read.
- **One mic, two people.** Nemotron infers who said each line in the same call that writes the cue, so it adds no latency, with a manual override.
- **Venue Wi-Fi blocked device-to-device traffic,** so the phone couldn't reach the backend. I switched to a phone hotspot and baked the backend URL into device builds.
```

## Accomplishments that we're proud of

```markdown
- A negotiation can start with zero setup. You talk, and the app works out the product, the price and the claims, then pulls live market research for it.
- Coaching that keeps up with a real conversation: a Nemotron Ultra cue in about a second after every line.
- The agreement lock: a checkout that cannot charge more than what both people agreed to, and that tells you why when someone tries.
- Research that changes what you say: the suggested phrases quote real comparable prices found seconds earlier.
```

## What we learned

```markdown
- Pick the model per call, not per app. Ultra with thinking off was both more accurate and fast enough for live cues; Lightning was perfect for simple background extraction; thinking was worth its 4 extra seconds only for the agreement that gets paid.
- Measure model choices against a test with known right answers. Our cue benchmark caught a cents-conversion bug that would have shown wrong prices in the glasses.
- Short beats smart on a heads-up display. The best cue is 3–6 words.
- Separating "fast and good enough" (cues) from "slow and thorough" (research) is what makes a live AI experience feel instant.
- Trust features (fingerprints, blocked charges, verification on both phones) matter as much as the AI coaching for people meeting strangers.
```

## What's next for DEAL

```markdown
- Real Tap to Pay on iPhone through Stripe Terminal instead of the simulated tap.
- Glasses-native capture: use the glasses' microphone for hands-free listening and their camera for condition checks.
- Personal coaching over time from your negotiation history.
- More scenarios: car dealerships, pawn shops, rent and salary negotiations.
```

---

## Which model(s) did you use, and why did you choose that size/variant?

```
I use four NVIDIA Nemotron models through Nebius Token Factory, each matched to what its call needs. Thinking is off everywhere except the agreement.

- Nemotron 3 Ultra (550B-A55B), thinking off: the live cue after every line of the conversation. It has to be accurate and fast at once. I scored Lightning and Ultra on my bike-negotiation script: Lightning got 0 of 19 offer amounts right (it converted cents twice), Ultra got 18 of 19, and Ultra with thinking off still answers in about 1.0 s median (1.4 s max), fast enough to coach a live conversation.

- Nemotron 3 Ultra, thinking on: drafting the final agreement. This is the one output that gets locked, fingerprinted and paid, so I let it reason. It takes about 5.5 s instead of 1.2 s, and it adds the open questions the buyer should confirm before locking.

- Nemotron 3.5 Lightning: detecting the product, asking price and seller claims, the suggested phrases, the end-of-chat summary, and Look mode's price synthesis. These are simple extraction or short writing tasks, mostly in the background, and Lightning gets them right in 0.5–0.8 s.

- Nemotron 3 Super (120B-A12B): the three research agents. Each one reads the top 10 Tavily search results and writes a summary, a fair price range and a headline of 24 characters or less for the glasses; it also parses pasted listings. That's longer input and structured output where quality matters more than sub-second speed (3–4 s per agent).

- Nemotron 3.5 Super VL: everything visual, meaning listing screenshots, condition-check photos and identifying products in Look mode (1.5–8 s).

In short: Ultra where a mistake costs the user money, Lightning where speed matters and the task is easy, Super for reading lots of web text, and VL for images. Every output is validated against a schema and retried once if invalid.
```

---

## Extra answers, in case the form asks

### How did you use Tavily?

```
Tavily powers all of DEAL's live web research. When DEAL detects the product in the conversation, three research agents start at once: comparable listings, known issues and wear, and fair price and leverage. Each agent runs 2–3 targeted Tavily searches in parallel, using advanced search depth where the snippets need to carry prices. The top 10 deduplicated results (ranked by Tavily score) go to Nemotron 3 Super, which writes a summary, a fair price range and a short headline for the glasses; any source the model names that Tavily didn't return is dropped. Thumbnails come from the result pages' og:images, with Tavily's images as a fallback. Look mode's price check is one Tavily search ("<item> price used sold") plus a Nemotron Lightning synthesis, cached per item for 30 minutes. A full research run takes about 3.5–11 s, down from 15–25 s with my previous search setup, which is what makes research usable in the middle of a conversation.
```

### How did you use Nebius Token Factory?

```
Every AI call DEAL makes in real mode goes through Nebius Token Factory's OpenAI-compatible chat completions API. That's four NVIDIA Nemotron models (3 Ultra, 3.5 Lightning, 3 Super and 3.5 Super VL), chosen per call for latency and accuracy, in JSON mode with each output validated by zod. I use chat_template_kwargs.enable_thinking to switch reasoning off for everything live and on only for the agreement draft. That switch is what makes even the 550B Ultra model fast enough (~1 s) to coach a conversation in real time. GET /health on the backend reports which provider and model handles each call.
```

---

## Built with (tags)

```
nvidia-nemotron, nebius-token-factory, tavily, swift, swiftui, meta-wearables-device-access-toolkit, ray-ban-meta, apple-speech, apple-vision, node.js, typescript, fastify, zod, stripe, xcodegen
```

## Links

GitHub repo:

```
https://github.com/lukietee/DEAL
```

Demo video: upload `DEAL-demo-vo-music.mp4` (in the project folder) to YouTube, then paste the link here.

```
https://youtu.be/...
```
