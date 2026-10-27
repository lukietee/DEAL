import Anthropic from "@anthropic-ai/sdk";
import type { Config } from "../config.js";
import { AgreementDraftSchema, CueExtractionSchema, getTactics } from "../content.js";
import {
  ConditionCheckError, ConditionModelSchema, LISTING_UNREADABLE, ListingModelSchema, ListingUnreadableError, URL_UNREADABLE,
  decodeImage, isFacebookUrl, mockConditionCheck, mockParseListing, type ConditionInput, type Discrepancy, type Listing, type ListingInput,
} from "../listing.js";
import { mockAgreement, type AgreementDraft } from "../mock/agreement.js";
import { lookupScriptLine, mockCue, type PriceRange } from "../mock/extract.js";
import { clampSummary, guessSpeaker, itemName, mockDetect, mockSummary, normalizeDetectedCategory, type SummaryInput } from "../auto.js";
import { z } from "zod";
import { templateExplanation, formatClock } from "../mismatch.js";
import { formatCents } from "../money.js";
import type { CueExtraction, DealEvent, Detection, LineItem, MismatchDetails, Session, SessionSummary, Speaker } from "../types.js";
import {
  AGREEMENT_SYSTEM, CONDITION_SYSTEM, CUE_SYSTEM, DETECT_SYSTEM, LISTING_SYSTEM, LISTING_URL_SYSTEM, MISMATCH_SYSTEM, SUMMARY_SYSTEM,
  agreementUserPrompt, cueUserPrompt, detectUserPrompt, listingUrlPrompt, summaryUserPrompt,
} from "./prompts.js";
import type { ResearchState } from "../research.js";
import { NemotronAi } from "./nemotron.js";

export interface CueInput {
  session: Session;
  recent: DealEvent[];
  speaker: Speaker | "auto"; // "auto": the model (or the heuristic) decides and returns CueExtraction.speaker
  text: string;
  scriptId?: string;
  /** The session's live web research (finished agents only); null until at least one agent is done. */
  research?: CueResearch | null;
}

/** Compact view of the live research agents, passed to the cue model instead of static comparables. */
export interface CueResearch {
  status: "running" | "done";
  agents: {
    title: string;
    summary: string | null;
    price_low: number | null; // cents
    price_high: number | null; // cents
    top_sources: { title: string; price: number | null }[];
  }[];
}

export function cueResearchFrom(state: ResearchState | null): CueResearch | null {
  const done = state?.agents.filter((a) => a.status === "done") ?? [];
  if (!state || !done.length) return null;
  return {
    status: state.status,
    agents: done.map((a) => ({
      title: a.title,
      summary: a.summary,
      price_low: a.price_low,
      price_high: a.price_high,
      top_sources: a.sources.slice(0, 4).map((s) => ({ title: s.title, price: s.price })),
    })),
  };
}

/** The research fair range (cents) for null-target cues: the first finished agent with both ends. */
export function researchRange(r: CueResearch | null | undefined): PriceRange | null {
  const a = r?.agents.find((x) => x.price_low != null && x.price_high != null);
  return a ? { low: a.price_low!, high: a.price_high! } : null;
}

export const DetectionSchema = z.object({
  item: z.string().nullable(),
  category: z.string().nullable().optional(),
  asking_price: z.number().int().nonnegative().nullable().optional(),
  condition_claims: z.array(z.string()).nullable().optional(),
});

export const SummarySchema = z.object({
  outcome: z.enum(["deal", "no_deal", "undecided"]),
  final_price: z.number().int().nonnegative().nullable().optional(),
  headline: z.string().min(1),
  key_points: z.array(z.string()).default([]),
});

// ---------- shared by the Claude and Nemotron implementations ----------

/** Trim / normalise a model detection. */
export function finishDetection(out: z.infer<typeof DetectionSchema>): Detection {
  const item = out.item?.trim() || null;
  return {
    item,
    category: normalizeDetectedCategory(out.category, item ?? ""),
    asking_price: out.asking_price && out.asking_price > 0 ? out.asking_price : null,
    condition_claims: (out.condition_claims ?? []).map((c) => c.trim()).filter(Boolean).slice(0, 8),
  };
}

/** Deterministic guard-rails on a model agreement: known event ids, items[0] = the session item, total = price + fees. */
export function guardAgreement(draft: AgreementDraft, session: Session, events: DealEvent[]): AgreementDraft {
  const ids = new Set(events.map((e) => e.id));
  draft.source_event_ids = draft.source_event_ids.filter((id) => ids.has(id));
  const main = itemName(session);
  if (draft.items[0] !== main) draft.items = [main, ...draft.items.filter((i) => i !== main)];
  const computed = draft.price + draft.fees.reduce((s, f) => s + f.amount, 0);
  if (computed !== draft.total) {
    draft.open_questions.push(`Model total ${formatCents(draft.total)} did not equal price + fees; corrected to ${formatCents(computed)}.`);
    draft.total = computed;
  }
  return draft;
}

export function listingUserPrompt(input: ListingInput): string {
  return JSON.stringify({ url: input.url ?? null, pasted_text: input.text ?? null, screenshot_attached: !!input.image_base64 }, null, 1);
}

export function conditionUserPrompt(listing: Listing, input: ConditionInput): string {
  return JSON.stringify(
    { listing: { title: listing.title, condition_claims: listing.condition_claims, description: listing.description, asking_price: listing.asking_price }, buyer_observation: input.observation ?? null, photo_attached: !!input.image_base64 },
    null,
    1,
  );
}

/** Guard-rail: only claims the listing actually made (model claims mapped back to the listing's wording). */
export function keepListedClaims(listing: Listing, discrepancies: Discrepancy[]): Discrepancy[] {
  const claims = new Map(listing.condition_claims.map((c) => [c.trim().toLowerCase(), c]));
  return discrepancies
    .map((d) => ({ ...d, claim: claims.get(d.claim.trim().toLowerCase()) ?? d.claim }))
    .filter((d) => claims.has(d.claim.trim().toLowerCase()));
}

export function mismatchUserPrompt(m: MismatchDetails, lineItems: LineItem[], timeZone: string): string {
  return JSON.stringify({
    reasons: m.reasons,
    agreed_total: formatCents(m.agreed_total),
    requested_total: formatCents(m.requested_total),
    difference: formatCents(m.difference),
    extra_line_items: m.unmatched_line_items.map((li) => ({ label: li.label, amount: formatCents(li.amount) })),
    changed_line_items: m.mismatched_amount_line_items.map((li) => ({ label: li.label, amount: formatCents(li.amount) })),
    requested_line_items: lineItems.map((li) => ({ label: li.label, amount: formatCents(li.amount) })),
    contradicting_line: m.source_event_text,
    contradicting_line_time: m.source_event_timestamp ? formatClock(m.source_event_timestamp, timeZone) : null,
  });
}

export interface Ai {
  readonly kind: "mock" | "claude" | "nemotron";
  cue(input: CueInput): Promise<CueExtraction>;
  /** Auto sessions: what is being sold, the asking price and the seller's condition claims, from the transcript so far. */
  detect(session: Session, events: DealEvent[]): Promise<Detection>;
  /** POST /sessions/:id/end: the history summary. */
  summarize(input: SummaryInput): Promise<SessionSummary>;
  agreement(session: Session, events: DealEvent[]): Promise<AgreementDraft>;
  explainMismatch(m: MismatchDetails, lineItems: LineItem[]): Promise<string>;
  parseListing(input: ListingInput): Promise<Listing>;
  conditionCheck(listing: Listing, input: ConditionInput): Promise<Discrepancy[]>;
}

type Logger = { warn: (obj: unknown, msg?: string) => void };

export class MockAi implements Ai {
  readonly kind = "mock" as const;
  constructor(private timeZone = "America/Los_Angeles") {}
  async cue({ session, recent, speaker, text, scriptId, research }: CueInput): Promise<CueExtraction> {
    if (speaker !== "auto") return mockCue(text, speaker, session, scriptId, researchRange(research));
    // Speaker "auto": a verbatim script line knows its speaker; otherwise the keyword / alternation heuristic.
    const scripted = lookupScriptLine(text, undefined, scriptId);
    if (scripted) return { ...scripted.expected, speaker: scripted.speaker };
    const resolved = guessSpeaker(text, recent);
    return { ...mockCue(text, resolved, session, scriptId, researchRange(research)), speaker: resolved };
  }
  async detect(_session: Session, events: DealEvent[]) {
    return mockDetect(events);
  }
  async summarize(input: SummaryInput) {
    return mockSummary(input);
  }
  async agreement(session: Session, events: DealEvent[]) {
    return mockAgreement(session, events);
  }
  async explainMismatch(m: MismatchDetails) {
    return templateExplanation(m, this.timeZone);
  }
  async parseListing(input: ListingInput) {
    return mockParseListing(input);
  }
  async conditionCheck(listing: Listing, input: ConditionInput) {
    return mockConditionCheck(listing, input);
  }
}

type UserContent = string | Anthropic.ContentBlockParam[];

/** Text plus an optional base64 image (vision) as one user turn. */
function withImage(text: string, imageBase64?: string): UserContent {
  if (!imageBase64) return text;
  const { data, media_type } = decodeImage(imageBase64);
  return [
    { type: "image", source: { type: "base64", media_type, data } },
    { type: "text", text },
  ];
}

/** Extract the first JSON object from model text (tolerates code fences / stray prose). */
export function extractJson(text: string): unknown {
  const cleaned = text.replace(/```(?:json)?/gi, "").trim();
  const start = cleaned.indexOf("{");
  const end = cleaned.lastIndexOf("}");
  if (start < 0 || end <= start) throw new Error("no JSON object in model output");
  return JSON.parse(cleaned.slice(start, end + 1));
}

function textOf(msg: Anthropic.Message): string {
  if (msg.stop_reason === "refusal") throw new Error("model refused the request");
  return msg.content
    .filter((b): b is Anthropic.TextBlock => b.type === "text")
    .map((b) => b.text)
    .join("");
}

export class ClaudeAi implements Ai {
  readonly kind = "claude" as const;
  private client: Anthropic;
  private fallback: MockAi;

  constructor(private cfg: Config, private log: Logger, client?: Anthropic) {
    this.client = client ?? new Anthropic({ apiKey: cfg.anthropicApiKey, maxRetries: 2 });
    this.fallback = new MockAi(cfg.displayTimeZone);
  }

  private async call(model: string, system: string, user: UserContent, maxTokens: number, effort: "low" | "medium"): Promise<Anthropic.Message> {
    return this.client.messages.create({
      model,
      max_tokens: maxTokens,
      system,
      messages: [{ role: "user", content: user }],
      output_config: { effort },
    });
  }

  /** Call the model, validate with zod, retry once (with the validation error) on invalid JSON. */
  private async structured<S extends z.ZodTypeAny>(model: string, system: string, user: UserContent, schema: S, effort: "low" | "medium"): Promise<z.infer<S>> {
    const first = await this.call(model, system, user, 4000, effort);
    const firstText = textOf(first);
    try {
      return schema.parse(extractJson(firstText));
    } catch (err) {
      this.log.warn({ err: String(err), model }, "invalid model JSON, retrying once");
      const retry = await this.client.messages.create({
        model,
        max_tokens: 4000,
        system,
        output_config: { effort },
        messages: [
          { role: "user", content: user },
          { role: "assistant", content: firstText || "(empty)" },
          { role: "user", content: `That was not valid. Error: ${String(err).slice(0, 500)}. Reply with ONLY the corrected JSON object.` },
        ],
      });
      return schema.parse(extractJson(textOf(retry)));
    }
  }

  async cue(input: CueInput): Promise<CueExtraction> {
    try {
      const user = cueUserPrompt(input.session, input.recent, { speaker: input.speaker, text: input.text }, getTactics(), input.research ?? null);
      const out = await this.structured(this.cfg.cueModel, CUE_SYSTEM, user, CueExtractionSchema, "low");
      if (input.speaker !== "auto") return { ...out, speaker: undefined };
      return { ...out, speaker: out.speaker ?? guessSpeaker(input.text, input.recent) };
    } catch (err) {
      this.log.warn({ err: String(err) }, "cue model failed; using mock extraction");
      return this.fallback.cue(input);
    }
  }

  async detect(session: Session, events: DealEvent[]): Promise<Detection> {
    try {
      return finishDetection(await this.structured(this.cfg.cueModel, DETECT_SYSTEM, detectUserPrompt(session, events), DetectionSchema, "low"));
    } catch (err) {
      this.log.warn({ err: String(err) }, "detection model failed; using regex detection");
      return this.fallback.detect(session, events);
    }
  }

  async summarize(input: SummaryInput): Promise<SessionSummary> {
    try {
      const user = summaryUserPrompt(input.session, input.events, input.agreement, input.receipt, input.marketRange ?? null);
      const out = await this.structured(this.cfg.cueModel, SUMMARY_SYSTEM, user, SummarySchema, "low");
      return clampSummary({ outcome: out.outcome, final_price: out.final_price ?? null, headline: out.headline, key_points: out.key_points }, input.receipt);
    } catch (err) {
      this.log.warn({ err: String(err) }, "summary model failed; using template");
      return this.fallback.summarize(input);
    }
  }

  async agreement(session: Session, events: DealEvent[]): Promise<AgreementDraft> {
    try {
      const draft = await this.structured(this.cfg.agreementModel, AGREEMENT_SYSTEM, agreementUserPrompt(session, events), AgreementDraftSchema, "medium");
      return guardAgreement(draft, session, events);
    } catch (err) {
      this.log.warn({ err: String(err) }, "agreement model failed; using mock agreement");
      return this.fallback.agreement(session, events);
    }
  }

  /**
   * Real mode never returns the canned listing. Text / screenshot: Claude reads them. A bare URL: Claude reads the
   * page with the server-side web_fetch tool (we never scrape ourselves). Failures throw ListingUnreadableError (422).
   */
  async parseListing(input: ListingInput): Promise<Listing> {
    let listing: Listing;
    if (!input.text && !input.image_base64) {
      if (!input.url) throw new ListingUnreadableError(LISTING_UNREADABLE, "empty input");
      listing = await this.parseListingUrl(input.url);
    } else {
      try {
        listing = await this.structured(this.cfg.agreementModel, LISTING_SYSTEM, withImage(listingUserPrompt(input), input.image_base64), ListingModelSchema, "low");
      } catch (err) {
        this.log.warn({ err: String(err) }, "listing model failed");
        throw new ListingUnreadableError(LISTING_UNREADABLE, String(err).slice(0, 300));
      }
      if (!listing.title.trim() || listing.asking_price <= 0) throw new ListingUnreadableError(LISTING_UNREADABLE, "no title or price found");
    }
    if (input.url) listing.url = input.url;
    if (isFacebookUrl(input.url)) listing.source = "facebook_marketplace";
    return listing;
  }

  /** Bare-URL import: AGREEMENT_MODEL + web_fetch (max 2 fetches), pause_turn continued, then ListingModelSchema. */
  private async parseListingUrl(url: string): Promise<Listing> {
    const fail = (reason: string): never => {
      this.log.warn({ reason, url }, "listing url could not be read");
      throw new ListingUnreadableError(URL_UNREADABLE, reason);
    };
    const tools: Anthropic.ToolUnion[] = [{ type: "web_fetch_20260209", name: "web_fetch", max_uses: 2, max_content_tokens: 40000 }];
    const messages: Anthropic.MessageParam[] = [{ role: "user", content: listingUrlPrompt(url) }];
    const blocks: Anthropic.ContentBlock[] = [];
    const send = () =>
      this.client.messages.create({
        model: this.cfg.agreementModel,
        max_tokens: 4000,
        system: LISTING_URL_SYSTEM,
        output_config: { effort: "low" },
        tools,
        messages,
      });

    let msg: Anthropic.Message;
    try {
      msg = await send();
      blocks.push(...msg.content);
      // Server tools can pause a long turn; re-send with the assistant content so far to let it continue.
      for (let i = 0; msg.stop_reason === "pause_turn" && i < 3; i++) {
        messages.push({ role: "assistant", content: msg.content });
        msg = await send();
        blocks.push(...msg.content);
      }
    } catch (err) {
      return fail(`api error: ${String(err).slice(0, 200)}`);
    }
    if (msg.stop_reason === "refusal") return fail("model refused");
    if (msg.stop_reason === "pause_turn") return fail("still paused after 3 continuations");

    // Server-tool errors arrive as result blocks with an error object, not as exceptions.
    const fetches = blocks.filter((b): b is Anthropic.WebFetchToolResultBlock => b.type === "web_fetch_tool_result");
    const ok = fetches.filter((f) => f.content.type === "web_fetch_result");
    if (!ok.length) {
      const codes = fetches.map((f) => (f.content.type === "web_fetch_tool_result_error" ? f.content.error_code : "?"));
      return fail(fetches.length ? `web_fetch failed: ${codes.join(", ")}` : "model did not fetch the page");
    }

    let raw: unknown;
    try {
      raw = extractJson(textOf(msg));
    } catch (err) {
      return fail(`no JSON: ${String(err).slice(0, 200)}`);
    }
    const r = raw as { error?: unknown } | null;
    if (r && typeof r === "object" && r.error) return fail(`model: ${String(r.error).slice(0, 200)}`);
    const parsed = ListingModelSchema.safeParse(raw);
    if (!parsed.success) return fail(`invalid listing: ${parsed.error.message.slice(0, 200)}`);
    if (!parsed.data.title.trim() || parsed.data.asking_price <= 0) return fail("no title or price on the page");
    return parsed.data;
  }

  async conditionCheck(listing: Listing, input: ConditionInput): Promise<Discrepancy[]> {
    try {
      const out = await this.structured(this.cfg.agreementModel, CONDITION_SYSTEM, withImage(conditionUserPrompt(listing, input), input.image_base64), ConditionModelSchema, "low");
      return keepListedClaims(listing, out.discrepancies);
    } catch (err) {
      this.log.warn({ err: String(err) }, "condition model failed");
      throw new ConditionCheckError("Condition check failed. Try again, or describe what you see in a few words.");
    }
  }

  async explainMismatch(m: MismatchDetails, lineItems: LineItem[]): Promise<string> {
    try {
      const user = mismatchUserPrompt(m, lineItems, this.cfg.displayTimeZone);
      const msg = await this.client.messages.create({
        model: this.cfg.agreementModel,
        max_tokens: 1000,
        system: MISMATCH_SYSTEM,
        output_config: { effort: "low" },
        messages: [{ role: "user", content: user }],
      });
      const sentence = textOf(msg).trim().replace(/\s+/g, " ");
      if (!sentence) throw new Error("empty explanation");
      return sentence;
    } catch (err) {
      this.log.warn({ err: String(err) }, "explanation model failed; using template");
      return templateExplanation(m, this.cfg.displayTimeZone);
    }
  }
}

/**
 * Real mode: Nemotron on Nebius Token Factory when NEBIUS_API_KEY is set (unless AI_PROVIDER=claude), with Claude as the
 * per-call backup when ANTHROPIC_API_KEY is also set; Claude alone when only the Anthropic key is set; otherwise mock.
 */
export function createAi(cfg: Config, log: Logger): Ai {
  if (cfg.mockMode) return new MockAi(cfg.displayTimeZone);
  const claude = cfg.anthropicApiKey ? new ClaudeAi(cfg, log) : null;
  if (cfg.nebiusApiKey && cfg.aiProvider !== "claude") return new NemotronAi(cfg, log, { backup: claude });
  if (claude) {
    if (cfg.aiProvider === "nebius") log.warn({}, "AI_PROVIDER=nebius but NEBIUS_API_KEY is empty; using Claude");
    return claude;
  }
  log.warn({}, "MOCK_MODE=false but neither NEBIUS_API_KEY nor ANTHROPIC_API_KEY is set (or AI_PROVIDER=claude without a key); falling back to mock AI");
  return new MockAi(cfg.displayTimeZone);
}
