module AustralianElectricityMarketsData

using PythonCall
using ..AustralianElectricityMarkets: PM_MAPPING

export PyHiveConfiguration, fetch_table_data, list_available_tables
export read_affine_heatrates, read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters

@kwdef struct PyHiveConfiguration
    base_dir::String = joinpath(homedir(), ".nemweb_cache")
    filesystem::String = "local"
end


"""
    fetch_table_data(table::Symbol, time_range::Any; location::String=CONFIG[].hive_location, filesystem=CONFIG[].filesystem)

Download and cache data for a given `table` and `time_range`.

# Arguments
- `table::Symbol`: The table to populate.
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `location::String`: The directory to cache data in. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `local`.
"""
function fetch_table_data(
        table::Symbol,
        time_range::Any;
        hive_configuration::PyHiveConfiguration = PyHiveConfiguration(),
    )
    dbs = _get_pydb_manager(hive_configuration)
    dbItem = pygetattr(dbs, String(table), nothing)
    if isnothing(dbItem)
        available_tables = list_available_tables()
        throw("No such table exists. Available tables are $available_tables")
    end
    from_date = first(time_range)
    to_date = last(time_range)
    return dbItem.populate(pyslice(Py(from_date), Py(to_date)))
end

"""
    fetch_table_data(table::Symbol, time_range::Any; location::String=CONFIG[].hive_location, filesystem=CONFIG[].filesystem)

Download and cache data for a given `table` and `time_range`.

# Arguments
- `table::Symbol`: The table to populate.
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `location::String`: The directory to cache data in. Defaults to `~/.nemweb_cache`.
- `filesystem::String`: The filesystem to use for the cache. Defaults to `local`.
"""
function fetch_table_data(
        time_range::Any;
        hive_configuration::PyHiveConfiguration = PyHiveConfiguration(),
    )
    dbs = _get_pydb_manager(hive_configuration)
    from_date = first(time_range)
    to_date = last(time_range)
    return dbs.populate(pyslice(Py(from_date), Py(to_date)))
end

"""
    list_available_tables()::Array{String}

List the available tables to fetch data for.
"""
function list_available_tables()::Array{Symbol}
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    dbs = nemdb.NEMWEBManager(config)
    return Symbol.(pyconvert(Array, dbs.active_tables()))
end

"""
    _get_pydb_manager(location::String, filesystem::String)

Get a python `nemdb.NEMWEBManager` object.

# Arguments
- `hive_configuration::PyHiveConfiguration`: The configuration
"""
function _get_pydb_manager(hive_configuration::PyHiveConfiguration)
    nemdb = pyimport("nemdb")
    config = nemdb.Config
    config.set_cache_dir(hive_configuration.base_dir)
    config.set_filesystem(hive_configuration.filesystem)
    return nemdb.NEMWEBManager(config)
end


##

using CSV, DataFrames, Chain;

const ISP_DATA_DIR = joinpath(@__DIR__, "data", "isp2025")

function read_affine_heatrates()
    file_source = joinpath(ISP_DATA_DIR, "affine_heat_rates.csv")
    return @chain file_source begin
        CSV.read(DataFrame)
        transform!(
            :technology => ByRow(x -> PM_MAPPING[x]) => :primemovers,
        )
    end
end

function read_coal_prices()
    file_source = joinpath(ISP_DATA_DIR, "coal_prices.csv")
    return @chain file_source begin
        CSV.read(DataFrame)
        stack(Not([:station, :scenario]); variable_name = :year, value_name = :price_aud)
        transform!(
            :year => ByRow(x -> parse(Int, split(x, "-")[1])) => :year,
            :price_aud => ByRow(x -> parse(Float64, strip(x, ['$', ' ']))) => :price_aud,
        )
    end
end

function read_gas_prices()
    file_source = joinpath(ISP_DATA_DIR, "gas_prices.csv")
    return @chain file_source begin
        CSV.read(DataFrame)
        stack(Not([:station, :scenario]); variable_name = :year, value_name = :price_aud)
        transform!(
            :year => ByRow(x -> parse(Int, split(x, "-")[1])) => :year,
            :price_aud => ByRow(x -> parse(Float64, strip(x, ['$', ' ']))) => :price_aud,
        )
    end
end

function read_biomass_prices()
    file_source = joinpath(ISP_DATA_DIR, "biomass_prices.csv")
    return @chain file_source begin
        CSV.read(DataFrame)
        stack(Not(:scenario); variable_name = :year, value_name = :price_aud)
        transform!(
            :year => ByRow(x -> parse(Int, split(x, "-")[1])) => :year,
            :price_aud => ByRow(x -> parse(Float64, strip(x, ['$', ' ']))) => :price_aud,
        )
    end
end

function read_isp_thermal_costs_parameters(year::Int, scenario::String)
    affine_heatrates = read_affine_heatrates()
    prices = vcat(
        read_coal_prices(),
        read_gas_prices(),
    )
    available_scenarios = unique(prices.scenario)
    available_years = unique(prices.year)
    !in(available_scenarios)(scenario) && throw(ArgumentError("scenario value must be one of $available_scenarios"))
    !in(available_years)(year) && throw(ArgumentError("year value must be one of $available_year"))
    subset!(prices, :year => ByRow(==(year)), :scenario => ByRow(==(scenario)))
    select!(prices, Not(:year, :scenario))

    biomass_prices = read_biomass_prices()
    subset!(biomass_prices, :year => ByRow(==(year)), :scenario => ByRow(==(scenario)))
    select!(biomass_prices, Not(:year, :scenario))
    biomass_price = biomass_prices.price_aud |> first # only one element


    df = leftjoin(affine_heatrates, prices, on = :station)
    # match biomass costs to biomass units
    transform!(
        df,
        [:technology, :price_aud] => ByRow((tech, price) -> tech == "Biomass" ? biomass_price : price) => :price_aud
    )

    #fill missing values with median price
    return @chain df begin
        groupby(:technology)
        transform(
            :price_aud => (
                x -> (
                    all(ismissing.(x)) ? missing : median(skipmissing(x))
                )
            ) => :price_aud
        )
    end
end


end
