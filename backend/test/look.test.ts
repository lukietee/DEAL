import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type Anthropic from "@anthropic-ai/sdk";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { MockAi } from "../src/ai/index.js";
import {
  LookRunner, MOCK_IDENTIFICATION, MOCK_PRICE_DELAY_MS, mockPrice, normalizeName, parseIdentification, parsePrice,
} from "../src/look.js";
import { MockPayments } from "../src/payments/index.js";
import { MemoryStore } from "../src/store/memory.js";

const quiet = { warn: () => undefined };
const JPEG = "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/";
const STARBOY = "The Weeknd – Starboy (2×LP vinyl)";

async function inject(app: FastifyInstance, url: string, payload: unknown) {
  const res = await app.inject({ method: "POST", url, payload: payload as object });
  return { status: res.statusCode, body: res.json() as any };
}

// ---------- mock mode (HTTP) ----------

describe("look mode: mock endpoints", () => {
  let app: FastifyInstance;
  beforeAll(async () => {
    ({ app } = await buildApp({ ...loadConfig(), mockMode: true }, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), logger: false }));
  });
  afterAll(async () => app.close());

  it("POST /look/identify returns the Starboy vinyl in the contract shape", async () => {
    const r = await inject(app, "/look/identify", { image_base64: JPEG, hint: "record" });
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["category", "confidence", "is_product", "name"]);
    expect(r.body).toEqual({ is_product: true, name: STARBOY, category: "vinyl", confidence: 0.92 });
    expect(r.body.confidence).toBeGreaterThanOrEqual(0.6); // the scanner's highlight threshold
  });

  it("POST /look/identify accepts a data: URL and a several-hundred-KB image", async () => {
    const big = `data:image/jpeg;base64,${JPEG}${"A".repeat(800_000)}`;
    expect((await inject(app, "/look/identify", { image_base64: big })).status).toBe(200);
  });

  it("POST /look/price returns deterministic Starboy prices", async () => {
    const r = await inject(app, "/look/price", { name: STARBOY, category: "vinyl" });
    expect(r.status).toBe(200);
    expect(Object.keys(r.body).sort()).toEqual(["name", "price_high", "price_low", "source_count", "summary"]);
    expect(r.body).toEqual({ name: STARBOY, price_low: 2500, price_high: 3500, summary: "Used $25–35 · new $40", source_count: 4 });
  });

  it("POST /look/price: other names get a stable range", async () => {
    const a = (await inject(app, "/look/price", { name: "Sony WH-1000XM5 headphones" })).body;
    const b = (await inject(app, "/look/price", { name: "Sony WH-1000XM5 headphones" })).body;
    expect(a).toEqual(b);
    expect(Number.isInteger(a.price_low)).toBe(true);
    expect(a.price_low).toBeLessThanOrEqual(a.price_high);
    expect(a.summary.length).toBeLessThanOrEqual(60);
  });

  it("validates bodies", async () => {
    expect((await inject(app, "/look/identify", {})).status).toBe(400);
    expect((await inject(app, "/look/identify", { image_base64: "short" })).status).toBe(400);
    expect((await inject(app, "/look/price", {})).status).toBe(400);
    expect((await inject(app, "/look/price", { name: "  " })).status).toBe(400);
  });
});

// ---------- parsing ----------

describe("look mode: model output parsing", () => {
  it("identification: keeps a named product, lowercases the category", () => {
    expect(parseIdentification({ is_product: true, name: ` ${STARBOY} `, category: "Vinyl", confidence: 0.9 }))
      .toEqual({ is_product: true, name: STARBOY, category: "vinyl", confidence: 0.9 });
  });

  it("identification: non-products and nameless products drop name and category", () => {
    expect(parseIdentification({ is_product: false, name: "a wall", category: "wall", confidence: 0.95 }))
      .toEqual({ is_product: false, name: null, category: null, confidence: 0.95 });
    expect(parseIdentification({ is_product: true, name: "", confidence: 0.7 }))
      .toEqual({ is_product: false, name: null, category: null, confidence: 0.7 });
  });

  it("identification: clamps confidence and rejects invalid shapes", () => {
    expect(parseIdentification({ is_product: true, name: "x", confidence: 7 }).confidence).toBe(1);
    expect(parseIdentification({ is_product: true, name: "x", confidence: -1 }).confidence).toBe(0);
    expect(() => parseIdentification({ is_product: "yes", name: "x", confidence: 0.5 })).toThrow();
    expect(() => parseIdentification({ name: "x" })).toThrow();
  });

  it("price: rounds cents, orders low/high, caps sources and summary length", () => {
    const p = parsePrice("x", { price_low: 3500.4, price_high: 2200, summary: "Used $22–35", source_count: 9 }, 3);
    expect(p).toEqual({ name: "x", price_low: 2200, price_high: 3500, summary: "Used $22–35", source_count: 3 });
    const long = parsePrice("x", { price_low: null, price_high: 0, summary: "word ".repeat(40) });
    expect(long.price_low).toBeNull();
    expect(long.price_high).toBeNull();
    expect(long.source_count).toBe(0);
    expect(long.summary.length).toBeLessThanOrEqual(60);
    expect(() => parsePrice("x", { price_low: 1, price_high: 2 })).toThrow();
  });

  it("normalizes names for the cache key", () => {
    expect(normalizeName(STARBOY)).toBe("the weeknd starboy 2xlp vinyl");
    expect(normalizeName("  THE WEEKND — starboy  (2xLP Vinyl) ")).toBe(normalizeName(STARBOY));
    expect(normalizeName("Beyoncé")).toBe("beyonce");
  });
});

// ---------- cache + in-flight dedupe (fake client, no network) ----------

type Reply = { stop_reason?: Anthropic.StopReason; content: unknown[] };

function fakeClient(replies: Reply[], delayMs = 0) {
  const calls: any[] = [];
  const client = {
    messages: {
      create: async (params: any) => {
        calls.push(structuredClone(params));
        if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
        const r = replies.shift();
        if (!r) throw new Error("no more fake replies");
        return { stop_reason: "end_turn", ...r };
      },
    },
  };
  return { client: client as unknown as Anthropic, calls };
}

const text = (t: string) => ({ type: "text", text: t });
const searchResult = (...urls: string[]) => ({
  type: "web_search_tool_result", tool_use_id: "srvtoolu_1",
  content: urls.map((url) => ({ type: "web_search_result", url, title: url, encrypted_content: "", page_age: null })),
});
const priceReply = (low: number, high: number): Reply => ({
  content: [searchResult("https://www.discogs.com/a", "https://www.ebay.com/b"), text(JSON.stringify({ price_low: low, price_high: high, summary: "Used $22–30 · new $35", source_count: 2 }))],
});

describe("look mode: real-mode runner", () => {
  it("identify: one vision call on the cue model, retried once on invalid JSON", async () => {
    const { client, calls } = fakeClient([{ content: [text("hmm")] }, { content: [text(JSON.stringify({ is_product: true, name: STARBOY, category: "vinyl", confidence: 0.88 }))] }]);
    const look = new LookRunner({ mockMode: false, client, model: "claude-haiku-5-5", log: quiet });
    expect(await look.identify({ image_base64: JPEG, hint: "vinyl" })).toEqual({ is_product: true, name: STARBOY, category: "vinyl", confidence: 0.88 });
    expect(calls).toHaveLength(2);
    expect(calls[0].model).toBe("claude-haiku-5-5");
    expect(calls[0].messages[0].content[0]).toMatchObject({ type: "image", source: { type: "base64", media_type: "image/jpeg" } });
    expect(calls[1].messages.at(-1).content).toContain("not valid");
  });

  it("identify: failure maps to 502 {error} over HTTP", async () => {
    const { client } = fakeClient([{ content: [text("nope")] }, { content: [text("nope")] }]);
    const look = new LookRunner({ mockMode: false, client, model: "m", log: quiet });
    const { app } = await buildApp({ ...loadConfig(), mockMode: true }, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), look, logger: false });
    const r = await inject(app, "/look/identify", { image_base64: JPEG });
    expect(r.status).toBe(502);
    expect(typeof r.body.error).toBe("string");
    await app.close();
  });

  it("price: one web-search call, source_count capped by real search results", async () => {
    const { client, calls } = fakeClient([priceReply(2200, 3000)]);
    const look = new LookRunner({ mockMode: false, client, model: "claude-haiku-5-5", log: quiet });
    expect(await look.price({ name: STARBOY, category: "vinyl" })).toEqual({ name: STARBOY, price_low: 2200, price_high: 3000, summary: "Used $22–30 · new $35", source_count: 2 });
    expect(calls).toHaveLength(1);
    expect(calls[0].tools).toEqual([{ type: "web_search_20250305", name: "web_search", max_uses: 2 }]);
  });

  it("price: cached per normalized name until the TTL expires", async () => {
    let t = 1_000_000;
    const { client, calls } = fakeClient([priceReply(2200, 3000), priceReply(2400, 3200)]);
    const look = new LookRunner({ mockMode: false, client, model: "m", log: quiet, ttlMs: 60_000, now: () => t });
    await look.price({ name: STARBOY });
    const again = await look.price({ name: "the weeknd starboy 2xLP vinyl" });
    expect(calls).toHaveLength(1);
    expect(again).toMatchObject({ name: "the weeknd starboy 2xLP vinyl", price_low: 2200 }); // echoes the asked name
    t += 60_001;
    expect((await look.price({ name: STARBOY })).price_low).toBe(2400);
    expect(calls).toHaveLength(2);
  });

  it("price: concurrent identical requests share one in-flight call", async () => {
    const { client, calls } = fakeClient([priceReply(2200, 3000)], 30);
    const look = new LookRunner({ mockMode: false, client, model: "m", log: quiet });
    const results = await Promise.all([look.price({ name: STARBOY }), look.price({ name: STARBOY.toUpperCase() }), look.price({ name: STARBOY })]);
    expect(calls).toHaveLength(1);
    expect(results.map((r) => r.price_low)).toEqual([2200, 2200, 2200]);
    expect(results[1]!.name).toBe(STARBOY.toUpperCase());
  });

  it("price: failures are shared by waiters but not cached", async () => {
    const { client, calls } = fakeClient([{ content: [text("no json")] }, priceReply(2200, 3000)], 10);
    const look = new LookRunner({ mockMode: false, client, model: "m", log: quiet });
    const both = await Promise.allSettled([look.price({ name: STARBOY }), look.price({ name: STARBOY })]);
    expect(both.map((r) => r.status)).toEqual(["rejected", "rejected"]);
    expect(calls).toHaveLength(1);
    expect((await look.price({ name: STARBOY })).price_low).toBe(2200);
    expect(calls).toHaveLength(2);
  });

  it("mock runner: deterministic and deduped too", async () => {
    const look = new LookRunner({ mockMode: true, client: null, model: "", log: quiet });
    expect(await look.identify({ image_base64: JPEG })).toEqual(MOCK_IDENTIFICATION);
    const t0 = Date.now();
    const [a, b] = await Promise.all([look.price({ name: STARBOY }), look.price({ name: STARBOY })]);
    expect(Date.now() - t0).toBeGreaterThanOrEqual(MOCK_PRICE_DELAY_MS - 20);
    expect(a).toEqual(mockPrice(STARBOY));
    expect(b).toEqual(a);
    const t1 = Date.now();
    await look.price({ name: STARBOY });
    expect(Date.now() - t1).toBeLessThan(MOCK_PRICE_DELAY_MS); // served from cache
  });
});
