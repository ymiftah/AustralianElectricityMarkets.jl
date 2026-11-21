"""
    EnergyLimitTimeSeriesParameter

Time-series parameter of an energy limit in system-base per-unit: the raw bid MAXAVAIL, with key meta
`"max_avail"`, or a semi-scheduled unit's UIGF, with key meta `"uigf"`.
"""
struct EnergyLimitTimeSeriesParameter <: PSI.TimeSeriesParameter end
