import { afterAll, beforeAll, describe, expect, it } from "vitest";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { MockAi } from "../src/ai/index.js";
import { MockPayments } from "../src/payments/index.js";
import { MemoryStore } from "../src/store/memory.js";
import { readContent } from "./helpers.js";

const extra = readContent("scripts/seller_extra_fee.json");
let app: FastifyInstance;

beforeAll(async () => {
  const cfg = { ...loadConfig(), mockMode: true };
  ({ app } = await buildApp(cfg, { store: new MemoryStore(), ai: new MockAi(), payments: new MockPayments(), logger: false }));
});
afterAll(async () => app.close());

async function call(method: "GET" | "POST" | "PATCH", url: string, payload?: unknown) {
  const res = await app.inject({ method, url, payload: payload as object });
  return { status: res.statusCode, body: res.json() as any };
}

describe("end-to-end demo flow (mock mode, in-memory)", () => {
  it("runs 12.6 from session to receipt", async () => {
    const health = await call("GET", "/health");
    expect(health.body).toMatchObject({ ok: true, ai: "mock", store: "memory", payments: "mock" });

    const s = await call("POST", "/sessions", {
      category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000, style: "firm",
    });
    expect(s.status).toBe(201);
    expect(s.body.join_code).toMatch(/^[A-Z2-9]{6}$/);
    const id = s.body.id;

    const joined = await call("POST", "/sessions/join", { join_code: s.body.join_code.toLowerCase() });
    expect(joined.body.id).toBe(id);

    const play = await call("POST", `/sessions/${id}/script/play`, { script_id: "car_accord", interval_ms: 0 });
    expect(play.body).toMatchObject({ started: true, line_count: 25 });
    let state: any;
    for (let i = 0; i < 100; i++) {
      state = (await call("GET", `/sessions/${id}`)).body;
      if (state.script?.done) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    expect(state.events).toHaveLength(25);
    expect(state.session.current_offer).toBe(3460000);
    const monthly = state.events.find((e: any) => e.script_line_id === "evt_12");
    expect(monthly).toMatchObject({ tactic: "monthly_payment_framing", cue: "Redirect to total price", cue_detail: "$489/mo × 72 = $35,208", status_color: "yellow" });
    const docFee = state.session.terms.find((t: any) => t.label === "doc fee");
    expect(docFee.amount).toBe(0);

    // fix a term
    const fixed = await call("PATCH", `/sessions/${id}/terms`, { term_id: docFee.id, correction: { amount: 0 } });
    expect(fixed.body.terms.find((t: any) => t.id === docFee.id).corrected).toBe(true);

    // live free-typed event
    const ev = await call("POST", `/sessions/${id}/events`, { speaker: "seller", text: "Remember, this price is only good today." });
    expect(ev.status).toBe(201);
    expect(ev.body).toMatchObject({ tactic: "false_urgency", status_color: "red" });

    // payment before agreement → 409
    expect((await call("POST", `/sessions/${id}/payment-requests`, { line_items: extra.corrected_request.line_items })).status).toBe(409);

    const draft = await call("POST", `/sessions/${id}/agreement`);
    expect(draft.status).toBe(201);
    expect(draft.body).toMatchObject({ price: 3460000, total: 3460000, status: "draft", fingerprint: null });
    expect(draft.body.source_event_ids).toHaveLength(3);

    const b = await call("POST", `/agreements/${draft.body.id}/confirm`, { role: "buyer" });
    expect(b.body.status).toBe("draft");
    const sc = await call("POST", `/agreements/${draft.body.id}/confirm`, { role: "seller" });
    expect(sc.body.status).toBe("locked");
    expect(sc.body.fingerprint).toMatch(/^[0-9a-f]{64}$/);
    expect(sc.body.fingerprint_valid).toBe(true);
    const fp1 = sc.body.fingerprint;

    const blocked = await call("POST", `/sessions/${id}/payment-requests`, { line_items: extra.blocked_request.line_items });
    expect(blocked.body.status).toBe("blocked");
    expect(blocked.body.amount).toBe(3580000);
    expect(blocked.body.mismatch.unmatched_line_items).toEqual([{ label: "protection package", amount: 120000 }]);
    expect(blocked.body.mismatch_explanation).toContain("No other fees, no add-ons");

    // can't pay a blocked request
    expect((await call("POST", `/payment-requests/${blocked.body.id}/pay`)).status).toBe(409);

    const rejected = await call("POST", `/payment-requests/${blocked.body.id}/decision`, { decision: "reject" });
    expect(rejected.body.status).toBe("rejected");

    const ok = await call("POST", `/sessions/${id}/payment-requests`, { line_items: extra.corrected_request.line_items });
    expect(ok.body.status).toBe("approved");

    const receipt = await call("POST", `/payment-requests/${ok.body.id}/pay`);
    expect(receipt.status).toBe(201);
    expect(receipt.body).toMatchObject({ amount: 3460000, status: "succeeded", agreement_fingerprint: fp1, blocked_total: 120000, mock: true });
    expect(receipt.body.summary).toBe("Asked $38,000, paid $34,600, blocked $1,200");
    expect(receipt.body.stripe_payment_id).toMatch(/^pi_/);

    // double pay rejected
    expect((await call("POST", `/payment-requests/${ok.body.id}/pay`)).status).toBe(409);

    const final = (await call("GET", `/sessions/${id}`)).body;
    expect(final.session.status).toBe("paid");
    expect(final.receipt.id).toBe(receipt.body.id);
    expect(final.payment_requests.map((p: any) => p.status)).toEqual(["rejected", "paid"]);

    const list = (await call("GET", "/sessions")).body;
    expect(list[0]).toMatchObject({ id, final_price: 3460000, blocked_total: 120000, savings: 340000 });

    const pack = (await call("GET", `/sessions/${id}/dispute-pack`)).body;
    expect(pack.fingerprint.valid).toBe(true);
    expect(pack.transcript_excerpts.length).toBeGreaterThan(0);

    const comps = await call("GET", "/comparables/Pawn Shop");
    expect(comps.status).toBe(200);
    expect(comps.body.listings.length).toBeGreaterThan(0);
  });

  it("approve flow amends the agreement and re-fingerprints", async () => {
    const s = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000, style: "firm" })).body;
    await call("POST", `/sessions/${s.id}/script/play`, { script_id: "car_accord", interval_ms: 0 });
    for (let i = 0; i < 100; i++) {
      if ((await call("GET", `/sessions/${s.id}`)).body.script?.done) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    const a = (await call("POST", `/sessions/${s.id}/agreement`)).body;
    await call("POST", `/agreements/${a.id}/confirm`, { role: "seller" });
    const locked = (await call("POST", `/agreements/${a.id}/confirm`, { role: "buyer" })).body;
    const pr = (await call("POST", `/sessions/${s.id}/payment-requests`, { line_items: extra.blocked_request.line_items })).body;
    expect(pr.status).toBe("blocked");
    const approved = await call("POST", `/payment-requests/${pr.id}/decision`, { decision: "approve" });
    expect(approved.body.status).toBe("approved");
    const after = (await call("GET", `/sessions/${s.id}`)).body.agreement;
    expect(after.total).toBe(3580000);
    expect(after.fees).toContainEqual({ label: "protection package", amount: 120000, note: "added at checkout, approved by buyer" });
    expect(after.fingerprint).not.toBe(locked.fingerprint);
    expect(after.fingerprint_valid).toBe(true);
    expect(after.version).toBe(2);
    expect(after.amendments[0]).toMatchObject({ payment_request_id: pr.id, previous_total: 3460000, new_total: 3580000, previous_fingerprint: locked.fingerprint });
    const receipt = (await call("POST", `/payment-requests/${pr.id}/pay`)).body;
    expect(receipt).toMatchObject({ amount: 3580000, blocked_total: 0, agreement_fingerprint: after.fingerprint });
  });

  it("PATCH /terms corrections reach the drafted agreement (iOS repro)", async () => {
    const s = (await call("POST", "/sessions", { category: "car", item: "2023 Honda Accord EX", asking_price: 3800000, target_price: 3450000, max_budget: 3600000, style: "firm" })).body;
    await call("POST", `/sessions/${s.id}/script/play`, { script_id: "car_accord", interval_ms: 0 });
    let state: any;
    for (let i = 0; i < 100; i++) {
      state = (await call("GET", `/sessions/${s.id}`)).body;
      if (state.script?.done) break;
      await new Promise((r) => setTimeout(r, 10));
    }
    const mats = state.session.terms.find((t: any) => t.label === "floor mats");
    const patched = await call("PATCH", `/sessions/${s.id}/terms`, { term_id: mats.id, correction: { label: "floor mats (all-weather)" } });
    expect(patched.body.terms.find((t: any) => t.id === mats.id)).toMatchObject({ label: "floor mats (all-weather)", original_label: "floor mats", corrected: true });
    const a = (await call("POST", `/sessions/${s.id}/agreement`)).body;
    expect(a.items).toEqual(["2023 Honda Accord EX", "floor mats (all-weather)"]);
    expect(a.total).toBe(3460000);
    expect(a.source_event_ids).toHaveLength(3);
  });

  it("validates bodies", async () => {
    expect((await call("POST", "/sessions", { item: "x" })).status).toBe(400);
    expect((await call("POST", "/sessions", { category: "car", item: "x", asking_price: 10.5, target_price: 1, max_budget: 1, style: "firm" })).status).toBe(400);
    expect((await call("GET", "/sessions/nope")).status).toBe(404);
  });
});
