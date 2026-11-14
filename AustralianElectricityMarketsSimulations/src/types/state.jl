# The telemetry of a replay unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_telemetry(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.telemetry
end

# The observed state of a replay unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_observed(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.observed_state
end
