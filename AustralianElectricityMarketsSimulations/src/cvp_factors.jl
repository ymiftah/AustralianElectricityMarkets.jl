"""
    MARKET_PRICE_CAP_BY_FINANCIAL_YEAR

Published Market Price Cap (`\$/MWh`), by the `Date` its financial year starts (1 July).
Source: AEMC *Schedule of reliability settings, 2026-27 financial year* (FY2024-25: AEMC's
2024-25 schedule).
"""
const MARKET_PRICE_CAP_BY_FINANCIAL_YEAR = [
    Date(2024, 7, 1) => 17_500.0,
    Date(2025, 7, 1) => 20_300.0,
    Date(2026, 7, 1) => 23_200.0,
]


"""
    UNIT_RAMP_CVP_FACTOR

CVP factor (1155) of AEMO's Unit Ramp Rate constraint (`DeficitRampRate` and `SurplusRampRate`),
item 3 of the *Schedule of Constraint Violation Penalty Factors* v8.0. Prices
[`UnitRampUpSlack`](@ref) and [`UnitRampDownSlack`](@ref).
"""
const UNIT_RAMP_CVP_FACTOR = 1155.0


"""
    INTERCONNECTOR_FLOW_CVP_FACTOR

CVP factor (1150) of AEMO's Interconnector Capacity Limit constraint, item 5 of the *Schedule of
Constraint Violation Penalty Factors* v8.0. Prices [`InterconnectorFlowSurplusSlack`](@ref) and
[`InterconnectorFlowDeficitSlack`](@ref).
"""
const INTERCONNECTOR_FLOW_CVP_FACTOR = 1150.0


"""
    ENERGY_OFFER_CVP_FACTOR

CVP factor (1135) of AEMO's Total Band MW Offer constraint, item 8 of the *Schedule of Constraint
Violation Penalty Factors* v8.0. Prices the [`EnergyOfferSurplusSlack`](@ref) family.
"""
const ENERGY_OFFER_CVP_FACTOR = 1135.0


"""
    ENERGY_UIGF_CVP_FACTOR

CVP factor (385) of AEMO's semi-scheduled UIGF constraint, item 12 of the *Schedule of Constraint
Violation Penalty Factors* v8.0. Prices [`EnergyUIGFSlack`](@ref).
"""
const ENERGY_UIGF_CVP_FACTOR = 385.0


"""
    ENERGY_MAX_AVAIL_CVP_FACTOR

CVP factor (370) of AEMO's Unit MaxAvail constraint, item 14 of the *Schedule of Constraint
Violation Penalty Factors* v8.0. Prices [`EnergyMaxAvailSlack`](@ref),
[`EnergyMaxAvailOutSlack`](@ref) and [`EnergyMaxAvailInSlack`](@ref).
"""
const ENERGY_MAX_AVAIL_CVP_FACTOR = 370.0


"""
    AREA_BALANCE_CVP_FACTOR

CVP factor (150) of AEMO's Regional Energy Demand Supply Balance constraint (`DeficitGen` and
`SurplusGen`), items 22 and 23 of the *Schedule of Constraint Violation Penalty Factors* v8.0.
"""
const AREA_BALANCE_CVP_FACTOR = 150.0
