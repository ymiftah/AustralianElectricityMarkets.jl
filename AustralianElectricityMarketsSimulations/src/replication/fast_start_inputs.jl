"""
    FastStartProfile(minimum_load_mw, t1_minutes, t2_minutes, t3_minutes, t4_minutes)

The offered dispatch inflexibility profile for one fast-start unit.

# Fields
- `minimum_load_mw`: profile minimum loading in MW.
- `t1_minutes`, `t2_minutes`, `t3_minutes`, `t4_minutes`: profile durations in minutes.
"""
struct FastStartProfile
    minimum_load_mw::Float64
    t1_minutes::Float64
    t2_minutes::Float64
    t3_minutes::Float64
    t4_minutes::Float64
end

"""
    FastStartState(mode, elapsed_minutes)

The fast-start mode and time spent in that mode at the start of an interval.

# Fields
- `mode`: dispatch mode from the preceding run.
- `elapsed_minutes`: minutes spent in that mode.
"""
struct FastStartState
    mode::Int
    elapsed_minutes::Float64
end

"""
    FastStartInput(profile, state, initial_mw, ramp_up_rate, ramp_down_rate, max_avail,
                   previous_total_cleared)

Historical fast-start inputs for one DUID and settlement interval.

# Fields
- `profile`: offered nonzero fast-start profile.
- `state`: mode and elapsed time at the interval start.
- `initial_mw`: metered MW at interval start.
- `ramp_up_rate`, `ramp_down_rate`: effective energy ramp rates in MW/h.
- `max_avail`: offered energy availability in MW.
- `previous_total_cleared`: preceding-run target, used for RTD profile-reset preprocessing.
"""
struct FastStartInput
    profile::FastStartProfile
    state::FastStartState
    initial_mw::Float64
    ramp_up_rate::Float64
    ramp_down_rate::Float64
    max_avail::Float64
    previous_total_cleared::Float64
end

"""
    read_fast_start_inputs(db, settlement_date; intervention = 0)

Reads one interval's fast-start profile, starting state and energy inputs from NEMWEB data.
Offers with all-zero or all-null timing parameters are slow-start offers and are omitted.

# Arguments
- `db`: an `AEMDB` connection.
- `settlement_date`: the dispatch interval end.
- `intervention`: 0 for the pricing run, 1 for the physical run.

# Returns
A `Dict{String, FastStartInput}` keyed by DUID.
"""
function read_fast_start_inputs(db, settlement_date::DateTime; intervention::Integer = 0)
    date_range = settlement_date:DISPATCH_INTERVAL:(settlement_date + DISPATCH_INTERVAL)
    dispatch = read_dispatch_limits(db, date_range; intervention = intervention)
    bids = read_bids(db, date_range; resolution = DISPATCH_INTERVAL)
    previous = _read_previous_fast_start_state(db, settlement_date - DISPATCH_INTERVAL, intervention)
    dispatch_by_duid = Dict(row.DUID => row for row in eachrow(dispatch))
    previous_by_duid = Dict(row.DUID => row for row in eachrow(previous))
    inputs = Dict{String, FastStartInput}()

    for row in eachrow(bids)
        row.DIRECTION == "GEN" || continue
        duid = row.DUID
        timings = (row.T1, row.T2, row.T3, row.T4)
        all(x -> ismissing(x) || iszero(x), timings) && continue
        limits = dispatch_by_duid[duid]
        prior = previous_by_duid[duid]
        profile = FastStartProfile(
            Float64(row.MINIMUMLOAD),
            (Float64(ismissing(x) ? 0.0 : x) for x in timings)...,
        )
        inputs[duid] = FastStartInput(
            profile,
            FastStartState(Int(prior.DISPATCHMODE), Float64(prior.DISPATCHMODETIME)),
            Float64(limits.INITIALMW),
            Float64(limits.RAMPUPRATE),
            Float64(limits.RAMPDOWNRATE),
            Float64(row.MAXAVAIL),
            Float64(prior.TOTALCLEARED),
        )
    end
    return inputs
end

# The preceding normal/intervention run supplies the state and target that RTD preprocessing may
# need. Current-interval outcomes are deliberately not read as model inputs.
function _read_previous_fast_start_state(db, settlement_date::DateTime, intervention::Integer)
    table = read_hive(db, :DISPATCHLOAD)
    return AustralianElectricityMarkets._query(
        db,
        """
        SELECT SETTLEMENTDATE, RUNNO, INTERVENTION, DUID, DISPATCHMODE, DISPATCHMODETIME, TOTALCLEARED
        FROM $table
        WHERE SETTLEMENTDATE = ? AND RUNNO = 1 AND COALESCE(INTERVENTION, 0) = ?
        QUALIFY row_number() OVER (
            PARTITION BY SETTLEMENTDATE, DUID, INTERVENTION, RUNNO ORDER BY archive_month DESC
        ) = 1
        """,
        [settlement_date, intervention],
    )
end
