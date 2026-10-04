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
