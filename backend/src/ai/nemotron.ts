// The Ai interface on NVIDIA Nemotron via Nebius Token Factory (src/nebius.ts). Same prompts, zod schemas and
// validate-and-retry-once pattern as the Claude implementation; each call is routed to the Nemotron model that fits it:
//   cue (Ultra, no thinking)  live cues + speaker                               (per line, ~0.9 s; Lightning mis-scaled money)
//   fast (Lightning)     product detection, session summary                          (background, ~0.6 s)
//   reasoning (Ultra)    agreement draft (thinking on), mismatch sentence           (money that gets locked)
//   general (Super)      listing parse from pasted text or a fetched page
//   vision (Super VL)    listing screenshots, condition-check photos
// When a Nemotron call fails, the call goes to the backup (ClaudeAi when ANTHROPIC_API_KEY is set), then to the mock
// for the calls that have one. Listing parse / condition check never return canned results in real mode.
import { z } from "zod";
import type { Config } from "../config.js";
import { AgreementDraftSchema, CueExtractionSchema, getTactics } from "../content.js";
import { clampSummary, guessSpeaker, type SummaryInput } from "../auto.js";
import {
  ConditionCheckError, ConditionModelSchema, LISTING_UNREADABLE, ListingModelSchema, ListingUnreadableError, URL_UNREADABLE,
  decodeImage, fetchListingPage, isFacebookUrl, type ConditionInput, type Discrepancy, type Listing, type ListingInput,
} from "../listing.js";
import { templateExplanation } from "../mismatch.js";
import type { AgreementDraft } from "../mock/agreement.js";
import { NemotronClient, imagePart, type NemotronContent, type NemotronMessage } from "../nebius.js";
import type { CueExtraction, DealEvent, Detection, LineItem, MismatchDetails, Session, SessionSummary } from "../types.js";
import {
  DetectionSchema, MockAi, SummarySchema, conditionUserPrompt, extractJson, finishDetection, guardAgreement, keepListedClaims,
  listingUserPrompt, mismatchUserPrompt, type Ai, type CueInput,
} from "./index.js";
import {
  AGREEMENT_SYSTEM, CONDITION_SYSTEM, CUE_SYSTEM, DETECT_SYSTEM, LISTING_PAGE_SYSTEM, LISTING_SYSTEM, MISMATCH_SYSTEM, NEMOTRON_CUE_NOTES, SUMMARY_SYSTEM,
  agreementUserPrompt, cueUserPrompt, detectUserPrompt, listingPagePrompt, summaryUserPrompt,
} from "./prompts.js";

type Logger = { warn: (obj: unknown, msg?: string) => void };
type Chat = Pick<NemotronClient, "chat">;

/** Per-call settings. Thinking only for the agreement: Ultra reasons in a few seconds and the result is locked + paid. */
const CALLS = {
  cue: { maxTokens: 600, timeoutMs: 8_000, thinking: false },
  detect: { maxTokens: 400, timeoutMs: 8_000, thinking: false },
  summary: { maxTokens: 600, timeoutMs: 12_000, thinking: false },
  agreement: { maxTokens: 6_000, timeoutMs: 60_000, thinking: true },
  mismatch: { maxTokens: 300, timeoutMs: 15_000, thinking: false },
  listing: { maxTokens: 2_000, timeoutMs: 25_000, thinking: false },
  vision: { maxTokens: 2_000, timeoutMs: 30_000, thinking: false },
} as const;
type CallSettings = (typeof CALLS)[keyof typeof CALLS];

/** Text plus an optional base64 image (vision) as one user turn, OpenAI-style parts. */
export function nemotronUserContent(text: string, imageBase64?: string): NemotronContent {
  if (!imageBase64) return text;
  const { data, media_type } = decodeImage(imageBase64);
  return [imagePart(data, media_type), { type: "text", text }];
}

/** Drop a leaked <think>…</think> block (thinking output should arrive separately, but never parse it as the answer). */
export function stripThinking(text: string): string {
  return text.replace(/<think>[\s\S]*?(<\/think>|$)/gi, "").trim();
}

/**
 * Deterministic guard on cue money: a value more than 20× the session's reference price that is still plausible after
 * dividing by 100 was cents converted twice ($475 → 4750000). Fixes current_offer and new_terms amounts.
 */
export function fixCentsScale(out: CueExtraction, session: Session): CueExtraction {
  const ref = session.asking_price ?? session.target_price ?? session.max_budget ?? session.current_offer;
  if (!ref) return out;
  const fix = <T extends number | null>(v: T): T => (v != null && v > ref * 20 && v % 100 === 0 && v / 100 <= ref * 20 ? (v / 100) as T : v);
  return {
    ...out,
    current_offer: fix(out.current_offer),
    new_terms: out.new_terms.map((t) => ({ ...t, amount: fix(t.amount) })),
  };
}

const ListingPageSchema = z.union([z.object({ error: z.string().min(1) }), ListingModelSchema]);

export interface NemotronAiOptions {
  client?: Chat;
  /** Tried when a Nemotron call fails (ClaudeAi in production when ANTHROPIC_API_KEY is set). */
  backup?: Ai | null;
  /** Page fetch for bare-URL listing imports (tests inject a fake). */
  fetch?: typeof fetch;
}

export class NemotronAi implements Ai {
  readonly kind = "nemotron" as const;
  readonly backup: Ai | null;
  private client: Chat;
  private mock: MockAi;
  private fetchImpl: typeof fetch;

  constructor(private cfg: Config, private log: Logger, opts: NemotronAiOptions = {}) {
    this.client = opts.client ?? new NemotronClient(cfg.nebiusApiKey, cfg.nebiusBaseUrl);
    this.backup = opts.backup ?? null;
    this.mock = new MockAi(cfg.displayTimeZone);
    this.fetchImpl = opts.fetch ?? fetch;
  }

  /** Call the model in JSON mode, validate with zod, retry once (with the validation error) on invalid JSON. */
  private async structured<S extends z.ZodTypeAny>(model: string, system: string, user: NemotronContent, schema: S, call: CallSettings): Promise<z.infer<S>> {
    const messages: NemotronMessage[] = [
      { role: "system", content: system },
      { role: "user", content: user },
    ];
    const first = stripThinking((await this.client.chat({ model, messages, json: true, ...call })).text);
    try {
      return schema.parse(extractJson(first));
    } catch (err) {
      this.log.warn({ err: String(err), model }, "invalid model JSON, retrying once");
      const retry = await this.client.chat({
        model,
        json: true,
        ...call,
        messages: [
          ...messages,
          { role: "assistant", content: first || "(empty)" },
          { role: "user", content: `That was not valid. Error: ${String(err).slice(0, 500)}. Reply with ONLY the corrected JSON object.` },
        ],
      });
      return schema.parse(extractJson(stripThinking(retry.text)));
    }
  }

  /** Nemotron first; on failure the backup provider, then the mock. */
  private async withBackup<T>(what: string, run: () => Promise<T>, backup: (ai: Ai) => Promise<T>): Promise<T> {
    try {
      return await run();
    } catch (err) {
      this.log.warn({ err: String(err) }, `nemotron ${what} failed; using ${this.backup?.kind ?? "mock"}`);
      return backup(this.backup ?? this.mock);
    }
  }

  async cue(input: CueInput): Promise<CueExtraction> {
    return this.withBackup("cue", async () => {
      const user = cueUserPrompt(input.session, input.recent, { speaker: input.speaker, text: input.text }, getTactics(), input.research ?? null);
      const out = fixCentsScale(await this.structured(this.cfg.nemotronCueModel, CUE_SYSTEM + NEMOTRON_CUE_NOTES, user, CueExtractionSchema, CALLS.cue), input.session);
      // Guard: never a calm colour while the standing offer is above the buyer's max (the prompt's own red rule).
      const max = input.session.max_budget;
      if (max != null && out.current_offer != null && out.current_offer > max) out.status = "red";
      if (input.speaker !== "auto") return { ...out, speaker: undefined };
      return { ...out, speaker: out.speaker ?? guessSpeaker(input.text, input.recent) };
    }, (ai) => ai.cue(input));
  }

  async detect(session: Session, events: DealEvent[]): Promise<Detection> {
    return this.withBackup(
      "detection",
      async () => finishDetection(await this.structured(this.cfg.nemotronFastModel, DETECT_SYSTEM, detectUserPrompt(session, events), DetectionSchema, CALLS.detect)),
      (ai) => ai.detect(session, events),
    );
  }

  async summarize(input: SummaryInput): Promise<SessionSummary> {
    return this.withBackup("summary", async () => {
      const user = summaryUserPrompt(input.session, input.events, input.agreement, input.receipt, input.marketRange ?? null);
      const out = await this.structured(this.cfg.nemotronFastModel, SUMMARY_SYSTEM, user, SummarySchema, CALLS.summary);
      return clampSummary({ outcome: out.outcome, final_price: out.final_price ?? null, headline: out.headline, key_points: out.key_points }, input.receipt);
    }, (ai) => ai.summarize(input));
  }

  async agreement(session: Session, events: DealEvent[]): Promise<AgreementDraft> {
    return this.withBackup("agreement", async () => {
      const draft = await this.structured(this.cfg.nemotronReasoningModel, AGREEMENT_SYSTEM, agreementUserPrompt(session, events), AgreementDraftSchema, CALLS.agreement);
      return guardAgreement(draft, session, events);
    }, (ai) => ai.agreement(session, events));
  }

  async explainMismatch(m: MismatchDetails, lineItems: LineItem[]): Promise<string> {
    try {
      const res = await this.client.chat({
        model: this.cfg.nemotronReasoningModel,
        messages: [
          { role: "system", content: MISMATCH_SYSTEM },
          { role: "user", content: mismatchUserPrompt(m, lineItems, this.cfg.displayTimeZone) },
        ],
        ...CALLS.mismatch,
      });
      const sentence = stripThinking(res.text).replace(/^["'\s]+|["'\s]+$/g, "").replace(/\s+/g, " ");
      if (!sentence) throw new Error("empty explanation");
      return sentence;
    } catch (err) {
      this.log.warn({ err: String(err) }, `nemotron explanation failed; using ${this.backup ? this.backup.kind : "template"}`);
      return this.backup ? this.backup.explainMismatch(m, lineItems) : templateExplanation(m, this.cfg.displayTimeZone);
    }
  }

  /**
   * Real mode never returns the canned listing. Text: Super. Screenshot: Super VL. A bare URL: we fetch the page
   * server-side and Super reads its text; Facebook links are 422 at once (login wall, never scraped).
   * Failures go to the backup provider when there is one, else throw ListingUnreadableError (422).
   */
  async parseListing(input: ListingInput): Promise<Listing> {
    if (!input.text && !input.image_base64) {
      if (!input.url) throw new ListingUnreadableError(LISTING_UNREADABLE, "empty input");
      if (isFacebookUrl(input.url)) {
        this.log.warn({ url: input.url }, "listing url could not be read: facebook link (login wall)");
        throw new ListingUnreadableError(URL_UNREADABLE, "facebook links are not fetched");
      }
    }
    let listing: Listing;
    try {
      listing = input.text || input.image_base64 ? await this.parseListingContent(input) : await this.parseListingUrl(input.url!);
    } catch (err) {
      if (!(err instanceof ListingUnreadableError)) throw err;
      if (!this.backup) throw err;
      this.log.warn({ reason: err.reason }, `nemotron listing parse failed; trying ${this.backup.kind}`);
      return this.backup.parseListing(input);
    }
    if (input.url) listing.url = input.url;
    if (isFacebookUrl(input.url)) listing.source = "facebook_marketplace";
    return listing;
  }

  private async parseListingContent(input: ListingInput): Promise<Listing> {
    let listing: Listing;
    try {
      const [model, call] = input.image_base64 ? [this.cfg.nemotronVisionModel, CALLS.vision] : [this.cfg.nemotronModel, CALLS.listing];
      listing = await this.structured(model, LISTING_SYSTEM, nemotronUserContent(listingUserPrompt(input), input.image_base64), ListingModelSchema, call);
    } catch (err) {
      this.log.warn({ err: String(err) }, "listing model failed");
      throw new ListingUnreadableError(LISTING_UNREADABLE, String(err).slice(0, 300));
    }
    if (!listing.title.trim() || listing.asking_price <= 0) throw new ListingUnreadableError(LISTING_UNREADABLE, "no title or price found");
    return listing;
  }

  private async parseListingUrl(url: string): Promise<Listing> {
    const fail = (reason: string): never => {
      this.log.warn({ reason, url }, "listing url could not be read");
      throw new ListingUnreadableError(URL_UNREADABLE, reason);
    };
    let page: string;
    try {
      page = await fetchListingPage(url, this.fetchImpl);
    } catch (err) {
      return fail(`fetch failed: ${String(err).slice(0, 200)}`);
    }
    let out: z.infer<typeof ListingPageSchema>;
    try {
      out = await this.structured(this.cfg.nemotronModel, LISTING_PAGE_SYSTEM, listingPagePrompt(url, page), ListingPageSchema, CALLS.listing);
    } catch (err) {
      return fail(`model: ${String(err).slice(0, 200)}`);
    }
    if ("error" in out) return fail(`model: ${out.error.slice(0, 200)}`);
    if (!out.title.trim() || out.asking_price <= 0) return fail("no title or price on the page");
    return out;
  }

  async conditionCheck(listing: Listing, input: ConditionInput): Promise<Discrepancy[]> {
    try {
      // A photo goes to the vision model; a typed observation alone to Super.
      const [model, call] = input.image_base64 ? [this.cfg.nemotronVisionModel, CALLS.vision] : [this.cfg.nemotronModel, CALLS.listing];
      const out = await this.structured(model, CONDITION_SYSTEM, nemotronUserContent(conditionUserPrompt(listing, input), input.image_base64), ConditionModelSchema, call);
      return keepListedClaims(listing, out.discrepancies);
    } catch (err) {
      if (this.backup) {
        this.log.warn({ err: String(err) }, `nemotron condition check failed; using ${this.backup.kind}`);
        return this.backup.conditionCheck(listing, input);
      }
      this.log.warn({ err: String(err) }, "condition model failed");
      throw new ConditionCheckError("Condition check failed. Try again, or describe what you see in a few words.");
    }
  }
}
