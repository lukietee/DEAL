import { describe, expect, it } from "vitest";
import { mapSourceIds, mockAgreement } from "../src/mock/agreement.js";
import { mergeTerms } from "../src/deal.js";
import { fallbackExtraction, lookupScriptExpectation, mockCue, parseMoney } from "../src/mock/extract.js";
import type { Session } from "../src/types.js";
import { carEvents, readContent } from "./helpers.js";

const car = readContent("scripts/car_accord.json");
const pawn = readContent("scripts/pawn_guitar.json");

function session(over: Partial<Session> = {}): Session {
  return {
    id: "ses_test", category: "car", item: car.item, asking_price: car.asking_price, target_price: car.target_price,
    max_budget: car.max_budget, style: "firm", status: "live", join_code: "ABC123", current_offer: null,
    current_offer_by: null, terms: [], created_at: "", updated_at: "", ...over,
  };
}

describe("mock extraction: script lookups", () => {
  it.each<[string, any]>(car.lines.map((l: any) => [l.id, l] as [string, any]))("car %s returns its expected extraction", (_id, line: any) => {
    expect(mockCue(line.text, line.speaker, session(), "car_accord")).toEqual(line.expected);
  });

  it.each<[string, any]>(pawn.lines.map((l: any) => [l.id, l] as [string, any]))("pawn %s returns its expected extraction", (_id, line: any) => {
    expect(lookupScriptExpectation(line.text, line.speaker, "pawn_guitar")).toEqual(line.expected);
  });

  it("matches despite case and punctuation differences", () => {
    const l = car.lines.find((x: any) => x.id === "evt_12");
    const got = lookupScriptExpectation(l.text.toUpperCase().replace(/[?.!]/g, ""), "seller");
    expect(got?.tactic_detected).toBe("monthly_payment_framing");
    expect(got?.cue_detail).toBe("$489/mo × 72 = $35,208");
  });
});

describe("mock extraction: keyword/regex fallback", () => {
  it("parses money formats", () => {
    expect(parseMoney("I can do $34,600 or 35k").map((m) => m.cents)).toEqual([3460000, 3500000]);
    expect(parseMoney("$489 a month")[0]).toMatchObject({ cents: 48900, monthly: true });
    expect(parseMoney("It's a 2023 with 28,000 miles")).toEqual([]);
  });

  it("detects monthly payment framing with total math", () => {
    const x = fallbackExtraction("So what kind of monthly payment works? I could do $520 a month.", "seller", session());
    expect(x.tactic_detected).toBe("monthly_payment_framing");
    expect(x.cue).toBe("Redirect to total price");
    expect(x.cue_detail).toBe("$520/mo × 72 = $37,440");
    expect(x.status).toBe("yellow");
  });

  it("detects pressure tactics as red", () => {
    const x = fallbackExtraction("Honestly this deal is today only, someone else is looking at it.", "seller", session({ current_offer: 3500000, current_offer_by: "seller" }));
    expect(x.tactic_detected).toBe("false_urgency");
    expect(x.status).toBe("red");
    expect(x.current_offer).toBe(3500000); // carried forward
  });

  it("extracts a price offer and status vs target/max", () => {
    expect(fallbackExtraction("I can do $34,000 for it.", "buyer", session())).toMatchObject({ current_offer: 3400000, offer_by: "buyer", status: "green" });
    expect(fallbackExtraction("Best I can do is $35,500.", "seller", session())).toMatchObject({ current_offer: 3550000, status: "yellow" });
    expect(fallbackExtraction("It's $37,900.", "seller", session())).toMatchObject({ current_offer: 3790000, status: "red" });
  });

  it("extracts a surprise fee as a new term", () => {
    const x = fallbackExtraction("There's also a $350 processing fee.", "seller", session({ current_offer: 3460000 }));
    expect(x.new_terms).toContainEqual({ type: "fee", label: "processing fee", amount: 35000 });
    expect(x.tactic_detected).toBe("surprise_fee");
    expect(x.current_offer).toBe(3460000);
  });

  it("flags an offer just above a comparable", () => {
    const x = fallbackExtraction("I'll let it go for $34,940.", "seller", session());
    expect(x.tactic_detected).toBe("near_comparable");
    expect(x.cue).toBe("Mention the $340 comparable");
  });

  it("always returns a short cue", () => {
    const x = fallbackExtraction("Nice weather today.", "seller", session());
    expect(x.cue.split(/\s+/).length).toBeLessThanOrEqual(6);
    expect(x.tactic_detected).toBeNull();
  });
});

describe("mock agreement", () => {
  // Session state after playing the car script: terms merged from every line's extraction.
  function playedCar() {
    const events = carEvents();
    let terms: Session["terms"] = [];
    for (const e of events) terms = mergeTerms(terms, e.new_terms, e.id);
    return { events, s: session({ terms, current_offer: 3460000, current_offer_by: "seller" }) };
  }

  it("reproduces the script expected_agreement from terms, with real event ids", () => {
    const { events, s } = playedCar();
    const a = mockAgreement(s, events);
    const { source_event_ids, ...rest } = car.expected_agreement;
    expect(a).toMatchObject(rest);
    expect(a.source_event_ids).toEqual(mapSourceIds(source_event_ids, events));
    expect(a.source_event_ids.every((id) => id.startsWith("evt_real_"))).toBe(true);
  });

  it("reproduces the pawn expected_agreement (promise listed as an item)", () => {
    const events = pawn.lines.map((l: any, i: number) => ({
      id: `p${i}`, session_id: "x", seq: i + 1, speaker: l.speaker, text: l.text, timestamp: new Date(0).toISOString(),
      extracted_offer: l.expected.current_offer, offer_by: l.expected.offer_by, new_terms: l.expected.new_terms,
      tactic: null, cue: null, cue_detail: null, status_color: l.expected.status, script_line_id: l.id,
    }));
    let terms: Session["terms"] = [];
    for (const e of events) terms = mergeTerms(terms, e.new_terms, e.id);
    const s = session({ item: pawn.item, category: "pawn_shop", asking_price: pawn.asking_price, terms });
    const { source_event_ids, ...rest } = pawn.expected_agreement;
    expect(mockAgreement(s, events)).toMatchObject(rest);
  });

  it("honours buyer corrections: renamed, re-priced and removed terms", () => {
    const { events, s } = playedCar();
    const mats = s.terms.find((t) => t.label === "floor mats")!;
    const doc = s.terms.find((t) => t.label === "doc fee")!;
    const price = s.terms.find((t) => t.type === "price")!;
    Object.assign(mats, { label: "floor mats (all-weather)", original_label: "floor mats", corrected: true });
    Object.assign(price, { amount: 3450000, corrected: true });
    const a = mockAgreement(s, events);
    expect(a.items).toEqual(["2023 Honda Accord EX", "floor mats (all-weather)"]);
    expect(a.price).toBe(3450000);
    expect(a.total).toBe(3450000);
    expect(a.fees).toEqual([{ label: "doc fee", amount: 0, note: "waived" }]);

    doc.removed = true;
    expect(mockAgreement(s, events).fees).toEqual([]);
  });

  it("a corrected term is not overwritten when the transcript mentions it again", () => {
    let terms = mergeTerms([], [{ type: "item", label: "floor mats", amount: 0 }], "e1");
    terms[0] = { ...terms[0]!, label: "floor mats (all-weather)", original_label: "floor mats", corrected: true };
    terms = mergeTerms(terms, [{ type: "item", label: "floor mats", amount: 0 }], "e2");
    expect(terms).toHaveLength(1);
    expect(terms[0]).toMatchObject({ label: "floor mats (all-weather)", corrected: true, source_event_id: "e2" });
  });

  it("falls back to extracted terms for unscripted sessions", () => {
    const s = session({
      current_offer: 3500000,
      terms: [
        { id: "term_1", type: "price", label: "price", amount: 3500000, source_event_id: "e1", uncertain: false, corrected: false, removed: false },
        { id: "term_2", type: "fee", label: "doc fee", amount: 49900, source_event_id: "e2", uncertain: false, corrected: false, removed: false },
        { id: "term_3", type: "item", label: "floor mats", amount: 0, source_event_id: "e2", uncertain: false, corrected: false, removed: false },
      ],
    });
    const a = mockAgreement(s, []);
    expect(a).toMatchObject({ price: 3500000, total: 3549900, items: [car.item, "floor mats"], fees: [{ label: "doc fee", amount: 49900 }] });
  });
});

describe("model JSON parsing (real-mode helper)", async () => {
  const { extractJson } = await import("../src/ai/index.js");
  const { CueExtractionSchema } = await import("../src/content.js");
  it("tolerates code fences and validates with zod", () => {
    const raw = '```json\n{"current_offer":3490000,"offer_by":"seller","new_terms":[],"tactic_detected":null,"cue":"Hold firm","status":"yellow"}\n```';
    expect(CueExtractionSchema.parse(extractJson(raw)).current_offer).toBe(3490000);
  });
  it("rejects float money and bad status", () => {
    expect(CueExtractionSchema.safeParse({ current_offer: 34.9, offer_by: null, new_terms: [], tactic_detected: null, cue: "x", status: "blue" }).success).toBe(false);
    expect(() => extractJson("no json here")).toThrow();
  });
});
