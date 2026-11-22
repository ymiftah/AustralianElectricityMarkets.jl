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
    conditions = read_unit_conditions(db, (first(date_range) - Minute(5)):Minute(5):last(date_range); intervention)
    devices = DataFrame(
        order = Int[], device = Any[], DUID = String[], pinned = Bool[], storage = Bool[], semi = Bool[],
        registration = NEMRegistration[], smap = Float64[],
    )
    _foreach_nem_dispatch_device(sys) do device
        registration = get_registration(device)
        storage = device isa PSY.Storage
        pinned = is_non_scheduled_load(device)
        semi = !pinned && !storage && registration.schedule_type == ScheduleType.SEMI_SCHEDULED
        smap = storage ? NaN : with_units_base(() -> get_max_active_power(device), sys, "NATURAL_UNITS")
        push!(devices, (; order = nrow(devices) + 1, device, DUID = get_name(device), pinned, storage, semi, registration, smap))
        return
    end

    # One row per device and interval: the metered conditions, and the previous interval's dispatch mode.
    metered = transform!(conditions, :DUID => ByRow(String) => :DUID, :DUID => ByRow(_ -> true) => :HAS_ROW)
    previous = select(
        metered, :DUID, :SETTLEMENTDATE => ByRow(t -> t + Minute(5)) => :SETTLEMENTDATE,
        :DISPATCHMODE => :PREV_MODE, :DISPATCHMODETIME => :PREV_MODE_TIME,
    )
    # `crossjoin` lists each device's stamps in grid order, and `leftjoin!` keeps that order.
    rows = @chain crossjoin(devices, DataFrame(SETTLEMENTDATE = grid)) begin
        leftjoin!(metered; on = [:DUID, :SETTLEMENTDATE])
        leftjoin!(previous; on = [:DUID, :SETTLEMENTDATE])
        transform!(:HAS_ROW => ByRow(!ismissing) => :HAS_ROW)
        transform!([:registration, :SETTLEMENTDATE] => ByRow(_is_registered) => :registered)
    end

    # Each problem kind is one subset. A device reports its first: device-wide problems, then the earliest
    # interval, then the kind in the order below.
    report(frame, stage, kind, message) = DataFrame(
        order = frame.order, DUID = frame.DUID, message = map(message, eachrow(frame)),
        priority = [(stage, r.SETTLEMENTDATE, kind) for r in eachrow(frame)],
    )
    present = Set(conditions.DUID)
    live = subset(rows, :pinned => ByRow(!), :HAS_ROW)
    no_rows = @chain devices begin
        subset(:pinned => ByRow(!), :DUID => ByRow(!in(present)))
        insertcols(:SETTLEMENTDATE => first(grid))
    end
    unexplained = @chain rows begin
        subset(:pinned => ByRow(!), :HAS_ROW => ByRow(!), :registered)
        transform(groupby(_, :DUID), nrow => :n)
    end
    bad_smap = @chain devices begin
        subset(:storage => ByRow(!), :smap => ByRow(<=(0)))
        insertcols(:SETTLEMENTDATE => first(grid))
    end
    missing_value = subset(
        live, [:INITIALMW, :RAMPUPRATE, :RAMPDOWNRATE, :AVAILABILITY, :storage] =>
            ByRow((mw, up, down, avail, storage) -> any(ismissing, (mw, up, down)) || (!storage && ismissing(avail))),
    )
    negative_ramp = subset(
        live, [:RAMPUPRATE, :RAMPDOWNRATE] => ByRow((up, down) -> coalesce((up < 0) | (down < 0), false)),
    )
    negative_availability = subset(
        live, [:AVAILABILITY, :storage] => ByRow((avail, storage) -> !storage && coalesce(avail < 0, false)),
    )
    bad_uigf = subset(live, [:UIGF, :semi] => ByRow((uigf, semi) -> semi && (ismissing(uigf) || !isfinite(uigf) || uigf < 0)))
    problems = @chain vcat(
        report(no_rows, 1, 0, r -> "$(r.DUID): no DISPATCHLOAD rows in $(first(grid)) to $(last(grid))"),
        report(
            unexplained, 2, 0,
            r -> "$(r.DUID): missing DISPATCHLOAD row(s) for $(r.n) of $(length(grid)) interval(s) (e.g. $(r.SETTLEMENTDATE))",
        ),
        report(
            bad_smap, 3, 0,
            r -> "$(r.DUID): static max_active_power is $(r.smap) (cannot normalise AVAILABILITY without dividing by zero)",
        ),
        report(
            missing_value, 4, 1,
            r -> "$(r.DUID): missing INITIALMW/RAMPUPRATE/RAMPDOWNRATE" * (r.storage ? "" : "/AVAILABILITY") * " at $(r.SETTLEMENTDATE)",
        ),
        report(
            negative_ramp, 4, 2,
            r -> "$(r.DUID): negative RAMPUPRATE/RAMPDOWNRATE ($(r.RAMPUPRATE)/$(r.RAMPDOWNRATE)) at $(r.SETTLEMENTDATE)",
        ),
        report(negative_availability, 4, 3, r -> "$(r.DUID): negative AVAILABILITY ($(r.AVAILABILITY)) at $(r.SETTLEMENTDATE)"),
        report(bad_uigf, 4, 4, r -> "$(r.DUID) at $(r.SETTLEMENTDATE): missing or invalid UIGF");
        cols = :union,
    ) begin
        sort([:order, :priority])
        unique(:DUID)
    end
    isempty(problems) || throw(ArgumentError("set_unit_conditions!: " * join(problems.message, "; ") * "."))

    # Missing values are NaN, except that a unit with no row has zero initial output and UIGF.
    nan(column) = Float64.(coalesce.(column, NaN))
    enablement(lo, hi) = ismissing(lo) || ismissing(hi) ? (NaN, NaN) : (Float64(lo), Float64(hi))
    for unit in groupby(rows, :DUID)
        (; device, pinned, semi) = first(unit)
        series = Pair{String, Vector}[
            NEM_OBSERVED_SERIES.initial_mw => pinned ? zeros(nrow(unit)) : Float64.(coalesce.(unit.INITIALMW, 0.0)),
            NEM_OBSERVED_SERIES.dispatch_mode => nan(unit.PREV_MODE),
            NEM_OBSERVED_SERIES.dispatch_mode_time => nan(unit.PREV_MODE_TIME),
            NEM_TELEMETRY_SERIES.agc_status => nan(unit.AGCSTATUS),
            NEM_TELEMETRY_SERIES.ramp_up_limit => nan(unit.RAMPUPRATE),
            NEM_TELEMETRY_SERIES.ramp_down_limit => nan(unit.RAMPDOWNRATE),
            NEM_TELEMETRY_SERIES.raise_reg_enablement => enablement.(unit.RAISEREGENABLEMENTMIN, unit.RAISEREGENABLEMENTMAX),
            NEM_TELEMETRY_SERIES.lower_reg_enablement => enablement.(unit.LOWERREGENABLEMENTMIN, unit.LOWERREGENABLEMENTMAX),
            NEM_TELEMETRY_SERIES.raise_reg_max_avail => nan(unit.RAISEREGAVAILABILITY),
            NEM_TELEMETRY_SERIES.lower_reg_max_avail => nan(unit.LOWERREGAVAILABILITY),
        ]
        semi && push!(series, NEM_TELEMETRY_SERIES.uigf => Float64.(coalesce.(unit.UIGF, 0.0)))
        series_keys = Dict{String, IS.StaticTimeSeriesKey}()
        for (name, values) in series
            series_keys[name] = replace_single_series!(sys, device, single_series(name, first(grid), values, Minute(5)))
        end
        _set_unit_data!(sys, device, semi, series_keys)
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
