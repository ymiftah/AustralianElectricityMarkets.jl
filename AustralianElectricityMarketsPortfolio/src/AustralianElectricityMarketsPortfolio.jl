"""
    AustralianElectricityMarketsPortfolio

Read the 2026 ISP PLEXOS cache and build a `PSIP.Portfolio` of ISP scenarios.
"""
module AustralianElectricityMarketsPortfolio

using AustralianElectricityMarketsCache
using DataFrames
using Dates
using DuckDB
using InfrastructureSystems
using PowerSystems
using PowerSystemsInvestmentsPortfolios

export ISPSourceData, ISPSourceRecord, ISPSourceTag, ISPTimeSlice, ISPTraceHandle
export read_isp_source, read_isp_trace, isp_scenarios, isp_trace_handle
export isp_property_catalogue, isp_matching_timeslices, resolve_property, resolve_properties

include("isp_source.jl")
include("isp_properties.jl")

end
