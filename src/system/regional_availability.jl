"""
    set_regional_availability!(sys, db, date_range; resolution::Dates.Period = Minute(30), intervention::Integer = 0)

Attaches a `"max_active_power"` series to every available `RenewableDispatch` and `HydroDispatch` in
`sys`, for the economic studies of a [`RegionalNetworkConfiguration`](@ref). Unlike
`set_nem_dispatch_limits!`, a unit with no `DISPATCHLOAD` rows is not an error: each stamp takes the
first of these values that exists:

1. a `RenewableDispatch` with a [`read_uigf`](@ref) row: `UIGF / capacity`;
2. a [`read_dispatch_limits`](@ref) `AVAILABILITY` row: `AVAILABILITY / capacity`;
3. a solar (`PVe`) or wind (`WT`) `RenewableDispatch`: the regional capacity factor of its area, the
   `DISPATCHREGIONSUM` `SS_SOLAR_AVAILABILITY` or `SS_WIND_AVAILABILITY` divided by the summed
   capacity of the region's semi-scheduled units of that prime mover, clamped to [0, 1];
4. otherwise `1.0`, the registered capacity.

Values are clamped to be non-negative. The series is per-unit of each device's own
`max_active_power`, as `set_nem_dispatch_limits!` writes it. A repeat call replaces the series.
Thermal, storage and load devices are not touched.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the intervals to build. Only its first and last values are used, as the half-open
  `first(date_range) <= t < last(date_range)`.
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
    stamps = collect(DateTime(first(date_range)):resolution:(DateTime(last(date_range)) - resolution))
    # The readers use only the first and last values, so the bounds pass as a pair.
    bounds = (DateTime(first(date_range)), DateTime(last(date_range)))
    uigf = read_uigf(db, bounds; resolution, intervention)
    limits = read_dispatch_limits(db, bounds; intervention, resolution)
    regional = Readers._read_regional_renewable_availability(db, bounds; resolution, intervention)

    uigf_at = Dict((r.DUID, r.SETTLEMENTDATE) => r.UIGF for r in eachrow(uigf))
    avail_at = Dict(
        (r.DUID, r.SETTLEMENTDATE) => r.AVAILABILITY for r in eachrow(limits) if !ismissing(r.AVAILABILITY)
    )
    regional_at = Dict((r.REGIONID, r.SETTLEMENTDATE) => r for r in eachrow(regional))

    renewables = collect(get_available_components(RenewableDispatch, sys))
    hydros = collect(get_available_components(HydroDispatch, sys))
    uigf_duids = Set(uigf.DUID)
    # Summed capacity of the semi-scheduled units per region and prime mover.
    denominators = Dict{Tuple{String, typeof(PrimeMovers.PVe)}, Float64}()
    for device in renewables
        get_name(device) in uigf_duids || continue
        key = (get_name(get_area(get_bus(device))), get_prime_mover_type(device))
        capacity = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        denominators[key] = get(denominators, key, 0.0) + capacity
    end

    for device in vcat(renewables, hydros)
        capacity = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        values = [
            max(0.0, _availability_at(device, t, capacity, uigf_at, avail_at, regional_at, denominators))
                for t in stamps
        ]
        replace_single_series!(
            sys, device,
            single_series(NEM_SERIES.max_active_power, stamps, values; scaling_factor_multiplier = get_max_active_power),
        )
    end
    return
end


"""
    _availability_at(device, t, capacity, uigf_at, avail_at, regional_at, denominators) -> Float64

The per-unit availability of `device` at stamp `t`, by the priority of
[`set_regional_availability!`](@ref), where `capacity` is the device's `max_active_power` in MW.
"""
function _availability_at(device, t, capacity, uigf_at, avail_at, regional_at, denominators)
    duid = get_name(device)
    if device isa RenewableDispatch && haskey(uigf_at, (duid, t))
        return uigf_at[(duid, t)] / capacity
    elseif haskey(avail_at, (duid, t))
        return avail_at[(duid, t)] / capacity
    end
    factor = device isa RenewableDispatch ? _regional_capacity_factor(device, t, regional_at, denominators) : nothing
    return something(factor, 1.0)
end


"""
    _regional_capacity_factor(device, t, regional_at, denominators) -> Union{Float64, Nothing}

The regional capacity factor of a solar or wind `device` at stamp `t`, or `nothing` when the device is
neither, or its region has no regional availability at `t`.
"""
function _regional_capacity_factor(device, t, regional_at, denominators)
    pm = get_prime_mover_type(device)
    column = if pm == PrimeMovers.PVe
        :SS_SOLAR_AVAILABILITY
    elseif pm == PrimeMovers.WT
        :SS_WIND_AVAILABILITY
    else
        return nothing
    end
    region = get_name(get_area(get_bus(device)))
    row = get(regional_at, (region, t), nothing)
    (isnothing(row) || ismissing(row[column])) && return nothing
    denominator = get(denominators, (region, pm), 0.0)
    denominator > 0 || return 1.0
    return clamp(row[column] / denominator, 0.0, 1.0)
end
