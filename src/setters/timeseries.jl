"""
    set_demand!(sys, db, date_range; kwargs...)

Adds load time series data to the system from the database.

This function reads demand data for a specified date range, processes it into a time series,
and attaches it to the `PowerLoad` components in the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch demand data.
- `kwargs`: Additional keyword arguments passed to `read_demand`.
"""
function set_demand!(sys, db, date_range; kwargs...)
    demand = read_demand(db; kwargs...)
    ts = @chain demand begin
        transform!(:REGIONID => ByRow(x -> x * " Load") => :name)
        subset!(:SETTLEMENTDATE => ByRow(x -> first(date_range) <= x < last(date_range)))
        _as_timearray(:SETTLEMENTDATE, :name, :TOTALDEMAND)
    end
    return _add_demand_ts_to_components!(sys, ts, PowerLoad)
end

"""
    set_renewable_pv!(sys, db, date_range; kwargs...)

Adds photovoltaic (PV) generation ceilings to the system, from each unit's own
[`read_uigf`](@ref) forecast.

`UIGF` is the per-`DUID` upper limit NEMDE itself applied to a semi-scheduled unit. Units with no `UIGF` (scheduled units, or
intervals AEMO did not publish) keep their static `max_active_power` and get no time series.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to [`read_uigf`](@ref), e.g. `resolution`.
"""
function set_renewable_pv!(sys, db, date_range; kwargs...)
    uigf = read_uigf(db, date_range; kwargs...)
    @info "Setting PV power time series"
    return _add_uigf_ts_to_components!(sys, uigf, PrimeMovers.PVe)
end

"""
    set_renewable_wind!(sys, db, date_range; kwargs...)

Adds wind generation ceilings to the system, from each unit's own [`read_uigf`](@ref) forecast.

`UIGF` is the per-`DUID` upper limit NEMDE itself applied to a semi-scheduled unit. Units with no `UIGF` (scheduled units, or
intervals AEMO did not publish) keep their static `max_active_power` and get no time series.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `db`: The database connection.
- `date_range`: A range of dates for which to fetch the data.
- `kwargs`: Additional keyword arguments passed to [`read_uigf`](@ref), e.g. `resolution`.
"""
function set_renewable_wind!(sys, db, date_range; kwargs...)
    uigf = read_uigf(db, date_range; kwargs...)
    @info "Setting wind power time series"
    return _add_uigf_ts_to_components!(sys, uigf, PrimeMovers.WT)
end

function set_hydro_limits!(sys, db, date_range; kwargs...)
    energy_bids = read_energy_bids(db, date_range; kwargs...)
    ts = @chain energy_bids begin
        subset!(:DIRECTION => ByRow(==("GEN")))
        select!(:INTERVAL_DATETIME, :DUID, :MAXAVAIL)
        unstack(:INTERVAL_DATETIME, :DUID, :MAXAVAIL; combine = maximum)
        disallowmissing!
        TimeArray(timestamp = :INTERVAL_DATETIME)
    end
    return _add_demand_ts_to_components!(sys, ts, HydroDispatch)
end

"""
    _as_timearray(df, index, col, value)

Converts a DataFrame to a TimeArray.

# Arguments
- `df`: The input `DataFrame`.
- `index`: The column to use as the timestamp.
- `col`: The column to use for the column names of the `TimeArray`.
- `value`: The column to use for the values of the `TimeArray`.
"""
function _as_timearray(df, index, col, value)
    out = TimeArray(unstack(df, index, col, value); timestamp = index)
    return Float64.(out)
end

"""
    _add_demand_ts_to_components!(sys, ts, type)

Adds demand time series data to the system components.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `ts`: A `TimeArray` of demand data.
- `type`: The type of component to add the time series to.
"""
function _add_demand_ts_to_components!(sys, ts, type)
    loads = colnames(ts)
    for component in get_components(type, sys)
        name = Symbol(get_name(component))
        if !in(name, loads)
            @info "Setting loads to 0 for $name"
            ts_component = ts[first(loads)] .* 0.0
        else
            ts_component = ts[name]
        end
        max_active_power = with_units_base(() -> get_max_active_power(component), sys, "NATURAL_UNITS")
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = Float64.(ts_component ./ max_active_power),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
    end
    return
end

"""
    _add_uigf_ts_to_components!(sys, uigf, prime_mover)

Attaches each semi-scheduled unit's own `UIGF` upper limit to the matching `RenewableDispatch`
component, keyed by `DUID`.

Units absent from `uigf` are left untouched.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `uigf`: A `DataFrame` from [`read_uigf`](@ref) (`SETTLEMENTDATE`, `DUID`, `UIGF`).
- `prime_mover`: The prime mover type of the renewable generator.
"""
function _add_uigf_ts_to_components!(sys, uigf, prime_mover)
    isempty(uigf) && return
    by_duid = groupby(uigf, :DUID)
    for component in get_components(x -> get_prime_mover_type(x) == prime_mover, RenewableDispatch, sys)
        name = get_name(component)
        haskey(by_duid, (DUID = name,)) || continue
        rows = sort(DataFrame(by_duid[(DUID = name,)]), :SETTLEMENTDATE)
        nrow(rows) > 1 || continue
        max_active_power = with_units_base(() -> get_max_active_power(component), sys, "NATURAL_UNITS")
        psy_ts = SingleTimeSeries(;
            name = "max_active_power",
            data = TimeArray(rows.SETTLEMENTDATE, Float64.(rows.UIGF ./ max_active_power)),
            scaling_factor_multiplier = get_max_active_power,
        )
        add_time_series!(sys, component, psy_ts)
    end
    return
end
