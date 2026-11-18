"Time-series parameter of a unit's participant fixed loading, net injection in system-base per-unit."
struct FixedLoadTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Time-series parameter that is `1` at the intervals a unit's fixed loading applies and `0` elsewhere."
struct FixedLoadInvokedTimeSeriesParameter <: PSI.TimeSeriesParameter end
