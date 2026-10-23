module AustralianElectricityMarketsCache

using DataFrames
using Dates
using DuckDB
using DBInterface

export HiveConfiguration, AEMDB, aem_connect
export get_table, list_available_tables, ARCHIVE_MONTH_PARTITION

const ARCHIVE_MONTH_PARTITION = "archive_month"

include("types/hive_configuration.jl")
include("types/database.jl")
include("paths.jl")
include("types/data_source.jl")
include("connection.jl")
include("partitions.jl")
include("tables.jl")

end
