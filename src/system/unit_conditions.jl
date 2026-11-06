"""
    set_unit_conditions!(sys, db, date_range; intervention = 0)

Attaches each unit's operating condition from one [`read_unit_conditions`](@ref) read, as
per-unit `SingleTimeSeries` of the system base. Every available `Generator`, `Storage` and
`ControllableLoad` gets the regulation and dispatch-mode series it has rows for:
`"fcas_agc_enablement_min_<svc>"`, `"fcas_agc_enablement_max_<svc>"`,
`"fcas_regulation_availability_<svc>"` (`RAISEREG`, `LOWERREG`), `"fcas_agc_status"` and
`"dispatch_mode"`. A NEM dispatch device also gets `"initial_mw"`, `"dispatch_ramp_up_rate"` and
`"dispatch_ramp_down_rate"` (per minute, from `RAMPUPRATE`/`RAMPDOWNRATE`), `"availability"` (not for
storage) and, for a semi-scheduled unit, `"uigf"`. AEMSim derives `ramp_*`, `max_active_power` and
`fcas_agc_ramp_rate_*` from these.

The schedule type and registration span of a NEM dispatch device come from its
[`NEMRegistration`](@ref). A non-scheduled load gets zero `initial_mw` and `availability` whatever
`DISPATCHLOAD` meters, but keeps its metered ramp rates for AGC ramping. A device with no
`DISPATCHLOAD` rows in `date_range`, a missing interval inside its registration, a `missing` or
negative rate or `AVAILABILITY`, or a missing or invalid `UIGF` on a semi-scheduled interval is a
problem. Every problem across every device is raised as one `ArgumentError`, and `sys` is left
unmodified. Ramp rates, regulation and dispatch-mode values with no row at an interval are `NaN`,
which applies no scaling there. A repeat call replaces each series it writes.

# Arguments
- `sys`: the `System` to add to, after [`set_market_bids!`](@ref) has made the non-scheduled loads
  with FCAS bids available.
- `db`: an `AEMDB` connection.
- `date_range`: the five-minute dispatch intervals to replay, including the exclusive stop timestamp.
- `intervention`: the `DISPATCHLOAD` run, `0` for pricing or `1` for physical dispatch.

# Returns
`nothing`.
"""
function set_unit_conditions!(sys, db, date_range; intervention::Integer = 0)
    step(date_range) == Minute(5) || throw(ArgumentError("unit conditions require five-minute intervals"))
    grid = collect(date_range)[1:(end - 1)]
    isempty(grid) && throw(ArgumentError("unit conditions require at least one interval"))
    rows = read_unit_conditions(db, date_range; intervention)
    base = get_base_power(sys)
    by_duid = Dict(String(key.DUID) => group for (key, group) in pairs(groupby(rows, :DUID)))
    problems = String[]
    staged = NamedTuple[]
    for device in _fcas_scaling_devices(sys, (Generator, Storage, ControllableLoad))
        device_rows = get(by_duid, get_name(device), nothing)
        by_time = isnothing(device_rows) ? Dict{DateTime, DataFrameRow}() :
            Dict(zip(device_rows.SETTLEMENTDATE, eachrow(device_rows)))
        dispatch = any(T -> device isa T, NEM_DISPATCH_DEVICE_TYPES)
        push!(staged, _stage_unit_conditions!(problems, sys, device, by_time, grid, base, dispatch))
    end
    isempty(problems) || throw(ArgumentError("set_unit_conditions!: " * join(problems, "; ") * "."))
    for data in staged
        for (name, values) in data.series
            replace_single_series!(sys, data.device, single_series(name, first(grid), values, Minute(5)))
        end
        isnothing(data.semi) || data.semi || remove_single_series!(sys, data.device, NEM_SERIES.uigf)
    end
    return
end


# The available devices of the component types that carry FCAS scaling inputs.
function _fcas_scaling_devices(sys, component_types)
    devices = Device[]
    for component_type in component_types
        append!(devices, get_components(get_available, component_type, sys))
    end
    return devices
end


# The FCAS regulation columns, each with the series it attaches to, per unit of the system base.
const _UNIT_CONDITION_PER_UNIT_COLUMNS = (
    (:RAISEREGENABLEMENTMIN, fcas_series_name("fcas_agc_enablement_min", BidType.RAISEREG)),
    (:RAISEREGENABLEMENTMAX, fcas_series_name("fcas_agc_enablement_max", BidType.RAISEREG)),
    (:LOWERREGENABLEMENTMIN, fcas_series_name("fcas_agc_enablement_min", BidType.LOWERREG)),
    (:LOWERREGENABLEMENTMAX, fcas_series_name("fcas_agc_enablement_max", BidType.LOWERREG)),
    (:RAISEREGAVAILABILITY, fcas_series_name("fcas_regulation_availability", BidType.RAISEREG)),
    (:LOWERREGAVAILABILITY, fcas_series_name("fcas_regulation_availability", BidType.LOWERREG)),
)


# `column` of the row at `t` per unit of `base`, or `NaN` without a row or with a `missing` value.
function _per_unit_value(by_time, t::DateTime, column::Symbol, base::Real)
    row = get(by_time, t, nothing)
    (isnothing(row) || ismissing(row[column])) && return NaN
    return row[column] / base
end


# `column` of the row at `t` as a `Float64`, or `NaN` without a row or with a `missing` value.
function _raw_value(by_time, t::DateTime, column::Symbol)
    row = get(by_time, t, nothing)
    (isnothing(row) || ismissing(row[column])) && return NaN
    return Float64(row[column])
end


# Stages the series of one device and records its problems. `semi` is `nothing` for storage and for a
# device without dispatch limits, and whether the unit is semi-scheduled otherwise.
function _stage_unit_conditions!(problems, sys, device, by_time, grid, base, dispatch::Bool)
    series = Pair{String, Vector{Float64}}[]
    for (column, series_name) in _UNIT_CONDITION_PER_UNIT_COLUMNS
        values = [_per_unit_value(by_time, t, column, base) for t in grid]
        all(isnan, values) || push!(series, series_name => values)
    end
    raw = ((:DISPATCHMODE, NEM_SERIES.dispatch_mode), (:AGCSTATUS, NEM_SERIES.fcas_agc_status))
    for (column, series_name) in raw
        values = [_raw_value(by_time, t, column) for t in grid]
        all(isnan, values) || push!(series, series_name => values)
    end
    dispatch || return (; device, series, semi = nothing)
    limits = _stage_dispatch_limits!(problems, sys, device, by_time, grid, base)
    isnothing(limits) && return (; device, series, semi = nothing)
    append!(series, limits.series)
    return (; device, series, semi = limits.semi)
end


# The dispatch limit series of a NEM dispatch device, or `nothing` after recording a problem. A
# non-scheduled load is pinned to zero limits, but keeps its metered ramp rates as published, which AGC
# ramping reads. A missing row leaves the ramp rates `NaN`.
function _stage_dispatch_limits!(problems, sys, device, by_time, grid, base)
    name = get_name(device)
    registration = get_registration(device)
    is_storage = device isa PSY.Storage
    pinned = is_non_scheduled_load(device)
    if !pinned && isempty(by_time)
        push!(problems, "$name: no DISPATCHLOAD rows in $(first(grid)) to $(last(grid))")
        return nothing
    end
    unexplained = [t for t in grid if !pinned && !haskey(by_time, t) && _is_registered(registration, t)]
    if !isempty(unexplained)
        push!(
            problems,
            "$name: missing DISPATCHLOAD row(s) for $(length(unexplained)) of $(length(grid)) interval(s) (e.g. $(minimum(unexplained)))",
        )
        return nothing
    end
    if !is_storage
        smap = with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        if smap <= 0
            push!(problems, "$name: static max_active_power is $smap (cannot normalise AVAILABILITY without dividing by zero)")
            return nothing
        end
    end
    n = length(grid)
    initial_mw, ramp_up, ramp_down, availability = zeros(n), fill(NaN, n), fill(NaN, n), zeros(n)
    uigf_raw = zeros(n)
    semi_scheduled = !pinned && registration.schedule_type == ScheduleType.SEMI_SCHEDULED
    for (i, t) in enumerate(grid)
        row = get(by_time, t, nothing)
        if pinned
            isnothing(row) || (ramp_up[i] = _nan_if_missing(row.RAMPUPRATE); ramp_down[i] = _nan_if_missing(row.RAMPDOWNRATE))
            continue
        end
        isnothing(row) && continue
        if ismissing(row.INITIALMW) || ismissing(row.RAMPUPRATE) || ismissing(row.RAMPDOWNRATE) ||
                (!is_storage && ismissing(row.AVAILABILITY))
            push!(problems, "$name: missing INITIALMW/RAMPUPRATE/RAMPDOWNRATE" * (is_storage ? "" : "/AVAILABILITY") * " at $t")
            return nothing
        elseif row.RAMPUPRATE < 0 || row.RAMPDOWNRATE < 0
            push!(problems, "$name: negative RAMPUPRATE/RAMPDOWNRATE ($(row.RAMPUPRATE)/$(row.RAMPDOWNRATE)) at $t")
            return nothing
        elseif !is_storage && row.AVAILABILITY < 0
            push!(problems, "$name: negative AVAILABILITY ($(row.AVAILABILITY)) at $t")
            return nothing
        end
        initial_mw[i] = row.INITIALMW
        ramp_up[i] = row.RAMPUPRATE
        ramp_down[i] = row.RAMPDOWNRATE
        is_storage || (availability[i] = row.AVAILABILITY)
        if semi_scheduled && !is_storage
            if ismissing(row.UIGF) || !isfinite(row.UIGF) || row.UIGF < 0
                push!(problems, "$name at $t: missing or invalid UIGF")
                return nothing
            end
            uigf_raw[i] = row.UIGF
        end
    end
    series = Pair{String, Vector{Float64}}[
        NEM_SERIES.initial_mw => initial_mw ./ base,
        NEM_SERIES.dispatch_ramp_up_rate => ramp_up ./ 60 ./ base,
        NEM_SERIES.dispatch_ramp_down_rate => ramp_down ./ 60 ./ base,
    ]
    is_storage && return (; series, semi = nothing)
    push!(series, NEM_SERIES.availability => availability ./ base)
    semi_scheduled && push!(series, NEM_SERIES.uigf => uigf_raw ./ base)
    return (; series, semi = semi_scheduled)
end


# `x` as a `Float64`, or `NaN` when it is `missing`.
_nan_if_missing(x) = ismissing(x) ? NaN : Float64(x)
