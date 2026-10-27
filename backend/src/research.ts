// Live market research + suggested phrases.
//
// Research: when a session starts, three research agents run in parallel (comparable prices, known issues,
// fair price / negotiation leverage). Real mode has two providers (see researchProvider):
//   - Nemotron (NEBIUS_API_KEY + TAVILY_API_KEY): each agent runs 2-3 templated Tavily searches in parallel,
//     then one NEMOTRON_MODEL call turns the snippets into summary / headline / price range / per-source notes.
//     All three agents finish in ~3-5 s.
//   - Claude (fallback): each agent is a Claude call with the server-side web_search tool, streamed (~15-25 s).
// Both fill the same agent fields live (status, activity, queries, sources) so the phone and the glasses
// animate, then fetch the og:image of the top result pages so the app can show pictures. In mock mode the
// agents replay content/comparables on a timer so the UI still animates.
//
// Suggested phrases: after every transcript line, 2-3 full sentences the buyer could say next
// (NEMOTRON_FAST_MODEL, or CUE_MODEL on the Claude path).
//
// State lives in memory on the Deal (like script runs) and is returned by GET /sessions/:id.
import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import type { Config } from "./config.js";
import { getComparables, normalizeCategory } from "./content.js";
import { formatCentsShort as formatCents } from "./money.js";
import { NemotronClient, type NemotronMessage } from "./nebius.js";
import { TavilyClient, type TavilyResponse, type TavilyResult } from "./tavily.js";
import type { DealEvent, Session } from "./types.js";

export type AgentStatus = "queued" | "searching" | "reading" | "done" | "error";

export interface ResearchSource {
  title: string;
  url: string;
  price: number | null; // cents
  note: string | null;
  image_url: string | null;
}

export interface ResearchAgent {
  id: "comps" | "issues" | "price";
  title: string;
  status: AgentStatus;
  activity: string; // one-line "what it's doing now", shown under the title
  queries: string[];
  sources: ResearchSource[];
  summary: string | null;
  /** ≤ ~24 chars for the glasses research strip, e.g. "$590–725 nearby", "Check tire wear". */
  headline: string | null;
  price_low: number | null; // cents
  price_high: number | null; // cents
  started_at: string | null;
  finished_at: string | null;
  error: string | null;
}

export interface ResearchState {
  item: string;
  status: "running" | "done";
  agents: ResearchAgent[];
  started_at: string;
}

export interface Suggestions {
  for_event_id: string | null;
  phrases: { text: string; why: string }[];
  updated_at: string;
}

type Logger = { warn: (obj: unknown, msg?: string) => void };
const now = () => new Date().toISOString();

interface AgentSpec {
  id: ResearchAgent["id"];
  title: string;
  goal: string;
  /** Tavily path: the agent's searches (run in parallel) for a short item name. */
  queries: (item: string) => string[];
  depth: "basic" | "advanced"; // advanced = 2 credits, but snippets carry the prices
}

const AGENTS: AgentSpec[] = [
  {
    id: "comps",
    title: "Comparable listings",
    goal: "Find 3-5 current or recent listings/sales for the same or a very similar used item, with their prices. Prefer marketplace, eBay sold, Craigslist, OfferUp, dealer or classifieds pages.",
    queries: (item) => [`${item} used for sale price`, `${item} sold listings eBay`, `${item} Facebook Marketplace Craigslist OfferUp`],
    depth: "advanced",
  },
  {
    id: "issues",
    title: "Known issues & wear",
    goal: "Find the common problems, wear items and inspection points for this item that a buyer should check in person, and roughly what each costs to fix.",
    queries: (item) => [`${item} common problems`, `${item} what to check before buying used`],
    depth: "basic",
  },
  {
    id: "price",
    title: "Fair price & leverage",
    goal: "Estimate a fair used price range for this item from price guides, reviews or sold data, and note any negotiation leverage (new-model discounts, depreciation, seasonality).",
    queries: (item) => [`${item} used value price guide`, `${item} new price MSRP review`],
    depth: "advanced",
  },
];

const ResearchOutput = z.object({
  summary: z.string(),
  headline: z.string().nullable().optional(),
  price_low: z.number().int().nullable().optional(),
  price_high: z.number().int().nullable().optional(),
  sources: z
    .array(z.object({ title: z.string(), url: z.string(), price: z.number().int().nullable().optional(), note: z.string().nullable().optional() }))
    .default([]),
});

const PhrasesOutput = z.object({
  phrases: z.array(z.object({ text: z.string(), why: z.string() })).min(1).max(3),
});

function newAgent(a: AgentSpec): ResearchAgent {
  return {
    id: a.id, title: a.title, status: "queued", activity: "Waiting to start", queries: [], sources: [], summary: null, headline: null,
    price_low: null, price_high: null, started_at: null, finished_at: null, error: null,
  };
}

export function itemDescription(s: Session): string {
  const l = s.listing;
  if (!l) return s.item;
  const claims = l.condition_claims.length ? ` (listing claims: ${l.condition_claims.join("; ")})` : "";
  return `${l.title}${claims}`;
}

/** Short search name: the listing title (no claims) or the item, at most ~120 chars. */
export function searchName(s: Pick<Session, "item" | "listing">): string {
  const name = (s.listing?.title ?? s.item).replace(/\s+/g, " ").trim();
  return name.length > 120 ? name.slice(0, 120).replace(/\s+\S*$/, "") : name;
}

function extractJson(text: string): unknown {
  const cleaned = text.replace(/```(?:json)?/gi, "").trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start < 0 || end <= start) throw new Error("no JSON object in model output");
  return JSON.parse(cleaned.slice(start, end + 1));
}

// ---------- og:image ----------

const imageCache = new Map<string, string | null>();

/** True when the URL really serves an image (so the app never shows a broken thumbnail). */
async function isImage(url: string, timeoutMs: number): Promise<boolean> {
  try {
    const res = await fetch(url, { method: "GET", signal: AbortSignal.timeout(timeoutMs), headers: { range: "bytes=0-0" } });
    void res.body?.cancel();
    return res.ok && (res.headers.get("content-type") ?? "").startsWith("image/");
  } catch {
    return false;
  }
}

/** Best-effort main image of a web page (og:image / twitter:image), absolute URL or null. */
export async function fetchPageImage(pageUrl: string, timeoutMs = 4000): Promise<string | null> {
  if (imageCache.has(pageUrl)) return imageCache.get(pageUrl) ?? null;
  let result: string | null = null;
  try {
    const res = await fetch(pageUrl, {
      signal: AbortSignal.timeout(timeoutMs),
      redirect: "follow",
      headers: {
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
        accept: "text/html,application/xhtml+xml",
      },
    });
    if (res.ok && (res.headers.get("content-type") ?? "").includes("html")) {
      const html = (await res.text()).slice(0, 400_000);
      const metas = [...html.matchAll(/<meta\b[^>]*>/gi)].map((m) => m[0]);
      for (const key of ["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]) {
        const tag = metas.find((t) => new RegExp(`(?:property|name)\\s*=\\s*["']${key.replace(/[:]/g, "\\:")}["']`, "i").test(t));
        const content = tag?.match(/content\s*=\s*["']([^"']+)["']/i)?.[1];
        if (content) {
          const abs = new URL(content.replace(/&amp;/g, "&"), res.url || pageUrl).toString();
          if (abs.startsWith("https://") && !/\/(undefined|null)$/.test(abs) && (await isImage(abs, timeoutMs))) { result = abs; break; }
        }
      }
    }
  } catch {
    result = null;
  }
  imageCache.set(pageUrl, result);
  return result;
}

// ---------- one Claude research agent (web search) ----------

export interface AgentContext {
  item: string;
  category: string;
  asking_price: number | null; // cents
  target_price: number | null; // cents
  live: boolean; // true = mid-negotiation (session agents); false = before the meetup (preview)
}

/** The opening of every agent prompt: who the buyer is, the numbers, the agent's job. */
function agentBrief(spec: AgentSpec, ctx: AgentContext): string[] {
  return [
    ctx.live
      ? `You are one of three research agents helping a buyer who is negotiating in person, right now, for: ${ctx.item}.`
      : `You are a research agent helping a buyer who is about to meet a seller in person to buy: ${ctx.item}.`,
    [
      `Asking price: ${ctx.asking_price != null ? formatCents(ctx.asking_price) : "unknown"}.`,
      ctx.target_price != null ? `Buyer's target: ${formatCents(ctx.target_price)}.` : "",
      `Category: ${ctx.category}.`,
    ].filter(Boolean).join(" "),
    ``,
    `Your job: ${spec.goal}`,
  ];
}

const OUTPUT_SPEC = [
  `{"summary": "<= 2 short sentences a buyer can act on", "headline": "<= 4 words for a heads-up display, e.g. \"$590-725 nearby\" or \"Check tire wear\"", "price_low": <integer cents or null>, "price_high": <integer cents or null>,`,
  ` "sources": [{"title": "...", "url": "<a page URL you actually found>", "price": <integer cents or null>, "note": "<= 8 words"}]}`,
  `List up to 5 sources, best first. Prices are integer cents (e.g. $520 = 52000).`,
];

/** Copy a validated model answer onto the agent: its picks first (they carry price/note), other hits after. */
function applyOutput(agent: ResearchAgent, out: z.infer<typeof ResearchOutput>, known?: Map<string, string>) {
  const picked: ResearchSource[] = out.sources
    .filter((s) => /^https?:\/\//.test(s.url) && (!known || known.has(s.url)) )
    .filter((s, i, all) => all.findIndex((o) => o.url === s.url) === i)
    .map((s) => ({ title: known?.get(s.url) ?? s.title, url: s.url, price: s.price ?? null, note: s.note ?? null, image_url: null }));
  const rest = agent.sources.filter((s) => !picked.some((p) => p.url === s.url));
  agent.sources = [...picked, ...rest].slice(0, 8);
  agent.summary = out.summary;
  agent.price_low = out.price_low ?? null;
  agent.price_high = out.price_high ?? null;
  if (agent.price_low != null && agent.price_high != null && agent.price_low > agent.price_high) {
    [agent.price_low, agent.price_high] = [agent.price_high, agent.price_low];
  }
  agent.headline = agentHeadline(out.headline, agent);
}

/** Run one research agent with Claude + server-side web search, filling `agent` live as blocks stream in. */
export async function runClaudeAgent(client: Anthropic, model: string, spec: AgentSpec, agent: ResearchAgent, ctx: AgentContext) {
  agent.status = "searching";
  agent.started_at = now();
  agent.activity = "Planning searches";
  const prompt = [
    ...agentBrief(spec, ctx),
    ctx.live ? `Use web search (at most 3 searches). Be quick; the buyer is mid-conversation.` : `Use web search (at most 3 searches). Be quick; the buyer is waiting on this screen.`,
    ``,
    `Finish with ONLY a JSON object, no prose around it:`,
    ...OUTPUT_SPEC,
  ].join("\n");

  const stream = client.beta.messages.stream({
    model,
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "low" },
    tools: [{ type: "web_search_20260209", name: "web_search", max_uses: 3 }],
    messages: [{ role: "user", content: prompt }],
  } as Anthropic.Beta.Messages.MessageCreateParamsStreaming);

  // Live progress: each finished content block tells us what the agent just did.
  stream.on("contentBlock", (block) => {
    const b = block as unknown as { type: string; input?: { query?: string }; content?: unknown };
    if (b.type === "server_tool_use" && b.input?.query) {
      agent.queries.push(b.input.query);
      agent.status = "searching";
      agent.activity = `Searching "${b.input.query}"`;
    } else if (b.type === "web_search_tool_result" && Array.isArray(b.content)) {
      const results = b.content as { type: string; title?: string; url?: string }[];
      for (const r of results) {
        if (r.type !== "web_search_result" || !r.url || agent.sources.some((s) => s.url === r.url)) continue;
        agent.sources.push({ title: r.title ?? r.url, url: r.url, price: null, note: null, image_url: null });
      }
      agent.status = "reading";
      agent.activity = `Reading ${agent.sources.length} pages`;
    } else if (b.type === "text") {
      agent.activity = "Writing summary";
    }
  });

  const msg = await stream.finalMessage();
  if (msg.stop_reason === "refusal") throw new Error("model declined the research request");
  const text = msg.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("");
  applyOutput(agent, ResearchOutput.parse(extractJson(text)));

  agent.activity = "Pulling images";
  await Promise.all(
    agent.sources.slice(0, 4).map(async (s) => { s.image_url = await fetchPageImage(s.url); }),
  );
  agent.status = "done";
  agent.activity = `${agent.queries.length} searches · ${agent.sources.length} sources`;
  agent.finished_at = now();
}

// ---------- one Nemotron research agent (Tavily search) ----------

/** The Nemotron + Tavily path (Nebius Token Factory). Interfaces, not classes, so tests can pass fakes. */
export interface SearchAi {
  tavily: Pick<TavilyClient, "search">;
  nemotron: Pick<NemotronClient, "chat">;
  model: string; // NEMOTRON_MODEL: research synthesis
  fastModel: string; // NEMOTRON_FAST_MODEL: suggested phrases, Look price
  visionModel: string; // NEMOTRON_VISION_MODEL: Look identify
}

export function createSearchAi(cfg: Config): SearchAi {
  return {
    tavily: new TavilyClient(cfg.tavilyApiKey),
    nemotron: new NemotronClient(cfg.nebiusApiKey, cfg.nebiusBaseUrl),
    model: cfg.nemotronModel,
    fastModel: cfg.nemotronFastModel,
    visionModel: cfg.nemotronVisionModel,
  };
}

export type ResearchProvider = "nemotron" | "claude" | "mock";

/**
 * Research / Look provider, same rule as the core AI: Nemotron when NEBIUS_API_KEY is set (and, for search,
 * TAVILY_API_KEY) unless AI_PROVIDER=claude; else Claude when ANTHROPIC_API_KEY is set; else mock.
 */
export function researchProvider(cfg: Pick<Config, "mockMode" | "aiProvider" | "nebiusApiKey" | "tavilyApiKey" | "anthropicApiKey">): ResearchProvider {
  if (cfg.mockMode) return "mock";
  if (cfg.nebiusApiKey && cfg.tavilyApiKey && cfg.aiProvider !== "claude") return "nemotron";
  if (cfg.anthropicApiKey) return "claude";
  return "mock";
}

const SNIPPET_CHARS = 600;
const MAX_RESULTS = 10; // per agent, after dedupe, fed to the model

/** Tavily results as numbered blocks for the synthesis prompt. */
function resultsBlock(results: TavilyResult[]): string {
  return results
    .map((r, i) => `[${i + 1}] ${r.title}\n${r.url}\n${r.content.replace(/\s+/g, " ").trim().slice(0, SNIPPET_CHARS)}`)
    .join("\n\n");
}

/** One JSON chat call, retried once with the validation error if the reply doesn't parse. */
export async function chatJson<T>(ai: SearchAi, model: string, messages: NemotronMessage[], parse: (raw: unknown) => T, opts: { maxTokens: number; timeoutMs: number; json?: boolean }): Promise<T> {
  const send = (msgs: NemotronMessage[]) =>
    ai.nemotron.chat({ model, messages: msgs, maxTokens: opts.maxTokens, temperature: 0.2, json: opts.json ?? true, timeoutMs: opts.timeoutMs });
  const first = (await send(messages)).text;
  try {
    return parse(extractJson(first));
  } catch (err) {
    const retry = await send([
      ...messages,
      { role: "assistant", content: first },
      { role: "user", content: `That was not valid. Error: ${String(err).slice(0, 300)}. Reply with ONLY the corrected JSON object.` },
    ]);
    return parse(extractJson(retry.text));
  }
}

/**
 * Run one research agent on Tavily + Nemotron, filling `agent` live: its searches run in parallel (sources
 * appear as each one lands), og:images are fetched while one NEMOTRON_MODEL call writes the summary.
 * Throws if every search fails or the model output is invalid twice.
 */
export async function runNemotronAgent(ai: SearchAi, spec: AgentSpec, agent: ResearchAgent, ctx: AgentContext & { search_name: string }) {
  agent.status = "searching";
  agent.started_at = now();
  agent.activity = "Planning searches";
  const queries = spec.queries(ctx.search_name);
  agent.queries.push(...queries);
  agent.activity = `Searching "${queries[0]}"${queries.length > 1 ? ` +${queries.length - 1} more` : ""}`;

  const results: TavilyResult[] = [];
  const images: string[] = [];
  const settled = await Promise.allSettled(
    queries.map(async (query) => {
      const res: TavilyResponse = await ai.tavily.search({ query, maxResults: 5, depth: spec.depth, includeImages: spec.id === "comps", timeoutMs: 8000 });
      for (const r of res.results) {
        if (!r.url || results.some((o) => o.url === r.url)) continue;
        results.push(r);
        agent.sources.push({ title: r.title || r.url, url: r.url, price: null, note: null, image_url: null });
      }
      images.push(...res.images.filter((u) => u.startsWith("https://") && !images.includes(u)));
      agent.status = "reading";
      agent.activity = `Reading ${agent.sources.length} pages`;
    }),
  );
  if (settled.every((r) => r.status === "rejected")) throw (settled[0] as PromiseRejectedResult).reason;

  // Best results first (Tavily's relevance score), for the prompt and the fallback source order.
  results.sort((a, b) => b.score - a.score);
  const top = results.slice(0, MAX_RESULTS);
  agent.sources = results.map((r) => ({ title: r.title || r.url, url: r.url, price: null, note: null, image_url: null }));
  const pageImages = new Map(top.slice(0, 5).map((r) => [r.url, fetchPageImage(r.url, 2500)] as const));

  agent.activity = "Writing summary";
  const prompt = [
    ...agentBrief(spec, ctx),
    ``,
    top.length ? `Web search results (Tavily):\n\n${resultsBlock(top)}` : `The web search found nothing.`,
    ``,
    `Use ONLY these results; never invent a source, URL or price. If they hold no usable prices, use null.`,
    `Reply with ONLY a JSON object:`,
    ...OUTPUT_SPEC,
  ].join("\n");
  const out = await chatJson(ai, ai.model, [{ role: "user", content: prompt }], (raw) => ResearchOutput.parse(raw), { maxTokens: 1200, timeoutMs: 20_000 });
  applyOutput(agent, out, new Map(top.map((r) => [r.url, r.title || r.url])));

  agent.activity = "Pulling images";
  await Promise.all(agent.sources.slice(0, 4).map(async (s) => { s.image_url = (await pageImages.get(s.url)) ?? null; }));
  // Pages without an og:image get the search's own item photos (comps only), checked like og:images.
  const spare = images.filter((u) => !agent.sources.some((s) => s.image_url === u));
  for (const s of agent.sources.slice(0, 4)) {
    if (s.image_url) continue;
    let url: string | undefined;
    while ((url = spare.shift()) && !(await isImage(url, 2500)));
    if (!url) break;
    s.image_url = url;
  }
  agent.status = "done";
  agent.activity = `${agent.queries.length} searches · ${agent.sources.length} sources`;
  agent.finished_at = now();
}

/** Glasses headline: the model's if short enough, else the price range, else the summary's opening words. */
export function agentHeadline(raw: string | null | undefined, a: Pick<ResearchAgent, "summary" | "price_low" | "price_high">): string | null {
  const max = 24;
  const clean = raw?.trim().replace(/[.!]+$/, "");
  if (clean && clean.length <= max) return clean;
  if (a.price_low != null && a.price_high != null) return `${formatCents(a.price_low)}–${formatCents(a.price_high)}`;
  const text = (clean || a.summary || "").trim();
  if (!text) return null;
  if (text.length <= max) return text.replace(/[.!]+$/, "");
  const cut = text.slice(0, max - 1);
  return `${cut.slice(0, cut.lastIndexOf(" ") > 8 ? cut.lastIndexOf(" ") : cut.length).replace(/[,;:]$/, "")}…`;
}

// ---------- pre-session market check (POST /research/preview) ----------

export interface PreviewInput {
  item: string;
  category?: string;
  asking_price?: number; // cents
}

/** Contract for the iOS B2 screen. Keep these field names. */
export interface ResearchPreview {
  summary: string | null;
  price_low: number | null; // cents
  price_high: number | null; // cents
  sources: ResearchSource[]; // {title, url, price, note, image_url}
}

export const MOCK_PREVIEW_DELAY_MS = 1500;

type CompListing = { title: string; price: number; source?: string; note?: string; condition?: string };

function comparableListings(category: string): CompListing[] {
  const comps = (() => { try { return getComparables(category) ?? getComparables("other"); } catch { return null; } })();
  return ((comps as { listings?: unknown[] } | null)?.listings ?? []) as CompListing[];
}

/** Mock preview: the category's illustrative comparables, in the preview shape. */
export function mockPreview(category: string, askingPrice: number | null): ResearchPreview {
  const listings = comparableListings(category);
  const prices = listings.map((l) => l.price).sort((a, b) => a - b);
  const low = prices[Math.floor(prices.length * 0.25)] ?? null;
  const high = prices[Math.floor(prices.length * 0.75)] ?? null;
  const asking = askingPrice != null && high != null && askingPrice > high ? ` Asking ${formatCents(askingPrice)} is above most of them.` : "";
  return {
    summary: listings.length
      ? `${listings.length} similar listings run ${formatCents(prices[0]!)}–${formatCents(prices[prices.length - 1]!)} (illustrative).${asking}`
      : null,
    price_low: low,
    price_high: high,
    sources: listings.slice(0, 5).map((l, i) => ({
      title: l.title, url: `https://example.com/demo-listing-${i + 1}`, price: l.price, note: l.note ?? l.condition ?? null, image_url: null,
    })),
  };
}

// ---------- research runner ----------

export interface ResearchDeps {
  mockMode: boolean;
  client: Anthropic | null; // Claude path
  model: string; // Claude research agents (web search)
  cueModel: string; // Claude suggested phrases
  /** Nemotron + Tavily path; takes precedence over `client` when set. */
  search?: SearchAi | null;
  log: Logger;
}

export class ResearchRunner {
  private states = new Map<string, ResearchState>();
  private suggestions = new Map<string, Suggestions>();
  private suggestionSeq = new Map<string, number>();
  private timers = new Set<NodeJS.Timeout>();

  constructor(private deps: ResearchDeps) {}

  research(sessionId: string): ResearchState | null { return this.states.get(sessionId) ?? null; }

  get provider(): ResearchProvider {
    if (this.deps.mockMode) return "mock";
    return this.deps.search ? "nemotron" : this.deps.client ? "claude" : "mock";
  }
  suggestionsFor(sessionId: string): Suggestions | null { return this.suggestions.get(sessionId) ?? null; }

  stopAll() {
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.states.clear();
    this.suggestions.clear();
  }

  /** Start (or restart) the three research agents for a session. Returns immediately. */
  start(session: Session): ResearchState {
    const state: ResearchState = { item: itemDescription(session), status: "running", agents: AGENTS.map(newAgent), started_at: now() };
    this.states.set(session.id, state);
    const runs = AGENTS.map((spec, i) => {
      const agent = state.agents[i]!;
      const run = this.provider === "mock" ? this.mockAgent(session, agent, i) : this.realAgent(session, spec, agent);
      return run.catch((err) => {
        agent.status = "error";
        agent.error = String(err).slice(0, 300);
        agent.activity = "Failed";
        agent.finished_at = now();
        this.deps.log.warn({ err: String(err), agent: agent.id }, "research agent failed");
      });
    });
    void Promise.all(runs).then(() => { if (this.states.get(session.id) === state) state.status = "done"; });
    return state;
  }

  private sleep(ms: number) {
    return new Promise<void>((resolve) => { const t = setTimeout(() => { this.timers.delete(t); resolve(); }, ms); this.timers.add(t); });
  }

  private async realAgent(session: Session, spec: AgentSpec, agent: ResearchAgent) {
    await this.runAgent(spec, agent, {
      item: itemDescription(session),
      search_name: searchName(session),
      category: session.category,
      asking_price: session.asking_price,
      target_price: session.target_price,
      live: true,
    });
  }

  private runAgent(spec: AgentSpec, agent: ResearchAgent, ctx: AgentContext & { search_name: string }) {
    return this.deps.search
      ? runNemotronAgent(this.deps.search, spec, agent, ctx)
      : runClaudeAgent(this.deps.client!, this.deps.model, spec, agent, ctx);
  }

  /**
   * POST /research/preview: one "comparable listings" agent, no session, blocking until it finishes.
   * Real mode: Tavily + Nemotron (or Claude + web search), same code as the session agents, then og:images. Mock mode: the
   * category's content/comparables listings after ~1.5 s. A failed agent returns nulls (and any search hits).
   */
  async preview(input: PreviewInput): Promise<ResearchPreview> {
    const category = normalizeCategory(input.category ?? "") || "marketplace";
    if (this.provider === "mock") {
      await new Promise((r) => setTimeout(r, MOCK_PREVIEW_DELAY_MS));
      return mockPreview(category, input.asking_price ?? null);
    }
    const spec = AGENTS.find((a) => a.id === "comps")!;
    const agent = newAgent(spec);
    try {
      await this.runAgent(spec, agent, {
        item: input.item, search_name: searchName({ item: input.item, listing: null }), category,
        asking_price: input.asking_price ?? null, target_price: null, live: false,
      });
    } catch (err) {
      this.deps.log.warn({ err: String(err) }, "research preview failed");
      return { summary: null, price_low: null, price_high: null, sources: agent.sources.slice(0, 5) };
    }
    return { summary: agent.summary, price_low: agent.price_low, price_high: agent.price_high, sources: agent.sources };
  }

  /** Mock mode: replay content/comparables with realistic pacing so the UI animates without keys. */
  private async mockAgent(session: Session, agent: ResearchAgent, index: number) {
    const comps = (() => { try { return getComparables(session.category); } catch { return null; } })();
    const listings = ((comps as { listings?: unknown[] } | null)?.listings ?? []) as { title: string; price: number; source?: string; note?: string; condition?: string }[];
    const item = session.listing?.title ?? session.item;
    const queries = {
      comps: [`${item} used price`, `${item} sold listings`],
      issues: [`${item} common problems`, `${item} what to check before buying`],
      price: [`${item} fair used value`],
    }[agent.id];

    await this.sleep(400 + index * 500);
    agent.status = "searching";
    agent.started_at = now();
    for (const q of queries) {
      agent.queries.push(q);
      agent.activity = `Searching "${q}"`;
      await this.sleep(1600);
    }
    agent.status = "reading";
    const sources: ResearchSource[] = agent.id === "comps"
      ? listings.slice(0, 4).map((l, i) => ({ title: l.title, url: `https://example.com/demo-listing-${i + 1}`, price: l.price, note: l.note ?? l.condition ?? null, image_url: null }))
      : [];
    agent.sources = sources;
    agent.activity = `Reading ${Math.max(sources.length, 3)} pages`;
    await this.sleep(1800);

    const prices = listings.map((l) => l.price).sort((a, b) => a - b);
    const low = prices[Math.floor(prices.length * 0.25)] ?? session.target_price ?? null;
    const high = prices[Math.floor(prices.length * 0.75)] ?? session.asking_price ?? null;
    const money = (c: number | null) => (c != null ? formatCents(c) : "?");
    if (agent.id === "comps") {
      agent.summary = listings.length
        ? `${listings.length} similar listings run ${money(prices[0] ?? low)}–${money(prices[prices.length - 1] ?? high)} (illustrative).`
        : "No comparable listings in the demo data for this item.";
      agent.price_low = low; agent.price_high = high;
      agent.headline = low != null && high != null ? `${money(low)}–${money(high)} nearby` : "No comps found";
    } else if (agent.id === "issues") {
      agent.summary = session.listing?.condition_claims.length
        ? `Verify the listing's claims in person: ${session.listing.condition_claims.slice(0, 3).join(", ")}. Worn tires and drivetrain are the usual hidden costs.`
        : "Check wear items in person; hidden repair costs are your best leverage.";
      agent.headline = session.listing?.condition_claims.length ? "Verify listing claims" : "Check wear items";
    } else {
      const open = session.target_price ?? low;
      agent.summary = [
        low != null && high != null ? `Fair range about ${formatCents(low)}–${formatCents(high)}.` : "Not enough data for a fair range.",
        session.asking_price != null ? `Asking is ${formatCents(session.asking_price)}.` : "",
        open != null ? `Open near ${formatCents(open)}.` : "",
      ].filter(Boolean).join(" ");
      agent.price_low = low; agent.price_high = high;
      agent.headline = open != null ? `Open near ${formatCents(open)}` : agentHeadline(null, agent);
    }
    agent.status = "done";
    agent.activity = `${agent.queries.length} searches · ${Math.max(agent.sources.length, 3)} sources (demo data)`;
    agent.finished_at = now();
  }

  // ---------- suggested phrases ----------

  /** Refresh suggested phrases after a new transcript line. Fire-and-forget; latest line wins. */
  refreshSuggestions(session: Session, events: DealEvent[]) {
    const seq = (this.suggestionSeq.get(session.id) ?? 0) + 1;
    this.suggestionSeq.set(session.id, seq);
    const last = events[events.length - 1] ?? null;
    const apply = (phrases: Suggestions["phrases"]) => {
      if (this.suggestionSeq.get(session.id) !== seq) return; // a newer line already superseded this
      this.suggestions.set(session.id, { for_event_id: last?.id ?? null, phrases, updated_at: now() });
    };
    const fallback = () => mockPhrases(session, last, this.research(session.id));
    if (this.provider === "mock") { apply(fallback()); return; }
    const phrases = this.deps.search ? this.nemotronPhrases(session, events) : this.claudePhrases(session, events);
    void phrases.then(apply).catch((err) => {
      this.deps.log.warn({ err: String(err) }, "suggested phrases failed; using template");
      apply(fallback());
    });
  }

  private async claudePhrases(session: Session, events: DealEvent[]): Promise<Suggestions["phrases"]> {
    const msg = await this.deps.client!.messages.create({
      model: this.deps.cueModel,
      max_tokens: 2000,
      output_config: { effort: "low" },
      messages: [{ role: "user", content: this.phrasesPrompt(session, events) }],
    });
    if (msg.stop_reason === "refusal") throw new Error("model declined");
    const text = msg.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("");
    return PhrasesOutput.parse(extractJson(text)).phrases;
  }

  /** NEMOTRON_FAST_MODEL, JSON mode, no thinking (~0.5-1 s). */
  private async nemotronPhrases(session: Session, events: DealEvent[]): Promise<Suggestions["phrases"]> {
    const ai = this.deps.search!;
    return chatJson(ai, ai.fastModel, [{ role: "user", content: this.phrasesPrompt(session, events) }], (raw) => PhrasesOutput.parse(raw).phrases, { maxTokens: 600, timeoutMs: 10_000 });
  }

  private phrasesPrompt(session: Session, events: DealEvent[]): string {
    const research = this.research(session.id);
    const findings = research?.agents.filter((a) => a.summary).map((a) => `${a.title}: ${a.summary}`) ?? [];
    const transcript = events.slice(-8).map((e) => `${e.speaker}: ${e.text}`).join("\n");
    return [
      `You coach a buyer negotiating in person for: ${session.item.trim() ? itemDescription(session) : "an item not identified yet (infer it from the conversation)"}.`,
      [
        `Asking ${session.asking_price != null ? formatCents(session.asking_price) : "not heard yet"}.`,
        session.target_price != null ? `Buyer target ${formatCents(session.target_price)}.` : "",
        session.max_budget != null ? `Walk-away max ${formatCents(session.max_budget)} (never reveal the max).` : "",
      ].filter(Boolean).join(" "),
      session.target_price == null && session.max_budget == null
        ? `The buyer set no target or budget: never invent one. When suggesting a number, base it on the market research fair range if there is one; otherwise ask questions instead of naming a price.`
        : "",
      `Current offer on the table: ${session.current_offer != null ? formatCents(session.current_offer) : "none yet"}.`,
      findings.length ? `Market research so far:\n${findings.join("\n")}` : "",
      `Recent conversation:\n${transcript || "(nothing yet)"}`,
      ``,
      `Give the buyer 3 different things they could say next, each one natural spoken sentence (max 22 words), polite but firm, citing a concrete fact or number when you have one.`,
      `Reply with ONLY JSON: {"phrases": [{"text": "...", "why": "<= 6 words"}]}`,
    ].filter(Boolean).join("\n");
  }

}

/** Template phrases for mock mode / model failure. */
export function mockPhrases(session: Session, last: DealEvent | null, research: ResearchState | null): Suggestions["phrases"] {
  const offer = session.current_offer;
  const range = research?.agents.find((a) => (a.id === "comps" || a.id === "price") && a.price_low != null && a.price_high != null);
  // Never invent the buyer's budget: their own target, else the low end of the market range, else no number.
  const target = session.target_price ?? range?.price_low ?? null;
  const out: Suggestions["phrases"] = [];
  if (last?.kind === "condition_check" && last.cue) {
    out.push({ text: `I noticed ${last.text.replace(/^Condition check:\s*/i, "").replace(/\.$/, "").toLowerCase()}. That's a cost I'd have to cover, so can we adjust the price?`, why: "Condition doesn't match" });
  }
  if (range && range.price_low != null && range.price_high != null) {
    out.push({ text: `I've seen similar ones go for ${formatCents(range.price_low)} to ${formatCents(range.price_high)} around here. Would you do ${formatCents(target ?? range.price_low)}?`, why: "Anchor on comps" });
  }
  if (offer != null && target != null && offer > target) {
    out.push({ text: `I appreciate that. ${formatCents(offer)} is still above my budget. I can do ${formatCents(target)} cash today and pick it up now.`, why: "Counter with certainty" });
  } else if (offer != null && target == null) {
    out.push({ text: `Is ${formatCents(offer)} your best price? What's the lowest you'd take if I pay right now?`, why: "Test their floor" });
  } else if (offer != null) {
    out.push({ text: `${formatCents(offer)} works for me if that's the total, with no extra fees added at the end.`, why: "Lock the total" });
  } else {
    out.push({ text: `It looks great. What's the lowest you'd take if I can pay right now?`, why: "Let them move first" });
  }
  out.push({ text: `Let's put the final number in writing on DEAL so we both see exactly what I'm paying.`, why: "Lock the agreement" });
  return out.slice(0, 3);
}
