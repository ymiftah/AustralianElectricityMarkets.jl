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
    fetch_table_data(table, date_range)
end

println("Data fetching complete.")
