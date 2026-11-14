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
right-hand side time series, in MW.
"""
struct NEMConstraintRHSParameter <: PSI.TimeSeriesParameter end


"""
    LinearFactorLimit

Formulation for a [`GenericConstraint`](@ref): assembles [`NEMConstraintLHS`](@ref) from the
constraint's own stored terms and bounds it against [`NEMConstraintRHSParameter`](@ref) with a
[`NEMConstraintLimit`](@ref). Slack penalties are objective terms only, not part of any
PowerSimulations cost expression.
"""
struct LinearFactorLimit <: PSI.AbstractServiceFormulation end


"""
    FCASMarket

Formulation for an [`FCASService`](@ref), co-optimising FCAS capacity alongside energy. Band costs
and slack penalties are objective terms only, not part of any PowerSimulations cost expression.
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
AEMO *FCAS Model in NEMDE* §6.2's joint capacity constraint, the BDU and joint ramping rows of
[`FCASUnitConstraint`](@ref) read as "Raise Regulation FCAS Target"/"Lower
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
    FCASUnitConstraint

Constraint type for the per-unit FCAS rows of [`FCASMarket`](@ref), indexed `(device name, t)`. The key
meta is `"<row>|<meta>"`: the row first, then the row's own container meta.

- `"max_avail|<service>_maxavail"` (or `"_gen_maxavail"`/`"_load_maxavail"`): the MaxAvail limit on a
  [`FCASCapacityVariable`](@ref) or [`FCASSideCapacityVariable`](@ref). The row is elastic when the owning
  `PSI.ServiceModel` has `use_slacks = true`.
- `"offer_band|<group meta>"`: `Σ bands == capacity` for one contributing device's FCAS offer, its
  [`FCASOfferBandVariable`](@ref)s summing to its capacity variable.
- `"joint_ramping|<service>"`: AEMO *FCAS Model in NEMDE* §6.1's joint ramping constraint, bounding a
  contributing device's net energy dispatch combined with its [`FCASUnitRegulationTarget`](@ref) against its
  telemetered AGC ramp from `InitialMW`.
- `"bdu_ramping|<service>"`: AEMO *FCAS Model in NEMDE* §6.4's BDU regulating FCAS SCADA ramping constraint,
  bounding a `PSY.Storage` device's [`FCASUnitRegulationTarget`](@ref) against the device's SCADA ramping
  capability.

Its dual, when requested, is recorded for the `"joint_ramping"` rows only.
"""
struct FCASUnitConstraint <: PSI.ConstraintType end


"""
    FCASOfferLimitParameter

Time-series parameter of a device's effective FCAS offer limits for one market and side, read from
its `"fcas_effective_<BIDTYPE>[_decremental]"` series ([`fcas_effective_series_name`](@ref)), per-unit
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
its `"fcas_ramping_limits_<BIDTYPE>"` series ([`fcas_ramping_series_name`](@ref)), per-unit of the
system base, with a field axis `"joint_ramping"` ([`FCASUnitConstraint`](@ref) right-hand
side) and `"bdu_ramping"` ([`FCASUnitConstraint`](@ref) right-hand side). Keyed by device type
with meta `"<BIDTYPE>"`.
"""
struct FCASRampingLimitParameter <: PSI.TimeSeriesParameter end


"""
    FCASBandPriceParameter

Time-series cost parameter pricing [`FCASOfferBandVariable`](@ref)s: its value is each band's offer
price in `\$/MWh`, read from the offer's service series: the service name for the generation side and
`"<service>_decremental"` for the load side (`0.0` for a band not offered). Each band's cost target scales the
price by the system base power and the interval length in hours. Meta `"<group>_gen"` or `"<group>_load"`, one
parameter per device type and side.
"""
struct FCASBandPriceParameter <: PSI.TimeSeriesCostParameter end


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
    GenericConstraintInvocationParameter

Constraint-bound parameter holding the invocation (`1.0`/`0.0`) of a [`GenericConstraint`](@ref) per
interval, read at each simulation step from the constraint's `invoked` series. The row of an
invoked interval has its bounds and the row of a non-invoked interval is free (`-Inf`, `Inf`).
"""
struct GenericConstraintInvocationParameter <: PSI.ConstraintBoundParameter end


"""
    FCASSlack

Variable type for the elastic slacks of the [`FCASMarket`](@ref) rows, built when the owning
`PSI.ServiceModel` has `use_slacks = true`. The key meta is `"<variant>|<meta>"`: the variant first,
then the row's own container meta.

- `"joint_capacity|<meta>"`: a [`FCASJointCapacityConstraint`](@ref) row (AEMO `xxUpperDeficit`/`xxLowerSurplus`),
  priced at `FCAS_CAPACITY_CVP_FACTOR` times the Market Price Cap.
- `"joint_ramping|<service>"`: a joint ramping row of [`FCASUnitConstraint`](@ref) (AEMO
  `R5REJointRampDeficit`/`L5REJointRampDeficit`), priced at `FCAS_RAMPING_CVP_FACTOR`.
- `"max_avail|<meta>"`: a MaxAvail row of [`FCASUnitConstraint`](@ref), priced at `FCAS_MAXAVAIL_CVP_FACTOR`.
- `"bdu_ramping|<service>"`: a BDU ramping row of [`FCASUnitConstraint`](@ref), priced at
  `FCAS_BDU_RAMPING_CVP_FACTOR`.
"""
struct FCASSlack <: PSI.VariableType end

struct FCASJointCapacityVariant end
struct FCASJointRampingVariant end
struct FCASMaxAvailVariant end
struct FCASBDURampingVariant end

# The meta head of each FCAS slack variant.
_fcas_slack_head(::FCASJointCapacityVariant) = "joint_capacity"
_fcas_slack_head(::FCASJointRampingVariant) = "joint_ramping"
_fcas_slack_head(::FCASMaxAvailVariant) = "max_avail"
_fcas_slack_head(::FCASBDURampingVariant) = "bdu_ramping"

# The key meta of an `FCASSlack` variant on a row's container meta.
_fcas_slack_meta(variant, meta::AbstractString) = string(_fcas_slack_head(variant), "|", meta)

# The variant an `FCASSlack` meta names, its first segment.
function _fcas_slack_variant(meta::AbstractString)::Union{FCASJointCapacityVariant, FCASJointRampingVariant, FCASMaxAvailVariant, FCASBDURampingVariant}
    head = first(split(meta, '|'; limit = 2))
    head == "joint_capacity" && return FCASJointCapacityVariant()
    head == "joint_ramping" && return FCASJointRampingVariant()
    head == "max_avail" && return FCASMaxAvailVariant()
    head == "bdu_ramping" && return FCASBDURampingVariant()
    throw(ArgumentError("an FCASSlack has no variant named \"$head\""))
end

# The row's container meta after an `FCASSlack` meta's variant, split at its first `|`.
_fcas_slack_row_meta(meta::AbstractString) = String(last(split(meta, '|'; limit = 2)))


"""
    InterconnectorFlowSlack

Variable type for the elastic slack on an interconnector's flow limits, per `(interconnector, t)` in MW
per-unit of the system base. The key meta names the variant: `"surplus"` relaxes the upper limit (AEMO's
`FlowSurplus`) and `"deficit"` the lower limit (AEMO's `FlowDeficit`). Both are priced at
[`INTERCONNECTOR_FLOW_CVP_FACTOR`](@ref) times the Market Price Cap.
"""
struct InterconnectorFlowSlack <: PSI.VariableType end

struct InterconnectorFlowSurplus end
struct InterconnectorFlowDeficit end

# The key meta of each interconnector flow slack variant.
_interconnector_flow_meta(::InterconnectorFlowSurplus) = "surplus"
_interconnector_flow_meta(::InterconnectorFlowDeficit) = "deficit"

# The variant an `InterconnectorFlowSlack` meta names.
function _interconnector_flow_variant(meta::AbstractString)::Union{InterconnectorFlowSurplus, InterconnectorFlowDeficit}
    meta == "surplus" && return InterconnectorFlowSurplus()
    meta == "deficit" && return InterconnectorFlowDeficit()
    throw(ArgumentError("an InterconnectorFlowSlack has no variant named \"$meta\""))
end
