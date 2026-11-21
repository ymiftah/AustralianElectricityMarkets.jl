# The NEMDE input stage: each family's writer is called from `_set_nemde_inputs!` in a fixed order.
include("nemde_inputs/common.jl")
include("nemde_inputs/energy_offers.jl")
include("nemde_inputs/mnsp_fixed_loads.jl")
include("nemde_inputs/dispatch_limits.jl")
include("nemde_inputs/state_inputs.jl")
include("nemde_inputs/fast_start.jl")
include("nemde_inputs/fcas_effective.jl")
include("nemde_inputs/tie_break.jl")
include("nemde_inputs/loss_demand.jl")
include("nemde_inputs/constraints.jl")
include("nemde_inputs/prices.jl")
include("nemde_inputs/forecasts.jl")
include("nemde_inputs/availability.jl")
include("nemde_inputs/closed_loop.jl")


"""
    _set_nemde_inputs!(sys::PSY.System) -> Nothing

Writes the NEMDE input series derived from the built inputs of `sys`, once and in a fixed order, after checking
that its single time series are at the five-minute dispatch interval. Called by [`nem_system`](@ref) before its input
checks. The writers, in order:

- `_set_referred_energy_offers!`: energy offer curves, band prices referred by the side's loss factor.
- `_set_mnsp_fixed_loads!`: MNSP fixed-loading value and invocation series ([`NEM_MNSP_FIXED_LOAD_SERIES`](@ref)).
- `_set_dispatch_limits!`: dispatch and AGC ramp rates ([`NEM_SERIES`](@ref)).
- `_set_observed_state_inputs!`: observed starting output and fixed-loading targets ([`NEM_STATE_INPUT_SERIES`](@ref)).
- `_set_fast_start_inputs!`: fast-start flag, starting mode and time in mode ([`NEM_FAST_START_SERIES`](@ref)).
- `_set_fcas_effective_offers!`: effective FCAS offers and regulation ramping limits.
- `_set_tie_break!`: tie-break scales ([`tie_break_series_name`](@ref)) and the [`EnergyTieBreak`](@ref) service.
- `_set_loss_demand_coefficients!`: loss-factor demand terms of the loss-modelled interchanges.
- `_set_constraint_availability!`: marks constraints that cannot bind unavailable.
- `_set_band_prices!`: band prices of each energy, FCAS and MNSP bid.
- `_set_nemde_forecasts!`: transforms the single series into five-minute forecast windows; no series may be added after.
- `_set_nemde_availability!`: records the unavailable devices and services the inputs were derived for.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
`nothing`. Throws `ArgumentError` when a single time series of `sys` is not at the dispatch interval.
"""
function _set_nemde_inputs!(sys::PSY.System)
    _check_nemde_resolution(sys)
    _set_referred_energy_offers!(sys)
    _set_mnsp_fixed_loads!(sys)
    _set_dispatch_limits!(sys)
    _set_observed_state_inputs!(sys)
    _set_fast_start_inputs!(sys)
    _set_fcas_effective_offers!(sys)
    _set_tie_break!(sys)
    _set_loss_demand_coefficients!(sys)
    _set_constraint_availability!(sys)
    _set_band_prices!(sys)
    _set_nemde_forecasts!(sys)
    _set_nemde_availability!(sys)
    return
end
