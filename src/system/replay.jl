"""
    table_requirements(::NEMDEConfiguration)

Returns the constrained network tables plus interconnector loss, MNSP offer and metered-flow
tables needed for replay. `DISPATCHINTERCONNECTORRES` is required for MNSP ramping even when
published interval flow limits are not attached.

# Returns
A vector of NEMWEB table symbols.
"""
function AustralianElectricityMarkets.table_requirements(::NEMDEConfiguration)
    return [
        table_requirements(ConstrainedNetworkConfiguration())...,
        :LOSSMODEL, :LOSSFACTORMODEL, :MNSP_INTERCONNECTOR, :MNSP_DAYOFFER,
        :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK, :DISPATCHINTERCONNECTORRES,
    ]
end


"""
    nem_system(db, ::NEMDEConfiguration; date_range, intervention = 0,
        interval_flow_limits = false, time_series_in_memory = true, time_series_directory = nothing)

Builds a constrained system populated with demand, energy and FCAS bids, scaling and dispatch
inputs, energy limits, interconnector losses and MNSP offers as single time series.

# Arguments
- `db`: the market cache connection.
- `date_range`: five-minute interval-ending timestamps, including the exclusive stop; at least two stamps.
- `intervention`: `0` for pricing or `1` for physical dispatch inputs.
- `interval_flow_limits`: attach published interval flow limits for diagnostic runs; default `false`.
  These limits are computed after dispatch and must not be used to validate simulated flows.
- `time_series_in_memory`: store time series in memory when `true`.
- `time_series_directory`: optional directory for file-backed time series.

# Returns
A populated `PSY.System`. Throws `ArgumentError` for an invalid range or incomplete required inputs.
"""
function AustralianElectricityMarkets.nem_system(
        db, ::NEMDEConfiguration; date_range::StepRange{DateTime}, intervention::Integer = 0,
        interval_flow_limits::Bool = false, time_series_in_memory::Bool = true,
        time_series_directory::Union{Nothing, AbstractString} = nothing,
    )
    (step(date_range) == Minute(5) && length(date_range) >= 2) || throw(
        ArgumentError("NEMDEConfiguration: the date range must step by 5 minutes over at least two stamps, got $date_range."),
    )
    resolution = Minute(5)
    storage = isnothing(time_series_directory) ? (;) : (; time_series_directory)
    sys, units = _constrained_system(
        db; date_range, intervention,
        time_series_in_memory, storage...,
    )
    bids = read_energy_bids(db, date_range)
    dispatch = read_dispatch_limits(db, date_range; intervention, resolution)
    demand = read_demand(db, date_range; resolution)
    _check_replay_energy_bid_coverage(sys, bids, dispatch, units, demand, date_range)
    AustralianElectricityMarkets._set_demand!(sys, demand, date_range; resolution)
    set_loss_demand_coefficients!(sys)
    set_market_bids!(sys, db, date_range; resolution)
    set_fcas_scaling_inputs!(sys, db, date_range; intervention)
    AustralianElectricityMarkets._set_nem_dispatch_limits!(sys, dispatch, date_range)
    set_nem_energy_limits!(sys, db, date_range; intervention)
    set_mnsp_offers!(sys, db, date_range; intervention)
    interval_flow_limits && set_interconnector_flow_limits!(sys, db, date_range; intervention)
    return sys
end


# The `DIRECTION`s `device` must offer energy on ([`energy_offer_sides`](@ref)), given the offered
# `(DUID, DIRECTION)` keys of `coverage`.
_required_bid_directions(device, coverage) = string.(energy_offer_sides(device))
# A wholesale demand response unit bids GEN only; every other scheduled load, including one with no
# period offer at all, is required on LOAD.
_required_bid_directions(device::PSY.InterruptiblePowerLoad, coverage) =
    haskey(coverage, (PSY.get_name(device), "GEN")) ? ("GEN",) : string.(energy_offer_sides(device))


"""
    _check_replay_energy_bid_coverage(sys, db, date_range; intervention = 0)

Verifies the cached bids and demand cover every interval of `date_range` (its last stamp
excluded). Every region with a unit (`DUDETAILSUMMARY`) needs regional demand (`DISPATCHREGIONSUM`)
at every interval. Every scheduled unit of `sys` that bids energy (`BIDPEROFFER_D`), or is
available or metered in `DISPATCHLOAD`, needs an energy period offer with a finite non-negative
`MAXAVAIL` at every interval, read independently of the price join with `BIDDAYOFFER_D`.
Non-scheduled units and loads are not checked.

# Arguments
- `sys`: the `PSY.System` whose units are checked.
- `db`: an `AEMDB` connection.
- `date_range`: the replay range.
- `intervention`: the `DISPATCHLOAD` run, 0 for pricing and 1 for physical.

# Returns
`nothing`. Throws an `ArgumentError` naming the first unit and direction, or region, missing an input.
"""
function _check_replay_energy_bid_coverage(sys, db, date_range; intervention::Integer = 0)
    bids = read_energy_bids(db, date_range)
    dispatch = read_dispatch_limits(db, date_range; intervention = intervention)
    units = read_units(db; as_of = first(date_range))
    demand = read_demand(db, date_range)
    return _check_replay_energy_bid_coverage(sys, bids, dispatch, units, demand, date_range)
end


function _check_replay_energy_bid_coverage(sys, bids, dispatch, units, demand, date_range)
    demand_stamps = Set(zip(demand.REGIONID, demand.SETTLEMENTDATE))
    grid = collect(date_range)[1:(end - 1)]
    missing_demand = [(region, t) for region in sort!(unique(units.REGIONID)), t in grid if !((region, t) in demand_stamps)]
    isempty(missing_demand) || throw(
        ArgumentError(
            "missing regional demand inputs: $(join(string.(first(missing_demand, 5)), ", ")); " *
                "repopulate DISPATCHREGIONSUM with populate(...; force_new = true)",
        ),
    )
    non_scheduled = Set(r.DUID for r in eachrow(units) if isequal(r.SCHEDULE_TYPE, "NON-SCHEDULED"))
    required_names = Set(bids.DUID)
    for row in eachrow(dispatch)
        available = !ismissing(row.AVAILABILITY) && row.AVAILABILITY > 0
        metered = !ismissing(row.INITIALMW) && !iszero(row.INITIALMW)
        (available || metered) && push!(required_names, row.DUID)
    end
    required = Dict{String, Tuple{Vararg{String}}}()
    coverage = Dict{Tuple{String, String}, Set{DateTime}}()
    for row in eachrow(bids)
        push!(get!(coverage, (row.DUID, row.DIRECTION), Set{DateTime}()), row.INTERVAL_DATETIME)
    end
    for T in (PSY.Generator, PSY.InterruptiblePowerLoad, PSY.EnergyReservoirStorage), device in PSY.get_components(T, sys)
        name = PSY.get_name(device)
        name in required_names && !(name in non_scheduled) || continue
        is_non_scheduled_load(device) && continue
        required[name] = _required_bid_directions(device, coverage)
    end
    for row in eachrow(bids)
        row.DIRECTION in get(required, row.DUID, ()) || continue
        row.MAXAVAIL isa Real && isfinite(row.MAXAVAIL) && row.MAXAVAIL >= 0 || throw(
            ArgumentError(
                "incomplete energy bid MAXAVAIL for $(row.DUID) $(row.DIRECTION) at $(row.INTERVAL_DATETIME); " *
                    "repopulate BIDPEROFFER_D with populate(...; force_new = true)",
            ),
        )
    end
    for name in sort!(collect(keys(required))), direction in required[name]
        missing_intervals = setdiff(grid, get(coverage, (name, direction), Set{DateTime}()))
        isempty(missing_intervals) || throw(
            ArgumentError(
                "incomplete energy bid inputs for $name $direction: missing $(length(missing_intervals)) intervals, " *
                    "including $(first(missing_intervals)); repopulate BIDPEROFFER_D with populate(...; force_new = true)",
            ),
        )
    end
    return
end


export NEMDEConfiguration
