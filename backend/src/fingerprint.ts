import { createHash } from "node:crypto";
import type { Agreement } from "./types.js";

/**
 * Canonical JSON: object keys sorted recursively, arrays keep their order,
 * `undefined` values dropped (same as JSON.stringify), no whitespace.
 */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") {
    if (typeof value === "number" && !Number.isFinite(value)) throw new Error("non-finite number in canonical JSON");
    return JSON.stringify(value) ?? "null";
  }
  if (Array.isArray(value)) {
    return `[${value.map((v) => (v === undefined ? "null" : canonicalJson(v))).join(",")}]`;
  }
  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj)
    .filter((k) => obj[k] !== undefined)
    .sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(obj[k])}`).join(",")}}`;
}

/**
 * Normalise a timestamp so the fingerprint survives a database round-trip
 * (Postgres returns "2026-10-24T21:14:00+00:00"; JS writes "...00.000Z").
 */
export function normalizeTimestamp(ts: string | null | undefined): string | null {
  if (!ts) return null;
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts : d.toISOString();
}

export type FingerprintInput = Pick<
  Agreement,
  "session_id" | "price" | "items" | "fees" | "total" | "buyer_confirmed_at" | "seller_confirmed_at"
>;

/** The exact payload hashed per 12.5. */
export function fingerprintPayload(a: FingerprintInput) {
  return {
    session_id: a.session_id,
    price: a.price,
    items: a.items,
    fees: a.fees.map((f) => ({ label: f.label, amount: f.amount, ...(f.note !== undefined && f.note !== null ? { note: f.note } : {}) })),
    total: a.total,
    buyer_confirmed_at: normalizeTimestamp(a.buyer_confirmed_at),
    seller_confirmed_at: normalizeTimestamp(a.seller_confirmed_at),
  };
}

/** SHA-256 (hex) over canonical JSON of the 12.5 fingerprint fields. */
export function computeFingerprint(a: FingerprintInput): string {
  return createHash("sha256").update(canonicalJson(fingerprintPayload(a)), "utf8").digest("hex");
}

export function verifyFingerprint(a: FingerprintInput & { fingerprint: string | null }): boolean {
  return !!a.fingerprint && computeFingerprint(a) === a.fingerprint;
}

/** "a3f9…c21" style display form. */
export function shortFingerprint(fp: string | null): string | null {
  return fp ? `${fp.slice(0, 4)}…${fp.slice(-3)}` : null;
}
