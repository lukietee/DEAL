import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Agreement, DealEvent, PaymentRequest, Receipt, Session } from "../types.js";
import { NotFoundError, withSessionDefaults, type Store } from "./index.js";

/** Supabase (Postgres) store using the service-role key. Backend only. */
export class SupabaseStore implements Store {
  readonly kind = "supabase" as const;
  private db: SupabaseClient;

  constructor(url: string, serviceRoleKey: string) {
    this.db = createClient(url, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  }

  private async one<T>(table: string, column: string, value: string): Promise<T | null> {
    const { data, error } = await this.db.from(table).select("*").eq(column, value).maybeSingle();
    if (error) throw new Error(`${table} select failed: ${error.message}`);
    return (data as T) ?? null;
  }
  private async insert<T>(table: string, row: T): Promise<T> {
    const { data, error } = await this.db.from(table).insert(row as object).select("*").single();
    if (error) throw new Error(`${table} insert failed: ${error.message}`);
    return data as T;
  }
  private async update<T>(table: string, id: string, patch: Partial<T>): Promise<T> {
    const { data, error } = await this.db
      .from(table)
      .update({ ...patch, updated_at: new Date().toISOString() } as object)
      .eq("id", id)
      .select("*")
      .maybeSingle();
    if (error) throw new Error(`${table} update failed: ${error.message}`);
    if (!data) throw new NotFoundError(`${table} ${id} not found`);
    return data as T;
  }

  async insertSession(s: Session) { return withSessionDefaults(await this.insert("sessions", s)); }
  async getSession(id: string) {
    const s = await this.one<Session>("sessions", "id", id);
    return s ? withSessionDefaults(s) : null;
  }
  async getSessionByJoinCode(code: string) {
    const { data, error } = await this.db
      .from("sessions").select("*").eq("join_code", code.trim().toUpperCase())
      .order("created_at", { ascending: false }).limit(1);
    if (error) throw new Error(`sessions select failed: ${error.message}`);
    const s = data?.[0] as Session | undefined;
    return s ? withSessionDefaults(s) : null;
  }
  async listSessions() {
    const { data, error } = await this.db.from("sessions").select("*").order("created_at", { ascending: false });
    if (error) throw new Error(`sessions list failed: ${error.message}`);
    return ((data ?? []) as Session[]).map(withSessionDefaults);
  }
  async updateSession(id: string, patch: Partial<Session>) { return withSessionDefaults(await this.update<Session>("sessions", id, patch)); }

  insertEvent(e: DealEvent) { return this.insert("events", e); }
  async listEvents(sessionId: string) {
    const { data, error } = await this.db.from("events").select("*").eq("session_id", sessionId).order("seq", { ascending: true });
    if (error) throw new Error(`events list failed: ${error.message}`);
    return (data ?? []) as DealEvent[];
  }

  insertAgreement(a: Agreement) { return this.insert("agreements", a); }
  getAgreement(id: string) { return this.one<Agreement>("agreements", "id", id); }
  async getLatestAgreement(sessionId: string) {
    const { data, error } = await this.db.from("agreements").select("*").eq("session_id", sessionId)
      .order("created_at", { ascending: false }).limit(1);
    if (error) throw new Error(`agreements select failed: ${error.message}`);
    return (data?.[0] as Agreement) ?? null;
  }
  updateAgreement(id: string, patch: Partial<Agreement>) { return this.update<Agreement>("agreements", id, patch); }

  insertPaymentRequest(p: PaymentRequest) { return this.insert("payment_requests", p); }
  getPaymentRequest(id: string) { return this.one<PaymentRequest>("payment_requests", "id", id); }
  async listPaymentRequests(sessionId: string) {
    const { data, error } = await this.db.from("payment_requests").select("*").eq("session_id", sessionId)
      .order("created_at", { ascending: true });
    if (error) throw new Error(`payment_requests list failed: ${error.message}`);
    return (data ?? []) as PaymentRequest[];
  }
  updatePaymentRequest(id: string, patch: Partial<PaymentRequest>) {
    return this.update<PaymentRequest>("payment_requests", id, patch);
  }

  async insertReceipt(r: Receipt) {
    const { data, error } = await this.db.from("receipts").insert(r).select("*").single();
    if (error) throw new Error(`receipts insert failed: ${error.message}`);
    return data as Receipt;
  }
  async getReceiptForSession(sessionId: string) {
    const { data, error } = await this.db.from("receipts").select("*").eq("session_id", sessionId)
      .order("created_at", { ascending: false }).limit(1);
    if (error) throw new Error(`receipts select failed: ${error.message}`);
    return (data?.[0] as Receipt) ?? null;
  }

  async deleteAll() {
    // Cascades from sessions remove events/agreements/payment_requests/receipts.
    const { error } = await this.db.from("sessions").delete().neq("id", "");
    if (error) throw new Error(`delete failed: ${error.message}`);
  }
}
