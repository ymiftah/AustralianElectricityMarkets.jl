# The replay input stage: each family's writer is called from `_set_replay_inputs!` in a fixed order.
include("replay_inputs/common.jl")
include("replay_inputs/energy_offers.jl")
include("replay_inputs/mnsp_fixed_loads.jl")
include("replay_inputs/dispatch_limits.jl")
include("replay_inputs/state_inputs.jl")
include("replay_inputs/fcas_effective.jl")
include("replay_inputs/tie_break.jl")
include("replay_inputs/loss_demand.jl")
include("replay_inputs/constraints.jl")
include("replay_inputs/prices.jl")
include("replay_inputs/forecasts.jl")


"""
    _set_replay_inputs!(sys::PSY.System) -> Nothing

Writes the replay input series derived from the built inputs of `sys`, in a fixed order. The first
writer adds the energy offer curves of each bidding device, one series per offer side, with the band
prices referred to the reference node by the side's loss factor. The second adds the fixed-loading
value and invocation series of each MNSP link direction, named by [`NEM_MNSP_FIXED_LOAD_SERIES`](@ref).
The third adds the dispatch ramp rates of each replay unit, named by [`NEM_SERIES`](@ref), and its AGC ramp
rates, named by `fcas_series_name("fcas_agc_ramp_rate", service)`. The fourth adds the observed starting output
of each replay unit and its fixed-loading target and invocation, named by [`NEM_STATE_INPUT_SERIES`](@ref). The
fifth adds the effective FCAS offers of each FCAS-bidding unit, named by [`fcas_effective_series_name`](@ref), and the
regulation ramping limits of each regulation market, named by [`fcas_ramping_series_name`](@ref), in per-unit of the
system base. It reads the AGC ramp rates the third writer added and the observed state the fourth added. The sixth
adds the tie-break scale of each price-tied energy band, named by [`tie_break_series_name`](@ref), and the
[`EnergyTieBreak`](@ref) service joining the units that carry an energy bid. It reads the energy offer curves the first
writer added. The seventh adds the demand term
of each loss-modelled interchange's loss factor, named by [`NEM_SERIES`](@ref), from the loads' `"loss_demand"` series
per unit of the system base. It reads the demand that [`set_demand!`](@ref) writes before the stage runs. The eighth
sets the constraints that cannot bind over the replay intervals unavailable, through
[`_set_constraint_availability!`](@ref). The ninth sets the band prices of each energy bid from the energy offer
series, through [`_set_band_prices!`](@ref). The tenth transforms the single time series of the system into five-minute
forecast windows, through [`_set_replay_forecasts!`](@ref). No series may be added after it.
Called by [`nem_system`](@ref) before its input checks.

# Arguments
- `sys`: the system built by [`nem_system`](@ref).

# Returns
`nothing`.
"""
function _set_replay_inputs!(sys::PSY.System)
    _set_referred_energy_offers!(sys)
    _set_mnsp_fixed_loads!(sys)
    _set_dispatch_limits!(sys)
    _set_observed_state_inputs!(sys)
    _set_fcas_effective_offers!(sys)
    _set_tie_break!(sys)
    _set_loss_demand_coefficients!(sys)
    _set_constraint_availability!(sys)
    _set_band_prices!(sys)
    _set_replay_forecasts!(sys)
    return
end
