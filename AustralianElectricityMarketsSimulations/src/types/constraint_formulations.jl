"""
    AbstractNEMConstraintFormulation

Shared trait ancestor for formulations that drive a [`GenericConstraint`](@ref) through
`PowerSimulations.jl`'s `ServiceModel` machinery, mirroring `PowerSimulations.jl`'s own
`AbstractReservesFormulation`.
"""
abstract type AbstractNEMConstraintFormulation <: PSI.AbstractServiceFormulation end


"""
    NEMConstraintLHS

Expression type for a [`GenericConstraint`](@ref)'s accumulated affine left-hand side,
`Σ FACTOR·variable`.
"""
struct NEMConstraintLHS <: PSI.ExpressionType end


"""
    NEMConstraintLimit

Constraint type bounding a [`GenericConstraint`](@ref)'s [`NEMConstraintLHS`](@ref) expression
against its replayed right-hand side.
"""
struct NEMConstraintLimit <: PSI.ConstraintType end


"""
    NEMConstraintRHSParameter

Time-series parameter type for a [`GenericConstraint`](@ref)'s right-hand side, fed from its
`"rhs"` time series.
"""
struct NEMConstraintRHSParameter <: PSI.TimeSeriesParameter end


"""
    LinearFactorLimit

Formulation for a [`GenericConstraint`](@ref): assembles [`NEMConstraintLHS`](@ref) from the
constraint's own stored terms and bounds it against [`NEMConstraintRHSParameter`](@ref) with a
[`NEMConstraintLimit`](@ref).
"""
struct LinearFactorLimit <: AbstractNEMConstraintFormulation end


"""
    FCASMarket

Formulation for an [`FCASService`](@ref), co-optimising FCAS capacity alongside energy.
"""
struct FCASMarket <: PSI.AbstractServiceFormulation end


"""
    FCASCapacityVariable

Variable type for a contributing device's enabled FCAS capacity in one [`FCASService`](@ref),
bounded above by the device's `MAXAVAIL` for that market and interval. For a `PSY.Storage`
device bidding a regulation market on both sides, this is not used; see
[`FCASSideCapacityVariable`](@ref)/[`FCASUnitRegulationTarget`](@ref).
"""
struct FCASCapacityVariable <: PSI.VariableType end


"""
    FCASSideCapacityVariable

Variable type for one side (named `"<service>_gen"`/`"<service>_load"` in its container key) of
a `PSY.Storage` device's regulation capacity, when it bids that market on both the generation
and load sides, bounded above by that side's own scaled `MAXAVAIL`.
"""
struct FCASSideCapacityVariable <: PSI.VariableType end


"""
    FCASUnitRegulationTarget

Expression type for a device's total regulation FCAS target in one [`FCASService`](@ref), per
`(device, t)`: [`FCASCapacityVariable`](@ref) for a device bidding one side, or the sum of both
[`FCASSideCapacityVariable`](@ref)s for a `PSY.Storage` device bidding both sides. This is what
AEMO *FCAS Model in NEMDE* §6.2's joint capacity constraint, the [`FCASBDURampingConstraint`](@ref)
and the [`FCASJointRampingConstraint`](@ref) read as "Raise Regulation FCAS Target"/"Lower
Regulation FCAS Target".
"""
struct FCASUnitRegulationTarget <: PSI.ExpressionType end


"""
    FCASJointCapacityLHS

Expression type for one side (named `"<service>_upper"`/`"<service>_lower"` in its container
key, or `"<service>_gen_upper"`/`"<service>_gen_lower"`/`"<service>_load_upper"`/
`"<service>_load_lower"` for a `PSY.Storage` device bidding a regulation market on both sides)
of the AEMO *FCAS Model in NEMDE* §6.2/§6.3 joint capacity constraint's left-hand side, per
`(device, t)`: energy dispatch and any matching regulation term. The service's own trapezium slope
term is added in the [`FCASJointCapacityConstraint`](@ref) row, with its coefficient driven by
[`FCASUpperSlopeParameter`](@ref) or [`FCASLowerSlopeParameter`](@ref).
"""
struct FCASJointCapacityLHS <: PSI.ExpressionType end


"""
    FCASOfferBandVariable

One band of a contributing device's FCAS offer at one timestep, non-negative and per-unit of the
system base. Indexed `(device name, band label, t)` with the meta of the capacity variable it sums
to: the service name, or `"<service>_gen"`/`"<service>_load"` for a `PSY.Storage` device's two
regulation sides. The band axis is sized to the most bands any of those offers has over the
system's series; a band an offer does not have at an interval has zero width.
"""
struct FCASOfferBandVariable <: PSI.VariableType end


"""
    FCASOfferLimitParameter

Time-series parameter of a device's effective FCAS offer limits for one market and side, read from
its `"fcas_effective_<BIDTYPE>[_decremental]"` series ([`set_fcas_effective_offers!`](@ref)), per-unit
of the system base, with a field axis `"max_avail"`, `"enablement_min"`, `"enablement_max"`. Keyed by
device type with meta `"<BIDTYPE>[_decremental]"`.
"""
struct FCASOfferLimitParameter <: PSI.TimeSeriesParameter end


"""
    FCASBandWidthParameter

Time-series parameter of a device's effective FCAS offer band widths for one market and side, read
from its `"fcas_effective_<BIDTYPE>[_decremental]"` series, per-unit of the system base, with a band
axis `"1"` to `"10"` ([`FCAS_BAND_COUNT`](@ref)). Keyed by device type with meta `"<BIDTYPE>[_decremental]"`.
"""
struct FCASBandWidthParameter <: PSI.TimeSeriesParameter end


"""
    FCASUpperSlopeParameter

Constraint-coefficient parameter of a device's effective FCAS `UpperSlopeCoeff` for one market and
side, the coefficient of its FCAS capacity in the upper [`FCASJointCapacityConstraint`](@ref) row,
read from its `"fcas_effective_<BIDTYPE>[_decremental]"` series. Keyed by device type with meta
`"<BIDTYPE>[_decremental]"`.
"""
struct FCASUpperSlopeParameter <: PSI.ConstraintCoefficientParameter end


"""
    FCASLowerSlopeParameter

Constraint-coefficient parameter of a device's effective FCAS `LowerSlopeCoeff` for one market and
side, the negated coefficient of its FCAS capacity in the lower [`FCASJointCapacityConstraint`](@ref)
row, read from its `"fcas_effective_<BIDTYPE>[_decremental]"` series. Keyed by device type with meta
`"<BIDTYPE>[_decremental]"`.
"""
struct FCASLowerSlopeParameter <: PSI.ConstraintCoefficientParameter end


"""
    FCASRampingLimitParameter

Time-series parameter of a device's regulation ramping limits for one regulation market, read from
its `"fcas_ramping_limits_<BIDTYPE>"` series ([`set_fcas_effective_offers!`](@ref)), per-unit of the
system base, with a field axis `"joint_ramping"` ([`FCASJointRampingConstraint`](@ref) right-hand
side) and `"bdu_ramping"` ([`FCASBDURampingConstraint`](@ref) right-hand side). Keyed by device type
with meta `"<BIDTYPE>"`.
"""
struct FCASRampingLimitParameter <: PSI.TimeSeriesParameter end


"""
    FCASBandPriceParameter

Objective-function parameter pricing [`FCASOfferBandVariable`](@ref)s: its value is each band's
offer price in `\$/MW` per hour (`0.0` for a band not offered) and its multiplier the system base
power times the interval length in hours. Same meta as the band variables it prices.
"""
struct FCASBandPriceParameter <: PSI.ObjectiveFunctionParameter end


"""
    FCASJointCapacityConstraint

Constraint type for one side (named `"<service>_upper"`/`"<service>_lower"` in its container
key, or `"<service>_gen_upper"`/`"<service>_gen_lower"`/`"<service>_load_upper"`/
`"<service>_load_lower"` for a `PSY.Storage` device bidding a regulation market on both sides)
of the AEMO *FCAS Model in NEMDE* §6.2/§6.3 joint capacity constraint, bounding a device's
[`FCASJointCapacityLHS`](@ref) against its FCAS trapezium's enablement window.
"""
struct FCASJointCapacityConstraint <: PSI.ConstraintType end


"""
    FCASBDURampingConstraint

Constraint type for AEMO *FCAS Model in NEMDE* §6.4's BDU regulating FCAS SCADA ramping
constraint, bounding a `PSY.Storage` device's [`FCASUnitRegulationTarget`](@ref) in one
regulation [`FCASService`](@ref) against the device's SCADA ramping capability.
"""
struct FCASBDURampingConstraint <: PSI.ConstraintType end


"""
    FCASMaxAvailConstraint

Constraint type for AEMO's FCAS MaxAvail limit (the effective `MaxAvail` of a service's trapezium,
[`FCASOfferLimitParameter`](@ref)), built as a row on [`FCASCapacityVariable`](@ref) or
[`FCASSideCapacityVariable`](@ref) per `(device, t)`, named `"<service>_maxavail"` or
`"<service>_gen_maxavail"`/`"<service>_load_maxavail"` in its container key. The row is elastic
when the owning `PSI.ServiceModel` has `use_slacks = true`.
"""
struct FCASMaxAvailConstraint <: PSI.ConstraintType end


"""
    FCASMaxAvailSlack

Variable type for the elastic slack on an [`FCASMaxAvailConstraint`](@ref) row, built only when
the owning `PSI.ServiceModel` has `use_slacks = true`. Priced at
[`FCAS_MAXAVAIL_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct FCASMaxAvailSlack <: PSI.VariableType end


"""
    FCASBDURampingSlack

Variable type for the elastic slack on a [`FCASBDURampingConstraint`](@ref) row, built only when
the owning `PSI.ServiceModel` has `use_slacks = true`. Priced at
[`FCAS_BDU_RAMPING_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct FCASBDURampingSlack <: PSI.VariableType end


"""
    GenericConstraintSlackUp

Variable type for the elastic slack absorbing a [`GenericConstraint`](@ref)'s left-hand side
above its right-hand side limit, built only when [`LinearFactorLimit`](@ref)'s `sense` is `LE`
or `EQ` and the owning `PSI.ServiceModel` has `use_slacks = true`. Merged into
[`NEMConstraintLHS`](@ref) with multiplier `-1.0`.
"""
struct GenericConstraintSlackUp <: PSI.VariableType end


"""
    GenericConstraintSlackDown

Variable type for the elastic slack absorbing a [`GenericConstraint`](@ref)'s left-hand side
below its right-hand side limit, built only when [`LinearFactorLimit`](@ref)'s `sense` is `GE`
or `EQ` and the owning `PSI.ServiceModel` has `use_slacks = true`. Merged into
[`NEMConstraintLHS`](@ref) with multiplier `+1.0`.
"""
struct GenericConstraintSlackDown <: PSI.VariableType end


"""
    GenericConstraintSlackCostParameter

Objective-function parameter pricing a [`GenericConstraint`](@ref)'s elastic slacks: its value is
the constraint's `"invoked"` mask (`1.0`/`0.0`) per interval and its multiplier the violation
penalty, `GENERICCONSTRAINTWEIGHT` times the Market Price Cap per MW of one interval, so a
non-invoked interval's slack costs nothing.
"""
struct GenericConstraintSlackCostParameter <: PSI.ObjectiveFunctionParameter end


"""
    MarketPriceCapPenaltyParameter

Objective-function parameter that re-prices every Market Price Cap penalty slack recorded by
`_add_mpc_penalty!` at each simulation step, each interval at its own Market Price Cap, so a
model built once follows the cap across a financial year boundary. Registered on the `PSY.Area`
components of the area balance.
"""
struct MarketPriceCapPenaltyParameter <: PSI.ObjectiveFunctionParameter end


"""
    FCASJointRampingConstraint

Constraint type for AEMO *FCAS Model in NEMDE* §6.1's joint ramping constraint, bounding a
contributing device's net energy dispatch combined with its [`FCASUnitRegulationTarget`](@ref) in
one regulation [`FCASService`](@ref) against its telemetered AGC ramp from `InitialMW`.
"""
struct FCASJointRampingConstraint <: PSI.ConstraintType end


"""
    FCASJointCapacitySlack

Variable type for the elastic slack on a [`FCASJointCapacityConstraint`](@ref) row (AEMO
`xxUpperDeficit`/`xxLowerSurplus`), built when the owning `PSI.ServiceModel` has
`use_slacks = true`. Priced at [`FCAS_CAPACITY_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct FCASJointCapacitySlack <: PSI.VariableType end


"""
    FCASJointRampingSlack

Variable type for the elastic slack on a [`FCASJointRampingConstraint`](@ref) row (AEMO
`R5REJointRampDeficit`/`L5REJointRampDeficit`), built when the owning `PSI.ServiceModel` has
`use_slacks = true`. Priced at [`FCAS_RAMPING_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct FCASJointRampingSlack <: PSI.VariableType end


"""
    UnitRampUpSlack

Variable type for the elastic slack on the up row of a `PSI.RampConstraint` (`meta = "up"`) under an
[`AbstractNEMDispatch`](@ref) formulation, in the units of the active power variable.
"""
struct UnitRampUpSlack <: PSI.VariableType end


"""
    UnitRampDownSlack

Variable type for the elastic slack on the down row of a `PSI.RampConstraint` (`meta = "down"`)
under an [`AbstractNEMDispatch`](@ref) formulation, in the units of the active power variable.
"""
struct UnitRampDownSlack <: PSI.VariableType end


"""
    InterconnectorFlowSurplusSlack

Variable type for the elastic slack on an interconnector's upper flow limit (AEMO's
`FlowSurplus`), per `(interconnector, t)` in MW per-unit of the system base. Priced at
[`INTERCONNECTOR_FLOW_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct InterconnectorFlowSurplusSlack <: PSI.VariableType end


"""
    InterconnectorFlowDeficitSlack

Variable type for the elastic slack on an interconnector's lower flow limit (AEMO's
`FlowDeficit`), per `(interconnector, t)` in MW per-unit of the system base. Priced at
[`INTERCONNECTOR_FLOW_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct InterconnectorFlowDeficitSlack <: PSI.VariableType end
