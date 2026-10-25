import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { MockAi } from "../src/ai/index.js";
import { ListingSchema, decodeImage, isFacebookUrl, mockConditionCheck } from "../src/listing.js";
import { fallbackExtraction, lookupScriptExpectation } from "../src/mock/extract.js";
import { MockPayments } from "../src/payments/index.js";
import { MemoryStore } from "../src/store/memory.js";
import type { Session } from "../src/types.js";
import { readContent } from "./helpers.js";

const bike = readContent("scripts/marketplace_bike.json");
const extra = readContent("scripts/seller_extra_fee_marketplace.json");
const canned = readContent("listings/marketplace_bike.json");
const FB_URL = "https://www.facebook.com/marketplace/item/1234567890/";
const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

let app: FastifyInstance;
beforeAll(async () => {
  const cfg = { ...loadConfig(), mockMode: true };
  ({ app } = await buildApp(cfg, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), logger: false }));
});
afterAll(async () => app.close());

async function call(method: "GET" | "POST", url: string, payload?: unknown) {
  const res = await app.inject({ method, url, payload: payload as object });
  return { status: res.statusCode, body: res.json() as any };
}

async function bikeSession(withListing = true) {
  const listing = withListing ? (await call("POST", "/listings/parse", { url: FB_URL })).body : undefined;
  const body = { category: bike.category, item: bike.item, asking_price: bike.asking_price, target_price: bike.target_price, max_budget: bike.max_budget, style: bike.style, ...(listing ? { listing } : {}) };
  const s = await call("POST", "/sessions", body);
  expect(s.status).toBe(201);
  return s.body;
}

async function playToEnd(id: string) {
  const play = await call("POST", `/sessions/${id}/script/play`, { script_id: "marketplace_bike", interval_ms: 0 });
  expect(play.body).toMatchObject({ started: true, script_id: "marketplace_bike", line_count: bike.lines.length });
  let state: any;
  for (let i = 0; i < 200; i++) {
    state = (await call("GET", `/sessions/${id}`)).body;
    if (state.script?.done) break;
    await new Promise((r) => setTimeout(r, 10));
  }
  return state;
}

describe("content: marketplace bike", () => {
  it("script is well-formed: 15–25 lines, 3–6 word cues, valid tactics", () => {
    const tactics = new Set(readContent("tactics.json").tactics.map((t: any) => t.id));
    expect(bike.lines.length).toBeGreaterThanOrEqual(15);
    expect(bike.lines.length).toBeLessThanOrEqual(25);
    for (const l of bike.lines) {
      const words = l.expected.cue.split(/\s+/).length;
      expect(words, l.id).toBeGreaterThanOrEqual(3);
      expect(words, l.id).toBeLessThanOrEqual(6);
      if (l.expected.tactic_detected) expect(tactics.has(l.expected.tactic_detected), l.id).toBe(true);
    }
    for (const id of ["fake_competing_buyer", "cash_zelle_pressure", "price_raised_after_agreement", "undisclosed_condition"]) expect(tactics.has(id)).toBe(true);
    expect(bike.expected_agreement).toMatchObject({ price: 52000, total: 52000 });
    expect(extra.blocked_request.line_items.reduce((s: number, l: any) => s + l.amount, 0)).toBe(54000);
    expect(extra.corrected_request.line_items.reduce((s: number, l: any) => s + l.amount, 0)).toBe(52000);
  });

  it.each<[string, any]>(bike.lines.map((l: any) => [l.id, l] as [string, any]))("bike %s returns its expected extraction", (_id, line: any) => {
    expect(lookupScriptExpectation(line.text, line.speaker, "marketplace_bike")).toEqual(line.expected);
  });

  it("canned listing matches the Listing contract", () => {
    const l = ListingSchema.parse(canned);
    expect(l).toMatchObject({ category: "marketplace", source: "facebook_marketplace", asking_price: 65000 });
    expect(l.condition_claims).toEqual(expect.arrayContaining(["like new", "new tires last month", "no scratches"]));
  });
});

describe("fallback tactics for marketplace (free-typed lines)", () => {
  const s = { category: "marketplace", asking_price: 65000, target_price: 52000, max_budget: 58000, current_offer: 52000, current_offer_by: "seller" } as Pick<Session, "category" | "asking_price" | "target_price" | "max_budget" | "current_offer" | "current_offer_by">;
  it("fake competing buyer", () => {
    expect(fallbackExtraction("Look, someone offered me $700 already.", "seller", s)).toMatchObject({ tactic_detected: "fake_competing_buyer", status: "red", cue_detail: "Still listed at $650" });
  });
  it("cash / Zelle pressure", () => {
    expect(fallbackExtraction("Just Zelle me and we're good.", "seller", s)).toMatchObject({ tactic_detected: "cash_zelle_pressure", cue: "Pay verified, not Zelle" });
  });
  it("price raised after agreeing", () => {
    const x = fallbackExtraction("Oh and $20 for gas, I drove here.", "seller", s);
    expect(x).toMatchObject({ tactic_detected: "price_raised_after_agreement", status: "red", current_offer: 52000, cue_detail: "Agreed $520" });
    expect(x.new_terms).toContainEqual({ type: "fee", label: "gas fee", amount: 2000 });
  });
});

describe("POST /listings/parse (mock)", () => {
  it("returns the canned listing and keeps the url", async () => {
    const r = await call("POST", "/listings/parse", { url: FB_URL });
    expect(r.status).toBe(200);
    expect(r.body).toEqual({ ...canned, url: FB_URL });
    expect(isFacebookUrl(FB_URL)).toBe(true);
  });
  it("text or screenshot also returns the canned listing", async () => {
    expect((await call("POST", "/listings/parse", { text: "Road bike, $650, like new" })).body).toEqual(canned);
    expect((await call("POST", "/listings/parse", { image_base64: PNG_1PX })).body.title).toBe(canned.title);
  });
  it("requires at least one input", async () => {
    expect((await call("POST", "/listings/parse", {})).status).toBe(400);
  });
  it("detects image media types", () => {
    expect(decodeImage(PNG_1PX).media_type).toBe("image/png");
    expect(decodeImage("data:image/jpeg;base64,/9j/4AAQ").data).toBe("/9j/4AAQ");
  });
});

describe("sessions with a listing + condition check (mock)", () => {
  it("stores the listing on the session and returns it from GET", async () => {
    const s = await bikeSession();
    expect(s.listing).toMatchObject({ title: canned.title, url: FB_URL });
    expect(s.condition_checks).toEqual([]);
    const state = (await call("GET", `/sessions/${s.id}`)).body;
    expect(state.session.listing.condition_claims).toContain("new tires last month");
  });

  it("rejects an invalid listing and keeps listing optional", async () => {
    const base = { category: "car", item: "x", asking_price: 100, target_price: 90, max_budget: 95, style: "firm" };
    expect((await call("POST", "/sessions", { ...base, listing: { ...canned, asking_price: 650.5 } })).status).toBe(400);
    expect((await call("POST", "/sessions", base)).body.listing).toBeNull();
  });

  it("worn tires → $40 off cue, inserted as a condition_check event", async () => {
    const s = await bikeSession();
    const r = await call("POST", `/sessions/${s.id}/condition-check`, { observation: "The tires are worn and the rear one is cracked" });
    expect(r.status).toBe(201);
    expect(r.body.discrepancies).toEqual([
      { claim: "new tires last month", observed: "Tires are worn, with cracks in the rear sidewall", suggested_discount: 4000, cue: "Tires worn: ask $40 off" },
    ]);
    expect(r.body.event).toMatchObject({ kind: "condition_check", speaker: "buyer", tactic: "undisclosed_condition", cue: "Tires worn: ask $40 off", cue_detail: 'Listing says "new tires last month"', status_color: "yellow", seq: 1 });
    const state = (await call("GET", `/sessions/${s.id}`)).body;
    expect(state.events.map((e: any) => e.kind)).toEqual(["condition_check"]);
    expect(state.session.condition_checks).toHaveLength(1);
    expect(state.session.condition_checks[0]).toMatchObject({ event_id: r.body.event.id, had_image: false });
  });

  it("photo only → canned tires discrepancy; 'looks great' → none", async () => {
    const s = await bikeSession();
    const photo = await call("POST", `/sessions/${s.id}/condition-check`, { image_base64: PNG_1PX });
    expect(photo.body.discrepancies[0]).toMatchObject({ claim: "new tires last month", suggested_discount: 4000 });
    expect(photo.body.event.text).toContain("photo of the item");
    const fine = await call("POST", `/sessions/${s.id}/condition-check`, { observation: "Looks great, matches the listing" });
    expect(fine.body.discrepancies).toEqual([]);
    expect(fine.body.event).toMatchObject({ cue: "Matches the listing. Proceed.", status_color: "green", tactic: null });
  });

  it("multiple issues map to distinct claims", () => {
    const d = mockConditionCheck(ListingSchema.parse(canned), { observation: "worn tires and a big scratch on the top tube" });
    expect(d.map((x) => x.claim)).toEqual(["new tires last month", "no scratches"]);
  });

  it("validates condition-check input and requires a listing", async () => {
    const s = await bikeSession(false);
    expect((await call("POST", `/sessions/${s.id}/condition-check`, {})).status).toBe(400);
    expect((await call("POST", `/sessions/${s.id}/condition-check`, { observation: "worn tires" })).status).toBe(409);
    expect((await call("POST", "/sessions/nope/condition-check", { observation: "worn tires" })).status).toBe(404);
  });
});

describe("marketplace meetup end to end (mock mode)", () => {
  it("listing → condition check → bike script → lock $520 → $20 gas fee BLOCKED → reject → pay $520", async () => {
    expect((await call("GET", "/scripts")).body.scripts).toContain("marketplace_bike");
    const s = await bikeSession();
    const cc = await call("POST", `/sessions/${s.id}/condition-check`, { observation: "Tires are worn" });
    expect(cc.body.discrepancies[0].suggested_discount).toBe(4000);

    const state = await playToEnd(s.id);
    expect(state.script.error).toBeNull();
    expect(state.events).toHaveLength(bike.lines.length + 1);
    expect(state.session.current_offer).toBe(52000);
    const tactic = (lineId: string) => state.events.find((e: any) => e.script_line_id === lineId)?.tactic;
    expect(tactic("evt_03")).toBe("undisclosed_condition");
    expect(tactic("evt_06")).toBe("fake_competing_buyer");
    expect(tactic("evt_08")).toBe("cash_zelle_pressure");

    const draft = (await call("POST", `/sessions/${s.id}/agreement`)).body;
    expect(draft).toMatchObject({ price: 52000, items: [bike.item, "pedals"], fees: [], total: 52000, open_questions: [] });
    expect(draft.source_event_ids).toHaveLength(2);
    await call("POST", `/agreements/${draft.id}/confirm`, { role: "buyer" });
    const locked = (await call("POST", `/agreements/${draft.id}/confirm`, { role: "seller" })).body;
    expect(locked.status).toBe("locked");

    // Seller asks for gas money in person: live cue flags it.
    const ev = await call("POST", `/sessions/${s.id}/events`, { speaker: "seller", text: "Oh, and twenty bucks for gas, I drove here." });
    expect(ev.body).toMatchObject({ tactic: "price_raised_after_agreement", status_color: "red", kind: "speech" });

    // ...then tries to add it at the terminal: blocked by the mismatch rule.
    const blocked = (await call("POST", `/sessions/${s.id}/payment-requests`, { line_items: extra.blocked_request.line_items })).body;
    expect(blocked.status).toBe("blocked");
    expect(blocked.amount).toBe(54000);
    expect(blocked.mismatch.reasons).toEqual(expect.arrayContaining(["amount_mismatch", "unmatched_line_items"]));
    expect(blocked.mismatch.unmatched_line_items).toEqual([{ label: "gas fee", amount: 2000 }]);
    expect(blocked.mismatch.difference).toBe(2000);
    expect(blocked.mismatch_explanation).toContain("No extra charges");
    expect((await call("POST", `/payment-requests/${blocked.id}/pay`)).status).toBe(409);
    expect((await call("POST", `/payment-requests/${blocked.id}/decision`, { decision: "reject" })).body.status).toBe("rejected");

    const ok = (await call("POST", `/sessions/${s.id}/payment-requests`, { line_items: extra.corrected_request.line_items })).body;
    expect(ok).toMatchObject({ status: "approved", amount: 52000 });
    const receipt = (await call("POST", `/payment-requests/${ok.id}/pay`)).body;
    expect(receipt).toMatchObject({ amount: 52000, blocked_total: 2000, agreement_fingerprint: locked.fingerprint, summary: "Asked $650, paid $520, blocked $20" });

    const pack = (await call("GET", `/sessions/${s.id}/dispute-pack`)).body;
    expect(pack.listing).toMatchObject({ title: canned.title, url: FB_URL });
    expect(pack.condition_discrepancies).toEqual([expect.objectContaining({ claim: "new tires last month", suggested_discount: 4000, event_id: cc.body.event.id })]);
    expect(pack.transcript_excerpts.map((e: any) => e.id)).toContain(cc.body.event.id);
    expect(pack.fingerprint.valid).toBe(true);
  });

  it("car dispute pack has listing null and no discrepancies", async () => {
    const s = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000, style: "firm" })).body;
    const pack = (await call("GET", `/sessions/${s.id}/dispute-pack`)).body;
    expect(pack.listing).toBeNull();
    expect(pack.condition_discrepancies).toEqual([]);
  });
});
