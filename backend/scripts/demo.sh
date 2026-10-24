#!/usr/bin/env bash
# DEAL end-to-end demo (12.6): create session → play car script → draft agreement → both confirm →
# seller adds $1,200 protection package → BLOCKED → buyer rejects → seller submits correct amount → pay → receipt.
#
# Usage: start the server (`npm run dev`), then `npm run demo` or `bash scripts/demo.sh [BASE_URL]`.
# Requires curl + jq.
set -euo pipefail

BASE="${1:-${BASE_URL:-http://localhost:${PORT:-3000}}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTENT="${CONTENT_DIR:-$HERE/../../content}"
SCRIPT_FILE="$CONTENT/scripts/car_accord.json"
EXTRA_FILE="$CONTENT/scripts/seller_extra_fee.json"
INTERVAL_MS="${INTERVAL_MS:-50}"

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

bold "1. Create session (buyer B2)"
SESSION_BODY=$(jq -c '{category, item, asking_price, target_price, max_budget, style}' "$SCRIPT_FILE")
SESSION=$(api POST /sessions "$SESSION_BODY")
SID=$(jq -r .id <<<"$SESSION"); CODE=$(jq -r .join_code <<<"$SESSION")
echo "session $SID  join_code $CODE  item: $(jq -r .item <<<"$SESSION")"

bold "1b. Seller joins with code (S1)"
api POST /sessions/join "{\"join_code\":\"$CODE\"}" | jq -c '{id, item, status}'

bold "1c. Comparables"
api GET "/comparables/$(jq -r .category <<<"$SESSION")" | jq -r '.listings[] | "  \(.title): $\(.price/100)"'

bold "2. Play car script (interval ${INTERVAL_MS}ms) and wait"
PLAY=$(api POST "/sessions/$SID/script/play" "{\"script_id\":\"car_accord\",\"interval_ms\":$INTERVAL_MS}")
TOTAL=$(jq -r .line_count <<<"$PLAY"); echo "started: $(jq -c . <<<"$PLAY")"
for i in $(seq 1 600); do
  STATE=$(api GET "/sessions/$SID")
  N=$(jq '.events | length' <<<"$STATE"); DONE=$(jq -r '.script.done' <<<"$STATE")
  printf '\r  %s/%s lines' "$N" "$TOTAL"
  [[ "$DONE" == "true" ]] && break
  sleep 0.2
done
echo
[[ "$(jq -r '.script.error' <<<"$STATE")" == "null" ]] || fail "script error: $(jq -r .script.error <<<"$STATE")"
[[ "$N" == "$TOTAL" ]] || fail "expected $TOTAL events, got $N"
echo "cues:"
jq -r '.events[] | select(.tactic != null) | "  [\(.status_color)] \(.script_line_id) \(.tactic): \(.cue)\(if .cue_detail then " — " + .cue_detail else "" end)"' <<<"$STATE"
echo "current offer: $(jq '.session.current_offer' <<<"$STATE" | dollars)"
echo "terms: $(jq -c '[.session.terms[] | select(.removed|not) | "\(.label)=\(.amount)"]' <<<"$STATE")"

bold "3. Draft agreement (B4)"
AGR=$(api POST "/sessions/$SID/agreement")
AID=$(jq -r .id <<<"$AGR")
jq -c '{id, price, items, fees, total, source_event_ids, status}' <<<"$AGR"

bold "4. Both confirm"
api POST "/agreements/$AID/confirm" '{"role":"buyer"}' | jq -c '{status, buyer_confirmed_at, seller_confirmed_at}'
LOCKED=$(api POST "/agreements/$AID/confirm" '{"role":"seller"}')
jq -c '{status, fingerprint_short, fingerprint}' <<<"$LOCKED"
[[ "$(jq -r .status <<<"$LOCKED")" == "locked" ]] || fail "agreement not locked"
FP=$(jq -r .fingerprint <<<"$LOCKED")

bold "5. Seller adds \$1,200 protection package (S4)"
BLOCKED=$(api POST "/sessions/$SID/payment-requests" "$(jq -c '{line_items: .blocked_request.line_items}' "$EXTRA_FILE")")
PR1=$(jq -r .id <<<"$BLOCKED")
jq -c '{id, status, amount, reasons: .mismatch.reasons, extra: .mismatch.unmatched_line_items}' <<<"$BLOCKED"
echo "explanation: $(jq -r .mismatch_explanation <<<"$BLOCKED")"
[[ "$(jq -r .status <<<"$BLOCKED")" == "blocked" ]] || fail "expected blocked"

bold "6. Buyer rejects (B5)"
api POST "/payment-requests/$PR1/decision" '{"decision":"reject"}' | jq -c '{id, status}'

bold "7. Seller submits the agreed amount"
OK=$(api POST "/sessions/$SID/payment-requests" "$(jq -c '{line_items: .corrected_request.line_items}' "$EXTRA_FILE")")
PR2=$(jq -r .id <<<"$OK")
jq -c '{id, status, amount}' <<<"$OK"
[[ "$(jq -r .status <<<"$OK")" == "approved" ]] || fail "expected approved"

bold "8. Pay (simulated tap → Stripe test PaymentIntent / mock)"
RECEIPT=$(api POST "/payment-requests/$PR2/pay")
jq '{stripe_payment_id, amount, status, merchant, agreement_fingerprint, blocked_total, summary, mock}' <<<"$RECEIPT"
[[ "$(jq -r .agreement_fingerprint <<<"$RECEIPT")" == "$FP" ]] || fail "receipt fingerprint mismatch"

bold "9. Receipt + final state"
FINAL=$(api GET "/sessions/$SID")
jq -c '{session_status: .session.status, payment_requests: [.payment_requests[] | {status, amount}], receipt: .receipt.summary}' <<<"$FINAL"
api GET "/sessions/$SID/dispute-pack" | jq -c '{format, fingerprint_valid: .fingerprint.valid, excerpts: (.transcript_excerpts | length)}'

printf '\n\033[32mDEMO OK: %s\033[0m\n' "$(jq -r .summary <<<"$RECEIPT")"
