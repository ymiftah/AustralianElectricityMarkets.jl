# Gathering Data

`AustralianElectricityMarketsData.jl` downloads and caches NEMWEB data.
`AustralianElectricityMarkets.Readers` queries the cache with DuckDB.

## How it Works

The data is fetched from the NEMWEB archive and stored locally as hive-partitioned Parquet files. This provides a good trade-off between data compression and query efficiency using tools like DuckDB.

## Configuration

By default, data is cached in `~/.nemdb_cache`. You can customize the cache location and filesystem using `HiveConfiguration`.

```julia
using AustralianElectricityMarkets

# Configure a custom cache directory
config = HiveConfiguration(
    hive_location = "/path/to/my_cache",
    filesystem = "file",  # supports Amazon s3, Google Cloud Platform gs
)
db = aem_connect(config)
```

## Listing Available Tables

To see which AEMO tables are currently supported and available for download:

```julia
list_available_tables()
```

## Populating the Database

You can download and populate the cache for a specific table over a given date range using `populate`.

```julia
using Dates
using AustralianElectricityMarketsData: populate

# Download dispatch data for early 2024
populate(db, :DISPATCHREGIONSUM, Date(2024, 1, 1), Date(2024, 1, 2))
```

`populate` skips months already present in the cache; pass `force_new = true` to re-download them.

To download data for **all** supported tables for a specific period:

```julia
populate(db, Date(2024, 1, 1), Date(2024, 1, 2))
```

Constraint definitions revised before 2015 exist only in NEMWEB's monolithic pre-2015 archives. Backfill them
with `populate_legacy_archive`, which reads only the definition tables out of each monthly archive:

```julia
using AustralianElectricityMarketsData: populate_legacy_archive

populate_legacy_archive(db)  # GENCONDATA and SPD*CONSTRAINT, 2009-07 to 2014-12
```

To display the data requirements for specific network configurations:

```julia
table_requirements(RegionalNetworkConfiguration())
```

## Reading the Data

Once the data is cached, use `AustralianElectricityMarkets.Readers` to load it for
analysis. Public readers are also re-exported from `AustralianElectricityMarkets`.

```julia
using AustralianElectricityMarkets, DuckDB, DataFrames

# Connect to a local DuckDB instance
db = aem_connect()

# Low-level access to a specific hive table: read_hive returns a SQL source
# fragment that can be queried directly with DuckDB
source = read_hive(db, :DISPATCH_UNIT_SOLUTION)
df_raw = DataFrame(DuckDB.execute(db.db, "SELECT * FROM $source LIMIT 10"))

# Load unit information from the cached data
units = read_units(db)

```
