// Loads demo content from ../content (written by the Content agent). Read at runtime, cached.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { z } from "zod";
import { BACKEND_ROOT } from "./config.js";

const money = z.number().int();

export const NewTermSchema = z.object({
  type: z.string(),
  label: z.string(),
  amount: money.nullable(),
  uncertain: z.boolean().optional(),
});

export const CueExtractionSchema = z.object({
  current_offer: money.nullable(),
  offer_by: z.enum(["buyer", "seller"]).nullable(),
  new_terms: z.array(NewTermSchema),
  tactic_detected: z.string().nullable(),
  cue: z.string(),
  cue_detail: z.string().nullable().optional(),
  status: z.enum(["green", "yellow", "red"]),
});

const FeeSchema = z.object({ label: z.string(), amount: money, note: z.string().optional() });

export const AgreementDraftSchema = z.object({
  price: money,
  items: z.array(z.string()),
  fees: z.array(FeeSchema),
  total: money,
  source_event_ids: z.array(z.string()),
  open_questions: z.array(z.string()),
});

const ScriptLineSchema = z.object({
  id: z.string(),
  speaker: z.enum(["buyer", "seller"]),
  text: z.string(),
  delay_ms: z.number().int().nonnegative().default(2000),
  expected: CueExtractionSchema.optional(),
});

const ScriptSchema = z.object({
  id: z.string(),
  category: z.string().optional(),
  item: z.string().optional(),
  asking_price: money.optional(),
  target_price: money.optional(),
  max_budget: money.optional(),
  style: z.string().optional(),
  lines: z.array(ScriptLineSchema).min(1),
  expected_agreement: AgreementDraftSchema.optional(),
});

const TacticSchema = z.object({
  id: z.string(),
  name: z.string(),
  detection_hints: z.array(z.string()),
  cue_template: z.string(),
  cue_detail_template: z.string().nullable().optional(),
  status: z.enum(["green", "yellow", "red"]),
});

const TacticsFileSchema = z.object({ tactics: z.array(TacticSchema) });

export type Script = z.infer<typeof ScriptSchema>;
export type ScriptLine = z.infer<typeof ScriptLineSchema>;
export type Tactic = z.infer<typeof TacticSchema>;

let contentDir = process.env.CONTENT_DIR ? resolve(process.env.CONTENT_DIR) : resolve(BACKEND_ROOT, "..", "content");
const MOCK_DIR = resolve(BACKEND_ROOT, "src", "mock", "content"); // last-resort placeholders

export function setContentDir(dir: string) {
  contentDir = dir;
  cache.clear();
}

const cache = new Map<string, unknown>();

function readJson(...parts: string[]): unknown | null {
  for (const base of [contentDir, MOCK_DIR]) {
    const p = join(base, ...parts);
    if (existsSync(p)) return JSON.parse(readFileSync(p, "utf8"));
  }
  return null;
}

export function listScriptIds(): string[] {
  const ids = new Set<string>();
  for (const base of [contentDir, MOCK_DIR]) {
    const dir = join(base, "scripts");
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) {
      if (!f.endsWith(".json")) continue;
      const id = f.replace(/\.json$/, "");
      if (getScript(id)) ids.add(id);
    }
  }
  return [...ids].sort();
}

/** A conversation script (has `lines`). Returns null for non-conversation files like seller_extra_fee. */
export function getScript(id: string): Script | null {
  if (!/^[a-z0-9_-]+$/i.test(id)) return null;
  const key = `script:${id}`;
  if (cache.has(key)) return cache.get(key) as Script | null;
  const raw = readJson("scripts", `${id}.json`);
  const parsed = raw ? ScriptSchema.safeParse(raw) : null;
  const val = parsed?.success ? parsed.data : null;
  cache.set(key, val);
  return val;
}

export function getAllScripts(): Script[] {
  return listScriptIds().map((id) => getScript(id)!).filter(Boolean);
}

export function getTactics(): Tactic[] {
  if (cache.has("tactics")) return cache.get("tactics") as Tactic[];
  const raw = readJson("tactics.json");
  const parsed = raw ? TacticsFileSchema.safeParse(raw) : null;
  const val = parsed?.success ? parsed.data.tactics : [];
  cache.set("tactics", val);
  return val;
}

export function normalizeCategory(category: string): string {
  return category.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
}

export function getComparables(category: string): unknown | null {
  const c = normalizeCategory(category);
  if (!c) return null;
  return readJson("comparables", `${c}.json`);
}

/** Raw JSON of any content file under scripts/ (e.g. seller_extra_fee). */
export function getScriptFile(id: string): unknown | null {
  if (!/^[a-z0-9_-]+$/i.test(id)) return null;
  return readJson("scripts", `${id}.json`);
}
