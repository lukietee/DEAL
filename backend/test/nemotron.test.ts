import { describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { ClaudeAi, MockAi, createAi, type Ai } from "../src/ai/index.js";
import { NemotronAi, fixCentsScale, stripThinking } from "../src/ai/nemotron.js";
import { URL_UNREADABLE, htmlToText } from "../src/listing.js";
import type { NemotronRequest, NemotronResponse } from "../src/nebius.js";
import { MockPayments } from "../src/payments/index.js";
import { ResearchRunner } from "../src/research.js";
import { MemoryStore } from "../src/store/memory.js";
import { readContent } from "./helpers.js";

const canned = readContent("listings/marketplace_bike.json");
const quiet = { warn: () => undefined };
const baseCfg = { ...loadConfig(), mockMode: false, nebiusApiKey: "test-nebius", anthropicApiKey: "", aiProvider: "" as const };

/** Fake NemotronClient: replays text replies (an Error is thrown), records every request. */
function fakeNemotron(replies: (string | Error)[]) {
  const calls: NemotronRequest[] = [];
  const client = {
    chat: async (req: NemotronRequest): Promise<NemotronResponse> => {
      calls.push(structuredClone(req));
      const r = replies.shift();
      if (r === undefined) throw new Error("no more fake replies");
      if (r instanceof Error) throw r;
      return { text: r, model: req.model, usage: null, finishReason: "stop" };
    },
  };
  return { client, calls };
}

/** Fake page fetch: one HTML body (or status) for any URL, records the URLs. */
function fakeFetch(body: string, status = 200, type = "text/html; charset=utf-8") {
  const urls: string[] = [];
  const impl = (async (url: URL | string) => {
    urls.push(String(url));
    return new Response(body, { status, headers: { "content-type": type } });
  }) as typeof fetch;
  return { impl, urls };
}

async function nemoApp(ai: Ai): Promise<FastifyInstance> {
  const research = new ResearchRunner({ mockMode: true, client: null, model: "", cueModel: "", log: quiet });
  const { app } = await buildApp(baseCfg, { store: new MemoryStore(), ai, payments: new MockPayments(), research, logger: false });
  return app;
}

async function post(app: FastifyInstance, url: string, payload?: unknown) {
  const res = await app.inject({ method: "POST", url, payload: payload as object });
  return { status: res.statusCode, body: res.json() as any };
}

const CUE = { current_offer: 45000, offer_by: "buyer", new_terms: [{ type: "price", label: "bike", amount: 45000 }], tactic_detected: null, cue: "Strong anchor, hold firm", cue_detail: null, status: "green" };
const SESSION = { category: "marketplace", item: "Road bike", asking_price: 65000, target_price: 50000, max_budget: 55000, style: "firm" };

describe("provider selection (createAi)", () => {
  it("mock mode is always mock", () => {
    expect(createAi({ ...baseCfg, mockMode: true, anthropicApiKey: "k" }, quiet).kind).toBe("mock");
  });
  it("Nebius key -> Nemotron (mock backup); both keys -> Nemotron with Claude backup", () => {
    const only = createAi(baseCfg, quiet) as NemotronAi;
    expect(only.kind).toBe("nemotron");
    expect(only.backup).toBeNull();
    const both = createAi({ ...baseCfg, anthropicApiKey: "k" }, quiet) as NemotronAi;
    expect(both.kind).toBe("nemotron");
    expect(both.backup?.kind).toBe("claude");
  });
  it("AI_PROVIDER=claude forces Claude; only the Anthropic key -> Claude; no keys -> mock", () => {
    expect(createAi({ ...baseCfg, anthropicApiKey: "k", aiProvider: "claude" }, quiet).kind).toBe("claude");
    expect(createAi({ ...baseCfg, nebiusApiKey: "", anthropicApiKey: "k" }, quiet).kind).toBe("claude");
    expect(createAi({ ...baseCfg, nebiusApiKey: "", aiProvider: "nebius" }, quiet).kind).toBe("mock");
    expect(createAi({ ...baseCfg, aiProvider: "claude" }, quiet).kind).toBe("mock");
  });
  it("GET /health reports the provider and the Nemotron models", async () => {
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client: fakeNemotron([]).client }));
    const h = (await app.inject({ method: "GET", url: "/health" })).json();
    expect(h).toMatchObject({ ai: "nemotron", provider: "nebius" });
    expect(h.models).toMatchObject({
      cue: baseCfg.nemotronCueModel, detect: baseCfg.nemotronFastModel, agreement: baseCfg.nemotronReasoningModel, listing: baseCfg.nemotronModel, vision: baseCfg.nemotronVisionModel, backup: "mock",
    });
    await app.close();
  });
});

describe("Nemotron calls (fake Token Factory client)", () => {
  it("cue: cue model, JSON mode, no thinking; JSON wrapped in prose and fences is parsed", async () => {
    const { client, calls } = fakeNemotron([`Sure! Here it is:\n\`\`\`json\n${JSON.stringify(CUE)}\n\`\`\``]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    const s = await post(app, "/sessions", SESSION);
    const e = await post(app, `/sessions/${s.body.id}/events`, { speaker: "buyer", text: "Would you do four fifty?" });
    expect(e.status).toBe(201);
    expect(e.body).toMatchObject({ cue: "Strong anchor, hold firm", status_color: "green" });
    expect(calls[0]).toMatchObject({ model: baseCfg.nemotronCueModel, json: true, thinking: false });
    expect(calls[0]!.messages[0]).toMatchObject({ role: "system" });
    await app.close();
  });

  it("cue: invalid JSON is retried once with the validation error, then succeeds", async () => {
    const { client, calls } = fakeNemotron(["not json at all", JSON.stringify({ ...CUE, speaker: "seller" })]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    const s = await post(app, "/sessions", SESSION);
    const e = await post(app, `/sessions/${s.body.id}/events`, { speaker: "auto", text: "I'm asking six fifty, firm." });
    expect(e.body).toMatchObject({ speaker: "seller", cue: "Strong anchor, hold firm" });
    expect(calls).toHaveLength(2);
    expect(calls[1]!.messages.at(-2)).toEqual({ role: "assistant", content: "not json at all" });
    expect(String(calls[1]!.messages.at(-1)!.content)).toContain("That was not valid");
    await app.close();
  });

  it("cue: two failures fall back to the backup provider", async () => {
    const backup = new MockAi();
    let used = 0;
    const spy: Ai = Object.assign(Object.create(backup), { kind: "claude", cue: async (i: any) => (used++, backup.cue(i)) });
    const { client } = fakeNemotron(["nope", new Error("Token Factory 503")]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client, backup: spy }));
    const s = await post(app, "/sessions", SESSION);
    const e = await post(app, `/sessions/${s.body.id}/events`, { speaker: "buyer", text: "Hi, is this still available?" });
    expect(e.status).toBe(201);
    expect(used).toBe(1);
    await app.close();
  });

  it("cue guards: double-converted cents are scaled back, and an offer above max is red", async () => {
    const { client } = fakeNemotron([JSON.stringify({ ...CUE, current_offer: 6000000, offer_by: "seller", new_terms: [{ type: "price", label: "bike", amount: 6000000 }], status: "yellow" })]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    const s = await post(app, "/sessions", SESSION);
    const e = await post(app, `/sessions/${s.body.id}/events`, { speaker: "seller", text: "I could do six hundred." });
    expect(e.body).toMatchObject({ extracted_offer: 60000, status_color: "red" });
    await app.close();
  });

  it("agreement: reasoning model with thinking; guard-rails fix items[0] and the total", async () => {
    const draft = { price: 52000, items: ["bike"], fees: [{ label: "gas", amount: 0, note: "waived" }], total: 99, source_event_ids: ["evt_bogus"], open_questions: [] };
    const { client, calls } = fakeNemotron([JSON.stringify(CUE), `<think>price is 520</think>${JSON.stringify(draft)}`]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    const s = await post(app, "/sessions", SESSION);
    await post(app, `/sessions/${s.body.id}/events`, { speaker: "buyer", text: "Deal at 520." });
    const a = await post(app, `/sessions/${s.body.id}/agreement`);
    expect(a.status).toBe(201);
    expect(a.body).toMatchObject({ price: 52000, total: 52000, items: ["Road bike", "bike"], source_event_ids: [] });
    expect(calls[1]).toMatchObject({ model: baseCfg.nemotronReasoningModel, json: true, thinking: true });
    await app.close();
  });

  it("condition check with a photo: vision model, image part first (media type from magic bytes)", async () => {
    const out = { discrepancies: [{ claim: "NEW TIRES LAST MONTH", observed: "Rear sidewall cracked", suggested_discount: 4000, cue: "Tires worn: ask $40 off" }, { claim: "invented", observed: "x", suggested_discount: 1, cue: "x" }] };
    const { client, calls } = fakeNemotron([JSON.stringify(out)]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    const s = await post(app, "/sessions", { ...SESSION, listing: canned });
    const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==";
    const r = await post(app, `/sessions/${s.body.id}/condition-check`, { image_base64: png });
    expect(r.status).toBe(201);
    expect(r.body.discrepancies).toEqual([{ ...out.discrepancies[0], claim: "new tires last month" }]);
    expect(calls[0]!.model).toBe(baseCfg.nemotronVisionModel);
    const content = calls[0]!.messages[1]!.content as any[];
    expect(content[0]).toEqual({ type: "image_url", image_url: { url: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==" } });
    expect(content[1]).toMatchObject({ type: "text" });
    expect(content[1].text).toContain("new tires last month");
    await app.close();
  });

  it("condition check: model failure without a backup -> 502", async () => {
    const { client } = fakeNemotron(["nope", "nope"]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    const s = await post(app, "/sessions", { ...SESSION, listing: canned });
    const r = await post(app, `/sessions/${s.body.id}/condition-check`, { observation: "tires look worn" });
    expect(r.status).toBe(502);
    await app.close();
  });

  it("listing text: general model; screenshot: vision model", async () => {
    const listing = { title: "Trek Domane", asking_price: 80000, category: "marketplace", condition_claims: ["barely ridden"], description: "d", location: null, seller_name: null, source: "other", url: null };
    const { client, calls } = fakeNemotron([JSON.stringify(listing), JSON.stringify(listing)]);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client }));
    expect((await post(app, "/listings/parse", { text: "Trek Domane $800 barely ridden" })).body).toMatchObject({ title: "Trek Domane", asking_price: 80000 });
    await post(app, "/listings/parse", { image_base64: "/9j/4AAQSkZJRg==" });
    expect(calls.map((c) => c.model)).toEqual([baseCfg.nemotronModel, baseCfg.nemotronVisionModel]);
    expect((calls[1]!.messages[1]!.content as any[])[0].image_url.url).toMatch(/^data:image\/jpeg;base64,\/9j/);
    await app.close();
  });
});

describe("Nemotron listing URLs (server-side fetch)", () => {
  const FB = "https://www.facebook.com/marketplace/item/1234567890/";
  const URL_ = "https://sfbay.craigslist.org/sfc/bik/d/trek-domane/123.html";
  const PAGE = `<html><head><title>Trek Domane AL 2 - bicycles</title><meta property="og:title" content="Trek Domane AL 2 &amp; pedals">
    <meta property="product:price:amount" content="800"><script>var x = "ignore me";</script></head>
    <body><h1>Trek Domane AL 2</h1><p>$800. Barely ridden, new chain.</p></body></html>`;

  it("a Facebook link is 422 at once: no fetch, no model call", async () => {
    const { client, calls } = fakeNemotron([]);
    const f = fakeFetch(PAGE);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client, fetch: f.impl }));
    const r = await post(app, "/listings/parse", { url: FB });
    expect(r).toEqual({ status: 422, body: { error: URL_UNREADABLE } });
    expect(f.urls).toEqual([]);
    expect(calls).toEqual([]);
    await app.close();
  });

  it("fetches the page, passes its text to the general model, keeps the url", async () => {
    const listing = { title: "Trek Domane AL 2", asking_price: 80000, category: "marketplace", condition_claims: ["barely ridden", "new chain"], description: "Barely ridden", location: null, seller_name: null, source: "other", url: null };
    const { client, calls } = fakeNemotron([JSON.stringify(listing)]);
    const f = fakeFetch(PAGE);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client, fetch: f.impl }));
    const r = await post(app, "/listings/parse", { url: URL_ });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ title: "Trek Domane AL 2", asking_price: 80000, url: URL_, source: "other" });
    expect(f.urls).toEqual([URL_]);
    expect(calls[0]!.model).toBe(baseCfg.nemotronModel);
    const user = String(calls[0]!.messages[1]!.content);
    expect(user).toContain(URL_);
    expect(user).toContain("META product:price:amount: 800");
    expect(user).not.toContain("ignore me");
    await app.close();
  });

  it("HTTP error, a non-page, or a model {error} -> 422 with the link message", async () => {
    for (const [f, replies] of [[fakeFetch("gone", 404), []], [fakeFetch("%PDF", 200, "application/pdf"), []], [fakeFetch(PAGE), ['{"error":"login wall"}']]] as const) {
      const { client } = fakeNemotron([...replies]);
      const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client, fetch: f.impl }));
      expect(await post(app, "/listings/parse", { url: URL_ })).toEqual({ status: 422, body: { error: URL_UNREADABLE } });
      await app.close();
    }
  });

  it("internal hosts are never fetched", async () => {
    const f = fakeFetch(PAGE);
    const app = await nemoApp(new NemotronAi(baseCfg, quiet, { client: fakeNemotron([]).client, fetch: f.impl }));
    for (const url of ["http://localhost:3000/health", "http://169.254.169.254/latest/meta-data", "http://192.168.1.1/", "file:///etc/passwd"]) {
      expect((await post(app, "/listings/parse", { url })).status).toBe(422);
    }
    expect(f.urls).toEqual([]);
    await app.close();
  });
});

describe("helpers", () => {
  it("htmlToText keeps title, meta and visible text and drops scripts", () => {
    const t = htmlToText(`<title>A &amp; B</title><meta name="description" content="Nice"><style>.x{}</style><p>Hello&nbsp;world</p><script>bad()</script>`);
    expect(t).toContain("TITLE: A & B");
    expect(t).toContain("META description: Nice");
    expect(t).toContain("Hello world");
    expect(t).not.toContain("bad()");
  });
  it("fixCentsScale leaves plausible amounts alone", () => {
    const session = { asking_price: 65000, target_price: null, max_budget: null, current_offer: null } as any;
    const out = { ...CUE, current_offer: 52000, new_terms: [{ type: "fee", label: "gas", amount: 2000 }] } as any;
    expect(fixCentsScale(out, session)).toEqual(out);
    expect(fixCentsScale({ ...out, current_offer: 5200000 }, session).current_offer).toBe(52000);
  });
  it("stripThinking drops a leaked think block", () => {
    expect(stripThinking('<think>hmm {"a":1}</think>{"b":2}')).toBe('{"b":2}');
  });
  it("ClaudeAi is still constructible as a backup", () => {
    expect(new ClaudeAi({ ...baseCfg, anthropicApiKey: "k" }, quiet).kind).toBe("claude");
  });
});
