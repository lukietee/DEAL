import Anthropic from "@anthropic-ai/sdk";
import type { z } from "zod";
import type { Config } from "../config.js";
import { AgreementDraftSchema, CueExtractionSchema, getComparables, getTactics } from "../content.js";
import {
  ConditionModelSchema, ListingModelSchema, decodeImage, isFacebookUrl, mockConditionCheck, mockParseListing,
  type ConditionInput, type Discrepancy, type Listing, type ListingInput,
} from "../listing.js";
import { mockAgreement, type AgreementDraft } from "../mock/agreement.js";
import { mockCue } from "../mock/extract.js";
import { templateExplanation, formatClock } from "../mismatch.js";
import { formatCents } from "../money.js";
import type { CueExtraction, DealEvent, LineItem, MismatchDetails, Session, Speaker } from "../types.js";
import {
  AGREEMENT_SYSTEM, CONDITION_SYSTEM, CUE_SYSTEM, LISTING_SYSTEM, MISMATCH_SYSTEM, agreementUserPrompt, cueUserPrompt,
} from "./prompts.js";

export interface CueInput {
  session: Session;
  recent: DealEvent[];
  speaker: Speaker;
  text: string;
  scriptId?: string;
}

export interface Ai {
  readonly kind: "mock" | "claude";
  cue(input: CueInput): Promise<CueExtraction>;
  agreement(session: Session, events: DealEvent[]): Promise<AgreementDraft>;
  explainMismatch(m: MismatchDetails, lineItems: LineItem[]): Promise<string>;
  parseListing(input: ListingInput): Promise<Listing>;
  conditionCheck(listing: Listing, input: ConditionInput): Promise<Discrepancy[]>;
}

type Logger = { warn: (obj: unknown, msg?: string) => void };

export class MockAi implements Ai {
  readonly kind = "mock" as const;
  constructor(private timeZone = "America/Los_Angeles") {}
  async cue({ session, speaker, text, scriptId }: CueInput) {
    return mockCue(text, speaker, session, scriptId);
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

  constructor(private cfg: Config, private log: Logger) {
    this.client = new Anthropic({ apiKey: cfg.anthropicApiKey, maxRetries: 2 });
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
      const user = cueUserPrompt(input.session, input.recent, { speaker: input.speaker, text: input.text }, getTactics(), getComparables(input.session.category));
      return await this.structured(this.cfg.cueModel, CUE_SYSTEM, user, CueExtractionSchema, "low");
    } catch (err) {
      this.log.warn({ err: String(err) }, "cue model failed; using mock extraction");
      return this.fallback.cue(input);
    }
  }

  async agreement(session: Session, events: DealEvent[]): Promise<AgreementDraft> {
    try {
      const draft = await this.structured(this.cfg.agreementModel, AGREEMENT_SYSTEM, agreementUserPrompt(session, events), AgreementDraftSchema, "medium");
      // Deterministic guard-rails on model output.
      const ids = new Set(events.map((e) => e.id));
      draft.source_event_ids = draft.source_event_ids.filter((id) => ids.has(id));
      if (draft.items[0] !== session.item) draft.items = [session.item, ...draft.items.filter((i) => i !== session.item)];
      const computed = draft.price + draft.fees.reduce((s, f) => s + f.amount, 0);
      if (computed !== draft.total) {
        draft.open_questions.push(`Model total ${formatCents(draft.total)} did not equal price + fees; corrected to ${formatCents(computed)}.`);
        draft.total = computed;
      }
      return draft;
    } catch (err) {
      this.log.warn({ err: String(err) }, "agreement model failed; using mock agreement");
      return this.fallback.agreement(session, events);
    }
  }

  async parseListing(input: ListingInput): Promise<Listing> {
    // A bare URL can't be read without scraping Facebook (which we don't do): use the canned listing.
    if (!input.text && !input.image_base64) {
      this.log.warn({}, "listing parse with only a url: no scraping, returning the canned listing");
      return this.fallback.parseListing(input);
    }
    try {
      const user = JSON.stringify({ url: input.url ?? null, pasted_text: input.text ?? null, screenshot_attached: !!input.image_base64 }, null, 1);
      const listing = await this.structured(this.cfg.agreementModel, LISTING_SYSTEM, withImage(user, input.image_base64), ListingModelSchema, "low");
      if (input.url) listing.url = input.url;
      if (isFacebookUrl(input.url)) listing.source = "facebook_marketplace";
      return listing;
    } catch (err) {
      this.log.warn({ err: String(err) }, "listing model failed; using canned listing");
      return this.fallback.parseListing(input);
    }
  }

  async conditionCheck(listing: Listing, input: ConditionInput): Promise<Discrepancy[]> {
    try {
      const user = JSON.stringify(
        { listing: { title: listing.title, condition_claims: listing.condition_claims, description: listing.description, asking_price: listing.asking_price }, buyer_observation: input.observation ?? null, photo_attached: !!input.image_base64 },
        null,
        1,
      );
      const out = await this.structured(this.cfg.agreementModel, CONDITION_SYSTEM, withImage(user, input.image_base64), ConditionModelSchema, "low");
      // Guard-rail: only claims the listing actually made.
      const claims = new Map(listing.condition_claims.map((c) => [c.trim().toLowerCase(), c]));
      return out.discrepancies
        .map((d) => ({ ...d, claim: claims.get(d.claim.trim().toLowerCase()) ?? d.claim }))
        .filter((d) => claims.has(d.claim.trim().toLowerCase()));
    } catch (err) {
      this.log.warn({ err: String(err) }, "condition model failed; using mock condition check");
      return this.fallback.conditionCheck(listing, input);
    }
  }

  async explainMismatch(m: MismatchDetails, lineItems: LineItem[]): Promise<string> {
    try {
      const user = JSON.stringify({
        reasons: m.reasons,
        agreed_total: formatCents(m.agreed_total),
        requested_total: formatCents(m.requested_total),
        difference: formatCents(m.difference),
        extra_line_items: m.unmatched_line_items.map((li) => ({ label: li.label, amount: formatCents(li.amount) })),
        changed_line_items: m.mismatched_amount_line_items.map((li) => ({ label: li.label, amount: formatCents(li.amount) })),
        requested_line_items: lineItems.map((li) => ({ label: li.label, amount: formatCents(li.amount) })),
        contradicting_line: m.source_event_text,
        contradicting_line_time: m.source_event_timestamp ? formatClock(m.source_event_timestamp, this.cfg.displayTimeZone) : null,
      });
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

export function createAi(cfg: Config, log: Logger): Ai {
  if (cfg.mockMode) return new MockAi(cfg.displayTimeZone);
  if (!cfg.anthropicApiKey) {
    log.warn({}, "MOCK_MODE=false but ANTHROPIC_API_KEY is empty; falling back to mock AI");
    return new MockAi(cfg.displayTimeZone);
  }
  return new ClaudeAi(cfg, log);
}
