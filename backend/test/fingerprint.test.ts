import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { canonicalJson, computeFingerprint, fingerprintPayload, shortFingerprint, verifyFingerprint } from "../src/fingerprint.js";
import { lockedCarAgreement } from "./helpers.js";

describe("canonicalJson", () => {
  it("sorts keys recursively and keeps array order", () => {
    expect(canonicalJson({ b: 1, a: { d: [3, 1, { z: 1, y: 2 }], c: null } })).toBe('{"a":{"c":null,"d":[3,1,{"y":2,"z":1}]},"b":1}');
  });
  it("is independent of key insertion order", () => {
    expect(canonicalJson({ x: 1, y: "two" })).toBe(canonicalJson({ y: "two", x: 1 }));
  });
  it("drops undefined object values like JSON.stringify", () => {
    expect(canonicalJson({ a: undefined, b: 2 })).toBe('{"b":2}');
  });
  it("escapes strings exactly like JSON", () => {
    expect(canonicalJson({ s: 'quote " and ünïcode' })).toBe(JSON.stringify({ s: 'quote " and ünïcode' }));
  });
  it("rejects non-finite numbers", () => {
    expect(() => canonicalJson({ n: Number.NaN })).toThrow();
  });
});

describe("computeFingerprint", () => {
  const a = lockedCarAgreement();

  it("is a 64-char hex SHA-256 and deterministic", () => {
    const fp = computeFingerprint(a);
    expect(fp).toMatch(/^[0-9a-f]{64}$/);
    expect(computeFingerprint(structuredClone(a))).toBe(fp);
  });

  it("hashes exactly the 12.5 fields", () => {
    expect(Object.keys(fingerprintPayload(a)).sort()).toEqual(
      ["buyer_confirmed_at", "fees", "items", "price", "seller_confirmed_at", "session_id", "total"],
    );
    // fields outside the payload don't change it
    expect(computeFingerprint({ ...a, open_questions: ["x"], id: "other" } as typeof a)).toBe(computeFingerprint(a));
  });

  it("matches a known vector", () => {
    const fp = computeFingerprint({
      session_id: "s1", price: 100, items: ["thing"], fees: [], total: 100,
      buyer_confirmed_at: "2026-01-01T00:00:00.000Z", seller_confirmed_at: "2026-01-01T00:00:01.000Z",
    });
    // sha256 of the canonical string below
    const canonical = '{"buyer_confirmed_at":"2026-01-01T00:00:00.000Z","fees":[],"items":["thing"],"price":100,"seller_confirmed_at":"2026-01-01T00:00:01.000Z","session_id":"s1","total":100}';
    expect(fp).toBe(createHash("sha256").update(canonical).digest("hex"));
  });

  it("changes when any term changes", () => {
    const fp = computeFingerprint(a);
    expect(computeFingerprint({ ...a, total: a.total + 1 })).not.toBe(fp);
    expect(computeFingerprint({ ...a, price: a.price - 100 })).not.toBe(fp);
    expect(computeFingerprint({ ...a, items: [...a.items, "warranty"] })).not.toBe(fp);
    expect(computeFingerprint({ ...a, fees: [{ label: "doc fee", amount: 49900 }] })).not.toBe(fp);
    expect(computeFingerprint({ ...a, seller_confirmed_at: "2026-10-24T21:15:00.000Z" })).not.toBe(fp);
    expect(computeFingerprint({ ...a, session_id: "ses_other" })).not.toBe(fp);
  });

  it("survives a Postgres timestamptz round-trip format", () => {
    const pg = { ...a, buyer_confirmed_at: "2026-10-24T21:14:05+00:00", seller_confirmed_at: "2026-10-24 21:14:09+00" };
    expect(computeFingerprint(pg)).toBe(computeFingerprint(a));
  });

  it("verifies and shortens", () => {
    expect(verifyFingerprint(a)).toBe(true);
    expect(verifyFingerprint({ ...a, total: 1 })).toBe(false);
    expect(verifyFingerprint({ ...a, fingerprint: null })).toBe(false);
    expect(shortFingerprint("a3f9000000c21")).toBe("a3f9…c21");
  });
});
