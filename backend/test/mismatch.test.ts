import { describe, expect, it } from "vitest";
import { checkPaymentRequest, labelsMatch, templateExplanation } from "../src/mismatch.js";
import { carEvents, lockedCarAgreement, readContent } from "./helpers.js";

const extra = readContent("scripts/seller_extra_fee.json");
const events = carEvents();

describe("checkPaymentRequest (12.5 rules 1–3)", () => {
  it("match: corrected request is approved", () => {
    const m = checkPaymentRequest(lockedCarAgreement(), extra.corrected_request.line_items, events);
    expect(m.ok).toBe(true);
    expect(m.reasons).toEqual([]);
    expect(m.requested_total).toBe(3460000);
    expect(m.difference).toBe(0);
  });

  it("match: only the main item at the agreed price", () => {
    const m = checkPaymentRequest(lockedCarAgreement(), [{ label: "  2023 HONDA Accord EX ", amount: 3460000 }], events);
    expect(m.ok).toBe(true);
  });

  it("extra fee: $1,200 protection package is blocked", () => {
    const m = checkPaymentRequest(lockedCarAgreement(), extra.blocked_request.line_items, events);
    expect(m.ok).toBe(false);
    expect(m.reasons).toContain("amount_mismatch");
    expect(m.reasons).toContain("unmatched_line_items");
    expect(m.unmatched_line_items).toEqual([{ label: "protection package", amount: 120000 }]);
    expect(m.difference).toBe(extra.blocked_request.expected_extra_amount);
    expect(m.fingerprint_valid).toBe(true);
  });

  it("extra item even when the sum matches is blocked (rule 3)", () => {
    const m = checkPaymentRequest(
      lockedCarAgreement(),
      [{ label: "2023 Honda Accord EX", amount: 3340000 }, { label: "protection package", amount: 120000 }],
      events,
    );
    expect(m.ok).toBe(false);
    expect(m.reasons).toEqual(expect.arrayContaining(["unmatched_line_items", "line_item_amount_mismatch"]));
    expect(m.reasons).not.toContain("amount_mismatch");
  });

  it("changed amount: main item charged higher is blocked", () => {
    const m = checkPaymentRequest(lockedCarAgreement(), [{ label: "2023 Honda Accord EX", amount: 3560000 }], events);
    expect(m.ok).toBe(false);
    expect(m.reasons).toEqual(["amount_mismatch", "line_item_amount_mismatch"]);
    expect(m.difference).toBe(100000);
  });

  it("changed amount: waived doc fee reinstated is blocked", () => {
    const m = checkPaymentRequest(
      lockedCarAgreement(),
      [{ label: "2023 Honda Accord EX", amount: 3460000 }, { label: "doc fee", amount: 49900 }],
      events,
    );
    expect(m.ok).toBe(false);
    expect(m.mismatched_amount_line_items).toEqual([{ label: "doc fee", amount: 49900 }]);
  });

  it("changed amount: included item charged is blocked", () => {
    const m = checkPaymentRequest(
      lockedCarAgreement(),
      [{ label: "2023 Honda Accord EX", amount: 3440000 }, { label: "floor mats", amount: 20000 }],
      events,
    );
    expect(m.ok).toBe(false);
    expect(m.reasons).toEqual(["line_item_amount_mismatch"]);
  });

  it("tampered agreement: total edited after confirmation is blocked even if the request matches it", () => {
    const tampered = { ...lockedCarAgreement(), total: 3580000, price: 3580000 };
    const m = checkPaymentRequest(tampered, [{ label: "2023 Honda Accord EX", amount: 3580000 }], events);
    expect(m.ok).toBe(false);
    expect(m.fingerprint_valid).toBe(false);
    expect(m.reasons).toEqual(["fingerprint_mismatch"]);
  });

  it("tampered agreement: item silently added is blocked", () => {
    const a = lockedCarAgreement();
    const tampered = { ...a, items: [...a.items, "protection package"] };
    const m = checkPaymentRequest(tampered, extra.corrected_request.line_items, events);
    expect(m.reasons).toContain("fingerprint_mismatch");
  });

  it("unlocked agreement is never ok", () => {
    const a = { ...lockedCarAgreement(), status: "draft" as const, fingerprint: null };
    const m = checkPaymentRequest(a, extra.corrected_request.line_items, events);
    expect(m.ok).toBe(false);
    expect(m.reasons).toContain("agreement_not_locked");
  });

  it("cites the seller's 'no other fees' line (evt_24) as the source", () => {
    const m = checkPaymentRequest(lockedCarAgreement(), extra.blocked_request.line_items, events);
    const src = events.find((e) => e.script_line_id === extra.blocked_request.contradicting_event_id)!;
    expect(m.source_event_id).toBe(src.id);
    expect(m.source_event_text).toBe(src.text);
    expect(m.source_event_timestamp).toBe(src.timestamp);
  });
});

describe("labelsMatch", () => {
  it("is exact, case-insensitive, trimmed", () => {
    expect(labelsMatch("Doc Fee", "doc fee")).toBe(true);
    expect(labelsMatch(" floor mats ", "floor mats")).toBe(true);
    expect(labelsMatch("floor mat", "floor mats")).toBe(false);
    expect(labelsMatch("2023 Honda Accord EX protection package", "2023 Honda Accord EX")).toBe(false);
  });
});

describe("templateExplanation (rule 4 mock)", () => {
  it("is one sentence citing the line, time and extra amount", () => {
    const m = checkPaymentRequest(lockedCarAgreement(), extra.blocked_request.line_items, events);
    const s = templateExplanation(m, "UTC");
    expect(s).toContain("protection package ($1,200.00)");
    expect(s).toContain("$34,600.00");
    expect(s).toContain(m.source_event_text!);
    expect(s).toMatch(/at \d{1,2}:\d{2} (AM|PM)/);
    expect(s.trim().endsWith(".")).toBe(true);
  });
  it("explains a tampered agreement", () => {
    const m = checkPaymentRequest({ ...lockedCarAgreement(), total: 1 }, [{ label: "2023 Honda Accord EX", amount: 1 }], events);
    expect(templateExplanation(m)).toMatch(/fingerprint no longer matches/);
  });
});
