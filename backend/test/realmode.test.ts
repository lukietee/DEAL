import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type Anthropic from "@anthropic-ai/sdk";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { ClaudeAi, MockAi, cueResearchFrom } from "../src/ai/index.js";
import { URL_UNREADABLE } from "../src/listing.js";
import { MockPayments } from "../src/payments/index.js";
import { ResearchRunner, type ResearchState } from "../src/research.js";
import { MemoryStore } from "../src/store/memory.js";
import { readContent } from "./helpers.js";

const canned = readContent("listings/marketplace_bike.json");
const FB_URL = "https://www.facebook.com/marketplace/item/1234567890/";
const quiet = { warn: () => undefined };

async function inject(app: FastifyInstance, url: string, payload: unknown) {
  const res = await app.inject({ method: "POST", url, payload: payload as object });
  return { status: res.statusCode, body: res.json() as any };
}

// ---------- mock mode ----------

describe("mock mode", () => {
  let app: FastifyInstance;
  beforeAll(async () => {
    ({ app } = await buildApp({ ...loadConfig(), mockMode: true }, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), logger: false }));
  });
  afterAll(async () => app.close());

  it("POST /listings/parse with only a url still returns the canned listing", async () => {
    const r = await inject(app, "/listings/parse", { url: FB_URL });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ...canned, url: FB_URL });
  });

  it("POST /research/preview returns comparables in the preview shape", async () => {
    const t0 = Date.now();
    const r = await inject(app, "/research/preview", { item: "Road bike 56cm", category: "Marketplace", asking_price: 65000 });
    expect(Date.now() - t0).toBeGreaterThanOrEqual(1400);
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["price_high", "price_low", "sources", "summary"]);
    expect(typeof r.body.summary).toBe("string");
    expect(Number.isInteger(r.body.price_low)).toBe(true);
    expect(Number.isInteger(r.body.price_high)).toBe(true);
    expect(r.body.price_low).toBeLessThanOrEqual(r.body.price_high);
    const comps = readContent("comparables/marketplace.json").listings;
    expect(r.body.sources.length).toBe(Math.min(5, comps.length));
    for (const s of r.body.sources) {
      expect(Object.keys(s).sort()).toEqual(["image_url", "note", "price", "title", "url"]);
      expect(s.url).toMatch(/^https:\/\//);
    }
    expect(r.body.sources[0]).toMatchObject({ title: comps[0].title, price: comps[0].price });
  });

  it("POST /research/preview validates the body", async () => {
    expect((await inject(app, "/research/preview", {})).status).toBe(400);
    expect((await inject(app, "/research/preview", { item: "bike", asking_price: 12.5 })).status).toBe(400);
  });
});

// ---------- real mode (ClaudeAi with a fake Anthropic client, no network) ----------

type Reply = { stop_reason?: Anthropic.StopReason; content: unknown[] };

function fakeClient(replies: Reply[]) {
  const calls: any[] = [];
  const client = {
    messages: {
      create: async (params: any) => {
        calls.push(structuredClone(params));
        const r = replies.shift();
        if (!r) throw new Error("no more fake replies");
        return { stop_reason: "end_turn", ...r };
      },
    },
  };
  return { client: client as unknown as Anthropic, calls };
}

const text = (t: string) => ({ type: "text", text: t });
const fetchUse = (url: string) => ({ type: "server_tool_use", id: "srvtoolu_1", name: "web_fetch", input: { url } });
const fetchOk = (url: string) => ({
  type: "web_fetch_tool_result", tool_use_id: "srvtoolu_1",
  content: { type: "web_fetch_result", url, retrieved_at: null, content: { type: "document", source: { type: "text", media_type: "text/plain", data: "Trek Domane, $800" } } },
});
const fetchErr = (code: string) => ({ type: "web_fetch_tool_result", tool_use_id: "srvtoolu_1", content: { type: "web_fetch_tool_result_error", error_code: code } });

async function realApp(client: Anthropic) {
  const cfg = { ...loadConfig(), mockMode: false, anthropicApiKey: "test-not-a-key" };
  const research = new ResearchRunner({ mockMode: true, client: null, model: "", cueModel: "", log: quiet });
  const { app } = await buildApp(cfg, { store: new MemoryStore(), ai: new ClaudeAi(cfg, quiet, client), payments: new MockPayments(), research, logger: false });
  return app;
}

describe("real mode: listing parse failures map to 422", () => {
  it("bare url: a web_fetch error block -> 422 with the contract message (never the canned bike)", async () => {
    const { client, calls } = fakeClient([{ content: [fetchUse(FB_URL), fetchErr("url_not_accessible"), text('{"error":"login wall"}')] }]);
    const app = await realApp(client);
    const r = await inject(app, "/listings/parse", { url: FB_URL });
    expect(r.status).toBe(422);
    expect(r.body).toEqual({ error: URL_UNREADABLE });
    expect(r.body.error).toBe("Couldn't read that link. Paste the listing text or a screenshot instead.");
    // web_fetch only fetches URLs already in the conversation.
    expect(JSON.stringify(calls[0].messages)).toContain(FB_URL);
    expect(calls[0].tools).toEqual([expect.objectContaining({ type: "web_fetch_20260209", name: "web_fetch", max_uses: 2 })]);
    await app.close();
  });

  it("bare url: model reports a login wall even though the fetch succeeded -> 422", async () => {
    const { client } = fakeClient([{ content: [fetchUse(FB_URL), fetchOk(FB_URL), text('{"error":"Facebook login page"}')] }]);
    const app = await realApp(client);
    expect((await inject(app, "/listings/parse", { url: FB_URL })).status).toBe(422);
    await app.close();
  });

  it("bare url: pause_turn is continued and the listing extracted", async () => {
    const url = "https://sfbay.craigslist.org/sfc/bik/d/trek-domane/123.html";
    const listing = { title: "Trek Domane AL 2", asking_price: 80000, category: "marketplace", condition_claims: ["barely ridden"], description: "Great bike", location: "SF", seller_name: null, source: "other", url };
    const { client, calls } = fakeClient([
      { stop_reason: "pause_turn", content: [fetchUse(url)] },
      { content: [fetchOk(url), text(JSON.stringify(listing))] },
    ]);
    const app = await realApp(client);
    const r = await inject(app, "/listings/parse", { url });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ title: "Trek Domane AL 2", asking_price: 80000, source: "other", url });
    expect(calls).toHaveLength(2);
    expect(calls[1].messages.at(-1)).toMatchObject({ role: "assistant", content: [fetchUse(url)] });
    await app.close();
  });

  it("pasted text: invalid model output twice -> 422", async () => {
    const { client } = fakeClient([{ content: [text("not json")] }, { content: [text("still not json")] }]);
    const app = await realApp(client);
    const r = await inject(app, "/listings/parse", { text: "Road bike, $650, like new" });
    expect(r.status).toBe(422);
    expect(typeof r.body.error).toBe("string");
    expect(r.body.title).toBeUndefined();
    await app.close();
  });

  it("condition check: model failure -> 502 {error}, not the canned tires result", async () => {
    const { client } = fakeClient([{ content: [text("nope")] }, { content: [text("nope")] }]);
    const app = await realApp(client);
    const s = await inject(app, "/sessions", { category: "marketplace", item: "bike", asking_price: 65000, target_price: 50000, max_budget: 55000, style: "firm", listing: canned });
    expect(s.status).toBe(201);
    const r = await inject(app, `/sessions/${s.body.id}/condition-check`, { observation: "tires look worn" });
    expect(r.status).toBe(502);
    expect(typeof r.body.error).toBe("string");
    await app.close();
  });
});

describe("cue research input", () => {
  it("is null until an agent finishes, then carries live summaries and sources", () => {
    expect(cueResearchFrom(null)).toBeNull();
    const state: ResearchState = {
      item: "bike", status: "running", started_at: "",
      agents: [
        { id: "comps", title: "Comparable listings", status: "done", activity: "", queries: [], summary: "Similar bikes $500-$600.", price_low: 50000, price_high: 60000, started_at: null, finished_at: null, error: null,
          sources: [{ title: "Trek on eBay", url: "https://ebay.com/x", price: 55000, note: null, image_url: null }] },
        { id: "issues", title: "Known issues & wear", status: "searching", activity: "", queries: [], summary: null, price_low: null, price_high: null, started_at: null, finished_at: null, error: null, sources: [] },
      ],
    };
    expect(cueResearchFrom({ ...state, agents: [state.agents[1]!] })).toBeNull();
    expect(cueResearchFrom(state)).toEqual({
      status: "running",
      agents: [{ title: "Comparable listings", summary: "Similar bikes $500-$600.", price_low: 50000, price_high: 60000, top_sources: [{ title: "Trek on eBay", price: 55000 }] }],
    });
  });
});
