import Dates
import PowerSimulations as PSI
import PowerSystems as PSY

"""
    add_fcas_variables!(model::PSI.DecisionModel, sys::PSY.System)

Adds one non-negative JuMP decision variable per (unit, FCAS service, timestep) directly to
`model`'s already-built JuMP model (`PSI.get_jump_model(model)`), for each of the eight NEM
FCAS services in `AustralianElectricityMarkets.FCAS_BID_TYPES` (`RAISE6SEC`, `LOWER6SEC`,
`RAISE60SEC`, `LOWER60SEC`, `RAISE5MIN`, `LOWER5MIN`, `RAISEREG`, `LOWERREG`). A unit gets a
variable for a service only if it carries that service's `"fcas_trapezium_<SERVICE>"`
`Deterministic` series (attached by [`set_fcas_bids!`](@ref)); the variable's upper bound at
each timestep is that series' `max_avail` (element 5 of the packed `NTuple{7,Float64}` row -
see [`set_fcas_bids!`](@ref)'s docstring for the full layout). Lower bound is `0.0`.

`t` indexes `model`'s own dispatch timesteps (`PSI.get_timestamps(model)`), not the trapezium
series' raw row order: for each model timestep, the matching trapezium row is looked up by
absolute timestamp against the series' own declared initial timestamp and resolution
(`PSY.get_data`/`PSY.get_resolution`), not by positional index. This is the reconciliation a
disjoint-grid predecessor of this function deferred; it now requires the trapezium series and
`model` to share a common time origin (as the PSCB NEMWEB test fixture does, keyed to the same
t0 as `augmented_pscb_system()`'s own forecast - its resolution need not also match, only every
model timestep's offset from that shared t0 must be an exact multiple of the trapezium series'
own resolution). A model timestep with no exactly-matching trapezium row - off the series' grid
entirely, or falling between two of its points - is a real data problem, so it throws rather
than silently skipping or misaligning.

**Decremental variables are out of scope here.** `EnergyReservoirStorage` units can carry a
second series per service, `"fcas_trapezium_<SERVICE>_decremental"` (load-direction bidding,
see [`set_fcas_bids!`](@ref)); this function never looks at those series, so no decremental
variable is ever created, for `EnergyReservoirStorage` or anything else. Deferred rather than
added now: a decremental unit's incremental and decremental capacity share one piece of physical
headroom, and expressing that coupling is exactly the kind of formulation logic this
post-build-augmentation step is deliberately avoiding.

# Arguments
- `model`: a `PowerSimulations.jl` `DecisionModel`, already built (`PSI.build!(model)`).
- `sys`: the `PowerSystems.System` `model` was built from - the same instance, so the
  `fcas_trapezium_<SERVICE>` series read here are the ones actually attached to `model`.

# Returns
`Dict{Tuple{String, String}, Vector{JuMP.VariableRef}}`, keyed by `(DUID, service)` (`service`
the `string` of the `BidType`, e.g. `"RAISE6SEC"`), each value the unit's per-timestep FCAS
capacity variables in `model` dispatch-timestep order (`PSI.get_timestamps(model)`).
"""
function add_fcas_variables!(model::PSI.DecisionModel, sys::PSY.System)
    jump_model = PSI.get_jump_model(model)
    timestamps = PSI.get_timestamps(model)
    variables = Dict{Tuple{String, String}, Vector{JuMP.VariableRef}}()
    for bid_type in AustralianElectricityMarkets.FCAS_BID_TYPES
        service = string(bid_type)
        series_name = "fcas_trapezium_$(service)"
        for comp in PSY.get_components(PSY.Device, sys)
            PSY.has_time_series(comp, PSY.Deterministic, series_name) || continue
            duid = PSY.get_name(comp)
            ts_data = PSY.get_time_series(PSY.Deterministic, comp, series_name)
            resolution_ms = Dates.value(Dates.Millisecond(PSY.get_resolution(ts_data)))
            data = PSY.get_data(ts_data)
            series_start = first(keys(data))
            rows = first(values(data))
            vars = Vector{JuMP.VariableRef}(undef, length(timestamps))
            for (t, timestamp) in enumerate(timestamps)
                offset_ms = Dates.value(Dates.Millisecond(timestamp - series_start))
                idx, rem = divrem(offset_ms, resolution_ms)
                if rem != 0 || idx < 0 || idx + 1 > length(rows)
                    error(
                        "add_fcas_variables!: no fcas_trapezium_$(service) value for $(duid) " *
                            "at model timestep $(timestamp) (series starts $(series_start), " *
                            "resolution $(PSY.get_resolution(ts_data)), $(length(rows)) rows)",
                    )
                end
                max_avail = rows[idx + 1][5]
                vars[t] = JuMP.@variable(
                    jump_model,
                    lower_bound = 0.0,
                    upper_bound = max_avail,
                    base_name = "FCAS_$(service)_$(duid)_$(t)",
                )
            end
            variables[(duid, service)] = vars
        end
    end
    return variables
end
