module AustralianElectricityMarketsData

using CSV, Chain
using DataFrames, HTTP, ZipArchives, Dates
using DuckDB, DBInterface
using Statistics: median, mean
using XML

export populate, get_table, list_available_tables
export ARCHIVE_MONTH_PARTITION
export HiveConfiguration, AEMDB, aem_connect
export read_hive, read_interconnectors, read_units, read_demand, read_energy_bids

const NEMWEB_URL = "http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_DVD_{table}_{year}{month:02d}010000.zip"
const NEMWEB_URL_ALT = "http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23{table}%23FILE01%23{year}{month:02d}010000.zip"
const ARCHIVE_MONTH_PARTITION = "archive_month"

include("connection.jl")
include("queries.jl")
include("nemweb_load/column_types.jl")
include("nemweb_load/errors.jl")
include("nemweb_load/parquet.jl")
include("nemweb_load/source.jl")
include("nemweb_load/tables.jl")
include("nemweb_load/populate.jl")
include("isp2025/isp2025.jl")
include("isp2026/xml.jl")

end
