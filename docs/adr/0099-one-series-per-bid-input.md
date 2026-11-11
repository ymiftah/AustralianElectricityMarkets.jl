# 0099. One series per bid input

## Status

Accepted.

## Context

A replay system held the same bid inputs more than once. `set_market_bids!` writes AEMO's bid data
as the bid series (`bid_<service>_<field>_<direction>`), and `set_effective_offers!` then copied
those values into derived series with their own names and writers:

- `fcas_offer_<service>[_decremental]`, the FCAS offer curves of the bid's `offer_curves`;
- `fcas_trapezium_<service>[_decremental]`, the FCAS trapezium of the bid, scaled to per-unit;
- `energy_availability[_decremental]`, the energy `MAXAVAIL` of the bid, scaled to per-unit.

The energy offer curves were copied the same way (`energy_offer[_decremental]`). Each copy held the
bid's values up to scaling, so a change to the bid needed a second writer to reach the copy. The
replay system held 25,042 static time series after `prepare_replay!` for a 288-interval build.

## Decision

- The bid series are the inputs. The FCAS offer curves and trapeziums and the energy availability
  are read from the keys of the device's bid (`NEMFCASBid`, `NEMEnergyBid`). `NEMDispatchInputs`
  holds the same keys, so the readers and the dispatch inputs agree on one name per input.
- Conversion happens at read. The FCAS trapezium is combined with the bid's `MAXAVAIL` when it is
  read (`_fcas_trapezium_window`), and the energy availability is divided by the system base when it
  is read, with a `1/base` multiplier on the stock PowerSimulations parameters.
- A non-scheduled load with no energy bid and available has a zero `MAXAVAIL` series, written by
  `set_market_bids!` in AEM, under the name of the `LOAD` energy bid. Every energy availability read
  therefore has a key.
- The energy offer curves stay derived. The loss-factor referral rounds prices to cents, and
  PowerSimulations' stock band-parameter path reads a series without the device, so the referral
  cannot be applied at read. The derived `energy_offer[_decremental]` series are the one remaining
  copy of a bid input.
- Removed: the `fcas_offer_*`, `fcas_trapezium_*` and `energy_availability[_decremental]` series
  and the names that built them (`fcas_offer_series_name`, `energy_availability_series_name`), and
  the `trapezium_name` keyword of `get_scaled_fcas_trapezium`. Added: the `max_avail` field of
  `NEMFCASInputs`, the key of the bid's `MAXAVAIL` series.

## Consequences

- The replay system holds 21,302 static time series after `prepare_replay!` for a 288-interval build,
  down from 25,042. Build time does not change measurably (see Verification).
- Results differ only by floating-point rounding, from the division at read and the multiplier on the
  stock parameters. On the 24-interval replay of 2026-06-04 the maximum difference is 4.3e-14 for
  prices and 3.1e-15 for FCAS prices, and zero for dispatch and interconnectors.
- The derived energy offer series remain: about 500 series, one per energy bid side, that repeat the
  bid. Removing them needs a PowerSimulations hook that applies the referral at read.
- AEM writes one zero `MAXAVAIL` series for each available non-scheduled load without an energy bid.
  That series is not AEMO data.
- Standing rule, stated 2026-11-11: AEMSim never writes data to the System; only AEM adds series. This
  is not yet met. `prepare_replay!` still writes derived series: the energy offers, the state seeds,
  the effective ramp and FCAS limits, the AGC ramp rates, the MNSP fixed loads, the loss demand, the
  tie-break scales and the `NEMDispatchInputs` attributes. Moving them to AEM is follow-up work,
  recorded here and not done in this change.

## Verification

Recorded on 2026-11-11 at HEAD `1c57b73` plus the change in this commit.

- Series count and build time: a warm build of 288 intervals from 2026-06-04 04:05, after a
  10-interval warm-up in the same process, with `nem_system` and `prepare_replay!` each timed twice.

  | Measure | Before (`3842103`) | After |
  | --- | --- | --- |
  | `static_time_series_count` after `prepare_replay!` | 25,042 | 21,302 |
  | `prepare_replay!`, warm (two trials) | 5.37 s, 5.55 s | 5.32 s, 5.36 s |
  | `nem_system`, warm (two trials) | 13.30 s, 11.32 s | 13.36 s, 11.37 s |

- Results: the per-change gates recorded in the plan's ledger (FCAS offers and trapeziums bit-identical;
  energy availability within the rounding above).
- Test suites, root and AEMSim in one process: the root suite completed with no failures. The AEMSim
  suite ran 3,924 tests with 1 failure, the known tie-break artefact of `stock_simulation`
  ("tie-break service model follows the template"), and no errors.
