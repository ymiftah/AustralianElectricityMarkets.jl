# Gathering Data

`AustralianElectricityMarkets.jl` provides a thin wrapper around the [nemdb](https://github.com/ymiftah/nemdb) Python package. This integration allows you to easily download and cache data from the AEMO NEMWEB data archive.

## How it Works

The data is fetched from the NEMWEB archive and stored locally as hive-partitioned Parquet files. This provides a good trade-off between data compression and query effieciency using tools like DuckDB (via `TidierDB.jl`).

## Configuration

By default, data is cached in `~/.nemweb_cache`. You can customize the cache location and filesystem using `PyHiveConfiguration`.

```julia
using AustralianElectricityMarkets

# Configure a custom cache directory
config = HiveConfiguration(base_dir = "/path/to/my_cache")
```

## Listing Available Tables

To see which AEMO tables are currently supported and available for download:

```julia
list_available_tables()
```

## Populating the Database

You can download and populate the cache for a specific table over a given date range using `fetch_table_data`.

```julia
using Dates

# Download dispatch data for early 2024
fetch_table_data(:DISPATCHREGIONSUM, Date(2024, 1, 1):Date(2024, 1, 2))
```

To download data for **all** supported tables for a specific period:

```julia
fetch_table_data(Date(2024, 1, 1):Date(2024, 1, 2))
```

To display the data requirements for specific network configurations:

```julia
table_requirements(RegionalNetworkConfiguration())
```


## Reading the Data

Once the data is cached, you can load itfor analysis. The package provides high-level functions to parse this raw data into structured DataFrames via TidierDB.

```julia
using TidierDB

# Connect to a local DuckDB instance
db = connect(duckdb())

# Low-level access to a specific hive table
df_raw = read_hive(db, :DISPATCH_UNIT_SOLUTION) |> @collect

# Load unit information from the cached data
units = read_units(db)

```
