# DEAL content

Demo data for DEAL. The backend's `MOCK_MODE` reads it in place of Claude. **All pricing is illustrative**, and the conversations are role-play. **All money is integer cents** (`3460000` = $34,600.00).

## Files

| File | What it is |
|---|---|
| `scripts/car_accord.json` | Flagship demo (Section 7): 2023 Honda Accord EX. The asking price is $38,000, the target $34,500 and the max $36,000. The deal lands at $34,600 with the doc fee waived and floor mats included. 25 lines. |
| `scripts/pawn_guitar.json` | Pawn shop sale of a used Fender Player Stratocaster. The asking price is $650, the target $500 and the max $575. The deal lands at $525 with a gig bag, a tremolo arm and a 7-day return. 13 lines. |
| `scripts/seller_extra_fee.json` | The car demo's payment requests after agreement: `blocked_request` adds a $1,200 protection package, and `corrected_request` matches the agreement exactly. |
| `comparables/{car,pawn_shop,marketplace,electronics,other}.json` | 3–4 illustrative comparable listings for each category. |
| `tactics.json` | 10 sales tactics, each with detection hints and a cue template. |

## Script format

```json
{
  "id": "car_accord", "category": "car", "item": "2023 Honda Accord EX",
  "asking_price": 3800000, "target_price": 3450000, "max_budget": 3600000,
  "style": "firm", "illustrative": true,
  "lines": [{
    "id": "evt_01", "speaker": "buyer|seller", "text": "...", "delay_ms": 1500,
    "expected": {
      "current_offer": 3800000, "offer_by": "seller",
      "new_terms": [{ "type": "price|fee|item|tradein|promise", "label": "vehicle price", "amount": 3800000 }],
      "tactic_detected": "fees_not_disclosed",
      "cue": "Ask for the all-in total",
      "cue_detail": null,
      "status": "green|yellow|red"
    }
  }],
  "expected_agreement": { "price", "items", "fees", "total", "source_event_ids", "open_questions" }
}
```

`expected` uses the Section 6 Live cue shape. `expected_agreement` uses the Section 6 Agreement shape.

## Conventions the backend must know

- **`current_offer` carries forward.** It is the standing offer *after* this line, and `offer_by` says who made it. A line with no new number repeats the previous value. It is `null` only before anyone has named a price.
- **`tactic_detected`** is `null` or an `id` from `tactics.json`.
- **`cue`** is 3–6 words.
- **`cue_detail` is an extra field, not in Section 6, and it is optional.** It holds a second glasses line, or `null`. The demo's math line is carried here: `evt_12` → `"$489/mo × 72 = $35,208"`. It is fine to drop it, or to make it optional in zod.
- **`new_terms[].amount` is always an integer.** Included items and promises use `0`. A waived fee shows up again as a `fee` term with `amount: 0`. Terms with the same `type`+`label` replace the earlier one, so the last value wins.
- **`delay_ms`** is the wait before this line plays, measured from the previous line. `/script/play`'s `interval_ms` can override it.
- **Status:** green means on track (the offer is at or below target, or the buyer made a strong move). Yellow means a tactic is in play or the offer sits between target and max. Red means the offer is above max, a pressure tactic was used, or a charge was blocked.
- **Agreement:** `items[0]` is always the session `item`, and `price` belongs to it. The other items are included at no charge. `total = price + sum(fees[].amount)`. Each entry in `source_event_ids` is a line `id`.

## Payment request label convention (mismatch rule 3)

A line item `label` must equal one of the agreement's `items[]` strings or `fees[].label`. The match is **exact, case-insensitive and trimmed**.

- Charge the primary item using its exact name, `items[0]`, for `agreement.price`. For example: `{"label": "2023 Honda Accord EX", "amount": 3460000}`.
- Other included items and fees can be listed. Items take `amount: 0`, and a fee's amount must equal its agreement amount (the waived doc fee is `0`).
- A line item whose label is not in the agreement is blocked. In the demo that is `"protection package"`, 120000. The line items must also add up to `agreement.total`.

For the car demo, `blocked_request` sums to 3580000 and `corrected_request` sums to 3460000. `blocked_request.contradicting_event_id` is `evt_24`, the seller's line "No other fees, no add-ons". Use it for the mismatch explanation.

## Comparables format

```json
{ "category": "car", "illustrative": true, "reference_item": "...", "listings": [
  { "id": "car_comp_01", "title": "...", "price": 3460000, "source": "...", "condition": "...", "note": "..." } ] }
```

In `car.json`, `car_comp_01` costs $34,600. That is $340 below the seller's $34,940 offer at `evt_18`, which triggers the "Mention the $340 comparable" cue. The category keys match the session `category` values: `car`, `pawn_shop`, `marketplace`, `electronics`, `other`.

## Tactics format

`{ id, name, detection_hints[], cue_template, cue_detail_template, status }`. Templates use `{placeholder}` slots, for example `${monthly}/mo × {months} = ${total}`.
