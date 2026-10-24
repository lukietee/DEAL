import type { Agreement, DealEvent, PaymentRequest, Receipt, Session } from "../types.js";
import { NotFoundError, type Store } from "./index.js";

const clone = <T>(v: T): T => structuredClone(v);

export class MemoryStore implements Store {
  readonly kind = "memory" as const;
  private sessions = new Map<string, Session>();
  private events = new Map<string, DealEvent>();
  private agreements = new Map<string, Agreement>();
  private paymentRequests = new Map<string, PaymentRequest>();
  private receipts = new Map<string, Receipt>();

  async insertSession(s: Session) { this.sessions.set(s.id, clone(s)); return clone(s); }
  async getSession(id: string) { const s = this.sessions.get(id); return s ? clone(s) : null; }
  async getSessionByJoinCode(code: string) {
    const c = code.trim().toUpperCase();
    const all = [...this.sessions.values()].filter((s) => s.join_code === c);
    const s = all.sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
    return s ? clone(s) : null;
  }
  async listSessions() {
    return [...this.sessions.values()].sort((a, b) => b.created_at.localeCompare(a.created_at)).map(clone);
  }
  async updateSession(id: string, patch: Partial<Session>) {
    const s = this.sessions.get(id);
    if (!s) throw new NotFoundError(`session ${id} not found`);
    const next = { ...s, ...clone(patch), updated_at: new Date().toISOString() };
    this.sessions.set(id, next);
    return clone(next);
  }

  async insertEvent(e: DealEvent) { this.events.set(e.id, clone(e)); return clone(e); }
  async listEvents(sessionId: string) {
    return [...this.events.values()].filter((e) => e.session_id === sessionId).sort((a, b) => a.seq - b.seq).map(clone);
  }

  async insertAgreement(a: Agreement) { this.agreements.set(a.id, clone(a)); return clone(a); }
  async getAgreement(id: string) { const a = this.agreements.get(id); return a ? clone(a) : null; }
  async getLatestAgreement(sessionId: string) {
    const a = [...this.agreements.values()]
      .filter((x) => x.session_id === sessionId)
      .sort((x, y) => y.created_at.localeCompare(x.created_at))[0];
    return a ? clone(a) : null;
  }
  async updateAgreement(id: string, patch: Partial<Agreement>) {
    const a = this.agreements.get(id);
    if (!a) throw new NotFoundError(`agreement ${id} not found`);
    const next = { ...a, ...clone(patch), updated_at: new Date().toISOString() };
    this.agreements.set(id, next);
    return clone(next);
  }

  async insertPaymentRequest(p: PaymentRequest) { this.paymentRequests.set(p.id, clone(p)); return clone(p); }
  async getPaymentRequest(id: string) { const p = this.paymentRequests.get(id); return p ? clone(p) : null; }
  async listPaymentRequests(sessionId: string) {
    return [...this.paymentRequests.values()]
      .filter((p) => p.session_id === sessionId)
      .sort((a, b) => a.created_at.localeCompare(b.created_at))
      .map(clone);
  }
  async updatePaymentRequest(id: string, patch: Partial<PaymentRequest>) {
    const p = this.paymentRequests.get(id);
    if (!p) throw new NotFoundError(`payment request ${id} not found`);
    const next = { ...p, ...clone(patch), updated_at: new Date().toISOString() };
    this.paymentRequests.set(id, next);
    return clone(next);
  }

  async insertReceipt(r: Receipt) { this.receipts.set(r.id, clone(r)); return clone(r); }
  async getReceiptForSession(sessionId: string) {
    const r = [...this.receipts.values()]
      .filter((x) => x.session_id === sessionId)
      .sort((a, b) => b.created_at.localeCompare(a.created_at))[0];
    return r ? clone(r) : null;
  }

  async deleteAll() {
    this.sessions.clear(); this.events.clear(); this.agreements.clear(); this.paymentRequests.clear(); this.receipts.clear();
  }
}
