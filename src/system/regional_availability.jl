"""
    set_regional_availability!(sys, db, date_range; resolution::Dates.Period = Minute(30), intervention::Integer = 0)

Attaches a `"max_active_power"` series to every available `RenewableGen` and `HydroGen` in
`sys`, for the economic studies of a [`RegionalNetworkConfiguration`](@ref). Unlike
`set_unit_conditions!`, a unit with no `DISPATCHLOAD` rows is not an error: each stamp takes the
first of these values that exists:

1. a `RenewableGen` with a [`read_uigf`](@ref) row: `UIGF / capacity`;
2. a [`read_dispatch_limits`](@ref) `AVAILABILITY` row: `AVAILABILITY / capacity`;
3. a solar (`PVe`) or wind (`WT` or `WS`) `RenewableGen`: the regional semi-scheduled UIGF of its
   area, the `DISPATCHREGIONSUM` `SS_SOLAR_UIGF` or `SS_WIND_UIGF`, over the summed NATURAL capacity of
   the region's semi-scheduled units of that fuel, clamped to [0, 1]. The denominator counts every such
   unit in `sys` that has UIGF rows, available or not;
4. otherwise `1.0`, the registered capacity.

Every value is clamped to [0, 1]. A device with a capacity of zero or less is 0.0 at every stamp. The
series is per-unit of each device's own `max_active_power`. A repeat call replaces the series. Thermal, storage and load devices are not touched.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the intervals to build. Only its first and last values are used, as the half-open
  `first(date_range) <= t < last(date_range)`. The first value must be a multiple of `resolution` on
  the epoch grid, or an `ArgumentError` is thrown.
- `resolution`: the spacing of the stamps. Defaults to 30 minutes.
- `intervention`: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
`nothing`.

# Example
```julia
db = aem_connect()
sys = nem_system(db, RegionalNetworkConfiguration(); date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2))
set_regional_availability!(sys, db, Date(2025, 1, 2):Date(2025, 1, 3))
```
"""
function set_regional_availability!(
        sys, db, date_range; resolution::Dates.Period = Minute(30), intervention::Integer = 0,
    )
    start = DateTime(first(date_range))
    floor(start, resolution) == start || throw(
        ArgumentError("the start $start is not a multiple of the resolution $resolution on the epoch grid"),
    )
    stamps = collect(start:resolution:(DateTime(last(date_range)) - resolution))
    # The readers use only the first and last values, so the bounds pass as a pair.
    bounds = (start, DateTime(last(date_range)))
    uigf = read_uigf(db, bounds; resolution, intervention)
    limits = read_dispatch_limits(db, bounds; intervention, resolution)
    regional = select(
        read_demand(db, bounds; resolution, intervention),
        :SETTLEMENTDATE, :REGIONID => :region, :SS_SOLAR_UIGF => :solar, :SS_WIND_UIGF => :wind,
    )

    fuels = Dict(PrimeMovers.PVe => "solar", PrimeMovers.WT => "wind", PrimeMovers.WS => "wind")
    devices = DataFrame(
        [
            (;
                device,
                name = get_name(device),
                available = get_available(device),
                renewable = device isa RenewableGen,
                fuel = device isa RenewableGen ? get(fuels, get_prime_mover_type(device), missing) : missing,
                region = device isa RenewableGen ? get_name(get_area(get_bus(device))) : missing,
                capacity = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS"),
            ) for device in Iterators.flatten((get_components(RenewableGen, sys), get_components(HydroGen, sys)))
        ]
    )
    # Summed NATURAL capacity of the semi-scheduled units per region and fuel, over all units in sys.
    denominators = @chain devices begin
        subset(:name => ByRow(in(Set(uigf.DUID))), :fuel => ByRow(!ismissing))
        groupby([:region, :fuel])
        combine(:capacity => sum => :denominator)
    end
    regional_uigf = stack(regional, [:solar, :wind]; variable_name = :fuel, value_name = :regional_uigf)

    series = @chain devices begin
        subset(:available)
        crossjoin(DataFrame(SETTLEMENTDATE = stamps))
        leftjoin(select(uigf, :DUID => :name, :SETTLEMENTDATE, :UIGF), on = [:name, :SETTLEMENTDATE])
        leftjoin(select(limits, :DUID => :name, :SETTLEMENTDATE, :AVAILABILITY), on = [:name, :SETTLEMENTDATE])
        leftjoin(regional_uigf, on = [:region, :fuel, :SETTLEMENTDATE], matchmissing = :notequal)
        leftjoin(denominators, on = [:region, :fuel], matchmissing = :notequal)
        sort([:name, :SETTLEMENTDATE])
        transform(
            [:renewable, :capacity, :UIGF, :AVAILABILITY, :regional_uigf, :denominator] => ByRow(
                (renewable, capacity, uigf, availability, regional, denominator) -> begin
                    capacity > 0 || return 0.0
                    # A region without a positive denominator has no capacity to scale by: full availability.
                    regional_factor = ismissing(regional) ? missing :
                        coalesce(denominator, 0.0) > 0 ? regional / denominator : 1.0
                    per_unit = coalesce(
                        renewable ? uigf / capacity : missing,
                        availability / capacity,
                        renewable ? regional_factor : missing,
                        1.0,
                    )
                    return clamp(per_unit, 0.0, 1.0)
                end
            ) => :per_unit,
        )
    end
    for group in groupby(series, :name)
        device = first(group.device)
        replace_single_series!(
            sys, device,
            single_series(
                NEM_SERIES.max_active_power, group.SETTLEMENTDATE, group.per_unit;
                scaling_factor_multiplier = get_max_active_power,
            ),
        )
    end
    return
end
