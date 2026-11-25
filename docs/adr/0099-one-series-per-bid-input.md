# 0099 One series per bid input

## Status

Accepted. Input ownership is in [0101](0101-aem-writes-aemsim-reads.md); the AGC ramp series is in [0087](0087-agc-ramp-rate-from-mmsdm.md).

## What

- AEM writes AEMO's bid data once, as the bid series `bid_<service>_<field>_<direction>` (`bid_series_name`), and the bid structs (`NEMEnergyBid`, `NEMFCASBid`) hold their keys. Readers and PSI parameters use those keys; no derived series copies a bid input unchanged.
- Conversion happens at read: the FCAS trapezium is combined with the bid's `MAXAVAIL` when read, and `MAXAVAIL` is divided by the system base on read, with a `1/base` multiplier on the stock PSI parameters.
- The energy offer curves stay derived (`energy_offer[_decremental]`), because the loss-factor referral rounds prices to cents and PSI's stock band-parameter path reads a series without the device. This is the one remaining copy of a bid input.
- Series that carry derived values rather than bid copies stay: the effective FCAS offers and regulation ramping limits (`fcas_effective_*`, `fcas_ramping_limits_*`) and the separate `fcas_agc_ramp_rate_<service>` series.

## How

- `set_market_bids!` writes a zero `MAXAVAIL` series under the `LOAD` energy bid name for each available non-scheduled load without an energy bid, so every energy availability read has a key. That series is not AEMO data.
- The energy limit parameter reads the bid's `MAXAVAIL` series through `_availability_series_name`, the unit multiplier `1 / system base` being `PSI.get_multiplier_value` for `EnergyLimitTimeSeriesParameter`. No `fcas_offer_*`, `fcas_trapezium_*` or `energy_availability` series exist.

## Why

- A copy needs a second writer to follow any change to the bid, and the duplicated series made up about 15% of a 288-interval NEMDE system's static time series (25,042 to 21,302 after the change).
- Results differ from the copied form only by floating-point rounding from the division at read.
