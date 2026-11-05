"Non-negative dispatch-to-energy-band mismatches in system-base per-unit."
abstract type AbstractEnergyOfferSlack <: PSI.VariableType end

"Dispatch above cleared incremental energy bands."
struct EnergyOfferSurplusSlack <: AbstractEnergyOfferSlack end

"Dispatch below cleared incremental energy bands."
struct EnergyOfferDeficitSlack <: AbstractEnergyOfferSlack end

"Consumption above cleared decremental energy bands."
struct EnergyDecrementalOfferSurplusSlack <: AbstractEnergyOfferSlack end

"Consumption below cleared decremental energy bands."
struct EnergyDecrementalOfferDeficitSlack <: AbstractEnergyOfferSlack end

const _ENERGY_OFFER_SLACK_TYPES = (
    EnergyOfferSurplusSlack, EnergyOfferDeficitSlack,
    EnergyDecrementalOfferSurplusSlack, EnergyDecrementalOfferDeficitSlack,
)


"""
    EnergyOfferBandVariable

Variable type of a device's cleared MW in each band of its energy offer, in system-base per-unit,
keyed `(name, label, t)` with band labels `"1"` to `"n"`. Meta `"gen"` for a generation-side offer and `"load"` for a
consumption-side offer; a band beyond an interval's offer has zero width.
"""
struct EnergyOfferBandVariable <: PSI.VariableType end

"""
    EnergyBandWidthParameter

Time-series parameter of an energy offer's band widths in MW, read from the device's
`energy_offer` series (`energy_offer_decremental` for meta `"load"`), with bands beyond an interval's
offer at width `0.0`. Meta `"gen"` or `"load"`.
"""
struct EnergyBandWidthParameter <: PSI.TimeSeriesParameter end

"""
    EnergyBandPriceParameter

Time-series cost parameter pricing [`EnergyOfferBandVariable`](@ref)s: each band's offer price in
`\$/MWh` per interval, read from the same series as [`EnergyBandWidthParameter`](@ref) (`0.0` for a
band not offered). Meta `"gen"` or `"load"`.
"""
struct EnergyBandPriceParameter <: PSI.TimeSeriesCostParameter end

"""
    EnergyOfferBandConstraint

Constraint type of `dispatch == Σ bands + surplus - deficit` for one device and interval, over its
[`EnergyOfferBandVariable`](@ref)s. Meta `"gen"` or `"load"`.
"""
struct EnergyOfferBandConstraint <: PSI.ConstraintType end
