"""
    set_unit_conditions!(sys, db, date_range; intervention = 0)

Attaches each available NEM dispatch device's operating condition from one [`read_unit_conditions`](@ref)
read. The values are `SingleTimeSeries` in AEMO's natural units, and their keys are held in the device's
[`NEMTelemetry`](@ref) and [`NEMObservedState`](@ref):

- `"telemetry_agc_status"`: `AGCSTATUS`, `0` or `1`.
- `"telemetry_uigf"`: `UIGF`, MW, for a semi-scheduled unit only.
- `"telemetry_ramp_up_limit"`, `"telemetry_ramp_down_limit"`: `RAMPUPRATE`, `RAMPDOWNRATE`, MW/h.
- `"telemetry_raise_reg_enablement"`, `"telemetry_lower_reg_enablement"`: the `(min, max)` MW
  enablement of each regulation service.
- `"telemetry_raise_reg_max_avail"`, `"telemetry_lower_reg_max_avail"`: `RAISEREGAVAILABILITY`,
  `LOWERREGAVAILABILITY`, MW.
- `"observed_initial_mw"`: `INITIALMW`, MW, zero where no row is published.
- `"observed_dispatch_mode"`: `DISPATCHMODE`.

A non-scheduled load is pinned to zero initial output, but keeps its metered ramp rates for AGC ramping.
A ramp, regulation or dispatch-mode value with no row at an interval is `NaN`; the telemetry `uigf` is
zero there. Every problem across every device is raised as one `ArgumentError`, and `sys` is left
unmodified. A repeat call replaces each series it writes, and replaces the structs on the devices.

The series are read through the keys, and AEMSim derives the dispatch inputs from them. The schedule type
and registration span of a device come from its [`NEMRegistration`](@ref).

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
    by_duid = Dict(String(key.DUID) => group for (key, group) in pairs(groupby(rows, :DUID)))
    problems = String[]
    staged = NamedTuple[]
    for device in nem_dispatch_devices(sys)
        device_rows = get(by_duid, get_name(device), nothing)
        by_time = isnothing(device_rows) ? Dict{DateTime, DataFrameRow}() :
            Dict(zip(device_rows.SETTLEMENTDATE, eachrow(device_rows)))
        data = _stage_unit_conditions!(problems, sys, device, by_time, grid)
        isnothing(data) || push!(staged, data)
    end
    isempty(problems) || throw(ArgumentError("set_unit_conditions!: " * join(problems, "; ") * "."))
    for data in staged
        for (name, values) in data.series
            replace_single_series!(sys, data.device, single_series(name, first(grid), values, Minute(5)))
        end
        _set_unit_data!(sys, data.device, data.semi)
    end
    return
end


# Holds the keys of the series of `device` in its telemetry and observed state. `uigf` is removed when the
# unit is not semi-scheduled, so a repeat call leaves no stale series.
function _set_unit_data!(sys, device, semi::Bool)
    if semi
        uigf = _series_key(device, NEM_TELEMETRY_SERIES.uigf)
    else
        remove_single_series!(sys, device, NEM_TELEMETRY_SERIES.uigf)
        uigf = nothing
    end
    set_telemetry!(
        device,
        NEMTelemetry(;
            agc_status = _series_key(device, NEM_TELEMETRY_SERIES.agc_status), uigf,
            ramp_up_limit = _series_key(device, NEM_TELEMETRY_SERIES.ramp_up_limit),
            ramp_down_limit = _series_key(device, NEM_TELEMETRY_SERIES.ramp_down_limit),
            raise_reg_enablement = _series_key(device, NEM_TELEMETRY_SERIES.raise_reg_enablement),
            lower_reg_enablement = _series_key(device, NEM_TELEMETRY_SERIES.lower_reg_enablement),
            raise_reg_max_avail = _series_key(device, NEM_TELEMETRY_SERIES.raise_reg_max_avail),
            lower_reg_max_avail = _series_key(device, NEM_TELEMETRY_SERIES.lower_reg_max_avail),
        ),
    )
    set_observed_state!(
        device,
        NEMObservedState(;
            initial_mw = _series_key(device, NEM_OBSERVED_SERIES.initial_mw),
            dispatch_mode = _series_key(device, NEM_OBSERVED_SERIES.dispatch_mode),
        ),
    )
    return
end


# `column` of the row at `t` as a `Float64`, or `NaN` without a row or with a `missing` value.
function _raw_value(by_time, t::DateTime, column::Symbol)
    row = get(by_time, t, nothing)
    (isnothing(row) || ismissing(row[column])) && return NaN
    return Float64(row[column])
end


# The `(min, max)` pair of the row at `t`, or `(NaN, NaN)` without a row or with a `missing` value.
function _raw_pair(by_time, t::DateTime, min_column::Symbol, max_column::Symbol)
    row = get(by_time, t, nothing)
    (isnothing(row) || ismissing(row[min_column]) || ismissing(row[max_column])) && return (NaN, NaN)
    return (Float64(row[min_column]), Float64(row[max_column]))
end


# Stages the series of one dispatch device and records its problems. Returns `nothing` after a problem.
function _stage_unit_conditions!(problems, sys, device, by_time, grid)
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
    initial_mw, ramp_up, ramp_down = zeros(n), fill(NaN, n), fill(NaN, n)
    uigf = zeros(n)
    semi_scheduled = !pinned && !is_storage && registration.schedule_type == ScheduleType.SEMI_SCHEDULED
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
        if semi_scheduled
            if ismissing(row.UIGF) || !isfinite(row.UIGF) || row.UIGF < 0
                push!(problems, "$name at $t: missing or invalid UIGF")
                return nothing
            end
            uigf[i] = row.UIGF
        end
    end
    series = Pair{String, Vector}[
        NEM_OBSERVED_SERIES.initial_mw => initial_mw,
        NEM_OBSERVED_SERIES.dispatch_mode => [_raw_value(by_time, t, :DISPATCHMODE) for t in grid],
        NEM_TELEMETRY_SERIES.agc_status => [_raw_value(by_time, t, :AGCSTATUS) for t in grid],
        NEM_TELEMETRY_SERIES.ramp_up_limit => ramp_up,
        NEM_TELEMETRY_SERIES.ramp_down_limit => ramp_down,
        NEM_TELEMETRY_SERIES.raise_reg_enablement => [_raw_pair(by_time, t, :RAISEREGENABLEMENTMIN, :RAISEREGENABLEMENTMAX) for t in grid],
        NEM_TELEMETRY_SERIES.lower_reg_enablement => [_raw_pair(by_time, t, :LOWERREGENABLEMENTMIN, :LOWERREGENABLEMENTMAX) for t in grid],
        NEM_TELEMETRY_SERIES.raise_reg_max_avail => [_raw_value(by_time, t, :RAISEREGAVAILABILITY) for t in grid],
        NEM_TELEMETRY_SERIES.lower_reg_max_avail => [_raw_value(by_time, t, :LOWERREGAVAILABILITY) for t in grid],
    ]
    semi_scheduled && push!(series, NEM_TELEMETRY_SERIES.uigf => uigf)
    return (; device, series, semi = semi_scheduled)
end


# `x` as a `Float64`, or `NaN` when it is `missing`.
_nan_if_missing(x) = ismissing(x) ? NaN : Float64(x)
