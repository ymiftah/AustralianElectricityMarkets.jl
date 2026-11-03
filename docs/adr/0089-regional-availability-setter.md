# 0089. Regional availability setter

## Status

Accepted.

## Context

`RegionalNetworkConfiguration` systems serve economic studies at 30-minute or hourly resolution.
They need every available `RenewableDispatch` and `HydroDispatch` to carry a `"max_active_power"`
series, but `set_nem_dispatch_limits!` is built for NEMDE replay and throws when a unit has no
`DISPATCHLOAD` rows. About 150 non-scheduled units have none, so the strict setter cannot serve the
regional system. NEMDE limits stay strict, so the regional path is a separate setter.

Release v0.1.3 gave regional studies a `max_active_power` from the regional semi-scheduled
`SS_SOLAR_AVAILABILITY` and `SS_WIND_AVAILABILITY` columns of `DISPATCHREGIONSUM`. That source
describes the region as a whole, not one unit, so it cannot give a unit-level limit.

## Decision

`set_regional_availability!(sys, db, date_range; resolution, intervention)` attaches the series.
Each stamp takes the first source that exists:

1. a `RenewableDispatch` with a `read_uigf` row: `UIGF / capacity`;
2. a `read_dispatch_limits` `AVAILABILITY` row: `AVAILABILITY / capacity`;
3. a solar (`PVe`) or wind (`WT` or `WS`) `RenewableDispatch`: the regional `SS_SOLAR_UIGF` or
   `SS_WIND_UIGF` from `DISPATCHREGIONSUM` divided by the summed NATURAL capacity of the region's
   semi-scheduled units of that fuel, clamped to [0, 1]. The denominator counts every such unit in the
   system that has UIGF rows, available or not, so withdrawing a unit does not raise the others' factor;
4. otherwise `1.0`, the registered capacity.

The numerator is the regional UIGF, as AEMO defines it in the MMS Data Model Report for DISPATCHREGIONSUM:
"Regional aggregated Unconstrained Intermittent Generation Forecast of Semi-scheduled generation (MW)
where the primary fuel source is solar/wind". The `SS_SOLAR_AVAILABILITY` and `SS_WIND_AVAILABILITY`
columns were rejected as the numerator. They are aggregate energy availability and include the MAXAVAIL
withdrawal, so a unit that is economically withdrawn at negative prices would drive the fallback to zero.

Values are per-unit of each device's own `max_active_power`, as `set_nem_dispatch_limits!` writes
them, and are clamped to [0, 1]. A device with a capacity of zero or less is 0.0 at every stamp. The
start of `date_range` must lie on the `resolution` grid. A repeat call replaces the series. Thermal,
storage and load devices are not touched.

## Consequences

- Non-scheduled generation is dispatchable in regional studies, although `DISPATCHREGIONSUM.TOTALDEMAND`
  excludes it. Those studies can therefore over-supply relative to `TOTALDEMAND`.
- A unit with no dispatch rows and no regional solar or wind data is treated as fully available. Its
  output is limited only by its registered capacity.
- The regional capacity factor is the same for every unit of a fuel group in a region, so it does not
  separate units within that group.
