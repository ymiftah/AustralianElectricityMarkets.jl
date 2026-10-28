# 0084. Native Sienna recurrent updates and data-owned NEM inputs

## Status

Accepted. Supersedes the `EnergyTieBreak`, CVP-factor and private-helper decisions of
[0066](0066-system-contract-and-formulation-ownership.md).

## Context

Each replay interval re-applies NEM inputs through code that departs from Sienna:

- AEMSim defines PSI-internal update methods for FCAS band prices, MNSP band prices,
  generic-constraint slack costs and Market Price Cap penalties.
- It overrides PSI's time-series reader and the energy-offer slope update to add caching.
- The replay scripts override PSI's `update_model!`, `solve_impl!` and `write_results!` to time
  intervals.

A previous plan moved this code into PSI by adding a parallel framework of parameter sources,
derived sources, objective targets and a timing collector. That framework duplicated mechanisms
PSI already has.

## Decision

Represent every per-interval NEM input as PSY data and let PSI's existing update machinery
apply it. Extend PSI, PSY and IS only where a generic gap blocks this, as small changes that can
go upstream, each with tests that use no NEM data.

Ownership:

- **AEM** owns the PSY system. That includes every per-interval value as a time series and the
  NEM market-rule tables:
  - `EnergyTieBreak` and `set_tie_break_scales!`;
  - `set_fcas_effective_offers!`;
  - the CVP factors and `constraint_cvp_factor`;
  - `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR`.

  Because `EnergyTieBreak` is a serialized PSY type, it lives in the top-level AEM module, so a
  `System` deserializes without AEMSim loaded.
- **AEMSim** holds PSI formulations, the replication template and pre-flight checks. It declares
  parameters through PSI's hooks (`get_default_time_series_names`, `get_multiplier_value`,
  `calc_additional_axes`, `_unwrap_for_param`, `add_parameters!`). It defines no update,
  cache-reader, execution or timing methods on PSI or IS functions.
- The helpers AEMSim needs from AEM are public, except for a short list of private ones that
  AEMSim imports explicitly in its module header.

Dependency changes, each on the fork branch `aem-simulation`:

| Repository | Change |
| --- | --- |
| IS | `ForecastCache` sizes from one window. Cache rows are sized by their deep footprint. The forecast cache budget grows to fit one window. |
| PSY | `get_services_bid` scales against the device. Decremental service bids (`set_decremental_service_bid!`, `get_decremental_services_bid`, series `"<service>_decremental"`) are added. Service bids are looked up by their own series, independent of the energy offer curves. |
| PSI | Time-varying offer-curve costs are read through the model time-series cache. `add_parameters!` takes `meta` and `time_series_name`. `TimeSeriesCostParameter` with `add_cost_target!` drives linear objective coefficients from any named series. Objectives keep their variant contributors unsynchronized across all-zero steps. |

How each family is updated:

- **Energy offers:** PSI's native `MarketBidCost` path.
- **FCAS offers:** stored as PSY service bids in both directions. They are priced with
  `TimeSeriesCostParameter`, because AEMSim's net-axis FCAS variables are not PSI's reserve
  variable.
- **MNSP band prices:** `TimeSeriesCostParameter`.
- **Generic-constraint slack costs:** `TimeSeriesCostParameter` on the existing `"invoked"`
  series, with a build-time scale (multiplier 1.0) of base power times CVP factor times Market Price Cap.
- **Market Price Cap penalties:** build-time constants. The runner splits replay chunks at
  00:05 on 1 July, and a pre-flight check rejects a range that crosses a financial year.
- **Interval timing:** read from PSI's recorders, `OptimizerStats` and `execute!` progress
  events.

## Model behaviour

This is an ownership and mechanism change. Equations, signs, units, CVP factors and cost
contributions are unchanged. No new departure from AEMO.

## Consequences

Code that used names moved to AEM must load `AustralianElectricityMarkets`. The PSY and PSI
forks carry the changes above until they are released upstream.

PSI's time-series cache is disabled for systems that hold time series in memory, so the cached
cost reads benefit HDF5-backed replay workers only.

Known follow-ups:

- PSI's build reads cost-at-min series with scaling factors ignored, while updates read them
  scaled. The two disagree when a series has a non-identity scaling multiplier.
- PSY fails to deserialize a `MarketBidCost` whose `no_load_cost` or `shut_down` is a whole-valued
  float such as `0.0`. AEM writes those zeros, so such systems do not survive a JSON round trip.

Out of scope:

- incremental objective updates;
- event-driven rebinding;
- the first energy-offer breakpoint, which PSI fixes at build.
