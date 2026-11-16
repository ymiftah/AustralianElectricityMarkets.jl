# 0033 Energy bids are referred to the regional reference node

## Status

Accepted

## What

- Every energy offer price is divided by the unit's loss factor, so the merit order is at the regional reference node. Only the price is referred; the MW axis and the regional balance stay at the connection point.

## How

- `set_market_bids!` divides the y-axis of each energy `PiecewiseStepData` by the unit's factor (`_referred_curves_on_grid`), rounded to cents because NEMDE's case files carry rounded prices (floor bands at -1000 x factor then tie exactly).
- `read_loss_factors(db; as_of, through)` reads `DUDETAILSUMMARY`: `LOAD_LOSS_FACTOR = TRANSMISSIONLOSSFACTOR x DISTRIBUTIONLOSSFACTOR`; `GEN_LOSS_FACTOR` uses `SECONDARY_TLF x DISTRIBUTIONLOSSFACTOR` only for a `BIDIRECTIONAL` unit with a non-null secondary factor, else the load factor.
- Generators and a battery's generation side use `GEN_LOSS_FACTOR`; scheduled loads and a battery's charge side use `LOAD_LOSS_FACTOR`.
- One factor per unit covers the whole `date_range` (earliest row registered in the window), with a warning when the factors change inside it. The interval ending at 00:00 on 1 July takes the new financial year's factors; no AEMO document says which side NEMDE uses, so this is unverified.
- A bidding unit with no row throws `ArgumentError`; there is no fallback. Re-populate `DUDETAILSUMMARY` with `force_new = true` if the columns are missing.
- Not scaled: FCAS prices, `MAXAVAIL`, `MINIMUMLOAD`, `DAILYENERGYCONSTRAINT`.

## Why

- AEMO, Treatment of Loss Factors, section 12: bid prices "are then divided by the MLF (and DLF if required) so that they can be referred to the RRN". Sections 12 and 13 dispatch connection-point MW against load plus losses; the factor reaches settlement only as `RRP x MLF`.
- nempy does the same (`objective_function.scale_by_loss_factors`, energy only; `units.py` for the bidirectional secondary factor).
- Unreferred prices misorder units in every region (about 100 of 216 unit gaps and 25 of 35 wrong prices in the June 2026 diagnosis).
- The MMS Data Model defines `SECONDARY_TLF` as the generation-component TLF of a BDU, with `TRANSMISSIONLOSSFACTOR` the load component.
- Units with equal referred prices stay tied; see [0036](0036-energy-tie-break.md).
