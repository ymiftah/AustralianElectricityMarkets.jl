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
bounded above by the device's `MAXAVAIL` for that market and interval.
"""
struct FCASCapacityVariable <: PSI.VariableType end

"""
    FCASJointCapacityLHS

Expression type for one side (named `"<service>_upper"`/`"<service>_lower"` in its container
key) of the AEMO *FCAS Model in NEMDE* §6.2/§6.3 joint capacity constraint's left-hand side, per
`(device, t)`: energy dispatch, the service's own trapezium slope term, and any matching
regulation term.
"""
struct FCASJointCapacityLHS <: PSI.ExpressionType end

"""
    FCASJointCapacityConstraint

Constraint type for one side (named `"<service>_upper"`/`"<service>_lower"` in its container
key) of the AEMO *FCAS Model in NEMDE* §6.2/§6.3 joint capacity constraint, bounding a device's
[`FCASJointCapacityLHS`](@ref) against its FCAS trapezium's enablement window.
"""
struct FCASJointCapacityConstraint <: PSI.ConstraintType end
