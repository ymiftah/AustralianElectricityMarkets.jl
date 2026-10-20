"""
    _check_replay_system_inputs(sys)

Verifies that `sys` carries every input the replay template depends on, from the records of the
setters that built it: [`get_missing_constraint_intervals`](@ref), [`get_defaulted_constraint_weights`](@ref),
[`get_skipped_constraints`](@ref) and [`get_dropped_terms`](@ref) of [`add_nem_constraints!`](@ref)
(`DISPATCHCONSTRAINT`, `GENCONDATA`, `SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`,
`SPDINTERCONNECTORCONSTRAINT`), the dispatch-limit series of [`set_nem_dispatch_limits!`](@ref)
(`DISPATCHLOAD`) on every dispatch device, and the offers of `set_mnsp_offers!`
(`INTERCONNECTORCONSTRAINT`, `MNSP_INTERCONNECTOR`, `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD`,
`DISPATCH_MNSPBIDTRK`) on every available MNSP.

# Arguments
- `sys`: the `PSY.System` to check.

# Returns
`nothing`. Throws an `ArgumentError` naming the first incomplete input and how to supply it.
"""
function _check_replay_system_inputs(sys::PSY.System)
    missing_intervals = get_missing_constraint_intervals(sys)
    isempty(missing_intervals) || throw(
        ArgumentError(
            "replication_template: missing dispatch constraint intervals: $(join(string.(missing_intervals), ", ")); " *
                "populate DISPATCHCONSTRAINT for the requested range",
        ),
    )
    defaulted_weights = get_defaulted_constraint_weights(sys)
    isempty(defaulted_weights) || throw(
        ArgumentError(
            "replication_template: constraints with a NULL GENERICCONSTRAINTWEIGHT: $(join(defaulted_weights, ", ")); " *
                "repopulate GENCONDATA with populate(...; force_new = true)",
        ),
    )
    skipped_inputs = get_skipped_constraints(sys)
    isempty(skipped_inputs) || throw(
        ArgumentError(
            "replication_template: incomplete constraint inputs: $(join(skipped_inputs.constraint, ", ")); see " *
                "get_skipped_constraints(sys) for the missing definitions and keys, and repopulate GENCONDATA and the " *
                "SPD*CONSTRAINT tables with populate(...; force_new = true)",
        ),
    )
    dropped_inputs = get_dropped_terms(sys)
    isempty(dropped_inputs) || throw(
        ArgumentError(
            "replication_template: incomplete constraint terms: " *
                "$(join(dropped_inputs.constraint .* ": " .* dropped_inputs.key, ", ")); see get_dropped_terms(sys), and " *
                "build sys with every unit its constraints name",
        ),
    )
    uncovered = [
        PSY.get_name(device) for device in AustralianElectricityMarkets._nem_dispatch_devices(sys)
            if !_has_nem_dispatch_limits(device, NEMReplayDispatch)
    ]
    isempty(uncovered) || throw(
        ArgumentError(
            "replication_template: incomplete dispatch inputs for $(join(sort!(uncovered), ", ")); " *
                "call set_nem_dispatch_limits! over the replay range before replay",
        ),
    )
    foreach(_check_mnsp_offers, PSY.get_components(PSY.get_available, PSY.AreaInterchange, sys))
    return
end


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
        device isa PSY.InterruptiblePowerLoad && AustralianElectricityMarkets._is_non_scheduled_load(device) && continue
        required[name] = if device isa PSY.Storage
            ("GEN", "LOAD")
        elseif device isa PSY.InterruptiblePowerLoad
            # A wholesale demand response unit bids GEN only; every other scheduled load,
            # including one with no period offer at all, is required on LOAD.
            haskey(coverage, (name, "GEN")) ? ("GEN",) : ("LOAD",)
        else
            ("GEN",)
        end
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


"""
    _check_mnsp_offers(device)

Verifies that `device` carries either none or all four of the links' offer and availability series
of `set_mnsp_offers!`, and all four when it is an MNSP (`ext["ic_type"] == "MNSP"`), since a partial
set cannot be modelled.

# Arguments
- `device`: the `PSY.AreaInterchange` to check.

# Returns
`nothing`. Throws an `ArgumentError` naming `device` otherwise.
"""
function _check_mnsp_offers(device::PSY.AreaInterchange)
    present = _mnsp_offer_series_present(device)
    required = get(PSY.get_ext(device), "ic_type", nothing) == "MNSP"
    (required || any(present)) && !all(present) && throw(
        ArgumentError(
            "AreaInterchange $(PSY.get_name(device)) is an MNSP with incomplete directional offer inputs; " *
                "call set_mnsp_offers! with complete data before dispatch",
        ),
    )
    return
end
