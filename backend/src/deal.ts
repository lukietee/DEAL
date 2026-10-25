// Core DEAL business logic, independent of HTTP. Routes are thin wrappers around this.
import { randomBytes, randomUUID } from "node:crypto";
import type { Ai } from "./ai/index.js";
import type { Config } from "./config.js";
import { getScript, getScriptFile } from "./content.js";
import { computeFingerprint, fingerprintPayload, shortFingerprint, verifyFingerprint } from "./fingerprint.js";
import { checkPaymentRequest, matchLineItem, sumLineItems } from "./mismatch.js";
import { type ConditionCheck, type ConditionInput, type Discrepancy, type Listing, type ListingInput } from "./listing.js";
import { formatCentsShort } from "./money.js";
import type { Payments } from "./payments/index.js";
import { ResearchRunner } from "./research.js";
import type { Store } from "./store/index.js";
import type {
  Agreement, CueExtraction, DealEvent, EventKind, Fee, LineItem, PaymentRequest, Receipt, Session, Speaker, Term,
} from "./types.js";

export class HttpError extends Error {
  constructor(public statusCode: number, message: string, public details?: unknown) {
    super(message);
  }
}

const now = () => new Date().toISOString();
const newId = (prefix: string) => `${prefix}_${randomUUID().replace(/-/g, "").slice(0, 20)}`;
const JOIN_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I

export interface ScriptRun {
  script_id: string;
  total: number;
  played: number;
  done: boolean;
  error: string | null;
  started_at: string;
}

export interface NewSessionInput {
  category: string;
  item: string;
  asking_price: number;
  target_price: number;
  max_budget: number;
  style: string;
  listing?: Listing | null;
}

export interface TermCorrection {
  label?: string;
  amount?: number | null;
  type?: string;
  removed?: boolean;
}

export class Deal {
  private locks = new Map<string, Promise<unknown>>();
  private scriptRuns = new Map<string, ScriptRun>();
  private timers = new Set<NodeJS.Timeout>();

  constructor(
    public store: Store,
    public ai: Ai,
    public payments: Payments,
    private cfg: Pick<Config, "merchantName" | "displayTimeZone">,
    public research: ResearchRunner = new ResearchRunner({ mockMode: true, client: null, model: "", cueModel: "", log: { warn: () => undefined } }),
  ) {}

  /** Serialise mutations per key (session id) so seq numbers and terms never race. */
  private withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.locks.get(key) ?? Promise.resolve();
    const next = prev.catch(() => undefined).then(fn);
    this.locks.set(key, next);
    void next.finally(() => { if (this.locks.get(key) === next) this.locks.delete(key); }).catch(() => undefined);
    return next;
  }

  private async mustSession(id: string): Promise<Session> {
    const s = await this.store.getSession(id);
    if (!s) throw new HttpError(404, `session ${id} not found`);
    return s;
  }

  // ---------- sessions ----------

  async createSession(input: NewSessionInput): Promise<Session> {
    let code = "";
    for (let i = 0; i < 10; i++) {
      const bytes = randomBytes(6);
      code = [...bytes].map((b) => JOIN_ALPHABET[b % JOIN_ALPHABET.length]).join("");
      const clash = await this.store.getSessionByJoinCode(code);
      if (!clash || clash.status === "paid") break;
    }
    const t = now();
    const session: Session = {
      id: newId("ses"),
      category: input.category,
      item: input.item,
      asking_price: input.asking_price,
      target_price: input.target_price,
      max_budget: input.max_budget,
      style: input.style,
      status: "live",
      join_code: code,
      current_offer: null,
      current_offer_by: null,
      terms: [],
      listing: input.listing ?? null,
      condition_checks: [],
      created_at: t,
      updated_at: t,
    };
    const saved = await this.store.insertSession(session);
    this.research.start(saved); // live market research agents (GET /sessions/:id -> research)
    this.research.refreshSuggestions(saved, []); // opening lines before anyone speaks
    return saved;
  }

  /** POST /sessions/:id/research: re-run the research agents. */
  async restartResearch(id: string) {
    return this.research.start(await this.mustSession(id));
  }

  async joinSession(code: string): Promise<Session> {
    const s = await this.store.getSessionByJoinCode(code);
    if (!s) throw new HttpError(404, `no session with join code ${code}`);
    return s;
  }

  async listSessions() {
    const sessions = await this.store.listSessions();
    return Promise.all(
      sessions.map(async (s) => {
        const [agreement, receipt] = await Promise.all([this.store.getLatestAgreement(s.id), this.store.getReceiptForSession(s.id)]);
        return {
          ...s,
          final_price: receipt?.amount ?? (agreement?.status === "locked" ? agreement.total : null),
          paid_at: receipt?.created_at ?? null,
          blocked_total: receipt?.blocked_total ?? 0,
          savings: receipt ? s.asking_price - receipt.amount : null,
        };
      }),
    );
  }

  async getState(id: string) {
    const session = await this.mustSession(id);
    const [events, agreement, payment_requests, receipt] = await Promise.all([
      this.store.listEvents(id),
      this.store.getLatestAgreement(id),
      this.store.listPaymentRequests(id),
      this.store.getReceiptForSession(id),
    ]);
    return {
      session,
      events,
      agreement: agreement ? this.decorateAgreement(agreement) : null,
      payment_requests,
      receipt,
      script: this.scriptRuns.get(id) ?? null,
      research: this.research.research(id),
      suggestions: this.research.suggestionsFor(id),
    };
  }

  /** Adds `fingerprint_short` and `fingerprint_valid` for display (not stored). */
  decorateAgreement(a: Agreement) {
    return { ...a, fingerprint_short: shortFingerprint(a.fingerprint), fingerprint_valid: a.fingerprint ? verifyFingerprint(a) : null };
  }

  async deleteAll() {
    this.stopAll();
    await this.store.deleteAll();
  }

  // ---------- events + live cues ----------

  async addEvent(sessionId: string, speaker: Speaker, text: string, opts: { scriptLineId?: string; scriptId?: string; extraction?: CueExtraction; kind?: EventKind } = {}): Promise<DealEvent> {
    return this.withLock(sessionId, async () => {
      const session = await this.mustSession(sessionId);
      const events = await this.store.listEvents(sessionId);
      const extraction = opts.extraction ?? (await this.ai.cue({ session, recent: events, speaker, text, scriptId: opts.scriptId }));
      const event: DealEvent = {
        id: newId("evt"),
        session_id: sessionId,
        seq: (events[events.length - 1]?.seq ?? 0) + 1,
        speaker,
        text,
        timestamp: now(),
        extracted_offer: extraction.current_offer,
        offer_by: extraction.offer_by,
        new_terms: extraction.new_terms,
        tactic: extraction.tactic_detected,
        cue: extraction.cue,
        cue_detail: extraction.cue_detail ?? null,
        status_color: extraction.status,
        script_line_id: opts.scriptLineId ?? null,
        kind: opts.kind ?? "speech",
      };
      const saved = await this.store.insertEvent(event);
      await this.store.updateSession(sessionId, {
        terms: mergeTerms(session.terms, extraction.new_terms, saved.id),
        current_offer: extraction.current_offer ?? session.current_offer,
        current_offer_by: extraction.current_offer != null ? extraction.offer_by : session.current_offer_by,
      });
      const updated = await this.store.getSession(sessionId);
      if (updated) this.research.refreshSuggestions(updated, [...events, saved]);
      return saved;
    });
  }

  // ---------- marketplace listing + condition check ----------

  /** POST /listings/parse: canned in mock mode, Claude (text or screenshot) in real mode. Never scrapes. */
  async parseListing(input: ListingInput): Promise<Listing> {
    return this.ai.parseListing(input);
  }

  /**
   * POST /sessions/:id/condition-check: compare what the buyer sees against session.listing.condition_claims.
   * The result is inserted as an event (kind "condition_check", speaker "buyer") carrying the cue, so it flows to
   * the glasses / teleprompter exactly like a transcript cue, and is appended to session.condition_checks.
   */
  async conditionCheck(sessionId: string, input: ConditionInput): Promise<{ discrepancies: Discrepancy[]; event: DealEvent }> {
    const session = await this.mustSession(sessionId);
    if (!session.listing) throw new HttpError(409, "session has no listing; attach one via POST /sessions {listing} (from POST /listings/parse)");
    const discrepancies = await this.ai.conditionCheck(session.listing, input);
    const total = discrepancies.reduce((s, d) => s + d.suggested_discount, 0);
    const first = discrepancies[0];
    const extraction: CueExtraction = {
      current_offer: session.current_offer,
      offer_by: session.current_offer_by,
      new_terms: [],
      tactic_detected: first ? "undisclosed_condition" : null,
      cue: first ? first.cue : "Matches the listing. Proceed.",
      cue_detail: first
        ? discrepancies.length > 1
          ? `${discrepancies.length} issues, ask ${formatCentsShort(total)} off`
          : `Listing says "${first.claim}"`
        : null,
      status: first ? (session.current_offer != null && session.current_offer > session.max_budget ? "red" : "yellow") : "green",
    };
    const what = input.observation?.trim().replace(/[.!?]+$/, "") || "photo of the item";
    const text = first
      ? `Condition check: ${what}. ${discrepancies.map((d) => `Listing says "${d.claim}", observed: ${d.observed}.`).join(" ")}`
      : `Condition check: ${what}. Matches the listing.`;
    const event = await this.addEvent(sessionId, "buyer", text, { extraction, kind: "condition_check" });
    await this.withLock(sessionId, async () => {
      const s = await this.mustSession(sessionId);
      const check: ConditionCheck = {
        id: newId("cc"),
        at: event.timestamp,
        observation: input.observation?.trim() || null,
        had_image: !!input.image_base64,
        discrepancies,
        event_id: event.id,
      };
      await this.store.updateSession(sessionId, { condition_checks: [...(s.condition_checks ?? []), check] });
    });
    return { discrepancies, event };
  }

  async playScript(sessionId: string, scriptId: string, intervalMs?: number): Promise<ScriptRun> {
    await this.mustSession(sessionId);
    const script = getScript(scriptId);
    if (!script) throw new HttpError(404, `script ${scriptId} not found`);
    const running = this.scriptRuns.get(sessionId);
    if (running && !running.done) throw new HttpError(409, `script ${running.script_id} is already playing`);
    const run: ScriptRun = { script_id: scriptId, total: script.lines.length, played: 0, done: false, error: null, started_at: now() };
    this.scriptRuns.set(sessionId, run);

    const lines = script.lines;
    const step = (i: number) => {
      if (i >= lines.length) { run.done = true; return; }
      const line = lines[i]!;
      const delay = intervalMs ?? line.delay_ms;
      const timer = setTimeout(async () => {
        this.timers.delete(timer);
        try {
          await this.addEvent(sessionId, line.speaker, line.text, { scriptLineId: line.id, scriptId });
          run.played++;
          step(i + 1);
        } catch (err) {
          run.error = String(err);
          run.done = true;
        }
      }, delay);
      this.timers.add(timer);
    };
    step(0);
    return run;
  }

  stopAll() {
    for (const t of this.timers) clearTimeout(t);
    this.timers.clear();
    this.research.stopAll();
  }

  async correctTerm(sessionId: string, termId: string, correction: TermCorrection): Promise<Term[]> {
    return this.withLock(sessionId, async () => {
      const session = await this.mustSession(sessionId);
      const idx = session.terms.findIndex((t) => t.id === termId);
      if (idx < 0) throw new HttpError(404, `term ${termId} not found`);
      const terms = session.terms.map((t) => ({ ...t }));
      const t = terms[idx]!;
      if (correction.label !== undefined && correction.label !== t.label) {
        t.original_label ??= t.label;
        t.label = correction.label;
      }
      if (correction.amount !== undefined) t.amount = correction.amount;
      if (correction.type !== undefined) t.type = correction.type;
      if (correction.removed !== undefined) t.removed = correction.removed;
      t.corrected = true;
      t.uncertain = false;
      const patch: Partial<Session> = { terms };
      // A corrected price term updates the standing offer shown in B3.
      const lastPrice = [...terms].reverse().find((x) => x.type === "price" && !x.removed);
      if (lastPrice?.id === t.id && t.amount != null) patch.current_offer = t.amount;
      const updated = await this.store.updateSession(sessionId, patch);
      return updated.terms;
    });
  }

  // ---------- agreements ----------

  async draftAgreement(sessionId: string): Promise<Agreement> {
    return this.withLock(sessionId, async () => {
      const session = await this.mustSession(sessionId);
      const existing = await this.store.getLatestAgreement(sessionId);
      if (existing?.status === "locked") throw new HttpError(409, "agreement is already locked", { agreement: existing });
      const events = await this.store.listEvents(sessionId);
      const draft = await this.ai.agreement(session, events);
      const t = now();
      const agreement: Agreement = {
        id: newId("agr"),
        session_id: sessionId,
        price: draft.price,
        items: draft.items,
        fees: draft.fees,
        total: draft.total,
        source_event_ids: draft.source_event_ids,
        open_questions: draft.open_questions,
        status: "draft",
        buyer_confirmed_at: null,
        seller_confirmed_at: null,
        fingerprint: null,
        version: 1,
        amendments: [],
        created_at: t,
        updated_at: t,
      };
      const saved = await this.store.insertAgreement(agreement);
      await this.store.updateSession(sessionId, { status: "agreement_draft" });
      return saved;
    });
  }

  async confirmAgreement(agreementId: string, role: Speaker): Promise<Agreement> {
    const a0 = await this.store.getAgreement(agreementId);
    if (!a0) throw new HttpError(404, `agreement ${agreementId} not found`);
    return this.withLock(a0.session_id, async () => {
      const a = (await this.store.getAgreement(agreementId))!;
      const latest = await this.store.getLatestAgreement(a.session_id);
      if (latest && latest.id !== a.id) throw new HttpError(409, "a newer agreement draft exists", { latest_agreement_id: latest.id });
      if (a.status === "locked") return a; // idempotent
      const field = role === "buyer" ? "buyer_confirmed_at" : "seller_confirmed_at";
      const patch: Partial<Agreement> = {};
      if (!a[field]) patch[field] = now();
      const merged = { ...a, ...patch };
      if (merged.buyer_confirmed_at && merged.seller_confirmed_at) {
        patch.status = "locked";
        patch.fingerprint = computeFingerprint(merged);
      }
      const saved = await this.store.updateAgreement(a.id, patch);
      if (saved.status === "locked") await this.store.updateSession(a.session_id, { status: "locked" });
      return saved;
    });
  }

  // ---------- payment requests ----------

  async createPaymentRequest(sessionId: string, lineItems: LineItem[]): Promise<PaymentRequest> {
    return this.withLock(sessionId, async () => {
      const session = await this.mustSession(sessionId);
      if (session.status === "paid") throw new HttpError(409, "session is already paid");
      const agreement = await this.store.getLatestAgreement(sessionId);
      if (!agreement) throw new HttpError(409, "no agreement for this session yet");
      if (agreement.status !== "locked") throw new HttpError(409, "agreement is not locked; both buyer and seller must confirm first");
      const events = await this.store.listEvents(sessionId);
      const mismatch = checkPaymentRequest(agreement, lineItems, events);
      const t = now();
      const pr: PaymentRequest = {
        id: newId("pr"),
        session_id: sessionId,
        agreement_id: agreement.id,
        amount: sumLineItems(lineItems),
        line_items: lineItems,
        status: mismatch.ok ? "approved" : "blocked",
        mismatch_explanation: mismatch.ok ? null : await this.ai.explainMismatch(mismatch, lineItems),
        mismatch,
        decided_at: null,
        created_at: t,
        updated_at: t,
      };
      return this.store.insertPaymentRequest(pr);
    });
  }

  async decide(paymentRequestId: string, decision: "approve" | "reject"): Promise<PaymentRequest> {
    const pr0 = await this.store.getPaymentRequest(paymentRequestId);
    if (!pr0) throw new HttpError(404, `payment request ${paymentRequestId} not found`);
    return this.withLock(pr0.session_id, async () => {
      const pr = (await this.store.getPaymentRequest(paymentRequestId))!;
      if (pr.status !== "blocked") throw new HttpError(409, `payment request is ${pr.status}; only blocked requests need a decision`);
      if (decision === "reject") {
        return this.store.updatePaymentRequest(pr.id, { status: "rejected", decided_at: now() });
      }
      // Approve: the buyer accepts the changed charge → amend the agreement to match it,
      // re-confirm on the buyer's behalf, re-fingerprint.
      const agreement = await this.store.getAgreement(pr.agreement_id);
      if (!agreement) throw new HttpError(409, "agreement missing");
      const amended = amendAgreement(agreement, pr);
      const t = now();
      const patch: Partial<Agreement> = {
        price: amended.price,
        fees: amended.fees,
        total: amended.total,
        buyer_confirmed_at: t,
        status: "locked",
        version: agreement.version + 1,
        amendments: [
          ...agreement.amendments,
          {
            at: t,
            payment_request_id: pr.id,
            added_fees: amended.addedFees,
            previous_total: agreement.total,
            new_total: amended.total,
            previous_fingerprint: agreement.fingerprint,
          },
        ],
      };
      patch.fingerprint = computeFingerprint({ ...agreement, ...patch } as Agreement);
      const savedAgreement = await this.store.updateAgreement(agreement.id, patch);
      const events = await this.store.listEvents(pr.session_id);
      const recheck = checkPaymentRequest(savedAgreement, pr.line_items, events);
      if (!recheck.ok) throw new HttpError(500, "amended agreement still does not match the request", recheck);
      return this.store.updatePaymentRequest(pr.id, { status: "approved", decided_at: t, mismatch: recheck });
    });
  }

  async pay(paymentRequestId: string): Promise<Receipt> {
    const pr0 = await this.store.getPaymentRequest(paymentRequestId);
    if (!pr0) throw new HttpError(404, `payment request ${paymentRequestId} not found`);
    return this.withLock(pr0.session_id, async () => {
      const pr = (await this.store.getPaymentRequest(paymentRequestId))!;
      if (pr.status === "paid") {
        throw new HttpError(409, "payment request already paid", { receipt: await this.store.getReceiptForSession(pr.session_id) });
      }
      if (pr.status !== "approved") throw new HttpError(409, `payment request is ${pr.status}; only approved requests can be paid`);
      const session = await this.mustSession(pr.session_id);
      if (session.status === "paid") throw new HttpError(409, "session is already paid");
      const agreement = await this.store.getAgreement(pr.agreement_id);
      if (!agreement) throw new HttpError(409, "agreement missing");
      // Defense in depth: re-run the deterministic check right before charging.
      const events = await this.store.listEvents(pr.session_id);
      const check = checkPaymentRequest(agreement, pr.line_items, events);
      if (!check.ok) {
        const blocked = await this.store.updatePaymentRequest(pr.id, {
          status: "blocked",
          mismatch: check,
          mismatch_explanation: await this.ai.explainMismatch(check, pr.line_items),
        });
        throw new HttpError(409, "charge no longer matches the agreement; blocked", { payment_request: blocked });
      }
      const charge = await this.payments.charge({
        amount: pr.amount,
        currency: "usd",
        description: `DEAL: ${session.item}`,
        metadata: { session_id: session.id, payment_request_id: pr.id, agreement_fingerprint: agreement.fingerprint ?? "" },
        idempotencyKey: `deal_${pr.id}`,
      });
      const all = await this.store.listPaymentRequests(pr.session_id);
      const blockedTotal = all
        .filter((p) => p.status === "rejected" || p.status === "blocked")
        .reduce((s, p) => s + Math.max(0, p.amount - (p.mismatch?.agreed_total ?? p.amount)), 0);
      const receipt: Receipt = {
        id: newId("rcpt"),
        session_id: session.id,
        payment_request_id: pr.id,
        stripe_payment_id: charge.id,
        amount: pr.amount,
        currency: "usd",
        status: charge.status,
        agreement_fingerprint: agreement.fingerprint!,
        merchant: this.cfg.merchantName,
        asking_price: session.asking_price,
        blocked_total: blockedTotal,
        summary: `Asked ${formatCentsShort(session.asking_price)}, paid ${formatCentsShort(pr.amount)}, blocked ${formatCentsShort(blockedTotal)}`,
        mock: charge.mock,
        created_at: now(),
      };
      const saved = await this.store.insertReceipt(receipt);
      await this.store.updatePaymentRequest(pr.id, { status: "paid" });
      await this.store.updateSession(session.id, { status: "paid" });
      return saved;
    });
  }

  // ---------- dispute pack ----------

  async disputePack(sessionId: string) {
    const state = await this.getState(sessionId);
    const a = state.agreement;
    const sourceIds = new Set(a?.source_event_ids ?? []);
    const blockedIds = new Set(state.payment_requests.map((p) => p.mismatch?.source_event_id).filter(Boolean) as string[]);
    const checks = state.session.condition_checks ?? [];
    for (const c of checks) blockedIds.add(c.event_id);
    return {
      generated_at: now(),
      format: "deal-dispute-pack/v1",
      session: state.session,
      agreement: a,
      fingerprint: a
        ? { value: a.fingerprint, algorithm: "SHA-256 over canonical (sorted-key) JSON", payload: fingerprintPayload(a), valid: a.fingerprint_valid }
        : null,
      confirmations: a ? { buyer_confirmed_at: a.buyer_confirmed_at, seller_confirmed_at: a.seller_confirmed_at } : null,
      transcript_excerpts: state.events.filter((e) => sourceIds.has(e.id) || blockedIds.has(e.id)).map((e) => ({ id: e.id, speaker: e.speaker, text: e.text, timestamp: e.timestamp })),
      payment_requests: state.payment_requests,
      receipt: state.receipt,
      listing: state.session.listing ?? null,
      condition_discrepancies: checks.flatMap((c) => c.discrepancies.map((d) => ({ ...d, checked_at: c.at, event_id: c.event_id }))),
      disclaimer: "Sandbox demo. Payments are Stripe test mode; pricing is illustrative.",
    };
  }

  /** Demo helper: the seller_extra_fee*.json content (blocked + corrected requests) for a script. */
  sellerExtraFee(scriptId = "car_accord") {
    return getScriptFile(scriptId === "marketplace_bike" ? "seller_extra_fee_marketplace" : "seller_extra_fee");
  }
}

/** Same type+label replaces the earlier term (content convention). */
export function mergeTerms(existing: Term[], incoming: CueExtraction["new_terms"], sourceEventId: string): Term[] {
  const terms = existing.map((t) => ({ ...t }));
  let nextNum = terms.reduce((m, t) => Math.max(m, Number(t.id.replace(/^term_/, "")) || 0), 0) + 1;
  const key = (type: string, label: string) => `${type.trim().toLowerCase()}|${label.trim().toLowerCase()}`;
  for (const nt of incoming) {
    const found = terms.find(
      (t) => key(t.type, t.label) === key(nt.type, nt.label) || (t.original_label !== undefined && key(t.type, t.original_label) === key(nt.type, nt.label)),
    );
    if (found) {
      if (found.corrected) {
        // The buyer's correction wins over later re-mentions of the same term.
        found.source_event_id = sourceEventId;
        continue;
      }
      found.amount = nt.amount;
      found.source_event_id = sourceEventId;
      found.uncertain = nt.uncertain ?? false;
      found.corrected = false;
      found.removed = false;
    } else {
      terms.push({
        id: `term_${nextNum++}`,
        type: nt.type,
        label: nt.label,
        amount: nt.amount,
        source_event_id: sourceEventId,
        uncertain: nt.uncertain ?? false,
        corrected: false,
        removed: false,
      });
    }
  }
  return terms;
}

/**
 * Build the agreement terms implied by a buyer-approved payment request:
 * main item line → price; every other charged line → fee; zero-amount included items stay items;
 * unlisted agreement fees are kept only if $0 (e.g. "waived"). total = sum(line items).
 */
export function amendAgreement(a: Agreement, pr: Pick<PaymentRequest, "line_items">) {
  let price = 0;
  const fees: Fee[] = [];
  const addedFees: Fee[] = [];
  const listedFeeLabels = new Set<string>();
  for (const li of pr.line_items) {
    const m = matchLineItem(li, a);
    if (m.kind === "main_item") price += li.amount;
    else if (m.kind === "item" && li.amount === 0) continue;
    else {
      const existing = a.fees.find((f) => f.label.trim().toLowerCase() === li.label.trim().toLowerCase());
      const fee: Fee = existing
        ? { label: existing.label, amount: li.amount, ...(li.amount === existing.amount && existing.note ? { note: existing.note } : { note: "changed at checkout, approved by buyer" }) }
        : { label: li.label, amount: li.amount, note: "added at checkout, approved by buyer" };
      if (!existing || existing.amount !== li.amount) addedFees.push(fee);
      fees.push(fee);
      listedFeeLabels.add(li.label.trim().toLowerCase());
    }
  }
  for (const f of a.fees) {
    if (!listedFeeLabels.has(f.label.trim().toLowerCase()) && f.amount === 0) fees.push(f);
  }
  const total = price + fees.reduce((s, f) => s + f.amount, 0);
  return { price, fees, total, addedFees };
}
