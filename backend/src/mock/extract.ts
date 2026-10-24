// Mock-mode extraction: script `expected` lookups first, then a keyword/regex fallback driven by tactics.json.
import { getAllScripts, getComparables, getTactics, type Script } from "../content.js";
import { formatCentsShort } from "../money.js";
import type { CueExtraction, DealEvent, NewTerm, Session, Speaker, StatusColor } from "../types.js";

export function normalizeText(t: string): string {
  return t.toLowerCase().replace(/[^a-z0-9$]+/g, " ").trim();
}

/** Find the expected extraction for a line that appears verbatim in any content script. */
export function lookupScriptExpectation(text: string, speaker?: Speaker, preferScriptId?: string): CueExtraction | null {
  const n = normalizeText(text);
  const scripts = getAllScripts().sort((a, b) => (a.id === preferScriptId ? -1 : b.id === preferScriptId ? 1 : 0));
  for (const s of scripts) {
    for (const line of s.lines) {
      if (line.expected && normalizeText(line.text) === n && (!speaker || line.speaker === speaker)) {
        return structuredClone(line.expected);
      }
    }
  }
  return null;
}

interface MoneyMention {
  cents: number;
  index: number;
  monthly: boolean;
}

/** Parse "$34,600", "$499", "34,600", "$35k", "34.6k", "$489 a month", "$489/mo". */
export function parseMoney(text: string): MoneyMention[] {
  const out: MoneyMention[] = [];
  const re = /(\$\s?)?(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?\s?(k|thousand)?\b/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    const [full, dollar, whole, frac, k] = m;
    if (!dollar && !k && !whole!.includes(",")) continue; // bare numbers (years, mileage) ignored
    let value = Number(whole!.replace(/,/g, "")) + (frac ? Number(frac) : 0);
    if (k) value *= 1000;
    const after = text.slice(m.index + full.length, m.index + full.length + 14).toLowerCase();
    if (/^\s*(miles|mi\b|k miles)/.test(after)) continue;
    const monthly = /^\s*(\/\s?mo|a month|per month|monthly|\/month)/.test(after);
    out.push({ cents: Math.round(value * 100), index: m.index, monthly });
  }
  return out;
}

const FEE_WORDS: Array<[RegExp, string, string]> = [
  [/doc(umentation)? fee/i, "fee", "doc fee"],
  [/processing fee/i, "fee", "processing fee"],
  [/(card|convenience) fee/i, "fee", "card fee"],
  [/dealer prep/i, "fee", "dealer prep"],
  [/protection package/i, "addon", "protection package"],
  [/extended warranty|warranty/i, "addon", "warranty"],
  [/service plan/i, "addon", "service plan"],
  [/(tax|taxes)\b/i, "fee", "tax"],
];

function fill(template: string, vars: Record<string, string>): string {
  return template.replace(/\{(\w+)\}/g, (_, k: string) => vars[k] ?? `{${k}}`);
}

function offerStatus(offer: number | null, session: Pick<Session, "target_price" | "max_budget">): StatusColor {
  if (offer == null) return "yellow";
  if (offer <= session.target_price) return "green";
  if (offer <= session.max_budget) return "yellow";
  return "red";
}

const SEVERITY: Record<StatusColor, number> = { green: 0, yellow: 1, red: 2 };

/** Keyword/regex fallback for free-typed lines that are not in any script. */
export function fallbackExtraction(
  text: string,
  speaker: Speaker,
  session: Pick<Session, "category" | "asking_price" | "target_price" | "max_budget" | "current_offer" | "current_offer_by">,
): CueExtraction {
  const lower = text.toLowerCase();
  const mentions = parseMoney(text);
  const newTerms: NewTerm[] = [];

  // Fees / add-ons with an amount near them.
  const nonMonthly = mentions.filter((m) => !m.monthly);
  const used = new Set<number>();
  for (const [re, type, label] of FEE_WORDS) {
    const hit = re.exec(text);
    if (!hit) continue;
    const near = nonMonthly
      .filter((m) => !used.has(m.index))
      .sort((a, b) => Math.abs(a.index - hit.index) - Math.abs(b.index - hit.index))[0];
    const waived = /waive|no (doc )?fee|free/i.test(lower);
    if (near && Math.abs(near.index - hit.index) < 40) {
      used.add(near.index);
      newTerms.push({ type, label, amount: near.cents });
    } else {
      newTerms.push({ type, label, amount: waived ? 0 : null, uncertain: !waived });
    }
  }

  // Price offer: the largest remaining non-monthly amount that looks like a price (>= 30% of asking).
  const candidates = nonMonthly.filter((m) => !used.has(m.index) && m.cents >= session.asking_price * 0.3);
  const offerMention = candidates.sort((a, b) => b.cents - a.cents)[0];
  let currentOffer = session.current_offer;
  let offerBy = session.current_offer_by;
  if (offerMention) {
    currentOffer = offerMention.cents;
    offerBy = speaker;
    newTerms.unshift({ type: "price", label: "price", amount: offerMention.cents });
  }
  if (/included|throw in|i'll include/i.test(lower)) {
    const m = /(?:throw in|include|including)\s+(?:the\s+)?([a-z][a-z \-]{2,30}?)(?:[.,!]|$| and )/i.exec(text);
    if (m) newTerms.push({ type: "item", label: m[1]!.trim(), amount: 0 });
  }

  // Tactic detection via tactics.json hints (seller lines only — the buyer's own words aren't tactics).
  let tacticId: string | null = null;
  let cue: string | null = null;
  let cueDetail: string | null = null;
  let tacticStatus: StatusColor | null = null;
  if (speaker === "seller") {
    for (const t of getTactics()) {
      const hit = t.detection_hints.some((h) => {
        const hint = h.toLowerCase();
        if (/[<>~]|within|stated with|after buyer/.test(hint)) return false; // descriptive hints, not phrases
        return hint.length > 1 && lower.includes(hint);
      });
      if (!hit) continue;
      tacticId = t.id;
      tacticStatus = t.status;
      cue = t.cue_template;
      if (t.id === "monthly_payment_framing") {
        const monthly = mentions.find((m) => m.monthly);
        const monthsMatch = /(\d{2})\s?(months|mo\b)/i.exec(text);
        const months = monthsMatch ? Number(monthsMatch[1]) : 72;
        if (monthly) {
          cueDetail = `${formatCentsShort(monthly.cents)}/mo × ${months} = ${formatCentsShort(monthly.cents * months)}`;
        }
      } else if (t.cue_detail_template) {
        const fee = newTerms.find((x) => x.type !== "price" && x.amount);
        if (fee) cueDetail = fill(t.cue_detail_template, { label: fee.label, amount: formatCentsShort(fee.amount!).slice(1) });
        else cueDetail = null;
      }
      break;
    }
  }

  // Offer near a comparable (seller offers only).
  if (!tacticId && speaker === "seller" && offerMention) {
    const comps = getComparables(session.category) as { listings?: Array<{ price: number }> } | null;
    const listings = comps?.listings ?? [];
    const tolerance = session.category === "car" ? 50000 : Math.round(offerMention.cents * 0.1);
    const near = listings
      .filter((l) => offerMention.cents > l.price && offerMention.cents - l.price <= tolerance)
      .sort((a, b) => offerMention.cents - a.price - (offerMention.cents - b.price))[0];
    if (near) {
      tacticId = "near_comparable";
      tacticStatus = "yellow";
      cue = `Mention the ${formatCentsShort(offerMention.cents - near.price)} comparable`;
      cueDetail = `Comparable listed at ${formatCentsShort(near.price)}`;
    }
  }

  let status = offerStatus(currentOffer, session);
  if (tacticStatus && SEVERITY[tacticStatus] > SEVERITY[status]) status = tacticStatus;
  if (!cue) {
    if (newTerms.some((t) => t.type !== "price" && t.type !== "item" && (t.amount ?? 1) > 0)) cue = "Ask for the all-in total";
    else if (offerMention && currentOffer != null) {
      if (currentOffer <= session.target_price) cue = speaker === "seller" ? "At target. Confirm the total." : "Strong offer. Stay quiet.";
      else if (currentOffer <= session.max_budget) cue = "Under max. Push further.";
      else cue = "Above max. Hold firm.";
    } else cue = speaker === "seller" ? "Listen. Stay on total price." : "Keep it on total price.";
  }

  return {
    current_offer: currentOffer,
    offer_by: offerBy,
    new_terms: newTerms,
    tactic_detected: tacticId,
    cue,
    cue_detail: cueDetail,
    status,
  };
}

export function mockCue(text: string, speaker: Speaker, session: Session, scriptId?: string): CueExtraction {
  return lookupScriptExpectation(text, speaker, scriptId) ?? fallbackExtraction(text, speaker, session);
}

/** Which script (if any) these events were played from. */
export function scriptForEvents(events: DealEvent[]): Script | null {
  const scripted = events.filter((e) => e.script_line_id);
  if (!scripted.length) return null;
  for (const s of getAllScripts()) {
    const texts = new Set(s.lines.map((l) => normalizeText(l.text)));
    if (scripted.every((e) => texts.has(normalizeText(e.text)))) return s;
  }
  return null;
}
