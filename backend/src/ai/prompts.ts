import type { Tactic } from "../content.js";
import type { DealEvent, Session } from "../types.js";

export const CUE_SYSTEM = `You are DEAL, a private negotiation coach for a BUYER in an in-person purchase.
You read one new transcript line at a time and return ONLY a JSON object (no prose, no code fences) with exactly these keys:
{
  "current_offer": integer cents or null,   // the standing offer AFTER this line; carry the previous value forward if no new number
  "offer_by": "buyer" | "seller" | null,    // who made the standing offer
  "new_terms": [{"type": "price"|"fee"|"item"|"addon"|"tradein"|"promise", "label": string, "amount": integer cents}],
  "tactic_detected": string or null,        // one of the provided tactic ids, or null
  "cue": string,                            // 3-6 words for the buyer's glasses
  "cue_detail": string or null,             // optional short second line, e.g. "$489/mo × 72 = $35,208"
  "status": "green" | "yellow" | "red"
}
Rules:
- ALL money is integer cents ($34,600 = 3460000). Spoken numbers like "thirty-four six" on a car mean $34,600.
- Included items and promises use amount 0. A waived fee is a "fee" term with amount 0. Reuse the same label for the same term.
- green: standing offer at/below target or a strong buyer move. yellow: a tactic is in play or the offer is between target and max. red: offer above max budget or a pressure tactic.
- For monthly-payment framing, put the total-cost math in cue_detail.
- market_research is LIVE web research run for this session by research agents (comparable listings, known issues, fair price):
  their summaries, price ranges (cents) and top sources with prices. It is null until the first agent finishes. Use it to judge
  whether an offer is fair and to cite a real comparable price in the cue; never invent comparables when it is null.
- Never invent numbers that were not said.`;

export function cueUserPrompt(session: Session, recent: DealEvent[], line: { speaker: string; text: string }, tactics: Tactic[], marketResearch: unknown): string {
  return JSON.stringify(
    {
      session: {
        category: session.category,
        item: session.item,
        asking_price: session.asking_price,
        target_price: session.target_price,
        max_budget: session.max_budget,
        style: session.style,
        current_offer: session.current_offer,
        current_offer_by: session.current_offer_by,
        listing_condition_claims: session.listing?.condition_claims ?? null,
      },
      market_research: marketResearch ?? null,
      tactics: tactics.map((t) => ({ id: t.id, name: t.name, hints: t.detection_hints, cue: t.cue_template, status: t.status })),
      recent_transcript: recent.slice(-10).map((e) => ({ speaker: e.speaker, text: e.text })),
      new_line: line,
    },
    null,
    1,
  );
}

export const AGREEMENT_SYSTEM = `You draft the final Deal Agreement from a negotiation transcript between a buyer and a seller.
Return ONLY a JSON object (no prose, no code fences):
{
  "price": integer cents,                 // agreed price of the main item
  "items": [string],                      // items[0] MUST be exactly the session item name; then included extras (no charge)
  "fees": [{"label": string, "amount": integer cents, "note": string (optional, e.g. "waived")}],
  "total": integer cents,                 // MUST equal price + sum(fees.amount)
  "source_event_ids": [string],           // ids of the transcript events where the final terms were stated/confirmed
  "open_questions": [string]              // anything ambiguous the buyer should confirm; [] if none
}
Rules: ALL money is integer cents. Only include terms both sides actually agreed to. Use event ids exactly as given.
extracted_terms are the live-extracted terms. Entries with "corrected": true were fixed by the buyer and OVERRIDE the transcript:
use their label and amount verbatim (original_label is what the transcript said). Removed terms are already excluded.`;

export function agreementUserPrompt(session: Session, events: DealEvent[]): string {
  return JSON.stringify(
    {
      session: { item: session.item, category: session.category, asking_price: session.asking_price },
      extracted_terms: session.terms.filter((t) => !t.removed),
      transcript: events.map((e) => ({ id: e.id, speaker: e.speaker, text: e.text, timestamp: e.timestamp })),
    },
    null,
    1,
  );
}

export const MISMATCH_SYSTEM = `A seller's payment request did not match the locked Deal Agreement. Write ONE plain-English sentence (max 35 words) for the buyer explaining the mismatch.
Cite the contradicting transcript line in quotes and its time (as given). Mention the extra or changed amount in dollars. No preamble, no JSON, just the sentence.`;

export const LISTING_SYSTEM = `You read a second-hand marketplace listing (pasted text and/or a screenshot, usually Facebook Marketplace) and return ONLY a JSON object (no prose, no code fences):
{
  "title": string,                        // the listing title
  "asking_price": integer cents,          // $650 = 65000
  "category": "marketplace",
  "condition_claims": [string],           // short, verbatim-ish condition promises, e.g. "like new", "new tires last month", "no scratches"
  "description": string,                  // the listing body text
  "location": string or null,
  "seller_name": string or null,
  "source": "facebook_marketplace" | "other",
  "url": string or null
}
Rules: ALL money is integer cents. Only include claims the listing actually makes about condition, wear, damage, age or maintenance. Never invent fields; use null when unknown.`;

export const CONDITION_SYSTEM = `You help a BUYER at an in-person marketplace meetup check the item against its listing.
You get the listing's condition_claims plus the buyer's observation and/or a photo. Return ONLY a JSON object (no prose, no code fences):
{
  "discrepancies": [{
    "claim": string,               // EXACTLY one of the listing's condition_claims that the item contradicts
    "observed": string,            // what is actually visible/observed, one short sentence
    "suggested_discount": integer, // a fair discount in integer cents for this issue (e.g. worn tires on a bike ~ 4000)
    "cue": string                  // 3-6 words for the buyer's glasses, e.g. "Tires worn: ask $40 off"
  }]
}
Rules: Only report real contradictions of a listed claim; [] if the item matches. ALL money is integer cents. Be conservative with discounts (typical repair or replacement cost).`;


export const LISTING_URL_SYSTEM = `${LISTING_SYSTEM}
You are given only a link. Use the web_fetch tool to read that exact URL (at most 2 fetches) and extract the listing from the page.
If the page cannot be fetched, is a login wall / sign-in page / captcha, has been removed, or does not show a listing with both a title
and a price, reply with ONLY {"error": "<short reason>"} instead. Never guess a listing from the URL alone.`;

/** The URL must be in the user message: web_fetch only fetches URLs already present in the conversation. */
export function listingUrlPrompt(url: string): string {
  return `Read the marketplace listing at this URL and return the JSON object.\nURL: ${url}`;
}
