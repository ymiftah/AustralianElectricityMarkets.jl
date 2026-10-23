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
`use_slacks` does not apply to them.
"""
abstract type AbstractNEMDispatch <: PSI.AbstractDeviceFormulation end


"""
    NEMReplayDispatch

[`AbstractNEMDispatch`](@ref) whose ramp constraint measures against the device's `"initial_mw"`
time series at every interval. Intervals are decoupled.
"""
struct NEMReplayDispatch <: AbstractNEMDispatch end


"""
    RampUpRateTimeSeriesParameter

Time-series parameter for a device's `"ramp_up_rate"` series, in system-base per-unit per minute.
"""
struct RampUpRateTimeSeriesParameter <: PSI.TimeSeriesParameter end


"""
    RampDownRateTimeSeriesParameter

Time-series parameter for a device's `"ramp_down_rate"` series, in system-base per-unit per minute.
"""
struct RampDownRateTimeSeriesParameter <: PSI.TimeSeriesParameter end


"""
    InitialPowerTimeSeriesParameter

Time-series parameter for a device's `"initial_mw"` series, in system-base per-unit.
"""
struct InitialPowerTimeSeriesParameter <: PSI.TimeSeriesParameter end
