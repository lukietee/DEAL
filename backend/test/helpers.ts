import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { computeFingerprint } from "../src/fingerprint.js";
import type { Agreement, DealEvent } from "../src/types.js";

export const CONTENT = resolve(import.meta.dirname, "..", "..", "content");
export const readContent = (p: string) => JSON.parse(readFileSync(resolve(CONTENT, p), "utf8"));

export function lockedCarAgreement(overrides: Partial<Agreement> = {}): Agreement {
  const base: Agreement = {
    id: "agr_test",
    session_id: "ses_test",
    price: 3460000,
    items: ["2023 Honda Accord EX", "floor mats"],
    fees: [{ label: "doc fee", amount: 0, note: "waived" }],
    total: 3460000,
    source_event_ids: ["evt_21", "evt_22", "evt_24"],
    open_questions: [],
    status: "locked",
    buyer_confirmed_at: "2026-10-24T21:14:05.000Z",
    seller_confirmed_at: "2026-10-24T21:14:09.000Z",
    fingerprint: null,
    version: 1,
    amendments: [],
    created_at: "2026-10-24T21:13:00.000Z",
    updated_at: "2026-10-24T21:14:09.000Z",
    ...overrides,
  };
  return { ...base, fingerprint: overrides.fingerprint ?? computeFingerprint(base) };
}

export function carEvents(): DealEvent[] {
  const script = readContent("scripts/car_accord.json");
  return script.lines.map((l: any, i: number) => ({
    id: `evt_real_${i + 1}`,
    session_id: "ses_test",
    seq: i + 1,
    speaker: l.speaker,
    text: l.text,
    timestamp: new Date(Date.UTC(2026, 9, 24, 21, 10 + Math.floor(i / 6), (i * 10) % 60)).toISOString(),
    extracted_offer: l.expected.current_offer,
    offer_by: l.expected.offer_by,
    new_terms: l.expected.new_terms,
    tactic: l.expected.tactic_detected,
    cue: l.expected.cue,
    cue_detail: l.expected.cue_detail ?? null,
    status_color: l.expected.status,
    script_line_id: l.id,
  }));
}
