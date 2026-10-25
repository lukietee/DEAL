// Marketplace listings (POST /listings/parse) and condition checks (POST /sessions/:id/condition-check).
// ALL money is integer cents. Mock mode serves content/listings/*.json and keyword rules; real mode uses Claude
// (AGREEMENT_MODEL, vision for screenshots / photos) — see ai/index.ts.
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
