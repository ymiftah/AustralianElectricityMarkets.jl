# TODO again here, some operations would be better read as DataFrames.jl operations, with final conversion to
# our types and insertion to sys


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
- `intervention`: `0` for the pricing run, `1` for the physical run.

# Returns
`nothing`.

# Example
```julia
db = aem_connect()
sys = nem_system(db, RegionalNetworkConfiguration())
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
    regional = Readers._read_regional_renewable_uigf(db, bounds; resolution, intervention)
    # TODO those are just group bys
    uigf_at = Dict((r.DUID, r.SETTLEMENTDATE) => r.UIGF for r in eachrow(uigf))
    avail_at = Dict(
        (r.DUID, r.SETTLEMENTDATE) => r.AVAILABILITY for r in eachrow(limits) if !ismissing(r.AVAILABILITY)
    )
    regional_at = Dict((r.REGIONID, r.SETTLEMENTDATE) => r for r in eachrow(regional))

    renewables = collect(get_available_components(RenewableGen, sys))
    hydros = collect(get_available_components(HydroGen, sys))
    uigf_duids = Set(uigf.DUID)
    # Summed NATURAL capacity of the semi-scheduled units per region and fuel, over all units in sys.
    denominators = Dict{Tuple{String, Symbol}, Float64}()
    for device in get_components(RenewableGen, sys)
        get_name(device) in uigf_duids || continue
        fuel = _renewable_fuel(device)
        isnothing(fuel) && continue
        key = (get_name(get_area(get_bus(device))), fuel)
        capacity = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        denominators[key] = get(denominators, key, 0.0) + capacity
    end

    for device in vcat(renewables, hydros)
        capacity = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        values = if capacity > 0
            [
                _availability_at(device, t, capacity, uigf_at, avail_at, regional_at, denominators)
                    for t in stamps
            ]
        else
            zeros(length(stamps))
        end
        replace_single_series!(
            sys, device,
            single_series(NEM_SERIES.max_active_power, stamps, values; scaling_factor_multiplier = get_max_active_power),
        )
    end
    return
end


"""
    _renewable_fuel(device) -> Union{Symbol, Nothing}

The regional fuel group of a `RenewableGen`: `:solar` for `PVe`, `:wind` for `WT` and `WS`, and
`nothing` for any other prime mover.
"""
function _renewable_fuel(device)
    pm = get_prime_mover_type(device)
    pm == PrimeMovers.PVe && return :solar
    pm in (PrimeMovers.WT, PrimeMovers.WS) && return :wind
    return nothing
end


"""
    _availability_at(device, t, capacity, uigf_at, avail_at, regional_at, denominators) -> Float64

The per-unit availability of `device` at stamp `t`, clamped to [0, 1], by the priority of
[`set_regional_availability!`](@ref), where `capacity` is the device's `max_active_power` in MW.
"""
function _availability_at(device, t, capacity, uigf_at, avail_at, regional_at, denominators)
    duid = get_name(device)
    if device isa RenewableGen && haskey(uigf_at, (duid, t))
        return clamp(uigf_at[(duid, t)] / capacity, 0.0, 1.0)
    elseif haskey(avail_at, (duid, t))
        return clamp(avail_at[(duid, t)] / capacity, 0.0, 1.0)
    end
    factor = device isa RenewableGen ? _regional_capacity_factor(device, t, regional_at, denominators) : nothing
    return something(factor, 1.0)
end


"""
    _regional_capacity_factor(device, t, regional_at, denominators) -> Union{Float64, Nothing}

The regional capacity factor of a solar or wind `device` at stamp `t`, clamped to [0, 1], or `nothing`
when the device is neither, or its region has no regional UIGF at `t`.
"""
function _regional_capacity_factor(device, t, regional_at, denominators)
    fuel = _renewable_fuel(device)
    isnothing(fuel) && return nothing
    column = fuel == :solar ? :SS_SOLAR_UIGF : :SS_WIND_UIGF
    region = get_name(get_area(get_bus(device)))
    row = get(regional_at, (region, t), nothing)
    (isnothing(row) || ismissing(row[column])) && return nothing
    denominator = get(denominators, (region, fuel), 0.0)
    denominator > 0 || return 1.0
    return clamp(row[column] / denominator, 0.0, 1.0)
end
