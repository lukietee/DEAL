import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { MockAi } from "../src/ai/index.js";
import type { NemotronRequest, NemotronResponse } from "../src/nebius.js";
import { MockPayments } from "../src/payments/index.js";
import { ResearchRunner, researchProvider, type ResearchState, type SearchAi } from "../src/research.js";
import { MemoryStore } from "../src/store/memory.js";
import type { TavilyResponse, TavilySearch } from "../src/tavily.js";
import type { Session } from "../src/types.js";

const quiet = { warn: () => undefined };
const session = {
  id: "s1", item: "Trek Domane AL 2 road bike", category: "marketplace", asking_price: 65000, target_price: 52000,
  max_budget: null, current_offer: null, listing: null,
} as unknown as Session;

const hit = (url: string, content = "Trek Domane AL 2, used, $600", score = 0.8) => ({ title: `Page ${url}`, url, content, score });

/** Fake Tavily: results per query (by substring), optional failure, records every call. */
function fakeTavily(opts: { fail?: (q: string) => boolean; images?: string[]; onSearch?: (s: TavilySearch) => void } = {}) {
  const calls: TavilySearch[] = [];
  const tavily = {
    search: async (s: TavilySearch): Promise<TavilyResponse> => {
      calls.push(s);
      opts.onSearch?.(s);
      await new Promise((r) => setTimeout(r, 5));
      if (opts.fail?.(s.query)) throw new Error("Tavily 432: usage limit");
      const slug = s.query.replace(/\W+/g, "-").toLowerCase();
      return {
        query: s.query,
        results: [hit(`https://example.com/${slug}/a`, undefined, 0.9), hit(`https://example.com/${slug}/b`, undefined, 0.5), hit("https://shared.example.com/guide", "Value guide $550-650", 0.7)],
        images: s.includeImages ? (opts.images ?? []) : [],
        responseTime: 0.3,
      };
    },
  };
  return { tavily, calls };
}

/** Fake Token Factory: the reply is computed from the request (so parallel agents get their own answer). */
function fakeNemotron(reply: (req: NemotronRequest) => string | Error) {
  const calls: NemotronRequest[] = [];
  const nemotron = {
    chat: async (req: NemotronRequest): Promise<NemotronResponse> => {
      calls.push(structuredClone(req));
      await new Promise((r) => setTimeout(r, 5));
      const out = reply(req);
      if (out instanceof Error) throw out;
      return { text: out, model: req.model, usage: null, finishReason: "stop" };
    },
  };
  return { nemotron, calls };
}

const promptOf = (req: NemotronRequest) => JSON.stringify(req.messages);
const agentReply = (req: NemotronRequest) => {
  const p = promptOf(req);
  const firstUrl = /https:\/\/example\.com\/[a-z0-9-]+\/a/.exec(p)?.[0] ?? "https://example.com/x";
  if (p.includes("common problems")) {
    return JSON.stringify({ summary: "Check the tires and the drivetrain for wear.", headline: "Check tire wear.", sources: [{ title: "x", url: firstUrl, note: "tires wear fast" }] });
  }
  return JSON.stringify({
    summary: "Used ones sell for $550-650.", headline: "$550–650 used", price_low: 55000, price_high: 65000,
    sources: [
      { title: "Model title", url: "https://shared.example.com/guide", price: 60000, note: "value guide" },
      { title: "Invented", url: "https://hallucinated.example.com/nope", price: 1, note: "not a real result" },
    ],
  });
};

function searchAi(tavily: SearchAi["tavily"], nemotron: SearchAi["nemotron"]): SearchAi {
  return { tavily, nemotron, model: "nvidia/super", fastModel: "nvidia/lightning", visionModel: "nvidia/vl" };
}

async function waitDone(state: ResearchState) {
  for (let i = 0; i < 200 && state.status !== "done"; i++) await new Promise((r) => setTimeout(r, 5));
  expect(state.status).toBe("done");
}

describe("research provider selection", () => {
  const keys = { mockMode: false, aiProvider: "" as const, nebiusApiKey: "nb", tavilyApiKey: "tv", anthropicApiKey: "sk" };

  it("Nemotron + Tavily when both keys are set, unless AI_PROVIDER=claude", () => {
    expect(researchProvider(keys)).toBe("nemotron");
    expect(researchProvider({ ...keys, aiProvider: "claude" })).toBe("claude");
    expect(researchProvider({ ...keys, aiProvider: "nebius" })).toBe("nemotron");
  });

  it("falls back to Claude without a Tavily or Nebius key, and to mock without any key", () => {
    expect(researchProvider({ ...keys, tavilyApiKey: "" })).toBe("claude");
    expect(researchProvider({ ...keys, nebiusApiKey: "" })).toBe("claude");
    expect(researchProvider({ ...keys, nebiusApiKey: "", anthropicApiKey: "" })).toBe("mock");
    expect(researchProvider({ ...keys, mockMode: true })).toBe("mock");
  });

  it("the runner reports its provider; mock mode wins over clients", () => {
    const { tavily } = fakeTavily();
    const { nemotron } = fakeNemotron(agentReply);
    expect(new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet }).provider).toBe("nemotron");
    expect(new ResearchRunner({ mockMode: true, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet }).provider).toBe("mock");
    expect(new ResearchRunner({ mockMode: false, client: null, model: "", cueModel: "", log: quiet }).provider).toBe("mock");
  });

  it("/health shows the research provider (mock AI keeps research on mock)", async () => {
    const { app } = await buildApp({ ...loadConfig(), mockMode: true }, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), logger: false });
    expect((await app.inject({ method: "GET", url: "/health" })).json().research).toBe("mock");
    await app.close();
  });
});

describe("research agents on Tavily + Nemotron (fake clients)", () => {
  // og:image lookups use the global fetch: no network in tests. Pages have no og:image; the Tavily image is an image.
  beforeEach(() => {
    vi.stubGlobal("fetch", async (url: string) =>
      url.startsWith("https://img.example.com/")
        ? new Response("x", { status: 200, headers: { "content-type": "image/jpeg" } })
        : new Response("<html></html>", { status: 404, headers: { "content-type": "text/html" } }));
  });
  afterEach(() => { vi.unstubAllGlobals(); });

  it("plans queries, searches in parallel, streams status and fills summary / headline / sources", async () => {
    let runner!: ResearchRunner;
    const seen: string[] = [];
    const { tavily, calls: searches } = fakeTavily({
      images: ["https://img.example.com/domane.jpg"],
      onSearch: () => { for (const a of runner.research("s1")!.agents) seen.push(`${a.id}:${a.status}`); },
    });
    const { nemotron, calls: chats } = fakeNemotron((req) => {
      const comps = runner.research("s1")!.agents[0]!;
      if (promptOf(req).includes("Find 3-5 current")) seen.push(`comps-at-synthesis:${comps.status}:${comps.activity}:${comps.sources.length}`);
      return agentReply(req);
    });
    runner = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    const state = runner.start(session);
    await waitDone(state);

    // 3 + 2 + 2 templated queries, all on Tavily; comps asks for images; one synthesis call per agent on NEMOTRON_MODEL.
    expect(searches).toHaveLength(7);
    expect(searches.filter((s) => s.includeImages).map((s) => s.query)).toEqual(state.agents[0]!.queries);
    expect(searches.every((s) => s.query.startsWith("Trek Domane AL 2 road bike"))).toBe(true);
    expect(chats).toHaveLength(3);
    expect(chats.every((c) => c.model === "nvidia/super" && c.json === true)).toBe(true);
    expect(promptOf(chats[0]!)).toContain("Web search results (Tavily)");

    // Status progression: searching while Tavily runs, reading (with sources) when the model writes the summary.
    expect(seen).toContain("comps:searching");
    expect(seen.find((s) => s.startsWith("comps-at-synthesis"))).toMatch(/^comps-at-synthesis:reading:Writing summary:\d+$/);

    const [comps, issues, price] = state.agents;
    for (const a of state.agents) {
      expect(a.status).toBe("done");
      expect(a.error).toBeNull();
      expect(a.started_at && a.finished_at).toBeTruthy();
      expect(a.activity).toMatch(/^\d searches · \d+ sources$/);
    }
    expect(comps!.queries).toHaveLength(3);
    expect(issues!.queries).toHaveLength(2);
    expect(comps!.headline).toBe("$550–650 used");
    expect(issues!.headline).toBe("Check tire wear");
    expect([price!.price_low, price!.price_high]).toEqual([55000, 65000]);
    // The model's pick goes first with Tavily's title; an invented URL is dropped; the rest follow by score.
    expect(comps!.sources[0]).toMatchObject({ url: "https://shared.example.com/guide", title: "Page https://shared.example.com/guide", price: 60000, note: "value guide" });
    expect(comps!.sources.some((s) => s.url.includes("hallucinated"))).toBe(false);
    expect(comps!.sources.length).toBeLessThanOrEqual(8);
    expect(new Set(comps!.sources.map((s) => s.url)).size).toBe(comps!.sources.length);
    // No og:image anywhere, so the comps search's own image fills the first thumbnail; other agents have none.
    expect(comps!.sources[0]!.image_url).toBe("https://img.example.com/domane.jpg");
    expect(issues!.sources.every((s) => s.image_url === null)).toBe(true);
    runner.stopAll();
  });

  it("an over-long headline falls back to the price range; invalid JSON is retried once", async () => {
    const { tavily } = fakeTavily();
    let first = true;
    const { nemotron, calls } = fakeNemotron((req) => {
      if (!promptOf(req).includes("Estimate a fair used price")) return agentReply(req);
      if (first) { first = false; return "Sure! Here is the research."; }
      return JSON.stringify({ summary: "Fair range $500-600.", headline: "A fair price range for this road bike", price_low: 60000, price_high: 50000, sources: [] });
    });
    const runner = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    const state = runner.start(session);
    await waitDone(state);
    const price = state.agents[2]!;
    expect(price.status).toBe("done");
    expect([price.price_low, price.price_high]).toEqual([50000, 60000]); // swapped into order
    expect(price.headline).toMatch(/^\$500.*\$600$/);
    expect(calls.filter((c) => promptOf(c).includes("Estimate a fair used price"))).toHaveLength(2);
    expect(JSON.stringify(calls.at(-1)!.messages.at(-1))).toContain("not valid");
    runner.stopAll();
  });

  it("a failing agent ends in error without stopping the others", async () => {
    const { tavily } = fakeTavily({ fail: (q) => /problems|before buying/.test(q) }); // every issues search fails
    const { nemotron } = fakeNemotron((req) => (promptOf(req).includes("Estimate a fair used price") ? new Error("Token Factory 503") : agentReply(req)));
    const warns: unknown[] = [];
    const runner = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: { warn: (o) => warns.push(o) } });
    const state = runner.start(session);
    await waitDone(state);
    const [comps, issues, price] = state.agents;
    expect(comps!.status).toBe("done");
    expect(issues).toMatchObject({ status: "error", activity: "Failed" });
    expect(issues!.error).toContain("Tavily 432");
    expect(price!.status).toBe("error");
    expect(price!.error).toContain("503");
    expect(price!.sources.length).toBeGreaterThan(0); // search hits survive a failed synthesis
    expect(warns).toHaveLength(2);
    runner.stopAll();
  });

  it("one failed query out of three still finishes the agent", async () => {
    const { tavily } = fakeTavily({ fail: (q) => q.includes("eBay") });
    const { nemotron } = fakeNemotron(agentReply);
    const runner = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    const state = runner.start(session);
    await waitDone(state);
    expect(state.agents[0]!.status).toBe("done");
    runner.stopAll();
  });

  it("POST /research/preview runs the comps agent on Tavily + Nemotron", async () => {
    const { tavily, calls: searches } = fakeTavily();
    const { nemotron } = fakeNemotron(agentReply);
    const research = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    const { app } = await buildApp({ ...loadConfig(), mockMode: true }, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), research, logger: false });
    const r = await app.inject({ method: "POST", url: "/research/preview", payload: { item: "Trek Domane AL 2", asking_price: 65000 } });
    expect(r.statusCode).toBe(200);
    const body = r.json();
    expect(Object.keys(body).sort()).toEqual(["price_high", "price_low", "sources", "summary"]);
    expect(body).toMatchObject({ summary: "Used ones sell for $550-650.", price_low: 55000, price_high: 65000 });
    expect(body.sources[0]).toEqual({ title: "Page https://shared.example.com/guide", url: "https://shared.example.com/guide", price: 60000, note: "value guide", image_url: null });
    expect(searches).toHaveLength(3);
    expect(searches[0]!.query).toBe("Trek Domane AL 2 used for sale price");
    await app.close();
  });

  it("preview: a failed synthesis returns nulls plus the search hits", async () => {
    const { tavily } = fakeTavily();
    const { nemotron } = fakeNemotron(() => new Error("Token Factory 500"));
    const research = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    const p = await research.preview({ item: "Trek Domane AL 2" });
    expect(p).toMatchObject({ summary: null, price_low: null, price_high: null });
    expect(p.sources.length).toBeGreaterThan(0);
  });
});

describe("suggested phrases on Nemotron", () => {
  it("uses the fast model in JSON mode", async () => {
    const { tavily } = fakeTavily();
    const { nemotron, calls } = fakeNemotron(() => JSON.stringify({ phrases: [{ text: "Would you take $550 cash today?", why: "Anchor on comps" }] }));
    const runner = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    runner.refreshSuggestions(session, []);
    for (let i = 0; i < 100 && !runner.suggestionsFor("s1"); i++) await new Promise((r) => setTimeout(r, 5));
    expect(runner.suggestionsFor("s1")!.phrases).toEqual([{ text: "Would you take $550 cash today?", why: "Anchor on comps" }]);
    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({ model: "nvidia/lightning", json: true });
    expect(promptOf(calls[0]!)).toContain("Trek Domane AL 2 road bike");
  });

  it("falls back to the template phrases when the model fails", async () => {
    const { tavily } = fakeTavily();
    const { nemotron } = fakeNemotron(() => new Error("Token Factory 429"));
    const runner = new ResearchRunner({ mockMode: false, client: null, search: searchAi(tavily, nemotron), model: "", cueModel: "", log: quiet });
    runner.refreshSuggestions(session, []);
    for (let i = 0; i < 100 && !runner.suggestionsFor("s1"); i++) await new Promise((r) => setTimeout(r, 5));
    expect(runner.suggestionsFor("s1")!.phrases.length).toBeGreaterThan(0);
  });
});
