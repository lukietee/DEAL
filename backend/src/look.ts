// "Look" mode: the buyer looks at an item through the glasses, the phone crops it and asks
//   POST /look/identify  what is it (and is it worth pricing at all)?
//   POST /look/price     a quick market price for the scanner's price window.
// Contract: ios/DEAL/Look/LookContracts.swift (LookIdentification, LookPrice).
//
// Nemotron path (NEBIUS_API_KEY + TAVILY_API_KEY, see researchProvider): identify is one NEMOTRON_VISION_MODEL
// call; price is one Tavily search plus one NEMOTRON_FAST_MODEL call that reads the snippets (~1-2 s).
// Claude path (fallback): both run on the fast CUE_MODEL; price is one call with at most 2 basic web searches.
// Prices are cached in memory per normalized name for 30 min, and concurrent requests for the same name
// share one call.
// Mock mode returns The Weeknd "Starboy" vinyl so the iOS demo works without keys.
import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { extractJson } from "./ai/index.js";
import { decodeImage } from "./listing.js";
import { formatCentsShort as formatCents } from "./money.js";
import { imagePart, type NemotronMessage } from "./nebius.js";
import { chatJson, type SearchAi } from "./research.js";
import type { TavilyResult } from "./tavily.js";

type Logger = { warn: (obj: unknown, msg?: string) => void };

export interface IdentifyInput {
  image_base64: string; // JPEG crop, <= 768 px
  hint?: string;
}

export interface LookIdentification {
  is_product: boolean;
  name: string | null;
  category: string | null;
  confidence: number; // 0..1; the scanner highlights at >= 0.6
}

export interface PriceInput {
  name: string;
  category?: string;
}

export interface LookPrice {
  name: string;
  price_low: number | null; // cents
  price_high: number | null; // cents
  summary: string; // one short line, e.g. "Used $22–30 · new $35"
  source_count: number;
}

export const PRICE_TTL_MS = 30 * 60 * 1000;
const MAX_CACHED = 500;
export const MOCK_PRICE_DELAY_MS = 300;
const MAX_SUMMARY = 60;

// ---------- model output parsing ----------

const IdentifyOutput = z.object({
  is_product: z.boolean(),
  name: z.string().nullable().optional(),
  category: z.string().nullable().optional(),
  confidence: z.number(),
});

const PriceOutput = z.object({
  price_low: z.number().nullable().optional(),
  price_high: z.number().nullable().optional(),
  summary: z.string().min(1),
  source_count: z.number().int().nonnegative().nullable().optional(),
});

/** Validate the identify model's JSON. A "product" without a name is not a product; confidence is clamped to 0..1. */
export function parseIdentification(raw: unknown): LookIdentification {
  const out = IdentifyOutput.parse(raw);
  const name = out.name?.trim() || null;
  const confidence = Math.min(1, Math.max(0, Number.isFinite(out.confidence) ? out.confidence : 0));
  if (!out.is_product || !name) return { is_product: false, name: null, category: null, confidence };
  return { is_product: true, name, category: out.category?.trim().toLowerCase() || null, confidence };
}

/** Validate the price model's JSON: whole non-negative cents, low <= high, a one-line summary. */
export function parsePrice(name: string, raw: unknown, maxSources = Infinity): LookPrice {
  const out = PriceOutput.parse(raw);
  const cents = (v: number | null | undefined) => (v != null && Number.isFinite(v) && v > 0 ? Math.round(v) : null);
  let low = cents(out.price_low);
  let high = cents(out.price_high);
  if (low != null && high != null && low > high) [low, high] = [high, low];
  const line = out.summary.replace(/\s+/g, " ").trim();
  return {
    name,
    price_low: low,
    price_high: high,
    summary: line.length > MAX_SUMMARY ? `${line.slice(0, MAX_SUMMARY - 1).trimEnd()}…` : line,
    source_count: Math.min(out.source_count ?? 0, maxSources),
  };
}

/** Cache key: "The Weeknd – Starboy (2×LP Vinyl)" and "the weeknd starboy 2xlp vinyl" are the same item. */
export function normalizeName(name: string): string {
  return name
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/×/g, "x")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

/** Real-mode model/API failure; Deal maps it to 502 {error}. */
export class LookError extends Error {}

// ---------- mock ----------

export const MOCK_IDENTIFICATION: LookIdentification = {
  is_product: true,
  name: "The Weeknd – Starboy (2×LP vinyl)",
  category: "vinyl",
  confidence: 0.92,
};

/** Mock price: Starboy's demo numbers, or a range derived from the name (same name, same answer). */
export function mockPrice(name: string): LookPrice {
  if (normalizeName(name).includes("starboy")) {
    return { name, price_low: 2500, price_high: 3500, summary: "Used $25–35 · new $40", source_count: 4 };
  }
  let h = 0;
  for (const ch of normalizeName(name)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  const low = (20 + (h % 180)) * 100; // $20–199
  const high = Math.round(low * 1.4 / 100) * 100;
  return { name, price_low: low, price_high: high, summary: `Used ${formatCents(low)}–${formatCents(high).replace("$", "")} (demo data)`, source_count: 3 };
}

// ---------- prompts ----------

export const IDENTIFY_SYSTEM = [
  `You identify the item in a cropped photo from a buyer's smart-glasses camera, so the app can show its market price.`,
  ``,
  `is_product is true only for a specific item a buyer could plausibly look up and price: records and CDs, sneakers, bikes,`,
  `electronics, cameras, instruments, watches, collectibles, toys, books, branded bags or clothing (with visible branding), and the like.`,
  `is_product is false for people, faces, hands, pets, walls, floors, ceilings, plain or generic furniture, screens showing an app or UI,`,
  `text or documents, food, and frames that are blurry, dark, cut off or that you cannot identify with confidence.`,
  ``,
  `name: as specific as you can honestly tell from the photo (artist and title, brand and model, edition, format), e.g.`,
  `"The Weeknd – Starboy (2×LP vinyl)", "Nike Air Jordan 1 Retro High OG 'Chicago'", "Sony WH-1000XM5 headphones (black)".`,
  `For media (records, CDs, games), include the physical format you can see or infer, e.g. "(vinyl LP)", "(CD)".`,
  `Never a bare generic name like "vinyl record" or "sneakers": if you cannot tell more than that, set is_product false.`,
  `category: one lowercase word or two, e.g. "vinyl", "sneakers", "bike", "electronics", "collectible", "clothing", "instrument".`,
  `confidence: 0 to 1, how sure you are of the name (not just that it is a product).`,
  ``,
  `Reply with ONLY a JSON object: {"is_product": true|false, "name": string|null, "category": string|null, "confidence": number}`,
].join("\n");

export function identifyUserPrompt(hint?: string): string {
  return hint ? `Identify the item. The app's hint (may be wrong): ${hint}` : "Identify the item.";
}

export function pricePrompt(input: PriceInput): string {
  return [
    `Quick market price check for: ${input.name}${input.category ? ` (category: ${input.category})` : ""}.`,
    `A buyer is looking at it right now and needs a number in seconds. Do ONE web search (two at most) for current used / sold`,
    `and new prices in the US, e.g. eBay sold, Discogs, StockX, Reverb, retailer pages. Do not open pages.`,
    ``,
    `Reply with ONLY a JSON object:`,
    `{"price_low": <integer cents, typical used low>, "price_high": <integer cents, typical used high>,`,
    ` "summary": "<one line, at most 40 characters, e.g. \\"Used $22–30 · new $35\\">", "source_count": <pages your numbers came from>}`,
    `Prices are integer cents ($25 = 2500). If you found no usable prices, use null for both and say so in the summary.`,
  ].join("\n");
}

/** Nemotron path: the same ask, answered from one Tavily search's snippets. */
export function priceFromResultsPrompt(input: PriceInput, results: TavilyResult[]): string {
  const block = results
    .map((r, i) => `[${i + 1}] ${r.title}\n${r.url}\n${r.content.replace(/\s+/g, " ").trim().slice(0, 500)}`)
    .join("\n\n");
  return [
    `Quick market price check for: ${input.name}${input.category ? ` (category: ${input.category})` : ""}.`,
    `A buyer is looking at it right now. Current US used / sold and new prices from a web search (Tavily):`,
    ``,
    block || "(no results)",
    ``,
    `Use ONLY these results; never invent a price. The range is what an ordinary used copy typically sells for: skip outliers`,
    `and limited, signed or rare editions unless the item is one. Mention the new price in the summary if you see it.`,
    `Reply with ONLY a JSON object:`,
    `{"price_low": <integer cents, typical used low>, "price_high": <integer cents, typical used high>,`,
    ` "summary": "<one line, at most 40 characters, e.g. \\"Used $22–30 · new $35\\">", "source_count": <how many results your numbers came from>}`,
    `Prices are integer cents ($25 = 2500). If no result has a usable price, use null for both and say so in the summary.`,
  ].join("\n");
}

// ---------- runner ----------

export interface LookDeps {
  mockMode: boolean;
  client: Anthropic | null; // Claude path
  model: string; // CUE_MODEL: fast, vision-capable
  /** Nemotron + Tavily path; takes precedence over `client` when set. */
  search?: SearchAi | null;
  log: Logger;
  ttlMs?: number;
  now?: () => number; // injectable clock for cache tests
}

function textOf(msg: Anthropic.Message): string {
  if (msg.stop_reason === "refusal") throw new Error("model refused the request");
  return msg.content.filter((b): b is Anthropic.TextBlock => b.type === "text").map((b) => b.text).join("");
}

export class LookRunner {
  private cache = new Map<string, { value: LookPrice; expires: number }>();
  private inflight = new Map<string, Promise<LookPrice>>();
  private ttlMs: number;
  private now: () => number;

  constructor(private deps: LookDeps) {
    this.ttlMs = deps.ttlMs ?? PRICE_TTL_MS;
    this.now = deps.now ?? Date.now;
  }

  private get real() { return !this.deps.mockMode && (!!this.deps.search || !!this.deps.client); }

  stopAll() {
    this.cache.clear();
    this.inflight.clear();
  }

  /** POST /look/identify. Real mode: one vision call, zod-validated, retried once. Failure throws LookError (502). */
  async identify(input: IdentifyInput): Promise<LookIdentification> {
    if (!this.real) return { ...MOCK_IDENTIFICATION };
    if (this.deps.search) return this.nemotronIdentify(input, this.deps.search);
    const { data, media_type } = decodeImage(input.image_base64);
    const user: Anthropic.ContentBlockParam[] = [
      { type: "image", source: { type: "base64", media_type, data } },
      { type: "text", text: identifyUserPrompt(input.hint) },
    ];
    const send = (messages: Anthropic.MessageParam[]) =>
      this.deps.client!.messages.create(
        { model: this.deps.model, max_tokens: 1000, system: IDENTIFY_SYSTEM, output_config: { effort: "low" }, messages },
        { timeout: 15_000 },
      );
    let firstText = "";
    try {
      firstText = textOf(await send([{ role: "user", content: user }]));
      return parseIdentification(extractJson(firstText));
    } catch (err) {
      if (!firstText) return this.fail("identify", err);
      this.deps.log.warn({ err: String(err), model: this.deps.model }, "invalid look identify JSON, retrying once");
      try {
        const retry = await send([
          { role: "user", content: user },
          { role: "assistant", content: firstText },
          { role: "user", content: `That was not valid. Error: ${String(err).slice(0, 300)}. Reply with ONLY the corrected JSON object.` },
        ]);
        return parseIdentification(extractJson(textOf(retry)));
      } catch (err2) {
        return this.fail("identify", err2);
      }
    }
  }

  /** NEMOTRON_VISION_MODEL, same system prompt; no JSON mode (the VL model answers ~2x faster without it). */
  private async nemotronIdentify(input: IdentifyInput, ai: SearchAi): Promise<LookIdentification> {
    const { data, media_type } = decodeImage(input.image_base64);
    const messages: NemotronMessage[] = [
      { role: "system", content: IDENTIFY_SYSTEM },
      { role: "user", content: [imagePart(data, media_type), { type: "text", text: identifyUserPrompt(input.hint) }] },
    ];
    try {
      return await chatJson(ai, ai.visionModel, messages, parseIdentification, { maxTokens: 300, timeoutMs: 15_000, json: false });
    } catch (err) {
      return this.fail("identify", err);
    }
  }

  /** POST /look/price. Cached per normalized name (TTL 30 min); identical concurrent requests share one call. */
  async price(input: PriceInput): Promise<LookPrice> {
    const key = normalizeName(input.name);
    const hit = this.cache.get(key);
    if (hit && hit.expires > this.now()) return { ...hit.value, name: input.name };
    if (hit) this.cache.delete(key);

    let pending = this.inflight.get(key);
    if (!pending) {
      pending = this.lookupPrice(input).then((value) => {
        if (this.inflight.get(key) === pending) {
          this.cache.set(key, { value, expires: this.now() + this.ttlMs });
          if (this.cache.size > MAX_CACHED) this.cache.delete(this.cache.keys().next().value!);
        }
        return value;
      });
      this.inflight.set(key, pending);
      // Failures are not cached: the next request tries again.
      void pending.finally(() => { if (this.inflight.get(key) === pending) this.inflight.delete(key); }).catch(() => undefined);
    }
    return { ...(await pending), name: input.name };
  }

  private async lookupPrice(input: PriceInput): Promise<LookPrice> {
    if (!this.real) {
      await new Promise((r) => setTimeout(r, MOCK_PRICE_DELAY_MS));
      return mockPrice(input.name);
    }
    if (this.deps.search) return this.nemotronPrice(input, this.deps.search);
    // Basic web search (Haiku-class models don't take the dynamic-filtering variant), no page fetches.
    const tools: Anthropic.ToolUnion[] = [{ type: "web_search_20250305", name: "web_search", max_uses: 2 }];
    const messages: Anthropic.MessageParam[] = [{ role: "user", content: pricePrompt(input) }];
    const blocks: Anthropic.ContentBlock[] = [];
    const send = () =>
      this.deps.client!.messages.create(
        { model: this.deps.model, max_tokens: 2000, output_config: { effort: "low" }, tools, messages },
        { timeout: 20_000 },
      );
    try {
      let msg = await send();
      blocks.push(...msg.content);
      // Server tools can pause a long turn; re-send with the assistant content so far to let it continue.
      for (let i = 0; msg.stop_reason === "pause_turn" && i < 2; i++) {
        messages.push({ role: "assistant", content: msg.content });
        msg = await send();
        blocks.push(...msg.content);
      }
      const results = new Set<string>();
      for (const b of blocks) {
        if (b.type === "web_search_tool_result" && Array.isArray(b.content)) for (const r of b.content) results.add(r.url);
      }
      return parsePrice(input.name, extractJson(textOf(msg)), results.size);
    } catch (err) {
      return this.fail("price", err);
    }
  }

  /** One advanced Tavily search (2 credits; its snippets carry prices), then NEMOTRON_FAST_MODEL reads them. */
  private async nemotronPrice(input: PriceInput, ai: SearchAi): Promise<LookPrice> {
    try {
      const res = await ai.tavily.search({ query: `${input.name} price used sold`, maxResults: 6, depth: "advanced", timeoutMs: 8000 });
      const prompt = priceFromResultsPrompt(input, res.results);
      return await chatJson(ai, ai.fastModel, [{ role: "user", content: prompt }], (raw) => parsePrice(input.name, raw, res.results.length), { maxTokens: 300, timeoutMs: 10_000 });
    } catch (err) {
      return this.fail("price", err);
    }
  }

  private fail(what: string, err: unknown): never {
    this.deps.log.warn({ err: String(err).slice(0, 300) }, `look ${what} failed`);
    throw new LookError(what === "identify" ? "Couldn't identify that item. Try again." : "Couldn't price that item. Try again.");
  }
}
