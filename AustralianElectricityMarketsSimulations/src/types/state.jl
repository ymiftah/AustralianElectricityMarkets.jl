# The telemetry of a NEMDE unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_telemetry(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.telemetry
end

# The observed state of a NEMDE unit, or `nothing` when it is unset or the device carries no unit data.
function _unit_observed(device)
    unit = AustralianElectricityMarkets._nem_unit_data(device)
    return isnothing(unit) ? nothing : unit.observed_state
end


"""
    NEMInitialPower <: PSI.InitialConditionType

The starting output of a NEMDE unit in a closed-loop run, in system-base per-unit (net of charging for a
battery): AEMO's observed output at the first interval, then the previous interval's solved output.
"""
struct NEMInitialPower <: PSI.InitialConditionType end


"""
    NEMInitialFlow <: PSI.InitialConditionType

The starting flow of an MNSP in a closed-loop run, in MW: the metered flow at the first interval, then the
previous interval's solved flow.
"""
struct NEMInitialFlow <: PSI.InitialConditionType end
