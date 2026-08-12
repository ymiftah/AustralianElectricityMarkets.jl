module AustralianElectricityMarketsData

using CSV, Chain
using DataFrames, HTTP, ZipArchives, Dates
using DuckDB, DBInterface
using Statistics: median

using ..AustralianElectricityMarkets: HiveConfiguration, islocal, get_filesystem, AEMDB, PM_MAPPING

export populate, get_table, list_available_tables
export ARCHIVE_MONTH_PARTITION

const NEMWEB_URL = "http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_DVD_{table}_{year}{month:02d}010000.zip"
const NEMWEB_URL_ALT = "http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23{table}%23FILE01%23{year}{month:02d}010000.zip"
const ARCHIVE_MONTH_PARTITION = "archive_month"

include("nemweb_load/column_types.jl")
include("nemweb_load/errors.jl")
include("nemweb_load/http.jl")
include("nemweb_load/parquet.jl")
include("nemweb_load/source.jl")
include("nemweb_load/archive.jl")
include("nemweb_load/tables.jl")
include("nemweb_load/populate.jl")
include("isp2025.jl")

end
