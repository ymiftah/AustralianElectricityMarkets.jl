"""
    table_requirements(::NEMDEConfiguration)

Returns the regional network tables plus the price, FCAS requirement, constraint, interconnector loss,
MNSP offer and metered-flow tables needed for replay. `DISPATCHINTERCONNECTORRES` is required for MNSP
ramping even when published interval flow limits are not attached.

# Returns
A vector of NEMWEB table symbols.
"""
function AustralianElectricityMarkets.table_requirements(::NEMDEConfiguration)
    return [
        table_requirements(RegionalNetworkConfiguration())...,
        :DISPATCHPRICE,
        # Both generations of the dispatch FCAS requirement table: DISPATCH_FCAS_REQ covers up
        # to the 2025-05 archive month, DISPATCH_FCAS_REQ_CONSTRAINT from 2025-06 on. A cache
        # holding only one still builds - readers union whichever are present.
        :DISPATCH_FCAS_REQ,
        :DISPATCH_FCAS_REQ_CONSTRAINT,
        :DISPATCHCONSTRAINT,
        :GENCONDATA,
        :SPDCONNECTIONPOINTCONSTRAINT,
        :SPDREGIONCONSTRAINT,
        :SPDINTERCONNECTORCONSTRAINT,
        :LOSSMODEL, :LOSSFACTORMODEL, :MNSP_INTERCONNECTOR, :MNSP_DAYOFFER,
        :MNSP_BIDOFFERPERIOD, :DISPATCH_MNSPBIDTRK, :DISPATCHINTERCONNECTORRES,
    ]
end


"""
    nem_system(db, ::NEMDEConfiguration; date_range, intervention = 0,
        interval_flow_limits = false, time_series_in_memory = true, time_series_directory = nothing)

Builds a constrained system populated with demand, energy and FCAS bids, unit conditions,
interconnector losses and MNSP offers as single time series. Every unit registered at any
interval of `date_range` is built for the whole range; outside its registration it has zero
availability and offers nothing. A missing input inside a registration is an error.

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
    # 1. Validate the inputs
    (step(date_range) == Minute(5) && length(date_range) >= 2) || throw(
        ArgumentError("NEMDEConfiguration: the date range must step by 5 minutes over at least two stamps, got $date_range."),
    )
    resolution = Minute(5)

    # 2. Check the required tables are cached
    _check_required_tables_cached(db)

    # 3. Base network: every unit registered during the range
    storage = isnothing(time_series_directory) ? (;) : (; time_series_directory)
    sys, units = nem_network(db; as_of = first(date_range), through = last(date_range) - resolution, time_series_in_memory, storage...)

    # 4. Units, bids and services
    (; dispatch, demand) = _nemde_energy_bids_with_coverage(sys, db, date_range, units; intervention, resolution)
    set_market_bids!(sys, db, date_range; resolution)
    set_unit_conditions!(sys, db, date_range; intervention)
    add_nem_constraints!(sys, db, date_range; intervention)
    attach_interconnector_losses!(sys, db, first(date_range))

    # 5. Time series
    set_demand!(sys, demand, date_range; resolution)
    set_loss_demand_coefficients!(sys)
    set_mnsp_offers!(sys, db, date_range; intervention)
    interval_flow_limits && set_interconnector_flow_limits!(sys, db, date_range; intervention)

    # 6. Validate the built inputs
    AustralianElectricityMarkets._check_nemde_replay_inputs(sys)
    return sys
end


# Checks that every required table of `NEMDEConfiguration` has a cached partition, and that at least
# one of the two FCAS requirement tables does. Does not check the date range.
function _check_required_tables_cached(db)
    fcas_requirements = (:DISPATCH_FCAS_REQ, :DISPATCH_FCAS_REQ_CONSTRAINT)
    for table in table_requirements(NEMDEConfiguration())
        table in fcas_requirements && continue
        AustralianElectricityMarkets._require_cached(db, table)
    end
    any(table -> AustralianElectricityMarkets._table_is_cached(db, table), fcas_requirements) || throw(
        ArgumentError("NEMDEConfiguration needs DISPATCH_FCAS_REQ or DISPATCH_FCAS_REQ_CONSTRAINT cached."),
    )
    return
end


# The `DIRECTION`s `device` must offer energy on ([`energy_offer_sides`](@ref)), given the offered
# `(DUID, DIRECTION)` keys of `coverage`.
_required_bid_directions(device, coverage) = string.(energy_offer_sides(device))
# A wholesale demand response unit bids GEN only; every other scheduled load, including one with no
# period offer at all, is required on LOAD.
_required_bid_directions(device::PSY.ControllableLoad, coverage) =
    haskey(coverage, (PSY.get_name(device), "GEN")) ? ("GEN",) : string.(energy_offer_sides(device))


"""
    _nemde_energy_bids_with_coverage(sys, db, date_range, units; intervention = 0, resolution = Minute(5))

Verifies the cached bids and demand cover every interval of `date_range` (its last stamp
excluded). Every region with a unit (`DUDETAILSUMMARY`) needs regional demand (`DISPATCHREGIONSUM`)
at every interval. Every scheduled unit of `sys` that bids energy (`BIDPEROFFER_D`), or is
available or metered in `DISPATCHLOAD`, needs an energy period offer with a finite non-negative
`MAXAVAIL` at every interval of its registration (its [`NEMRegistration`](@ref) on `sys`),
read independently of the price join with `BIDDAYOFFER_D`.
Non-scheduled units and loads are not checked.

# Arguments
- `sys`: the `PSY.System` whose units are checked.
- `db`: an `AEMDB` connection.
- `date_range`: the replay range.
- `units`: the unit table over `date_range`, as [`nem_network`](@ref) returns it; its regions need demand.
- `intervention`: the `DISPATCHLOAD` run, 0 for pricing and 1 for physical.
- `resolution`: the spacing of the dispatch intervals that `DISPATCHLOAD` and regional demand are aggregated to.

# Returns
A named tuple `(; dispatch, demand)` of the read inputs. Throws an `ArgumentError` naming
the first unit and direction, or region, missing an input.
"""
function _nemde_energy_bids_with_coverage(sys, db, date_range, units; intervention::Integer = 0, resolution = Minute(5))
    bids = read_energy_bids(db, date_range)
    dispatch = read_dispatch_limits(db, date_range; intervention, resolution)
    demand = read_demand(db, date_range; resolution)
    _check_nemde_energy_bid_coverage(sys, bids, dispatch, units, demand, date_range)
    return (; dispatch, demand)
end


function _check_nemde_energy_bid_coverage(sys, bids, dispatch, units, demand, date_range)
    demand_stamps = Set(zip(demand.REGIONID, demand.SETTLEMENTDATE))
    grid = collect(date_range)[1:(end - 1)]
    missing_demand = [(region, t) for region in sort!(unique(units.REGIONID)), t in grid if !((region, t) in demand_stamps)]
    isempty(missing_demand) || throw(
        ArgumentError(
            "missing regional demand inputs: $(join(string.(first(missing_demand, 5)), ", ")); " *
                "repopulate DISPATCHREGIONSUM with populate(...; force_new = true)",
        ),
    )
    required_names = Set(bids.DUID)
    for row in eachrow(dispatch)
        available = !ismissing(row.AVAILABILITY) && row.AVAILABILITY > 0
        metered = !ismissing(row.INITIALMW) && !iszero(row.INITIALMW)
        (available || metered) && push!(required_names, row.DUID)
    end
    required = Dict{String, Tuple{Vararg{String}}}()
    registrations = Dict{String, NEMRegistration}()
    coverage = Dict{Tuple{String, String}, Set{DateTime}}()
    for row in eachrow(bids)
        push!(get!(coverage, (row.DUID, row.DIRECTION), Set{DateTime}()), row.INTERVAL_DATETIME)
    end
    for T in (PSY.Generator, PSY.ControllableLoad, PSY.Storage), device in PSY.get_components(T, sys)
        name = PSY.get_name(device)
        name in required_names || continue
        registration = get_registration(device)
        registration.schedule_type == ScheduleType.NON_SCHEDULED && continue
        is_non_scheduled_load(device) && continue
        required[name] = _required_bid_directions(device, coverage)
        registrations[name] = registration
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
        expected = filter(t -> AustralianElectricityMarkets._is_registered(registrations[name], t), grid)
        missing_intervals = setdiff(expected, get(coverage, (name, direction), Set{DateTime}()))
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
