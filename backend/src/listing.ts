// Marketplace listings (POST /listings/parse) and condition checks (POST /sessions/:id/condition-check).
// ALL money is integer cents. Mock mode serves content/listings/*.json and keyword rules; real mode uses Nemotron
// (ai/nemotron.ts: vision model for screenshots / photos, pages fetched here) or Claude (ai/index.ts).
import { z } from "zod";
import { getListingFile } from "./content.js";

const cents = z.number().int().nonnegative();

export const ListingSchema = z.object({
  title: z.string().min(1),
  asking_price: cents,
  category: z.literal("marketplace"),
  condition_claims: z.array(z.string()),
  description: z.string(),
  location: z.string().optional(),
  seller_name: z.string().optional(),
  source: z.enum(["facebook_marketplace", "other"]),
  url: z.string().optional(),
});
export type Listing = z.infer<typeof ListingSchema>;

/** Model output for a listing: same shape, but tolerant of nulls for the optional fields. */
export const ListingModelSchema = ListingSchema.extend({
  category: z.string().transform(() => "marketplace" as const),
  location: z.string().nullish().transform((v) => v ?? undefined),
  seller_name: z.string().nullish().transform((v) => v ?? undefined),
  url: z.string().nullish().transform((v) => v ?? undefined),
});

export const DiscrepancySchema = z.object({
  claim: z.string().min(1), // the listing's claim, verbatim from condition_claims
  observed: z.string().min(1), // what the buyer actually sees
  suggested_discount: cents, // cents
  cue: z.string().min(1), // 3–6 words for the glasses, e.g. "Tires worn: ask $40 off"
});
export type Discrepancy = z.infer<typeof DiscrepancySchema>;

export const ConditionModelSchema = z.object({ discrepancies: z.array(DiscrepancySchema) });

export interface ListingInput {
  url?: string;
  text?: string;
  image_base64?: string;
}

export interface ConditionInput {
  observation?: string;
  image_base64?: string;
}

/** Stored on session.condition_checks[] (also surfaced in the dispute pack). */
export interface ConditionCheck {
  id: string;
  at: string;
  observation: string | null;
  had_image: boolean;
  discrepancies: Discrepancy[];
  event_id: string;
}

export const URL_UNREADABLE = "Couldn't read that link. Paste the listing text or a screenshot instead.";
export const LISTING_UNREADABLE = "Couldn't read that listing. Paste the full listing text or a clearer screenshot.";

/** Real mode: the listing couldn't be read (bad link, login wall, model failure). Mapped to HTTP 422. */
export class ListingUnreadableError extends Error {
  constructor(public userMessage: string, public reason: string) {
    super(`${userMessage} (${reason})`);
  }
}

/** Real mode: the condition model failed. Mapped to HTTP 502. */
export class ConditionCheckError extends Error {}

export function isFacebookUrl(url: string | undefined): boolean {
  return !!url && /(^|\/\/|\.)(facebook\.com|fb\.com|fb\.me)(\/|$)/i.test(url);
}

/** Strip a `data:image/...;base64,` prefix and whitespace; detect the media type from magic bytes. */
export function decodeImage(b64: string): { data: string; media_type: "image/jpeg" | "image/png" | "image/gif" | "image/webp" } {
  const m = /^data:(image\/[a-z]+);base64,/i.exec(b64);
  const data = (m ? b64.slice(m[0].length) : b64).replace(/\s+/g, "");
  const media_type = data.startsWith("iVBOR")
    ? "image/png"
    : data.startsWith("R0lGOD")
      ? "image/gif"
      : data.startsWith("UklGR")
        ? "image/webp"
        : "image/jpeg";
  return { data, media_type };
}

// ---------- server-side page fetch (Nemotron bare-URL import) ----------

/** Obvious internal hosts: never fetch them on a user's behalf. */
function isPrivateHost(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".internal") || h === "::1" || h.startsWith("fe80:") || h.startsWith("fc") || h.startsWith("fd")) return true;
  const m = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(h);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n < 0x110000 ? String.fromCodePoint(n) : all;
    }
    return ENTITIES[e.toLowerCase()] ?? all;
  });
}

/**
 * HTML → compact text for the listing model: the <title>, meta tags (og:*, product:price*, description), JSON-LD blocks
 * (marketplaces put the price there), then the visible text. Capped at maxChars.
 */
export function htmlToText(html: string, maxChars = 20_000): string {
  const parts: string[] = [];
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1];
  if (title) parts.push(`TITLE: ${decodeEntities(title).replace(/\s+/g, " ").trim()}`);
  for (const tag of html.match(/<meta\b[^>]*>/gi) ?? []) {
    const key = /\b(?:property|name|itemprop)\s*=\s*["']([^"']+)["']/i.exec(tag)?.[1];
    const content = /\bcontent\s*=\s*"([^"]*)"|\bcontent\s*=\s*'([^']*)'/i.exec(tag);
    const value = content?.[1] ?? content?.[2];
    if (key && value && /^(og:|product:|twitter:(title|description|data)|description$|price)/i.test(key)) parts.push(`META ${key}: ${decodeEntities(value).trim()}`);
  }
  for (const m of html.matchAll(/<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    parts.push(`JSON-LD: ${m[1]!.replace(/\s+/g, " ").trim().slice(0, 4000)}`);
  }
  const body = decodeEntities(
    html
      .replace(/<(script|style|noscript|svg|template|head)\b[\s\S]*?<\/\1>/gi, " ")
      .replace(/<!--[\s\S]*?-->/g, " ")
      .replace(/<(br|\/p|\/div|\/li|\/h\d|\/tr)\b[^>]*>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/[ \t\f\v\r]+/g, " ")
    .replace(/\s*\n\s*/g, "\n")
    .replace(/\n{2,}/g, "\n")
    .trim();
  if (body) parts.push(`TEXT:\n${body}`);
  return parts.join("\n").slice(0, maxChars);
}

/**
 * Fetch a listing page server-side (Nemotron has no web_fetch tool): http(s) only, no internal hosts, 8 s timeout,
 * HTML / text only, at most 3 MB read. Returns the page as compact text. Throws Error(reason) on any failure.
 */
export async function fetchListingPage(url: string, fetchImpl: typeof fetch = fetch, timeoutMs = 8000): Promise<string> {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    throw new Error("not a valid URL");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error(`unsupported protocol ${u.protocol}`);
  if (isPrivateHost(u.hostname)) throw new Error("internal host");
  const res = await fetchImpl(u, {
    redirect: "follow",
    signal: AbortSignal.timeout(timeoutMs),
    headers: {
      "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
      accept: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5",
      "accept-language": "en-US,en;q=0.9",
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const type = res.headers.get("content-type") ?? "";
  if (type && !/text\/html|application\/xhtml|text\/plain/i.test(type)) throw new Error(`not a web page (${type.split(";")[0]})`);
  const raw = (await res.text()).slice(0, 3_000_000);
  const text = /<html|<body|<head|<meta/i.test(raw) ? htmlToText(raw) : raw.replace(/\s+/g, " ").trim().slice(0, 20_000);
  if (text.length < 40) throw new Error("page is empty");
  return text;
}

// ---------- mock ----------

/** The canned demo listing (content/listings/marketplace_bike.json). */
export function cannedListing(): Listing {
  const raw = getListingFile("marketplace_bike");
  const parsed = raw ? ListingSchema.safeParse(raw) : null;
  if (parsed?.success) return parsed.data;
  // Last resort if content is missing: keep the demo alive.
  return {
    title: "56cm Aluminum Road Bike, Shimano 105",
    asking_price: 65000,
    category: "marketplace",
    condition_claims: ["like new", "new tires last month", "no scratches"],
    description: "Illustrative demo listing.",
    source: "facebook_marketplace",
  };
}

/** Mock parse: always the canned listing, keeping the caller's url (no scraping). */
export function mockParseListing(input: ListingInput): Listing {
  const listing = cannedListing();
  if (input.url) listing.url = input.url;
  return listing;
}

interface ConditionRule {
  observed: RegExp; // matches the buyer's observation
  claim: RegExp[]; // which listing claim it contradicts, most specific first
  text: string; // what was observed (canned wording)
  discount: number; // cents
  cue: string;
}

// Illustrative discounts. The first rule is also the canned answer when nothing else matches.
const RULES: ConditionRule[] = [
  { observed: /tire|tyre|tread|sidewall/i, claim: [/tire/i, /tyre/i], text: "Tires are worn, with cracks in the rear sidewall", discount: 4000, cue: "Tires worn: ask $40 off" },
  { observed: /scratch|scuff|chip|paint/i, claim: [/scratch/i, /like new/i, /mint/i], text: "Scratches on the frame", discount: 3000, cue: "Frame scratched: ask $30 off" },
  { observed: /rust|chain/i, claim: [/like new/i, /tuned/i, /maintained/i, /perfect/i], text: "Chain is rusty", discount: 1500, cue: "Rusty chain: ask $15 off" },
  { observed: /shift|derailleur|gear|skip/i, claim: [/shift/i, /tuned/i, /perfect/i], text: "Gears skip when shifting", discount: 3500, cue: "Shifting skips: ask $35 off" },
  { observed: /\bdent|\bbent\b|frame crack|cracked frame/i, claim: [/like new/i, /mint/i, /no damage/i], text: "Dent or crack in the frame", discount: 8000, cue: "Frame damage: ask $80 off" },
];

const LOOKS_FINE = /\b(no (issues|problems|damage)|looks (good|great|perfect|fine)|matches (the )?listing|as described)\b/i;

/**
 * Mock condition check: keyword rules over the observation, matched to the listing's claims.
 * If the observation names nothing recognisable (or only a photo was sent), return the canned
 * worn-tires discrepancy so the demo never stalls. An observation that says it all looks fine returns [].
 */
export function mockConditionCheck(listing: Listing, input: ConditionInput): Discrepancy[] {
  const obs = input.observation?.trim() ?? "";
  if (obs && LOOKS_FINE.test(obs) && !input.image_base64) return [];
  const claimFor = (res: RegExp[]) => {
    for (const re of res) {
      const c = listing.condition_claims.find((x) => re.test(x));
      if (c) return c;
    }
    return undefined;
  };
  const out: Discrepancy[] = [];
  for (const r of RULES) {
    if (!obs || !r.observed.test(obs)) continue;
    const claim = claimFor(r.claim);
    if (!claim || out.some((d) => d.claim === claim)) continue;
    out.push({ claim, observed: r.text, suggested_discount: r.discount, cue: r.cue });
  }
  if (out.length) return out;
  const tires = RULES[0]!;
  return [{
    claim: claimFor(tires.claim) ?? listing.condition_claims[0] ?? "Listed condition",
    observed: tires.text,
    suggested_discount: tires.discount,
    cue: tires.cue,
  }];
}
