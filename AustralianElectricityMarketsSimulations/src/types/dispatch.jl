"""
    AbstractNEMDispatch

Supertype for the NEM dispatch device formulations: a per-band bid stack, a per-interval ramp
limit, and separately priced energy availability limits, applied to one active power variable per device. A scheduled
load (`PowerSystems.ControllableLoad`) uses the same variable as consumed MW, priced on its
decremental offer and withdrawn from the area balance.

Methods are defined over `PowerSystems.StaticInjection`; a `PowerSimulations.ProblemTemplate`
selects the component types they apply to. Subtypes differ only in what the ramp constraint
measures against; [`NEMReplayDispatch`](@ref) is the one subtype. Ramp,
availability, offer-total and fixed-loading rows always carry priced slacks; the device model's
`use_slacks` does not apply to them. The energy offer cost and the slack penalties are objective terms
only; no `PowerSimulations` cost expression is built, and slack penalties are reported as violation
rows of a replay's results rather than as device cost.
"""
abstract type AbstractNEMDispatch <: PSI.AbstractDeviceFormulation end


"""
    NEMReplayDispatch

[`AbstractNEMDispatch`](@ref) whose ramp constraint measures against the device's initial MW at every
interval, read from the observed state series `NEM_STATE_INPUT_SERIES`. Intervals are decoupled.
"""
struct NEMReplayDispatch <: AbstractNEMDispatch end


"""
    RampRateTimeSeriesParameter

Time-series parameter for a device's ramp-rate series, in system-base per-unit per minute. The key
meta names the direction: `"up"` reads the `"ramp_up_rate"` series, `"down"` the `"ramp_down_rate"` series.
"""
struct RampRateTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Direction tag of the `\"up\"` [`RampRateTimeSeriesParameter`](@ref)."
struct RampUp end

"Direction tag of the `\"down\"` [`RampRateTimeSeriesParameter`](@ref)."
struct RampDown end

# The key meta of each ramp direction.
_ramp_meta(::RampUp) = "up"
_ramp_meta(::RampDown) = "down"


# The `NEMDispatchInputs` field holding each direction's series key.
_ramp_input_field(::RampUp) = :ramp_up
_ramp_input_field(::RampDown) = :ramp_down

# The series each direction reads on a device.
_ramp_series_name(::RampUp) = NEM_SERIES.ramp_up_rate
_ramp_series_name(::RampDown) = NEM_SERIES.ramp_down_rate


"""
    InitialPowerTimeSeriesParameter

Time-series parameter for a device's `"initial_mw_seed"` series, in MW; the parameter's multiplier
converts it to system-base per unit.
"""
struct InitialPowerTimeSeriesParameter <: PSI.TimeSeriesParameter end
