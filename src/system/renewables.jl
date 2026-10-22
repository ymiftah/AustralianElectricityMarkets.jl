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
        add_time_series!(
            sys, component,
            single_series(
                "max_active_power", rows.SETTLEMENTDATE, Float64.(rows.UIGF ./ max_active_power);
                scaling_factor_multiplier = get_max_active_power,
            ),
        )
    end
    return
end
