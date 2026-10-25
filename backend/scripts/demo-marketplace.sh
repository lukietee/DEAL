#!/usr/bin/env bash
# DEAL flagship demo: Facebook Marketplace meetup (used road bike), end to end.
# parse listing → create session with listing → condition check (worn tires, $40 off cue) → play bike script →
# draft agreement ($520) → both confirm → seller adds "$20 for gas, I drove here" → BLOCKED → buyer rejects →
# seller submits $520 → pay → receipt → dispute pack (listing + discrepancies).
#
# Usage: start the server (`npm run dev`), then `npm run demo:marketplace` or
#        `bash scripts/demo-marketplace.sh [BASE_URL]`. Requires curl + jq.
set -euo pipefail

BASE="${1:-${BASE_URL:-http://localhost:${PORT:-3000}}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENT="${CONTENT_DIR:-$HERE/../../content}"
SCRIPT_FILE="$CONTENT/scripts/marketplace_bike.json"
EXTRA_FILE="$CONTENT/scripts/seller_extra_fee_marketplace.json"
INTERVAL_MS="${INTERVAL_MS:-50}"
LISTING_URL="${LISTING_URL:-https://www.facebook.com/marketplace/item/1234567890/}"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
[[ -f "$SCRIPT_FILE" && -f "$EXTRA_FILE" ]] || { echo "content files missing under $CONTENT"; exit 1; }

bold() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*"; exit 1; }
api() { # api METHOD PATH [JSON]
  local method="$1" path="$2" body="${3:-}"
  local out code
  if [[ -n "$body" ]]; then
    out=$(curl -sS -X "$method" "$BASE$path" -H 'content-type: application/json' -d "$body" -w $'\n%{http_code}')
  else
    out=$(curl -sS -X "$method" "$BASE$path" -w $'\n%{http_code}')
  fi
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  if [[ "$code" -ge 400 ]]; then echo "$out" >&2; fail "$method $path -> HTTP $code"; fi
  echo "$out"
}
dollars() { jq -r '(. / 100) | tostring | "$" + .'; }

bold "Health ($BASE)"
api GET /health | jq -c '{ok, mock_mode, ai, store, payments}'

bold "1. Parse the Marketplace listing (no scraping: canned in mock mode)"
LISTING=$(api POST /listings/parse "$(jq -nc --arg u "$LISTING_URL" '{url: $u}')")
jq -c '{title, asking_price, source, condition_claims, url}' <<<"$LISTING"

bold "2. Create session with the listing (buyer B2) + seller joins"
SESSION_BODY=$(jq -c --argjson listing "$LISTING" '{category, item, asking_price, target_price, max_budget, style, listing: $listing}' "$SCRIPT_FILE")
SESSION=$(api POST /sessions "$SESSION_BODY")
SID=$(jq -r .id <<<"$SESSION"); CODE=$(jq -r .join_code <<<"$SESSION")
echo "session $SID  join_code $CODE  listing: $(jq -r .listing.title <<<"$SESSION")"
api POST /sessions/join "{\"join_code\":\"$CODE\"}" | jq -c '{id, item, status}'

bold "3. Condition check: buyer looks at the tires"
CC=$(api POST "/sessions/$SID/condition-check" '{"observation":"The tires are worn and the rear sidewall is cracked"}')
jq -c '.discrepancies[]' <<<"$CC"
echo "glasses: [$(jq -r .event.status_color <<<"$CC")] $(jq -r .event.cue <<<"$CC") — $(jq -r .event.cue_detail <<<"$CC")"
[[ "$(jq -r '.discrepancies[0].suggested_discount' <<<"$CC")" == "4000" ]] || fail "expected \$40 tire discount"

bold "4. Play bike script (interval ${INTERVAL_MS}ms) and wait"
PLAY=$(api POST "/sessions/$SID/script/play" "{\"script_id\":\"marketplace_bike\",\"interval_ms\":$INTERVAL_MS}")
TOTAL=$(jq -r .line_count <<<"$PLAY"); echo "started: $(jq -c . <<<"$PLAY")"
for i in $(seq 1 600); do
  STATE=$(api GET "/sessions/$SID")
  N=$(jq '[.events[] | select(.kind == "speech")] | length' <<<"$STATE"); DONE=$(jq -r '.script.done' <<<"$STATE")
  printf '\r  %s/%s lines' "$N" "$TOTAL"
  [[ "$DONE" == "true" ]] && break
  sleep 0.2
done
echo
[[ "$(jq -r '.script.error' <<<"$STATE")" == "null" ]] || fail "script error: $(jq -r .script.error <<<"$STATE")"
[[ "$N" == "$TOTAL" ]] || fail "expected $TOTAL events, got $N"
echo "cues:"
jq -r '.events[] | select(.tactic != null) | "  [\(.status_color)] \(.script_line_id // .kind) \(.tactic): \(.cue)\(if .cue_detail then " — " + .cue_detail else "" end)"' <<<"$STATE"
echo "current offer: $(jq '.session.current_offer' <<<"$STATE" | dollars)"

bold "5. Draft agreement + both confirm"
AGR=$(api POST "/sessions/$SID/agreement")
AID=$(jq -r .id <<<"$AGR")
jq -c '{price, items, fees, total, source_event_ids}' <<<"$AGR"
api POST "/agreements/$AID/confirm" '{"role":"buyer"}' >/dev/null
LOCKED=$(api POST "/agreements/$AID/confirm" '{"role":"seller"}')
jq -c '{status, fingerprint_short}' <<<"$LOCKED"
[[ "$(jq -r .status <<<"$LOCKED")" == "locked" ]] || fail "agreement not locked"
FP=$(jq -r .fingerprint <<<"$LOCKED")

bold "6. Seller: \"\$20 for gas, I drove here\" (said out loud, then added at the terminal)"
api POST "/sessions/$SID/events" '{"speaker":"seller","text":"Oh, and twenty bucks for gas, I drove here."}' | jq -c '{tactic, cue, cue_detail, status_color}'
BLOCKED=$(api POST "/sessions/$SID/payment-requests" "$(jq -c '{line_items: .blocked_request.line_items}' "$EXTRA_FILE")")
PR1=$(jq -r .id <<<"$BLOCKED")
jq -c '{status, amount, reasons: .mismatch.reasons, extra: .mismatch.unmatched_line_items}' <<<"$BLOCKED"
echo "explanation: $(jq -r .mismatch_explanation <<<"$BLOCKED")"
[[ "$(jq -r .status <<<"$BLOCKED")" == "blocked" ]] || fail "expected blocked"

bold "7. Buyer rejects; seller submits the agreed \$520"
api POST "/payment-requests/$PR1/decision" '{"decision":"reject"}' | jq -c '{status}'
OK=$(api POST "/sessions/$SID/payment-requests" "$(jq -c '{line_items: .corrected_request.line_items}' "$EXTRA_FILE")")
PR2=$(jq -r .id <<<"$OK")
jq -c '{status, amount}' <<<"$OK"
[[ "$(jq -r .status <<<"$OK")" == "approved" ]] || fail "expected approved"

bold "8. Pay: verified on both phones before the bike changes hands"
RECEIPT=$(api POST "/payment-requests/$PR2/pay")
jq -c '{stripe_payment_id, amount, status, blocked_total, summary, mock}' <<<"$RECEIPT"
[[ "$(jq -r .agreement_fingerprint <<<"$RECEIPT")" == "$FP" ]] || fail "receipt fingerprint mismatch"

bold "9. Dispute pack"
api GET "/sessions/$SID/dispute-pack" | jq -c '{format, fingerprint_valid: .fingerprint.valid, listing: .listing.title, condition_discrepancies: [.condition_discrepancies[] | {claim, suggested_discount}], excerpts: (.transcript_excerpts | length)}'

printf '\n\033[32mMARKETPLACE DEMO OK: %s\033[0m\n' "$(jq -r .summary <<<"$RECEIPT")"
