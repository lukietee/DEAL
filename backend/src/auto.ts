// "Start listening" (auto) sessions: the buyer starts with no item or prices and the backend works them out
// from the conversation. Pure helpers shared by mock and real mode: speaker heuristic, regex product detection,
// category normalisation, the listing built from heard condition claims, and the template session summary.
import type { Listing } from "./listing.js";
import { formatCentsShort } from "./money.js";
import type { Agreement, DealEvent, Detection, Receipt, Session, SessionSummary, Speaker } from "./types.js";

/** Item name used when 3 lines pass with no recognisable product. */
export const PLACEHOLDER_ITEM = "Item from conversation";

export const DETECTED_CATEGORIES = ["car", "pawn_shop", "marketplace", "electronics", "other"] as const;
export type DetectedCategory = (typeof DETECTED_CATEGORIES)[number];

/** The session's item for display / agreements, never empty. */
export function itemName(s: Pick<Session, "item">): string {
  return s.item.trim() || PLACEHOLDER_ITEM;
}

// ---------- speaker ----------

const BUYER_HINTS = [/\bi'?ll take\b/i, /\bwould you do\b/i, /\bcan you do\b/i, /\bi can pay\b/i, /\bi'?ll give\b/i, /\bstill available\b/i, /\bwould you take\b/i];
const SELLER_HINTS = [/\bi'?m asking\b/i, /\bfirm\b/i, /\blowest i\b/i, /\bselling\b/i];

/** Mock / fallback speaker for a line posted with speaker "auto". The buyer is the app user. */
export function guessSpeaker(text: string, previous: Pick<DealEvent, "speaker" | "kind">[]): Speaker {
  const buyer = BUYER_HINTS.some((r) => r.test(text));
  const seller = SELLER_HINTS.some((r) => r.test(text));
  if (buyer && !seller) return "buyer";
  if (seller && !buyer) return "seller";
  const last = [...previous].reverse().find((e) => (e.kind ?? "speech") === "speech");
  if (!last) return "buyer"; // the buyer usually opens ("Hi, is it still available?")
  return last.speaker === "buyer" ? "seller" : "buyer";
}

// ---------- category ----------

const CATEGORY_WORDS: Array<[DetectedCategory, RegExp]> = [
  ["car", /\b(car|truck|sedan|suv|van|coupe|minivan|pickup|honda|toyota|ford|chevy|chevrolet|nissan|bmw|audi|tesla|subaru|mazda|hyundai|kia|jeep|accord|civic|camry|corolla|motorcycle)\b/i],
  ["electronics", /\b(phone|iphone|android|pixel|galaxy|laptop|macbook|computer|pc|tablet|ipad|headphones?|earbuds|airpods|speaker|tv|television|monitor|camera|lens|console|playstation|ps[45]|xbox|nintendo|switch|gpu|graphics card|watch|sony|bose|canon|nikon|drone|kindle)\b/i],
  ["pawn_shop", /\b(pawn|ring|necklace|bracelet|jewel(?:ry|lery)|gold|diamond|guitar|amp|amplifier|rolex)\b/i],
  ["marketplace", /\b(bike|bicycle|couch|sofa|table|chair|desk|dresser|bed|mattress|stroller|furniture|lamp|shelf|bookcase|cabinet|scooter|treadmill|grill|crib|rug)\b/i],
];

/** Map a model's or a regex's category onto car | pawn_shop | marketplace | electronics | other. */
export function normalizeDetectedCategory(raw: string | null | undefined, item: string): DetectedCategory {
  const c = (raw ?? "").trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
  if ((DETECTED_CATEGORIES as readonly string[]).includes(c) && c !== "other") return c as DetectedCategory;
  if (/^(pawn|pawnshop)/.test(c)) return "pawn_shop";
  if (/^(auto|vehicle|cars?)$/.test(c)) return "car";
  if (/electronic|tech|gadget/.test(c)) return "electronics";
  if (/market|furniture|bike/.test(c)) return "marketplace";
  for (const [cat, re] of CATEGORY_WORDS) if (re.test(item)) return cat;
  return "other";
}

// ---------- mock detection ----------

const WORDS = String.raw`([A-Za-z0-9][A-Za-z0-9'./-]*(?:\s+[A-Za-z0-9][A-Za-z0-9'./-]*){0,7}?)`;
const AMOUNT = String.raw`\$?\s?(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?\s?(k)?\b`;

const ITEM_PATTERNS: RegExp[] = [
  new RegExp(String.raw`\b(?:is|are)\s+(?:the|this|that|your|these|those)\s+${WORDS}\s+still\s+(?:available|for sale|up)`, "i"),
  new RegExp(String.raw`\b(?:selling|this|the|my|that|your)\s+${WORDS}\s+for\s+\$?\s?\d`, "i"),
  new RegExp(String.raw`\$\s?[\d,]+(?:\.\d{1,2})?\s?k?\s+for\s+(?:the|this|that|your|my)\s+${WORDS}(?=[.,!?;]|$|\s+(?:and|if|right|today|now|cash)\b)`, "i"),
  new RegExp(String.raw`\b(?:interested in|here (?:about|for)|asking about|looking at|messaged about|came for)\s+(?:the|this|that|your)\s+${WORDS}(?=[.,!?;]|$|\s+(?:you|that|for|on)\b)`, "i"),
  new RegExp(String.raw`(?:^|[.!?]\s+)${WORDS}\s*(?:,|:|-|\.\.\.|…)\s*\$\s?\d`, "i"),
];

const NOT_ITEMS = /^(it|that|this|one|them|those|these|deal|price|lowest|best|most|total|whole thing|offer|cash|money|thing|stuff|lot|same|rest|i|you|we|me|he|she|they|yeah|yes|no|ok|okay|hey|hi|so|well|look|honestly|how about|what about)\b/i;
const LEAD_WORDS = /^(?:(?:the|this|that|my|your|a|an|our|these|those|i'm selling|selling|hey|hi|yeah|so|well|um|uh)\s+)+/i;

function cleanItem(raw: string): string | null {
  const item = raw.trim().replace(LEAD_WORDS, "").replace(/\s+(still|here|there|now|today)$/i, "").replace(/[.,!?;:\s]+$/, "").trim();
  if (item.length < 2 || item.length > 60 || NOT_ITEMS.test(item) || /^\d+$/.test(item)) return null;
  return item;
}

function amountCents(whole: string, frac?: string, k?: string): number {
  let v = Number(whole.replace(/,/g, "")) + (frac ? Number(frac) : 0);
  if (k) v *= 1000;
  return Math.round(v * 100);
}

const ASKING_PATTERNS: RegExp[] = [
  new RegExp(String.raw`\b(?:i'?m asking|asking|i want|i'?m looking for|price is|listed (?:it |them )?(?:at|for)|selling (?:it |them |this |these )?for|it'?s|they'?re|go(?:es)? for)\s+(?:about\s+|around\s+|like\s+)?${AMOUNT}`, "i"),
  new RegExp(String.raw`\bfor\s+\$\s?(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?\s?(k)?\b`, "i"),
  new RegExp(String.raw`\$\s?(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?\s?(k)?\s*(?:firm|obo|or best offer)?\b`, "i"),
];

const CLAIM_PATTERNS: RegExp[] = [
  /\b(barely used|never used|like new|brand new|mint condition|perfect condition|excellent condition|great condition|good condition|works (?:perfectly|great|fine)|no scratches|no dents|no damage|still under warranty|comes with (?:the )?(?:box|charger|case|everything)|original box|one owner|low miles|new (?:tires|battery|brakes|strings|screen)[a-z ]{0,20}?(?=[.,!?;]|$)|only used (?:a few times|once|twice))\b/gi,
];

/** Regex detection over an auto session's transcript (mock mode, and the real-mode fallback). */
export function mockDetect(events: Pick<DealEvent, "speaker" | "text" | "kind">[]): Detection {
  const lines = events.filter((e) => (e.kind ?? "speech") === "speech");
  let item: string | null = null;
  for (const l of lines) {
    for (const re of ITEM_PATTERNS) {
      const m = re.exec(l.text);
      const cleaned = m?.[1] ? cleanItem(m[1]) : null;
      if (cleaned) { item = cleaned; break; }
    }
    if (item) break;
  }
  let asking: number | null = null;
  for (const l of lines) {
    // A buyer's "$150 for the bike?" is an offer, not the asking price.
    if (l.speaker !== "seller" && !/\b(asking|listed)\b/i.test(l.text)) continue;
    for (const re of ASKING_PATTERNS) {
      const m = re.exec(l.text);
      if (!m) continue;
      const after = l.text.slice(m.index + m[0].length, m.index + m[0].length + 12).toLowerCase();
      if (/^\s*(miles|mi\b|months|mo\b|years|%|a month|per month)/.test(after)) continue;
      const cents = amountCents(m[1]!, m[2], m[3]);
      if (cents >= 100) { asking = cents; break; }
    }
    if (asking != null) break;
  }
  const claims: string[] = [];
  for (const l of lines) {
    if (l.speaker !== "seller") continue;
    for (const re of CLAIM_PATTERNS) {
      for (const m of l.text.matchAll(re)) {
        const c = m[1]!.toLowerCase().trim();
        if (!claims.includes(c)) claims.push(c);
      }
    }
  }
  return { item, category: normalizeDetectedCategory(null, item ?? ""), asking_price: asking, condition_claims: claims.slice(0, 8) };
}

/** session.listing for an auto session that heard condition claims but had no listing attached. */
export function listingFromClaims(item: string, askingPrice: number | null, claims: string[]): Listing {
  return {
    title: item,
    asking_price: askingPrice ?? 0,
    category: "marketplace",
    condition_claims: claims,
    description: `Heard in conversation: ${claims.join("; ")}`,
    source: "other",
  };
}

// ---------- summary ----------

const AGREE = /\b(deal|you got it|i'?ll take it|sounds good|works for me|agreed|let'?s do it|done|it'?s yours|okay,? (?:fine|deal)|fine,? )\b/i;
const WALK = /\b(no deal|walk away|i'?ll pass|not interested|too much for me|no thanks|forget it|can'?t do that|i'?ll think about it)\b/i;

/** Trim a summary to the contract (headline <= 12 words, <= 4 key points) and apply hard facts. */
export function clampSummary(s: SessionSummary, receipt: Receipt | null): SessionSummary {
  const out: SessionSummary = {
    outcome: s.outcome,
    final_price: s.outcome === "deal" ? s.final_price : null,
    headline: s.headline.trim().split(/\s+/).slice(0, 12).join(" "),
    key_points: s.key_points.map((k) => k.trim()).filter(Boolean).slice(0, 4),
  };
  if (receipt) { out.outcome = "deal"; out.final_price = receipt.amount; }
  return out;
}

export interface SummaryInput {
  session: Session;
  events: DealEvent[];
  agreement: Agreement | null;
  receipt: Receipt | null;
  marketRange?: { low: number; high: number } | null;
}

/** Template summary (mock mode / model failure), built from the receipt, agreement or last offer. */
export function mockSummary({ session, events, agreement, receipt, marketRange }: SummaryInput): SessionSummary {
  const item = itemName(session);
  const speech = events.filter((e) => e.kind === "speech");
  const lastTexts = speech.slice(-3).map((e) => e.text).join(" ");
  const offer = session.current_offer;
  let outcome: SessionSummary["outcome"];
  let price: number | null = null;
  if (receipt) { outcome = "deal"; price = receipt.amount; }
  else if (agreement?.status === "locked") { outcome = "deal"; price = agreement.total; }
  else if (WALK.test(lastTexts)) outcome = "no_deal";
  else if (offer != null && AGREE.test(lastTexts)) { outcome = "deal"; price = offer; }
  else outcome = "undecided";

  const headline =
    outcome === "deal" ? `Deal on ${item} at ${formatCentsShort(price!)}`
      : outcome === "no_deal" ? `No deal on ${item}${offer != null ? `, last offer ${formatCentsShort(offer)}` : ""}`
        : `Talked about ${item}${offer != null ? `, last offer ${formatCentsShort(offer)}` : ", no price settled"}`;

  const points: string[] = [];
  if (session.asking_price != null) points.push(`Seller asked ${formatCentsShort(session.asking_price)}`);
  if (outcome === "deal" && price != null && session.asking_price != null && session.asking_price > price) {
    points.push(`Saved ${formatCentsShort(session.asking_price - price)} off asking`);
  } else if (offer != null && outcome !== "deal") {
    points.push(`Last offer ${formatCentsShort(offer)}${session.current_offer_by ? ` by ${session.current_offer_by}` : ""}`);
  }
  if (receipt && receipt.blocked_total > 0) points.push(`Blocked ${formatCentsShort(receipt.blocked_total)} in extra charges`);
  if (marketRange) points.push(`Market range ${formatCentsShort(marketRange.low)}–${formatCentsShort(marketRange.high)}`);
  const claims = session.listing?.condition_claims ?? [];
  if (claims.length) points.push(`Seller claimed: ${claims.slice(0, 2).join(", ")}`);
  if (!points.length) points.push(speech.length ? `${speech.length} lines of conversation` : "Nothing was said");
  return clampSummary({ outcome, final_price: price, headline, key_points: points }, receipt);
}
