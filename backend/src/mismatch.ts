// Deterministic charge check (12.5 "Mismatch rule"). Pure functions, no I/O.
import { computeFingerprint } from "./fingerprint.js";
import { formatCents } from "./money.js";
import type { Agreement, DealEvent, LineItem, MismatchDetails } from "./types.js";

/** Labels compare case-insensitively after trimming and collapsing internal whitespace. */
export function normalizeLabel(label: string): string {
  return label.trim().toLowerCase().replace(/\s+/g, " ");
}

export function labelsMatch(requested: string, term: string): boolean {
  const r = normalizeLabel(requested);
  return r.length > 0 && r === normalizeLabel(term);
}

export type LineItemMatch =
  | { kind: "main_item"; expected: number }
  | { kind: "item"; expected: number }
  | { kind: "fee"; expected: number }
  | { kind: "none" };

/**
 * Map a requested line item onto the agreement (content convention):
 * items[0] is the main item and carries `price`; other items are $0; fees carry their agreed amount.
 */
export function matchLineItem(item: LineItem, agreement: Pick<Agreement, "items" | "fees" | "price">): LineItemMatch {
  const idx = agreement.items.findIndex((i) => labelsMatch(item.label, i));
  if (idx === 0) return { kind: "main_item", expected: agreement.price };
  if (idx > 0) return { kind: "item", expected: 0 };
  const fee = agreement.fees.find((f) => labelsMatch(item.label, f.label));
  if (fee) return { kind: "fee", expected: fee.amount };
  return { kind: "none" };
}

export function lineItemMapsToAgreement(item: LineItem, agreement: Pick<Agreement, "items" | "fees" | "price">): boolean {
  return matchLineItem(item, agreement).kind !== "none";
}

export function sumLineItems(items: LineItem[]): number {
  return items.reduce((s, li) => s + li.amount, 0);
}

/** Pick the transcript line that best evidences the agreed total (rule 4 citation). */
export function findSourceEvent(agreement: Pick<Agreement, "source_event_ids" | "price">, events: DealEvent[]): DealEvent | null {
  const byId = new Map<string, DealEvent>();
  for (const e of events) {
    byId.set(e.id, e);
    if (e.script_line_id) byId.set(e.script_line_id, e);
  }
  const sources = agreement.source_event_ids.map((id) => byId.get(id)).filter((e): e is DealEvent => !!e);
  const priced = sources.filter((e) => e.extracted_offer === agreement.price);
  if (priced.length) return priced[priced.length - 1]!;
  if (sources.length) return sources[sources.length - 1]!;
  const anyPriced = events.filter((e) => e.extracted_offer === agreement.price);
  return anyPriced.length ? anyPriced[anyPriced.length - 1]! : null;
}

/**
 * Rules 1–3 of 12.5:
 * 1. Recomputed fingerprint must equal agreement.fingerprint.
 * 2. Sum of line_items must equal agreement.total.
 * 3. Every line-item label must map to an agreement item/fee.
 */
export function checkPaymentRequest(agreement: Agreement, lineItems: LineItem[], events: DealEvent[] = []): MismatchDetails {
  const reasons: string[] = [];
  const locked = agreement.status === "locked" && !!agreement.fingerprint;
  if (!locked) reasons.push("agreement_not_locked");

  const fingerprintValid = locked && computeFingerprint(agreement) === agreement.fingerprint;
  if (locked && !fingerprintValid) reasons.push("fingerprint_mismatch");

  const requested = sumLineItems(lineItems);
  if (requested !== agreement.total) reasons.push("amount_mismatch");

  const unmatched: LineItem[] = [];
  const wrongAmount: LineItem[] = [];
  for (const li of lineItems) {
    const m = matchLineItem(li, agreement);
    if (m.kind === "none") unmatched.push(li);
    else if (li.amount !== m.expected) wrongAmount.push(li);
  }
  if (unmatched.length) reasons.push("unmatched_line_items");
  if (wrongAmount.length) reasons.push("line_item_amount_mismatch");

  const src = findSourceEvent(agreement, events);
  return {
    ok: reasons.length === 0,
    reasons,
    fingerprint_valid: fingerprintValid,
    agreed_total: agreement.total,
    requested_total: requested,
    difference: requested - agreement.total,
    unmatched_line_items: unmatched,
    mismatched_amount_line_items: wrongAmount,
    source_event_id: src?.id ?? null,
    source_event_text: src?.text ?? null,
    source_event_timestamp: src?.timestamp ?? null,
  };
}

export function formatClock(ts: string, timeZone = "America/Los_Angeles"): string {
  return new Date(ts).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZone });
}

/** Rule 4 (mock / fallback): one-sentence explanation citing the source line + time. */
export function templateExplanation(m: MismatchDetails, timeZone = "America/Los_Angeles"): string {
  const when = m.source_event_timestamp ? ` at ${formatClock(m.source_event_timestamp, timeZone)}` : "";
  const quote = m.source_event_text ? ` ("${m.source_event_text}")` : "";
  if (m.reasons.includes("agreement_not_locked")) {
    return "This charge is blocked because the agreement has not been confirmed by both buyer and seller yet.";
  }
  if (m.reasons.includes("fingerprint_mismatch")) {
    return `This charge is blocked because the agreement was changed after both sides confirmed it${when}${quote}, so its fingerprint no longer matches.`;
  }
  const extras = m.unmatched_line_items.map((li) => `${li.label} (${formatCents(li.amount)})`).join(", ");
  if (extras) {
    return `This doesn't match what you agreed to${when}${quote}: the request adds ${extras}, totaling ${formatCents(m.requested_total)} instead of the agreed ${formatCents(m.agreed_total)}.`;
  }
  if (m.mismatched_amount_line_items.length) {
    const li = m.mismatched_amount_line_items[0]!;
    return `This doesn't match what you agreed to${when}${quote}: ${li.label} is charged at ${formatCents(li.amount)}, and the request totals ${formatCents(m.requested_total)} instead of the agreed ${formatCents(m.agreed_total)}.`;
  }
  return `This doesn't match what you agreed to${when}${quote}: the request totals ${formatCents(m.requested_total)} instead of the agreed ${formatCents(m.agreed_total)}.`;
}
