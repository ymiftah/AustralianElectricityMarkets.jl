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
