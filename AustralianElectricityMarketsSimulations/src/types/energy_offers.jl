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
