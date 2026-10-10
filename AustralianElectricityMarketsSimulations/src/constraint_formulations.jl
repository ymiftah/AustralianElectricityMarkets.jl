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
`(device, t)`: energy dispatch, the service's own trapezium slope term, and any matching
regulation term.
"""
struct FCASJointCapacityLHS <: PSI.ExpressionType end

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

Constraint type for AEMO's FCAS MaxAvail limit (the offered `MaxAvail` of a service's trapezium),
built as a row on [`FCASCapacityVariable`](@ref) or [`FCASSideCapacityVariable`](@ref) per
`(device, t)` when the owning `PSI.ServiceModel` has `use_slacks = true`, named
`"<service>_maxavail"` or `"<service>_gen_maxavail"`/`"<service>_load_maxavail"` in its
container key. Without slacks the same limit is the variable's upper bound.
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

PSI.convert_result_to_natural_units(::Type{GenericConstraintSlackUp}) = true
PSI.convert_result_to_natural_units(::Type{GenericConstraintSlackDown}) = true

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
    UNIT_RAMP_CVP_FACTOR

CVP factor (1155) of AEMO's Unit Ramp Rate constraint (`DeficitRampRate` and `SurplusRampRate`),
item 3 of the *Schedule of Constraint Violation Penalty Factors* v8.0. Prices
[`UnitRampUpSlack`](@ref) and [`UnitRampDownSlack`](@ref).
"""
const UNIT_RAMP_CVP_FACTOR = 1155.0

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
    INTERCONNECTOR_FLOW_CVP_FACTOR

CVP factor (1150) of AEMO's Interconnector Capacity Limit constraint, item 5 of the *Schedule of
Constraint Violation Penalty Factors* v8.0. Prices [`InterconnectorFlowSurplusSlack`](@ref) and
[`InterconnectorFlowDeficitSlack`](@ref).
"""
const INTERCONNECTOR_FLOW_CVP_FACTOR = 1150.0

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

PSI.convert_result_to_natural_units(::Type{InterconnectorFlowSurplusSlack}) = true
PSI.convert_result_to_natural_units(::Type{InterconnectorFlowDeficitSlack}) = true
PSI.convert_result_to_natural_units(::Type{UnitRampUpSlack}) = true
PSI.convert_result_to_natural_units(::Type{UnitRampDownSlack}) = true
PSI.convert_result_to_natural_units(::Type{FCASJointCapacitySlack}) = true
PSI.convert_result_to_natural_units(::Type{FCASJointRampingSlack}) = true
PSI.convert_result_to_natural_units(::Type{FCASMaxAvailSlack}) = true
PSI.convert_result_to_natural_units(::Type{FCASBDURampingSlack}) = true
