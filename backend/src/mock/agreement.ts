// Mock agreement drafting. The draft is always built from the session's extracted terms, so buyer
// corrections (PATCH /terms: renamed, re-priced or removed terms) are honoured. When the session was
// played from a content script, its `expected_agreement` only supplies what terms can't:
// source_event_ids, open_questions, fee notes, and which promises count as included items.
import type { z } from "zod";
import type { AgreementDraftSchema } from "../content.js";
import { itemName } from "../auto.js";
import type { DealEvent, Session, Term } from "../types.js";
import { scriptForEvents } from "./extract.js";

export type AgreementDraft = z.infer<typeof AgreementDraftSchema>;

export interface DraftHints {
  /** Lower-cased labels of promise terms that should appear in items[] (e.g. "7-day return"). */
  promiseItemLabels?: Set<string>;
  /** Lower-cased fee label → note (e.g. "doc fee" → "waived"). */
  feeNotes?: Map<string, string>;
}

const lc = (s: string) => s.trim().toLowerCase();
/** Labels a term has carried: current, plus the originally extracted one if the buyer renamed it. */
const termLabels = (t: Term) => [lc(t.label), ...(t.original_label ? [lc(t.original_label)] : [])];

/** Translate script line ids ("evt_21") to stored event ids. Unknown ids are dropped. */
export function mapSourceIds(ids: string[], events: DealEvent[]): string[] {
  const out: string[] = [];
  for (const id of ids) {
    const e = events.find((x) => x.id === id) ?? events.find((x) => x.script_line_id === id);
    if (e && !out.includes(e.id)) out.push(e.id);
  }
  return out;
}

export function draftFromTerms(session: Session, events: DealEvent[], hints: DraftHints = {}): AgreementDraft {
  const active = session.terms.filter((t) => !t.removed);
  const priceTerm = [...active].reverse().find((t) => t.type === "price" && t.amount != null);
  const price = priceTerm?.amount ?? session.current_offer ?? session.asking_price ?? 0;
  const items = [itemName(session)];
  for (const t of active) {
    const isItem = t.type === "item";
    const isPromiseItem = t.type === "promise" && termLabels(t).some((l) => hints.promiseItemLabels?.has(l));
    if ((isItem || isPromiseItem) && !items.includes(t.label)) items.push(t.label);
  }
  const fees = active
    .filter((t) => t.type === "fee" || t.type === "addon")
    .map((t) => {
      const amount = t.amount ?? 0;
      const hinted = termLabels(t).map((l) => hints.feeNotes?.get(l)).find(Boolean);
      const note = amount === 0 ? (hinted ?? "waived") : t.corrected ? undefined : hinted;
      return { label: t.label, amount, ...(note ? { note } : {}) };
    });
  const openQuestions: string[] = [];
  for (const t of active) if (t.uncertain || t.amount == null) openQuestions.push(`Confirm ${t.label}${t.amount != null ? "" : " amount"}`);
  if (!priceTerm && session.current_offer == null) {
    openQuestions.push(session.asking_price != null ? "No price was agreed in the conversation; using the asking price." : "No price was heard in the conversation; set the price before confirming.");
  }
  const sources = new Set<string>();
  for (const t of active) if (t.source_event_id) sources.add(t.source_event_id);
  const ordered = events.filter((e) => sources.has(e.id)).map((e) => e.id);
  return {
    price,
    items,
    fees,
    total: price + fees.reduce((s, f) => s + f.amount, 0),
    source_event_ids: ordered.slice(-4),
    open_questions: openQuestions,
  };
}

export function mockAgreement(session: Session, events: DealEvent[]): AgreementDraft {
  const script = scriptForEvents(events);
  const ea = script?.expected_agreement;
  if (!ea) return draftFromTerms(session, events);

  const hints: DraftHints = {
    promiseItemLabels: new Set(ea.items.map(lc)),
    feeNotes: new Map(ea.fees.filter((f) => f.note).map((f) => [lc(f.label), f.note!])),
  };
  const draft = draftFromTerms(session, events, hints);
  const mapped = mapSourceIds(ea.source_event_ids, events);
  if (mapped.length === ea.source_event_ids.length) draft.source_event_ids = mapped;
  draft.open_questions = [...new Set([...ea.open_questions, ...draft.open_questions])];
  return draft;
}
