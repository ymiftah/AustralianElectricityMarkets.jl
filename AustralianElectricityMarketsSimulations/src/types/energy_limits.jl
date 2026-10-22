"Non-negative violations of a NEM energy availability limit, in system-base per-unit."
abstract type AbstractEnergyLimitSlack <: PSI.VariableType end

"A NEM energy availability constraint with an explicitly priced surplus."
abstract type AbstractEnergyLimitConstraint <: PSI.ConstraintType end

"Time-series parameter for raw bid MAXAVAIL in system-base per-unit."
struct EnergyMaxAvailTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Time-series parameter for a semi-scheduled unit's UIGF in system-base per-unit."
struct EnergyUIGFTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Raw energy bid availability constraint."
struct EnergyMaxAvailConstraint <: AbstractEnergyLimitConstraint end

"Semi-scheduled forecast availability constraint."
struct EnergyUIGFConstraint <: AbstractEnergyLimitConstraint end

"Non-negative dispatch above raw energy MAXAVAIL."
struct EnergyMaxAvailSlack <: AbstractEnergyLimitSlack end

"Non-negative dispatch above a semi-scheduled UIGF."
struct EnergyUIGFSlack <: AbstractEnergyLimitSlack end

"Storage generation MAXAVAIL constraint."
struct EnergyMaxAvailOutConstraint <: AbstractEnergyLimitConstraint end

"Storage charging MAXAVAIL constraint."
struct EnergyMaxAvailInConstraint <: AbstractEnergyLimitConstraint end

"Non-negative storage generation above raw GEN MAXAVAIL."
struct EnergyMaxAvailOutSlack <: AbstractEnergyLimitSlack end

"Non-negative storage charging above raw LOAD MAXAVAIL."
struct EnergyMaxAvailInSlack <: AbstractEnergyLimitSlack end
