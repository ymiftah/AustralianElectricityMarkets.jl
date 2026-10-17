PSI.convert_result_to_natural_units(::Type{GenericConstraintSlackUp}) = true

PSI.convert_result_to_natural_units(::Type{GenericConstraintSlackDown}) = true


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


PSI.convert_result_to_natural_units(::Type{InterconnectorFlowSurplusSlack}) = true

PSI.convert_result_to_natural_units(::Type{InterconnectorFlowDeficitSlack}) = true

PSI.convert_result_to_natural_units(::Type{UnitRampUpSlack}) = true

PSI.convert_result_to_natural_units(::Type{EnergyMaxAvailSlack}) = true

PSI.convert_result_to_natural_units(::Type{EnergyUIGFSlack}) = true

PSI.convert_result_to_natural_units(::Type{EnergyMaxAvailTimeSeriesParameter}) = true

PSI.convert_result_to_natural_units(::Type{EnergyUIGFTimeSeriesParameter}) = true

PSI.convert_result_to_natural_units(::Type{UnitRampDownSlack}) = true

PSI.convert_result_to_natural_units(::Type{FCASJointCapacitySlack}) = true

PSI.convert_result_to_natural_units(::Type{FCASJointRampingSlack}) = true

PSI.convert_result_to_natural_units(::Type{FCASMaxAvailSlack}) = true

PSI.convert_result_to_natural_units(::Type{FCASBDURampingSlack}) = true
