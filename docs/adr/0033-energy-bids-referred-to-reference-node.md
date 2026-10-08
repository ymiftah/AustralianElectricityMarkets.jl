# 0033. Energy bids are referred to the regional reference node

## Status

Accepted

## Context

Bid prices in `BIDDAYOFFER_D` apply at the unit's connection point (market floor bids appear as
-1000 x loss factor, for example -984.5 at 0.9845). NEMDE compares units at the regional reference
node, so each energy price is divided by the unit's loss factor before it enters the merit order
(AEMO, Treatment of Loss Factors, section 12: bid prices "are then divided by the MLF (and DLF if
required) so that they can be referred to the RRN"). nempy does the same in
`objective_function.scale_by_loss_factors`, dividing only `service == 'energy'` costs. The replica
used raw prices, so units with a loss factor below 1 cleared too early and set prices at their raw
band, which the diagnosis of the June 2026 run attributed to about 100 of 216 unit gaps and 25 of
35 wrong region prices.

## Decision

- **One place.** `set_market_bids!` divides the y-axis (price) of every energy `PiecewiseStepData`
  by the unit's loss factor, before the curves become `MarketBidCost` series. The MW axis is
  unchanged. `read_loss_factors(db; as_of)` supplies the factors from `DUDETAILSUMMARY`
  (`TRANSMISSIONLOSSFACTOR x DISTRIBUTIONLOSSFACTOR`), resolved as of `first(date_range)` with the
  same window as `read_units`.
- **Both sides of a battery.** The MMS Data Model defines `SECONDARY_TLF` as "the TLF for the
  generation component of a BDU, when null the TRANSMISSIONLOSSFACTOR is used for both the load and
  generation components", and `TRANSMISSIONLOSSFACTOR` as the load-component TLF where `DISPATCHTYPE`
  is `BIDIRECTIONAL`. nempy (`units.py`, lines 568-573) applies `SECONDARY_TLF x DLF` only to the
  generator direction of a `BIDIRECTIONAL` unit with a non-null secondary factor, and
  `TRANSMISSIONLOSSFACTOR x DLF` otherwise. `read_loss_factors` does the same: `GEN_LOSS_FACTOR`
  uses `SECONDARY_TLF` only when `DISPATCHTYPE = 'BIDIRECTIONAL'`, so a stray secondary factor on a
  generator is ignored. The June 2026 cache agrees: every bidirectional unit bids its market floor
  as -1000 times the factor on each side (KESSB1 GEN -1003.0 = -1000 x 1.003, LOAD -970.4 = -1000 x
  0.9704; GANNB1 GEN -1001.1 = -1000 x 1.0227 x 0.9789). Scheduled loads divide their load-side
  prices by `LOAD_LOSS_FACTOR` (merged in PR #168).
- **Not scaled.** FCAS prices (nempy scales only energy), scheduled capacity bounds (`MAXAVAIL`,
  `MINIMUMLOAD`) and `DAILYENERGYCONSTRAINT`.
- **No defensive paths.** The June 2026 cache has no null or non-positive loss factor in force,
  no `SECONDARY_TLF` on a non-bidirectional unit, and a row for every one of the 503 bidding units,
  so `read_loss_factors` does not replace or tolerate any of those. A bidding unit of the `System`
  without a row in force throws an `ArgumentError`. A cache without the columns fails in DuckDB:
  re-populate `DUDETAILSUMMARY` with `force_new = true` after upgrading. One factor per unit is used for the
  whole `date_range`, resolved as of `first(date_range)`, and a warning fires when a `START_DATE`
  falls in `(first, last]`. That timestamp is an interval end, so the interval ending at 00:00 on
  1 July selects the new financial year's factors, as `read_units` does. None of the cited AEMO
  documents says which side of that boundary NEMDE uses, so this stays unverified.
- **Open rows** (`as_of = nothing`) keep the earliest `START_DATE`, the row `read_units` keeps, so
  both readers agree.
- **Optional.** `loss_factors = false` keeps raw connection-point prices. The default is on,
  since raw prices misorder units in every region, replication or not.

## Balance

Only the price is referred. nempy divides the bid cost and leaves the MW untouched, and the AEMO
worked example (Treatment of Loss Factors, sections 12 and 13) dispatches the connection-point MW
blocks against load plus regional losses; the loss factor reaches settlement only as the price
multiplier `RRP x MLF`. The regional balance therefore keeps connection-point MW.

## Consequences

- The objective cost of a bid band changes by `1 / factor`; dispatch ordering follows the
  reference-node price. The pricing of marginal units is unchanged as a shadow price: the RRP is
  still at the reference node.
- Unit bids with equal reference-node prices remain tied; tie-breaking is a separate gap.
- Referred prices are rounded to cents because NEMDE's case files carry rounded prices; for example 356 floor bands on 2026-06-03 round to -1000.00 and tie exactly.
