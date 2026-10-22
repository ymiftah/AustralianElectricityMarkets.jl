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


"""
    INTERCONNECTOR_ZERO_CVP_FACTOR

CVP factor (1160) of AEMO's Unit and Interconnector Zero constraint, item 1 of the *Schedule of
Constraint Violation Penalty Factors* v8.0. Prices the built-in Interconnector Zero
[`GenericConstraint`](@ref)s.
"""
const INTERCONNECTOR_ZERO_CVP_FACTOR = 1160.0


"""
    FIXED_LOADING_CVP_FACTOR

CVP factor (380) of AEMO's Energy Inflexible Offer constraint, a unit held at its participant
fixed loading, item 13 of the *Schedule of Constraint Violation Penalty Factors* v8.0. Prices the
built-in `\$<DUID>` [`GenericConstraint`](@ref)s.
"""
const FIXED_LOADING_CVP_FACTOR = 380.0


const _BUILT_IN_CVP_FACTORS = Dict(
    "Interconnector Zero" => INTERCONNECTOR_ZERO_CVP_FACTOR,
    "Energy Inflexible Offer" => FIXED_LOADING_CVP_FACTOR,
)


"""
    constraint_cvp_factor(gc) -> Float64

CVP factor that prices `gc`'s slacks: its `GENCONDATA` weight ([`get_constraint_weight`](@ref)),
or, for a constraint whose `source` is `"built-in"`, the factor of its limit type
([`INTERCONNECTOR_ZERO_CVP_FACTOR`](@ref), [`FIXED_LOADING_CVP_FACTOR`](@ref)).

# Arguments
- `gc`: a [`GenericConstraint`](@ref).

# Returns
A `Float64`. Throws an `ArgumentError` for a built-in constraint of an unknown limit type.
"""
function constraint_cvp_factor(gc::GenericConstraint)
    get_source(gc) == "built-in" || return get_constraint_weight(gc)
    limit_type = get_limit_type(gc)
    haskey(_BUILT_IN_CVP_FACTORS, limit_type) || throw(
        ArgumentError("built-in generic constraint $(PSY.get_name(gc)) has no CVP factor for limit type $(repr(limit_type))"),
    )
    return _BUILT_IN_CVP_FACTORS[limit_type]
end
