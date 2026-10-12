module AustralianElectricityMarketsData

using HTTP, ZipArchives, Dates
using DuckDB, DBInterface
using AustralianElectricityMarketsCache
import AustralianElectricityMarketsCache: DataSource, get_filesystem, islocal,
    _parse_hive_root, _local_tmp_dir, _new_duckdb_connection, _partition_has_data,
    _partition_dir_names, cached_date_range, _TABLE_SPECS, _TABLE_SPECS_BY_NAME

export populate, get_table, list_available_tables
export ARCHIVE_MONTH_PARTITION
export HiveConfiguration, AEMDB, aem_connect

const NEMWEB_URL = "http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_DVD_{table}_{year}{month:02d}010000.zip"
const NEMWEB_URL_ALT = "http://nemweb.com.au/Data_Archive/Wholesale_Electricity/MMSDM/{year}/MMSDM_{year}_{month:02d}/MMSDM_Historical_Data_SQLLoader/DATA/PUBLIC_ARCHIVE%23{table}%23FILE{part:02d}%23{year}{month:02d}010000.zip"

include("types/errors.jl")
include("nemweb_load/column_types.jl")
include("nemweb_load/parquet.jl")
include("nemweb_load/download.jl")
include("nemweb_load/populate.jl")

@doc (@doc AustralianElectricityMarketsCache.HiveConfiguration) HiveConfiguration
@doc (@doc AustralianElectricityMarketsCache.AEMDB) AEMDB
@doc (@doc AustralianElectricityMarketsCache.aem_connect) aem_connect
@doc (@doc AustralianElectricityMarketsCache.get_table) get_table
@doc (@doc AustralianElectricityMarketsCache.list_available_tables) list_available_tables

end
