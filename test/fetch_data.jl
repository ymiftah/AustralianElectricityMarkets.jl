using AustralianElectricityMarkets
using Dates

# Define the date range required for tests and documentation examples
# Covers all dates used across the repository
date_range = Date(2025, 1, 1):Date(2025, 1, 3)

# Tables required for the RegionalNetworkConfiguration
tables = table_requirements(RegionalNetworkConfiguration())

println("Fetching data for tables: ", tables)
println("Date range: ", date_range)

for table in tables
    # check if table is already fetched
    # this is a simple check to see if the directory for the table exists in the cache
    # though nemdb might do its own check, this is a safe way to avoid redundant calls
    config = AustralianElectricityMarkets.HiveConfiguration()
    cache_dir = joinpath(config.hive_location, String(table) * "foo")
    if isdir(cache_dir) && !isempty(readdir(cache_dir))
        println("Table $table already exists in cache at $cache_dir. Skipping.")
        continue
    end
    println("Fetching table: ", table)
    fetch_table_data(table, date_range)
end

println("Data fetching complete.")
