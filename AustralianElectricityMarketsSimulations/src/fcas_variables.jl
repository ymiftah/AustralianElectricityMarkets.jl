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

`t` indexes the trapezium series itself (`1:length(series)`), not `model`'s own dispatch time
steps: `model`'s network/device formulations run at whatever resolution its `DecisionModel` was
built with (e.g. an hourly economic-dispatch grid, `PowerSystems` requires one common resolution
per `DecisionModel`), which need not match the 5-minute resolution NEMWEB publishes FCAS bids
at. This function is pure post-build augmentation - it adds free-standing variables to the JuMP
model via `PSI.get_jump_model`, not a `PSI.AbstractDeviceFormulation` wired into `model`'s
existing constraints - so no time-axis reconciliation between the two grids is needed yet; that
is deferred to whichever later milestone actually couples FCAS capacity to energy dispatch.

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
capacity variables in trapezium-series order.
"""
function add_fcas_variables!(model::PSI.DecisionModel, sys::PSY.System)
    jump_model = PSI.get_jump_model(model)
    variables = Dict{Tuple{String, String}, Vector{JuMP.VariableRef}}()
    for bid_type in AustralianElectricityMarkets.FCAS_BID_TYPES
        service = string(bid_type)
        series_name = "fcas_trapezium_$(service)"
        for comp in PSY.get_components(PSY.Device, sys)
            PSY.has_time_series(comp, PSY.Deterministic, series_name) || continue
            duid = PSY.get_name(comp)
            rows = first(values(PSY.get_data(PSY.get_time_series(PSY.Deterministic, comp, series_name))))
            vars = Vector{JuMP.VariableRef}(undef, length(rows))
            for (t, row) in enumerate(rows)
                max_avail = row[5]
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
