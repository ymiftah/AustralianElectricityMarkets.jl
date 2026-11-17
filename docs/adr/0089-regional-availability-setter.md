# 0089 Regional availability setter

## Status

Accepted.

## What

- `set_regional_availability!(sys, db, date_range; resolution, intervention)` attaches a `max_active_power` series (per-unit of the device's own limit, clamped to [0, 1]) to every available `RenewableGen` and `HydroGen` of a `RegionalNetworkConfiguration` system. Thermal, storage and load devices are untouched. A repeat call replaces the series. A device with capacity of zero or less is 0.0 throughout.
- `set_nem_dispatch_limits!` stays strict for NEMDE run (it throws on a unit with no `DISPATCHLOAD` rows); about 150 non-scheduled units have none, so the regional path is a separate setter.
- Each stamp takes the first source that exists:
  1. a `RenewableGen` with a `read_uigf` row: `UIGF / capacity`;
  2. a `read_dispatch_limits` `AVAILABILITY` row: `AVAILABILITY / capacity`;
  3. a solar (`PVe`) or wind (`WT`, `WS`) `RenewableGen`: regional `SS_SOLAR_UIGF` or `SS_WIND_UIGF` from `DISPATCHREGIONSUM` over the summed NATURAL capacity of the region's semi-scheduled units of that fuel;
  4. otherwise `1.0`.
- The start of `date_range` must lie on the `resolution` grid.

## Why

- The numerator is the regional Unconstrained Intermittent Generation Forecast (MMS Data Model Report, DISPATCHREGIONSUM). The `SS_*_AVAILABILITY` columns were rejected: they include the MAXAVAIL withdrawal, so a unit withdrawn at negative prices would drive the fallback to zero.
- The denominator counts every semi-scheduled unit of that fuel with UIGF rows, available or not, so withdrawing a unit does not raise the others' factor.

## Consequences

- Non-scheduled generation is dispatchable in regional studies although `DISPATCHREGIONSUM.TOTALDEMAND` excludes it, so studies can over-supply relative to `TOTALDEMAND`.
- A unit with no dispatch rows and no regional data is fully available.
- The regional factor is the same for every unit of a fuel group in a region.
