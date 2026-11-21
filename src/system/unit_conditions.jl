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
- `"observed_dispatch_mode"`: `DISPATCHMODE` of the previous interval, the fast-start mode at the start of each
  interval.
- `"observed_dispatch_mode_time"`: `DISPATCHMODETIME` of the previous interval, the minutes in that mode at the
  start of each interval.

A non-scheduled load is pinned to zero initial output, but keeps its metered ramp rates for AGC ramping.
The read also covers the interval before the first, which supplies the first dispatch mode. A ramp, regulation or
AGC status value with no row at an interval is `NaN`, and so is a dispatch mode or mode time whose previous interval
has no row;
the telemetry `uigf` is zero there. A registered unit with a `NaN` mode is refused by the NEMDE state. Every problem
across every device is raised as one `ArgumentError`, and `sys` is left unmodified. A repeat call replaces each series
it writes, and replaces the structs on the devices.

# Arguments
- `sys`: the `System` to add to, after [`set_market_bids!`](@ref) has made the non-scheduled loads
  with FCAS bids available.
- `db`: an `AEMDB` connection.
- `date_range`: the five-minute dispatch intervals to run, including the exclusive stop timestamp.
- `intervention`: the `DISPATCHLOAD` run: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
`nothing`.
"""
function set_unit_conditions!(sys, db, date_range; intervention::Integer = 0)
    step(date_range) == Minute(5) || throw(ArgumentError("unit conditions require five-minute intervals"))
    grid = collect(date_range)[1:(end - 1)]
    isempty(grid) && throw(ArgumentError("unit conditions require at least one interval"))
    # One interval before the grid, for the dispatch mode at the first stamp.
    rows = read_unit_conditions(db, (first(date_range) - Minute(5)):Minute(5):last(date_range); intervention)
    by_duid = Dict(String(key.DUID) => group for (key, group) in pairs(groupby(rows, :DUID)))
    problems = String[]
    staged = NamedTuple[]
    no_rows = view(rows, 1:0, :)
    _foreach_nem_dispatch_device(sys) do device
        device_rows = get(by_duid, get_name(device), no_rows)
        data = _stage_unit_conditions!(problems, sys, device, _unit_condition_columns(device_rows), grid)
        isnothing(data) || push!(staged, data)
        return
    end
    isempty(problems) || throw(ArgumentError("set_unit_conditions!: " * join(problems, "; ") * "."))
    for data in staged
        series_keys = Dict{String, IS.StaticTimeSeriesKey}()
        for (name, values) in data.series
            series_keys[name] = replace_single_series!(sys, data.device, single_series(name, first(grid), values, Minute(5)))
        end
        _set_unit_data!(sys, data.device, data.semi, series_keys)
    end
    return
end


# Holds the keys `series_keys` of the series just written for `device` in its telemetry and observed
# state. `uigf` is removed when the unit is not semi-scheduled, so a repeat call leaves no stale series.
function _set_unit_data!(sys, device, semi::Bool, series_keys::AbstractDict{String, IS.StaticTimeSeriesKey})
    if semi
        uigf = series_keys[NEM_TELEMETRY_SERIES.uigf]
    else
        remove_single_series!(sys, device, NEM_TELEMETRY_SERIES.uigf)
        uigf = nothing
    end
    set_telemetry!(
        device,
        NEMTelemetry(;
            agc_status = series_keys[NEM_TELEMETRY_SERIES.agc_status], uigf,
            ramp_up_limit = series_keys[NEM_TELEMETRY_SERIES.ramp_up_limit],
            ramp_down_limit = series_keys[NEM_TELEMETRY_SERIES.ramp_down_limit],
            raise_reg_enablement = series_keys[NEM_TELEMETRY_SERIES.raise_reg_enablement],
            lower_reg_enablement = series_keys[NEM_TELEMETRY_SERIES.lower_reg_enablement],
            raise_reg_max_avail = series_keys[NEM_TELEMETRY_SERIES.raise_reg_max_avail],
            lower_reg_max_avail = series_keys[NEM_TELEMETRY_SERIES.lower_reg_max_avail],
        ),
    )
    set_observed_state!(
        device,
        NEMObservedState(;
            initial_mw = series_keys[NEM_OBSERVED_SERIES.initial_mw],
            dispatch_mode = series_keys[NEM_OBSERVED_SERIES.dispatch_mode],
            dispatch_mode_time = series_keys[NEM_OBSERVED_SERIES.dispatch_mode_time],
        ),
    )
    return
end


const _UNIT_CONDITION_COLUMNS = (
    :SETTLEMENTDATE, :INITIALMW, :AVAILABILITY, :UIGF, :RAMPUPRATE, :RAMPDOWNRATE, :AGCSTATUS, :DISPATCHMODE,
    :DISPATCHMODETIME,
    :RAISEREGENABLEMENTMIN, :RAISEREGENABLEMENTMAX, :LOWERREGENABLEMENTMIN, :LOWERREGENABLEMENTMAX,
    :RAISEREGAVAILABILITY, :LOWERREGAVAILABILITY,
)

# The columns of one device's `DISPATCHLOAD` rows that the series are built from, with the row of each stamp.
function _unit_condition_columns(device_rows)
    columns = NamedTuple{_UNIT_CONDITION_COLUMNS}(map(n -> device_rows[!, n], _UNIT_CONDITION_COLUMNS))
    return (; columns..., index = Dict{DateTime, Int}(t => i for (i, t) in enumerate(columns.SETTLEMENTDATE)))
end


# `column` at the row of stamp `t` as a `Float64`, or `NaN` without a row or with a `missing` value.
function _raw_value(index::Dict{DateTime, Int}, column::AbstractVector, t::DateTime)
    i = get(index, t, 0)
    (i == 0 || ismissing(column[i])) && return NaN
    return Float64(column[i])
end


# The `(min, max)` pair at the row of stamp `t`, or `(NaN, NaN)` without a row or with a `missing` value.
function _raw_pair(index::Dict{DateTime, Int}, min_column::AbstractVector, max_column::AbstractVector, t::DateTime)
    i = get(index, t, 0)
    (i == 0 || ismissing(min_column[i]) || ismissing(max_column[i])) && return (NaN, NaN)
    return (Float64(min_column[i]), Float64(max_column[i]))
end


# Stages the series of one dispatch device from its `DISPATCHLOAD` columns (see `_unit_condition_columns`) and
# records its problems. Returns `nothing` after a problem.
function _stage_unit_conditions!(problems, sys, device, c, grid)
    name = get_name(device)
    registration = get_registration(device)
    is_storage = device isa PSY.Storage
    pinned = is_non_scheduled_load(device)
    index = c.index
    if !pinned && isempty(index)
        push!(problems, "$name: no DISPATCHLOAD rows in $(first(grid)) to $(last(grid))")
        return nothing
    end
    unexplained = [t for t in grid if !pinned && !haskey(index, t) && _is_registered(registration, t)]
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
    for (k, t) in enumerate(grid)
        i = get(index, t, 0)
        if pinned
            i == 0 || (ramp_up[k] = _nan_if_missing(c.RAMPUPRATE[i]); ramp_down[k] = _nan_if_missing(c.RAMPDOWNRATE[i]))
            continue
        end
        i == 0 && continue
        if ismissing(c.INITIALMW[i]) || ismissing(c.RAMPUPRATE[i]) || ismissing(c.RAMPDOWNRATE[i]) ||
                (!is_storage && ismissing(c.AVAILABILITY[i]))
            push!(problems, "$name: missing INITIALMW/RAMPUPRATE/RAMPDOWNRATE" * (is_storage ? "" : "/AVAILABILITY") * " at $t")
            return nothing
        elseif c.RAMPUPRATE[i] < 0 || c.RAMPDOWNRATE[i] < 0
            push!(problems, "$name: negative RAMPUPRATE/RAMPDOWNRATE ($(c.RAMPUPRATE[i])/$(c.RAMPDOWNRATE[i])) at $t")
            return nothing
        elseif !is_storage && c.AVAILABILITY[i] < 0
            push!(problems, "$name: negative AVAILABILITY ($(c.AVAILABILITY[i])) at $t")
            return nothing
        end
        initial_mw[k] = c.INITIALMW[i]
        ramp_up[k] = c.RAMPUPRATE[i]
        ramp_down[k] = c.RAMPDOWNRATE[i]
        if semi_scheduled
            u = c.UIGF[i]
            if ismissing(u) || !isfinite(u) || u < 0
                push!(problems, "$name at $t: missing or invalid UIGF")
                return nothing
            end
            uigf[k] = u
        end
    end
    previous = [t - Minute(5) for t in grid]
    series = Pair{String, Vector}[
        NEM_OBSERVED_SERIES.initial_mw => initial_mw,
        NEM_OBSERVED_SERIES.dispatch_mode => [_raw_value(index, c.DISPATCHMODE, t) for t in previous],
        NEM_OBSERVED_SERIES.dispatch_mode_time => [_raw_value(index, c.DISPATCHMODETIME, t) for t in previous],
        NEM_TELEMETRY_SERIES.agc_status => [_raw_value(index, c.AGCSTATUS, t) for t in grid],
        NEM_TELEMETRY_SERIES.ramp_up_limit => ramp_up,
        NEM_TELEMETRY_SERIES.ramp_down_limit => ramp_down,
        NEM_TELEMETRY_SERIES.raise_reg_enablement => [_raw_pair(index, c.RAISEREGENABLEMENTMIN, c.RAISEREGENABLEMENTMAX, t) for t in grid],
        NEM_TELEMETRY_SERIES.lower_reg_enablement => [_raw_pair(index, c.LOWERREGENABLEMENTMIN, c.LOWERREGENABLEMENTMAX, t) for t in grid],
        NEM_TELEMETRY_SERIES.raise_reg_max_avail => [_raw_value(index, c.RAISEREGAVAILABILITY, t) for t in grid],
        NEM_TELEMETRY_SERIES.lower_reg_max_avail => [_raw_value(index, c.LOWERREGAVAILABILITY, t) for t in grid],
    ]
    semi_scheduled && push!(series, NEM_TELEMETRY_SERIES.uigf => uigf)
    return (; device, series, semi = semi_scheduled)
end


# `x` as a `Float64`, or `NaN` when it is `missing`.
_nan_if_missing(x) = ismissing(x) ? NaN : Float64(x)
