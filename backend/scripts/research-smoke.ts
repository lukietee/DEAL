// Manual smoke test: run the live research agents + suggested phrases against the real API.
//   npx tsx scripts/research-smoke.ts
import Anthropic from "@anthropic-ai/sdk";
import { loadConfig } from "../src/config.js";
import { ResearchRunner } from "../src/research.js";
import type { Session } from "../src/types.js";

const cfg = loadConfig();
const runner = new ResearchRunner({
  mockMode: false,
  client: new Anthropic({ apiKey: cfg.anthropicApiKey }),
  model: cfg.researchModel,
  cueModel: cfg.cueModel,
  log: { warn: (o, m) => console.warn("WARN", m, o) },
});
const session = {
  id: "ses_smoke", category: "marketplace", item: "Used road bike", asking_price: 65000, target_price: 52000, max_budget: 57500,
  style: "friendly", status: "live", join_code: "X", current_offer: 60000, current_offer_by: "seller", terms: [], condition_checks: [],
  listing: { title: "Trek Domane AL 2 road bike, 56cm", asking_price: 65000, category: "marketplace", condition_claims: ["like new", "new tires last month"], description: "", source: "facebook_marketplace" },
  created_at: "", updated_at: "",
} as unknown as Session;

const t0 = Date.now();
const state = runner.start(session);
const tick = setInterval(() => {
  console.log(`[${((Date.now() - t0) / 1000).toFixed(0)}s] ` + state.agents.map((a) => `${a.id}:${a.status}(${a.queries.length}q/${a.sources.length}s) ${a.activity}`).join(" | "));
}, 3000);
while (state.status !== "done") await new Promise((r) => setTimeout(r, 500));
clearInterval(tick);
console.log(JSON.stringify(state, null, 1));
runner.refreshSuggestions(session, []);
while (!runner.suggestionsFor(session.id)) await new Promise((r) => setTimeout(r, 300));
console.log(JSON.stringify(runner.suggestionsFor(session.id), null, 1));
