module AustralianElectricityMarketsCache

using DataFrames
using Dates
using DuckDB
using DBInterface

export HiveConfiguration, AEMDB, aem_connect
export get_table, list_available_tables, ARCHIVE_MONTH_PARTITION
export isp_cache_path, isp_scenario_schema

const ARCHIVE_MONTH_PARTITION = "archive_month"

include("types/hive_configuration.jl")
include("types/database.jl")
include("paths.jl")
include("isp_cache.jl")
include("types/data_source.jl")
include("connection.jl")
include("partitions.jl")
include("tables.jl")
include("display.jl")

end
