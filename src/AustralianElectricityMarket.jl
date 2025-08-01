module AustralianElectricityMarket


# Write your package code here.
include("configurations.jl")
include("nemdb.jl")
include("etl.jl")

export fetch_table_data, list_available_tables
export read_hive

end
