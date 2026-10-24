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
- Never invent numbers that were not said.`;

export function cueUserPrompt(session: Session, recent: DealEvent[], line: { speaker: string; text: string }, tactics: Tactic[], comparables: unknown): string {
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
      },
      comparables,
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
