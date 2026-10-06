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
- **Both sides of a battery.** For a bidirectional unit that publishes `SECONDARY_TLF`, discharge
  (`GEN`) bids use `SECONDARY_TLF x DLF` and charge (`LOAD`) bids use `TRANSMISSIONLOSSFACTOR x
  DLF`. This was read off the data, not the documentation: every bidirectional unit in the June
  2026 cache bids its market floor as -1000 times that factor on each side (KESSB1 GEN -1003.0 =
  -1000 x 1.003, LOAD -970.4 = -1000 x 0.9704; GANNB1 GEN -1001.1 = -1000 x 1.0227 x 0.9789), so
  that is the factor that refers the floor back to -1000 at the reference node. Units without a
  secondary factor use `TRANSMISSIONLOSSFACTOR x DLF` on both sides. Scheduled loads use
  `LOAD_LOSS_FACTOR` and divide their load-side prices the same way.
- **Not scaled.** FCAS prices (nempy scales only energy), scheduled capacity bounds (`MAXAVAIL`,
  `MINIMUMLOAD`) and `DAILYENERGYCONSTRAINT`.
- **Missing or non-positive factors** default to 1.0 with a warning naming the units; a cache
  without the columns leaves prices raw with a warning. A single factor is used for the whole
  `date_range`, so builds spanning 1 July (when loss factors change) use the start-of-range value.
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
