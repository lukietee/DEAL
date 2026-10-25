// "Start listening" (auto) sessions: no setup, product detection from the conversation, speaker "auto",
// POST /sessions/:id/end summaries and the history list.
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { MockAi } from "../src/ai/index.js";
import { PLACEHOLDER_ITEM, guessSpeaker, mockDetect, normalizeDetectedCategory } from "../src/auto.js";
import { fallbackExtraction, mockCue } from "../src/mock/extract.js";
import { MockPayments } from "../src/payments/index.js";
import { mockPhrases, type ResearchState } from "../src/research.js";
import { MemoryStore } from "../src/store/memory.js";
import type { DealEvent, Session } from "../src/types.js";
import { readContent } from "./helpers.js";

let app: FastifyInstance;

beforeAll(async () => {
  ({ app } = await buildApp({ ...loadConfig(), mockMode: true }, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), logger: false }));
});
afterAll(async () => app.close());

async function call(method: "GET" | "POST", url: string, payload?: unknown) {
  const res = await app.inject({ method, url, payload: payload as object });
  return { status: res.statusCode, body: res.json() as any };
}
const say = (id: string, text: string, speaker = "auto") => call("POST", `/sessions/${id}/events`, { speaker, text });

function autoSession(over: Partial<Session> = {}): Session {
  return {
    id: "ses_auto", category: "other", item: "", asking_price: null, target_price: null, max_budget: null, style: "friendly",
    status: "live", join_code: "ABC123", current_offer: null, current_offer_by: null, terms: [], listing: null, condition_checks: [],
    auto: true, detected: false, ended_at: null, summary: null, created_at: "", updated_at: "", ...over,
  };
}

describe("POST /sessions with no setup", () => {
  it("creates an auto session with nulls and no research yet", async () => {
    const r = await call("POST", "/sessions", {});
    expect(r.status).toBe(201);
    expect(r.body).toMatchObject({
      auto: true, detected: false, item: "", category: "other", style: "friendly",
      asking_price: null, target_price: null, max_budget: null, ended_at: null, summary: null, status: "live",
    });
    const state = (await call("GET", `/sessions/${r.body.id}`)).body;
    expect(state.research).toBeNull();
    expect(state.suggestions.phrases.length).toBeGreaterThan(0); // opening lines still work
  });

  it("item given: exactly the set-up flow (auto false, detected true, research starts)", async () => {
    const r = await call("POST", "/sessions", { category: "Marketplace", item: "Road bike", asking_price: 65000, target_price: 50000, max_budget: 55000 });
    expect(r.body).toMatchObject({ auto: false, detected: true, category: "marketplace", style: "firm", asking_price: 65000 });
    expect((await call("GET", `/sessions/${r.body.id}`)).body.research.status).toBe("running");
  });

  it("empty item string is an auto session too; auto:true with an item keeps the item", async () => {
    expect((await call("POST", "/sessions", { item: "  ", auto: true })).body).toMatchObject({ auto: true, detected: false, item: "" });
    expect((await call("POST", "/sessions", { item: "iPhone 14", auto: true })).body).toMatchObject({ auto: true, detected: true, item: "iPhone 14", category: "electronics", asking_price: null });
  });
});

describe("auto detection from typed lines (mock mode)", () => {
  it("detects item, category, asking price and claims, then starts research", async () => {
    const id = (await call("POST", "/sessions", {})).body.id;
    const e1 = await say(id, "Hey, is the Sony WH-1000XM5 headphones still available?");
    expect(e1.status).toBe(201);
    expect(e1.body.speaker).toBe("buyer");
    let st = (await call("GET", `/sessions/${id}`)).body;
    expect(st.session).toMatchObject({ detected: true, item: "Sony WH-1000XM5 headphones", category: "electronics", asking_price: null });
    expect(st.research).toMatchObject({ status: "running", item: "Sony WH-1000XM5 headphones" });

    const e2 = await say(id, "Yeah, I'm asking 220, barely used");
    expect(e2.body.speaker).toBe("seller");
    st = (await call("GET", `/sessions/${id}`)).body;
    expect(st.session.asking_price).toBe(22000);
    expect(st.session.listing).toMatchObject({ source: "other", title: "Sony WH-1000XM5 headphones", condition_claims: ["barely used"], asking_price: 22000 });

    const e3 = await say(id, "Would you do 180 if I pay right now?");
    expect(e3.body).toMatchObject({ speaker: "buyer", extracted_offer: 18000, offer_by: "buyer" });
    expect(st.events).toBeDefined();
  });

  it("falls back to a placeholder item after 3 lines with no product", async () => {
    const id = (await call("POST", "/sessions", {})).body.id;
    await say(id, "Hi there");
    await say(id, "Hello");
    expect((await call("GET", `/sessions/${id}`)).body.session.detected).toBe(false);
    await say(id, "Nice weather today");
    const st = (await call("GET", `/sessions/${id}`)).body;
    expect(st.session).toMatchObject({ detected: true, item: PLACEHOLDER_ITEM, category: "other" });
    expect(st.research.status).toBe("running"); // mock mode researches the placeholder (demo data)
    // a real product named later replaces the placeholder
    await say(id, "So you're selling this Trek road bike for $300?");
    expect((await call("GET", `/sessions/${id}`)).body.session).toMatchObject({ item: "Trek road bike", category: "marketplace" });
  });

  it("set-up sessions never run detection", async () => {
    const id = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000 })).body.id;
    await say(id, "I'm selling my Trek bike for $300", "seller");
    expect((await call("GET", `/sessions/${id}`)).body.session).toMatchObject({ item: "2023 Honda Accord EX", auto: false, listing: null });
  });

  it("mockDetect patterns", () => {
    const L = (speaker: "buyer" | "seller", text: string) => ({ speaker, text, kind: "speech" as const });
    expect(mockDetect([L("seller", "I'm selling my Trek road bike for $300, like new")])).toMatchObject({ item: "Trek road bike", asking_price: 30000, condition_claims: ["like new"] });
    expect(mockDetect([L("buyer", "Would you take $150 for the bike?")])).toMatchObject({ item: "bike", asking_price: null });
    expect(mockDetect([L("seller", "Trek Domane road bike, $650 firm.")])).toMatchObject({ item: "Trek Domane road bike", asking_price: 65000 });
    expect(mockDetect([L("seller", "Hi")]).item).toBeNull();
    expect(normalizeDetectedCategory("Pawn Shop", "ring")).toBe("pawn_shop");
    expect(normalizeDetectedCategory("weird", "MacBook Air")).toBe("electronics");
  });
});

describe("speaker auto", () => {
  it("heuristic: keywords, else alternate from the previous line", () => {
    const prev = (speaker: "buyer" | "seller") => [{ speaker, kind: "speech" as const }];
    expect(guessSpeaker("I'll take it for 200", prev("buyer"))).toBe("buyer");
    expect(guessSpeaker("Can you do 150?", [])).toBe("buyer");
    expect(guessSpeaker("That's firm, sorry", prev("seller"))).toBe("seller");
    expect(guessSpeaker("The lowest I can go is 190", [])).toBe("seller");
    expect(guessSpeaker("Okay", prev("seller"))).toBe("buyer");
    expect(guessSpeaker("Okay", prev("buyer"))).toBe("seller");
    expect(guessSpeaker("Hello", [])).toBe("buyer");
  });

  it("verbatim script lines take the script's speaker; stored speaker is always resolved", async () => {
    const car = readContent("scripts/car_accord.json");
    const id = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000 })).body.id;
    const line = car.lines.find((l: any) => l.speaker === "seller");
    const e = await say(id, line.text);
    expect(e.body.speaker).toBe("seller");
    expect(e.body.cue).toBe(line.expected.cue);
    const events = (await call("GET", `/sessions/${id}`)).body.events as DealEvent[];
    expect(events.every((x) => x.speaker === "buyer" || x.speaker === "seller")).toBe(true);
  });
});

describe("POST /sessions/:id/end", () => {
  it("summarises, sets ended, and is idempotent", async () => {
    const id = (await call("POST", "/sessions", {})).body.id;
    await say(id, "Hey, is the Sony WH-1000XM5 headphones still available?");
    await say(id, "Yeah, I'm asking 220, barely used");
    await say(id, "Can you do $180?");
    await say(id, "Okay, deal.");
    const end = await call("POST", `/sessions/${id}/end`);
    expect(end.status).toBe(200);
    expect(end.body).toMatchObject({ id, status: "ended", summary: { outcome: "deal", final_price: 18000 } });
    expect(end.body.ended_at).toEqual(expect.any(String));
    expect(end.body.summary.headline.split(/\s+/).length).toBeLessThanOrEqual(12);
    expect(end.body.summary.key_points.length).toBeLessThanOrEqual(4);
    expect(end.body.summary.key_points).toContain("Seller asked $220");

    const again = await call("POST", `/sessions/${id}/end`);
    expect(again.body.ended_at).toBe(end.body.ended_at);
    expect(again.body.summary).toEqual(end.body.summary);
    expect((await call("POST", "/sessions/nope/end")).status).toBe(404);
  });

  it("undecided / no deal outcomes, and an empty conversation", async () => {
    const a = (await call("POST", "/sessions", {})).body.id;
    await say(a, "I'm selling my Trek road bike for $300", "seller");
    await say(a, "No thanks, I'll pass.", "buyer");
    expect((await call("POST", `/sessions/${a}/end`)).body.summary).toMatchObject({ outcome: "no_deal", final_price: null });
    const b = (await call("POST", "/sessions", {})).body.id;
    const sb = (await call("POST", `/sessions/${b}/end`)).body;
    expect(sb.summary).toMatchObject({ outcome: "undecided", final_price: null });
    expect(sb.summary.headline).toContain(PLACEHOLDER_ITEM);
  });

  it("stops a playing script", async () => {
    const id = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000 })).body.id;
    await call("POST", `/sessions/${id}/script/play`, { script_id: "car_accord", interval_ms: 50 });
    await new Promise((r) => setTimeout(r, 120));
    const end = await call("POST", `/sessions/${id}/end`);
    expect(end.body.status).toBe("ended");
    const n = (await call("GET", `/sessions/${id}`)).body.events.length;
    await new Promise((r) => setTimeout(r, 200));
    const st = (await call("GET", `/sessions/${id}`)).body;
    expect(st.events.length).toBe(n);
    expect(n).toBeLessThan(25);
    expect(st.script.done).toBe(true);
  });

  it("a paid session stays paid; the summary uses the receipt", async () => {
    const extra = readContent("scripts/seller_extra_fee.json");
    const id = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000, style: "firm" })).body.id;
    await call("POST", `/sessions/${id}/script/play`, { script_id: "car_accord", interval_ms: 0 });
    for (let i = 0; i < 200; i++) {
      if ((await call("GET", `/sessions/${id}`)).body.script?.done) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    const draft = (await call("POST", `/sessions/${id}/agreement`)).body;
    await call("POST", `/agreements/${draft.id}/confirm`, { role: "buyer" });
    await call("POST", `/agreements/${draft.id}/confirm`, { role: "seller" });
    const pr = (await call("POST", `/sessions/${id}/payment-requests`, { line_items: extra.corrected_request.line_items })).body;
    const receipt = (await call("POST", `/payment-requests/${pr.id}/pay`)).body;
    const end = (await call("POST", `/sessions/${id}/end`)).body;
    expect(end).toMatchObject({ status: "paid", summary: { outcome: "deal", final_price: receipt.amount } });
    expect(end.ended_at).toEqual(expect.any(String));
  });
});

describe("GET /sessions history", () => {
  it("includes ended, live and paid sessions with the new fields", async () => {
    const live = (await call("POST", "/sessions", {})).body.id;
    const ended = (await call("POST", "/sessions", {})).body.id;
    await say(ended, "I'm selling my Trek road bike for $300", "seller");
    await say(ended, "Can you do $250?", "buyer");
    await say(ended, "Okay, deal.", "seller");
    await call("POST", `/sessions/${ended}/end`);
    const noPrice = (await call("POST", "/sessions", {})).body.id;
    await say(noPrice, "Is the couch still available?");
    await say(noPrice, "Can you do $100?");
    await say(noPrice, "Sure, deal.");
    await call("POST", `/sessions/${noPrice}/end`);

    const list = (await call("GET", "/sessions")).body as any[];
    const byId = new Map(list.map((s) => [s.id, s]));
    for (const s of list) {
      for (const k of ["auto", "detected", "ended_at", "summary", "final_price", "paid_at", "blocked_total", "savings"]) expect(s).toHaveProperty(k);
    }
    expect(byId.get(live)).toMatchObject({ status: "live", summary: null, final_price: null, savings: null });
    expect(byId.get(ended)).toMatchObject({ status: "ended", final_price: 25000, savings: 5000, paid_at: null, asking_price: 30000 });
    expect(byId.get(noPrice)).toMatchObject({ status: "ended", final_price: 10000, asking_price: null, savings: null });
    expect(list.some((s) => s.status === "paid")).toBe(true); // from the receipt test above
  });
});

describe("null prices: cues and phrases never crash", () => {
  const s = autoSession({ item: "Sony WH-1000XM5 headphones", detected: true, category: "electronics" });

  it("fallback cues with null target / max / asking", () => {
    expect(() => fallbackExtraction("Can you do $180?", "buyer", s)).not.toThrow();
    expect(fallbackExtraction("I'm asking $220.", "seller", s)).toMatchObject({ current_offer: 22000, status: "yellow", cue: "Ask how firm that is." });
    expect(fallbackExtraction("Look, someone offered me $250 already.", "seller", s).tactic_detected).toBeTruthy();
    expect(fallbackExtraction("Oh and $20 for gas, I drove here.", "seller", s).new_terms).toContainEqual(expect.objectContaining({ label: "gas fee", amount: 2000 }));
    expect(mockCue("Nice weather.", "seller", s).status).toBe("yellow");
  });

  it("uses the research fair range when the buyer set no target / max", () => {
    const range = { low: 15000, high: 20000 };
    expect(fallbackExtraction("I can pay $140.", "buyer", s, range)).toMatchObject({ status: "green" });
    expect(fallbackExtraction("It's $180.", "seller", s, range)).toMatchObject({ status: "yellow", cue: "In market range. Push a bit." });
    expect(fallbackExtraction("It's $260.", "seller", s, range)).toMatchObject({ status: "red", cue: "Above market. Hold firm." });
  });

  it("phrases never invent a budget", () => {
    const none = mockPhrases(s, null, null);
    expect(none.length).toBeGreaterThan(0);
    expect(none.map((p) => p.text).join(" ")).not.toMatch(/\$/);
    const withOffer = mockPhrases({ ...s, current_offer: 22000, current_offer_by: "seller" }, null, null);
    expect(withOffer.map((p) => p.text).join(" ")).not.toMatch(/null|NaN|undefined/);
    const research: ResearchState = {
      item: s.item, status: "done", started_at: "",
      agents: [{ id: "comps", title: "Comparable listings", status: "done", activity: "", queries: [], sources: [], summary: "x", price_low: 15000, price_high: 20000, started_at: null, finished_at: null, error: null }],
    };
    const ranged = mockPhrases({ ...s, current_offer: 22000 }, null, research).map((p) => p.text).join(" ");
    expect(ranged).toContain("$150");
    expect(ranged).not.toMatch(/null|NaN|undefined/);
  });

  it("agreement on a session with no prices heard", async () => {
    const id = (await call("POST", "/sessions", {})).body.id;
    await say(id, "Hi there");
    const draft = await call("POST", `/sessions/${id}/agreement`);
    expect(draft.status).toBe(201);
    expect(draft.body).toMatchObject({ price: 0, items: [PLACEHOLDER_ITEM] });
  });
});

describe("real mode (fake Anthropic client)", () => {
  const quiet = { warn: () => undefined };
  function fake(replies: string[]) {
    const calls: any[] = [];
    const client = { messages: { create: async (p: any) => { calls.push(p); const t = replies.shift(); if (t == null) throw new Error("no reply"); return { stop_reason: "end_turn", content: [{ type: "text", text: t }] }; } } };
    return { client: client as any, calls };
  }
  const cfg = { ...loadConfig(), mockMode: false, anthropicApiKey: "test-not-a-key" };
  const cueJson = (extra: object) => JSON.stringify({ current_offer: 22000, offer_by: "seller", new_terms: [], tactic_detected: null, cue: "Ask what's included", cue_detail: null, status: "yellow", ...extra });

  it("cue: the model's speaker wins for 'auto'; heuristic when it omits one; ignored for explicit speakers", async () => {
    const { ClaudeAi } = await import("../src/ai/index.js");
    const { client, calls } = fake([cueJson({ speaker: "seller" }), cueJson({}), cueJson({ speaker: "seller" })]);
    const ai = new ClaudeAi(cfg, quiet, client);
    const s = autoSession();
    expect((await ai.cue({ session: s, recent: [], speaker: "auto", text: "Yeah, 220." })).speaker).toBe("seller");
    expect(JSON.parse(calls[0].messages[0].content).new_line.speaker).toBe("auto");
    expect((await ai.cue({ session: s, recent: [], speaker: "auto", text: "Can you do 180?" })).speaker).toBe("buyer");
    expect((await ai.cue({ session: s, recent: [], speaker: "buyer", text: "Hi" })).speaker).toBeUndefined();
  });

  it("detect normalises the model output; summary is clamped and the receipt wins", async () => {
    const { ClaudeAi } = await import("../src/ai/index.js");
    const { client } = fake([
      JSON.stringify({ item: " Sony WH-1000XM5 headphones ", category: "Electronics", asking_price: 22000, condition_claims: ["barely used"] }),
      JSON.stringify({ outcome: "no_deal", final_price: 1, headline: "one two three four five six seven eight nine ten eleven twelve thirteen", key_points: ["a", "b", "c", "d", "e"] }),
    ]);
    const ai = new ClaudeAi(cfg, quiet, client);
    expect(await ai.detect(autoSession(), [])).toEqual({ item: "Sony WH-1000XM5 headphones", category: "electronics", asking_price: 22000, condition_claims: ["barely used"] });
    const receipt = { amount: 18000 } as any;
    const sum = await ai.summarize({ session: autoSession(), events: [], agreement: null, receipt });
    expect(sum).toMatchObject({ outcome: "deal", final_price: 18000 });
    expect(sum.headline.split(" ")).toHaveLength(12);
    expect(sum.key_points).toHaveLength(4);
  });
});
