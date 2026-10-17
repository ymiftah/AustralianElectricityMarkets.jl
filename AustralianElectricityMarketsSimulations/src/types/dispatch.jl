"""
    AbstractNEMDispatch

Supertype for the NEM dispatch device formulations: a per-band bid stack, a per-interval ramp
limit, and separately priced bid-availability and UIGF constraints, applied to one active power
variable per device. A scheduled
load (`PowerSystems.ControllableLoad`) uses the same variable as consumed MW, priced on its
decremental offer and withdrawn from the area balance.

Methods are defined over `PowerSystems.StaticInjection`; a `PowerSimulations.ProblemTemplate`
selects the component types they apply to. Subtypes differ only in what the ramp constraint
measures against: [`NEMReplayDispatch`](@ref) and [`NEMLookaheadDispatch`](@ref).
"""
abstract type AbstractNEMDispatch <: PSI.AbstractDeviceFormulation end


"""
    NEMReplayDispatch

[`AbstractNEMDispatch`](@ref) whose ramp constraint measures against the device's `"initial_mw"`
time series at every interval. Intervals are decoupled.
"""
struct NEMReplayDispatch <: AbstractNEMDispatch end


"""
    NEMLookaheadDispatch

[`AbstractNEMDispatch`](@ref) whose ramp constraint measures against the `DevicePower` initial
condition at the first interval and the previous interval's `ActivePowerVariable` thereafter.
"""
struct NEMLookaheadDispatch <: AbstractNEMDispatch end


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

"Time-series parameter for the separate energy bid availability, in system-base per-unit."
struct EnergyMaxAvailTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Time-series parameter for a semi-scheduled unit's UIGF, in system-base per-unit."
struct EnergyUIGFTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Energy availability constraint with a priced surplus."
struct EnergyMaxAvailConstraint <: PSI.ConstraintType end

"Semi-scheduled UIGF constraint with a priced surplus."
struct EnergyUIGFConstraint <: PSI.ConstraintType end

"Non-negative energy availability violation, in system-base per-unit."
struct EnergyMaxAvailSlack <: PSI.VariableType end

"Non-negative UIGF violation, in system-base per-unit."
struct EnergyUIGFSlack <: PSI.VariableType end

"Energy availability CVP factor from AEMO's Schedule v8.0, Table 1 item 14."
const ENERGY_MAX_AVAIL_CVP_FACTOR = 370.0

"UIGF CVP factor from AEMO's Schedule v8.0, Table 1 item 12."
const ENERGY_UIGF_CVP_FACTOR = 385.0
