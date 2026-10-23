# 0067. NEM offers as named series and read-time views

## Status

Accepted. Builds on [0066](0066-system-contract-and-formulation-ownership.md).

## Context

An AEMO offer is one entity: ten price bands, `MAXAVAIL`, fixed loading and, for FCAS, the
trapezium (`BIDDAYOFFER_D`/`BIDPEROFFER_D`, MMS Data Model). The package spreads each offer across
many per-device `SingleTimeSeries` with names spelled out at every reader and writer, plus `ext`
flags and a `$DUID` generic constraint for fixed loading.

Bundling the offer into a PowerSystems type was rejected:

- An `OperationalCost` subtype cannot replace `MarketBidCost`: PSY types `operation_cost` on
  `ThermalStandard`, `RenewableDispatch`, `HydroDispatch`, `InterruptiblePowerLoad` and
  `EnergyReservoirStorage` as `Union{<own cost>, MarketBidCost}`.
- Series held on a supplemental attribute are skipped by PSI's per-step `TimeSeriesParameter`
  update, which only reads series on the model's devices, so parameters would silently stop
  updating.
- One `PSY.Service` per unit, market and side would mean about a thousand service models.

## Decision

- Offer data stays as device-owned series. `OfferSide` (`GEN`, `LOAD`), `NEM_SERIES`,
  `energy_max_avail_series_name` and `fcas_series_name` name every offer and dispatch-input series
  in one place.
- `is_semi_scheduled`, `has_schedule_classification`, `is_commissioned` and `energy_offer_sides`
  replace raw `ext` reads and type branches.
- `NEMEnergyOffer`/`get_energy_offer` and `NEMFCASOffer`/`get_fcas_offer` are plain read-time views
  over those series. They are not serialized and need no PSI hook.
- One `"uigf"` series serves the energy limit and FCAS trapezium scaling. `read_uigf` takes a
  `DUDETAILSUMMARY` row as in force for `START_DATE <= t < END_DATE`, as `read_energy_limits` and
  `read_units` do, so both setters classify a unit alike on a registration change.
- FCAS offer curves keep all ten bands, so band `k` is AEMO price band `k`, as for energy offers.
- A storage device's energy `MAXAVAIL` that is missing or not finite throws instead of leaving the
  series off.

## Kept on purpose

- `"fcas_agc_ramp_rate_<service>"` stays apart from `"ramp_up_rate"`/`"ramp_down_rate"`. Both come
  from `DISPATCHLOAD.RAMPUPRATE`/`RAMPDOWNRATE`, but the dispatch series pins a non-scheduled load to
  zero, while its FCAS regulation ramp capability (*FCAS Model in NEMDE* §4.2, §6.1) must keep the
  telemetered rate.
- The §5 energy-availability pre-condition keeps reading `DISPATCHLOAD.AVAILABILITY` for
  non-storage units. It already is the offer `MAXAVAIL`, capped at `UIGF` for a semi-scheduled unit,
  which is what §5 requires (`min[MaxAvail, UIGF] >= EnablementMin`).
- FCAS trapeziums are validated on every read as well as in `set_fcas_bids!`, because series can be
  attached outside the setter.

## Model behaviour

The FCAS band index and the storage `MAXAVAIL` check change inputs only for offers with empty bands
and for incomplete cached data. Moving UIGF classification to an exclusive `END_DATE` changes the
UIGF of a unit only on the interval its `DUDETAILSUMMARY` row ends. No new departure from AEMO.
