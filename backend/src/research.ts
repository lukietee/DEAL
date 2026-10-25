// Live market research + suggested phrases.
//
// Research: when a session starts, three research agents run in parallel (comparable prices, known issues,
// fair price / negotiation leverage). In real mode each is a Claude call with the server-side web_search
// tool, streamed so the phone sees queries and sources arrive live; afterwards we fetch the og:image of
// the top result pages so the app can show pictures. In mock mode the agents replay content/comparables
// on a timer so the UI still animates.
//
// Suggested phrases: after every transcript line, 2-3 full sentences the buyer could say next.
//
// State lives in memory on the Deal (like script runs) and is returned by GET /sessions/:id.
import Anthropic from "@anthropic-ai/sdk";
import { z } from "zod";
import { getComparables } from "./content.js";
import { formatCentsShort as formatCents } from "./money.js";
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

const AGENTS: { id: ResearchAgent["id"]; title: string; goal: string }[] = [
  {
    id: "comps",
    title: "Comparable listings",
    goal: "Find 3-5 current or recent listings/sales for the same or a very similar used item, with their prices. Prefer marketplace, eBay sold, Craigslist, OfferUp, dealer or classifieds pages.",
  },
  {
    id: "issues",
    title: "Known issues & wear",
    goal: "Find the common problems, wear items and inspection points for this item that a buyer should check in person, and roughly what each costs to fix.",
  },
  {
    id: "price",
    title: "Fair price & leverage",
    goal: "Estimate a fair used price range for this item from price guides, reviews or sold data, and note any negotiation leverage (new-model discounts, depreciation, seasonality).",
  },
];

const ResearchOutput = z.object({
  summary: z.string(),
  price_low: z.number().int().nullable().optional(),
  price_high: z.number().int().nullable().optional(),
  sources: z
    .array(z.object({ title: z.string(), url: z.string(), price: z.number().int().nullable().optional(), note: z.string().nullable().optional() }))
    .default([]),
});

const PhrasesOutput = z.object({
  phrases: z.array(z.object({ text: z.string(), why: z.string() })).min(1).max(3),
});

function newAgent(a: (typeof AGENTS)[number]): ResearchAgent {
  return {
    id: a.id, title: a.title, status: "queued", activity: "Waiting to start", queries: [], sources: [], summary: null,
    price_low: null, price_high: null, started_at: null, finished_at: null, error: null,
  };
}

export function itemDescription(s: Session): string {
  const l = s.listing;
  if (!l) return s.item;
  const claims = l.condition_claims.length ? ` (listing claims: ${l.condition_claims.join("; ")})` : "";
  return `${l.title}${claims}`;
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

// ---------- research runner ----------

export interface ResearchDeps {
  mockMode: boolean;
  client: Anthropic | null;
  model: string; // research agents (web search)
  cueModel: string; // suggested phrases
  log: Logger;
}

export class ResearchRunner {
  private states = new Map<string, ResearchState>();
  private suggestions = new Map<string, Suggestions>();
  private suggestionSeq = new Map<string, number>();
  private timers = new Set<NodeJS.Timeout>();

  constructor(private deps: ResearchDeps) {}

  research(sessionId: string): ResearchState | null { return this.states.get(sessionId) ?? null; }
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
      const run = this.deps.mockMode || !this.deps.client ? this.mockAgent(session, agent, i) : this.claudeAgent(session, spec, agent);
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

  private async claudeAgent(session: Session, spec: (typeof AGENTS)[number], agent: ResearchAgent) {
    const client = this.deps.client!;
    agent.status = "searching";
    agent.started_at = now();
    agent.activity = "Planning searches";
    const item = itemDescription(session);
    const prompt = [
      `You are one of three research agents helping a buyer who is negotiating in person, right now, for: ${item}.`,
      `Asking price: ${formatCents(session.asking_price)}. Buyer's target: ${formatCents(session.target_price)}. Category: ${session.category}.`,
      ``,
      `Your job: ${spec.goal}`,
      `Use web search (at most 3 searches). Be quick; the buyer is mid-conversation.`,
      ``,
      `Finish with ONLY a JSON object, no prose around it:`,
      `{"summary": "<= 2 short sentences a buyer can act on", "price_low": <integer cents or null>, "price_high": <integer cents or null>,`,
      ` "sources": [{"title": "...", "url": "<a page URL you actually found>", "price": <integer cents or null>, "note": "<= 8 words"}]}`,
      `List up to 5 sources, best first. Prices are integer cents (e.g. $520 = 52000).`,
    ].join("\n");

    const stream = client.beta.messages.stream({
      model: this.deps.model,
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
    const out = ResearchOutput.parse(extractJson(text));

    // The model's own picks go first (they carry price/note); keep other search hits after them.
    const picked: ResearchSource[] = out.sources
      .filter((s) => /^https?:\/\//.test(s.url))
      .map((s) => ({ title: s.title, url: s.url, price: s.price ?? null, note: s.note ?? null, image_url: null }));
    const rest = agent.sources.filter((s) => !picked.some((p) => p.url === s.url));
    agent.sources = [...picked, ...rest].slice(0, 8);
    agent.summary = out.summary;
    agent.price_low = out.price_low ?? null;
    agent.price_high = out.price_high ?? null;

    agent.activity = "Pulling images";
    await Promise.all(
      agent.sources.slice(0, 4).map(async (s) => { s.image_url = await fetchPageImage(s.url); }),
    );
    agent.status = "done";
    agent.activity = `${agent.queries.length} searches · ${agent.sources.length} sources`;
    agent.finished_at = now();
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
    const low = prices[Math.floor(prices.length * 0.25)] ?? session.target_price;
    const high = prices[Math.floor(prices.length * 0.75)] ?? session.asking_price;
    if (agent.id === "comps") {
      agent.summary = `${listings.length} similar listings run ${formatCents(prices[0] ?? low)}–${formatCents(prices[prices.length - 1] ?? high)} (illustrative).`;
      agent.price_low = low; agent.price_high = high;
    } else if (agent.id === "issues") {
      agent.summary = session.listing?.condition_claims.length
        ? `Verify the listing's claims in person: ${session.listing.condition_claims.slice(0, 3).join(", ")}. Worn tires and drivetrain are the usual hidden costs.`
        : "Check wear items in person; hidden repair costs are your best leverage.";
    } else {
      agent.summary = `Fair range about ${formatCents(low)}–${formatCents(high)}. Asking is ${formatCents(session.asking_price)}; open near ${formatCents(session.target_price)}.`;
      agent.price_low = low; agent.price_high = high;
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
    if (this.deps.mockMode || !this.deps.client) { apply(fallback()); return; }
    void this.claudePhrases(session, events).then(apply).catch((err) => {
      this.deps.log.warn({ err: String(err) }, "suggested phrases failed; using template");
      apply(fallback());
    });
  }

  private async claudePhrases(session: Session, events: DealEvent[]): Promise<Suggestions["phrases"]> {
    const research = this.research(session.id);
    const findings = research?.agents.filter((a) => a.summary).map((a) => `${a.title}: ${a.summary}`) ?? [];
    const transcript = events.slice(-8).map((e) => `${e.speaker}: ${e.text}`).join("\n");
    const prompt = [
      `You coach a buyer negotiating in person for: ${itemDescription(session)}.`,
      `Asking ${formatCents(session.asking_price)}, buyer target ${formatCents(session.target_price)}, walk-away max ${formatCents(session.max_budget)} (never reveal the max).`,
      `Current offer on the table: ${session.current_offer != null ? formatCents(session.current_offer) : "none yet"}.`,
      findings.length ? `Market research so far:\n${findings.join("\n")}` : "",
      `Recent conversation:\n${transcript || "(nothing yet)"}`,
      ``,
      `Give the buyer 3 different things they could say next, each one natural spoken sentence (max 22 words), polite but firm, citing a concrete fact or number when you have one.`,
      `Reply with ONLY JSON: {"phrases": [{"text": "...", "why": "<= 6 words"}]}`,
    ].filter(Boolean).join("\n");
    const msg = await this.deps.client!.messages.create({
      model: this.deps.cueModel,
      max_tokens: 2000,
      output_config: { effort: "low" },
      messages: [{ role: "user", content: prompt }],
    });
    if (msg.stop_reason === "refusal") throw new Error("model declined");
    const text = msg.content.filter((b) => b.type === "text").map((b) => (b as { text: string }).text).join("");
    return PhrasesOutput.parse(extractJson(text)).phrases;
  }

}

/** Template phrases for mock mode / model failure. */
export function mockPhrases(session: Session, last: DealEvent | null, research: ResearchState | null): Suggestions["phrases"] {
  const offer = session.current_offer;
  const target = session.target_price;
  const range = research?.agents.find((a) => a.id === "comps" && a.price_low != null && a.price_high != null);
  const out: Suggestions["phrases"] = [];
  if (last?.kind === "condition_check" && last.cue) {
    out.push({ text: `I noticed ${last.text.replace(/^Condition check:\s*/i, "").replace(/\.$/, "").toLowerCase()}. That's a cost I'd have to cover, so can we adjust the price?`, why: "Condition doesn't match" });
  }
  if (range && range.price_low != null && range.price_high != null) {
    out.push({ text: `I've seen similar ones go for ${formatCents(range.price_low)} to ${formatCents(range.price_high)} around here. Would you do ${formatCents(target)}?`, why: "Anchor on comps" });
  }
  if (offer != null && offer > target) {
    out.push({ text: `I appreciate that. ${formatCents(offer)} is still above my budget. I can do ${formatCents(target)} cash today and pick it up now.`, why: "Counter with certainty" });
  } else if (offer != null) {
    out.push({ text: `${formatCents(offer)} works for me if that's the total, with no extra fees added at the end.`, why: "Lock the total" });
  } else {
    out.push({ text: `It looks great. What's the lowest you'd take if I can pay right now?`, why: "Let them move first" });
  }
  out.push({ text: `Let's put the final number in writing on DEAL so we both see exactly what I'm paying.`, why: "Lock the agreement" });
  return out.slice(0, 3);
}
