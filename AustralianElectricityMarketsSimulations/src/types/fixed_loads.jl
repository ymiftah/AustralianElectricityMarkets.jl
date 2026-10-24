"Time-series parameter of a unit's participant fixed loading, net injection in system-base per-unit."
struct FixedLoadTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Time-series parameter that is `1` at the intervals a unit's fixed loading applies and `0` elsewhere."
struct FixedLoadInvokedTimeSeriesParameter <: PSI.TimeSeriesParameter end

"AEMO's Energy Inflexible Offer rows holding a unit's net energy at its fixed loading, metas `\"upper\"` and `\"lower\"`."
struct EnergyFixedLoadConstraint <: PSI.ConstraintType end

"Non-negative violations of a unit's fixed loading, in system-base per-unit."
abstract type AbstractFixedLoadSlack <: PSI.VariableType end

"Non-negative net energy above a unit's fixed loading."
struct EnergyFixedLoadSurplusSlack <: AbstractFixedLoadSlack end

"Non-negative net energy below a unit's fixed loading."
struct EnergyFixedLoadDeficitSlack <: AbstractFixedLoadSlack end
