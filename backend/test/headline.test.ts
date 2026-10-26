import { afterEach, describe, expect, it, vi } from "vitest";
import { ResearchRunner, agentHeadline } from "../src/research.js";
import type { Session } from "../src/types.js";

const quiet = { warn: () => undefined };
const base = { summary: null, price_low: null, price_high: null };

describe("agentHeadline (glasses research strip)", () => {
  it("keeps a short model headline, minus trailing punctuation", () => {
    expect(agentHeadline("Check tire wear.", base)).toBe("Check tire wear");
  });

  it("falls back to the price range when the headline is missing or too long", () => {
    const priced = { ...base, price_low: 59000, price_high: 72500 };
    expect(agentHeadline(null, priced)).toMatch(/^\$590.*\$725$/);
    expect(agentHeadline("A very long headline that will not fit on the glasses", priced)).toMatch(/^\$590/);
  });

  it("otherwise trims the summary at a word boundary to 24 chars", () => {
    const h = agentHeadline(null, { ...base, summary: "Drivetrain wear and old tires are the usual hidden costs." });
    expect(h!.length).toBeLessThanOrEqual(24);
    expect(h!.endsWith("…")).toBe(true);
    expect(agentHeadline(null, base)).toBeNull();
  });
});

describe("mock research agents fill a headline", () => {
  afterEach(() => { vi.useRealTimers(); });

  it("every finished agent has a short headline", async () => {
    vi.useFakeTimers();
    const runner = new ResearchRunner({ mockMode: true, client: null, model: "m", cueModel: "m", log: quiet });
    const session = {
      id: "s1", item: "Trek road bike", category: "marketplace", asking_price: 65000, target_price: 52000, listing: null,
    } as unknown as Session;
    const state = runner.start(session);
    expect(state.agents.every((a) => a.headline === null)).toBe(true);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(state.status).toBe("done");
    for (const a of state.agents) {
      expect(a.status).toBe("done");
      expect(a.headline).toBeTruthy();
      expect(a.headline!.length).toBeLessThanOrEqual(24);
    }
    runner.stopAll();
  });
});
