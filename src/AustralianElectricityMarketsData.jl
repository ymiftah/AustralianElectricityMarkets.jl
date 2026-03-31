module AustralianElectricityMarketsData

using PythonCall
using Statistics: median
using ..AustralianElectricityMarkets: PM_MAPPING

export PyHiveConfiguration, fetch_table_data, list_available_tables
export read_affine_heatrates, read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters
export read_isp_renewable_costs_parameters
export read_isp_fixed_opex, read_isp_variable_opex

"""
    PyHiveConfiguration

Configuration for `nemdb` Python library cache.

# Arguments
- `base_dir::String`: The base directory to cache data in. Defaults to `~/.nemdb_cache`.
- `filesystem::String`: The fsspec compatible filesystem to use. Defaults to `"local"`.
"""
@kwdef struct PyHiveConfiguration
    base_dir::String = joinpath(homedir(), ".nemdb_cache")
    filesystem::String = "local"
end


"""
    fetch_table_data(table::Symbol, time_range::Any; hive_configuration::PyHiveConfiguration)

Download and cache data for a given `table` and `time_range`.

# Arguments
- `table::Symbol`: The table to populate.
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `hive_configuration::PyHiveConfiguration`: Configuration to use for the cache. Defaults to a local directory ~/.nemdb_cache.
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
    fetch_table_data(time_range::Any; hive_configuration::PyHiveConfiguration)

Download and cache data for all tables for a given `time_range`.

# Arguments
- `time_range::Any`: The time range to populate data for. (e.g. `Date(2023,1,1):Date(2023,3,1)`)
- `hive_configuration::PyHiveConfiguration`: Configuration to use for the cache. Defaults to a local directory ~/.nemdb_cache.
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
    dbs = nemdb.NEMWEBManager()
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
    py_config = nemdb.config
    py_config.set_cache_dir(hive_configuration.base_dir)
    py_config.set_filesystem(hive_configuration.filesystem)
    return nemdb.NEMWEBManager()
end


##

using CSV, DataFrames, Chain;

const ISP_DATA_DIR = joinpath(@__DIR__, "data", "isp2025")

"""
    read_affine_heatrates()

Read affine heat rate model parameters from ISP 2025 data.

The affine heat rate model is of the form:

`HeatRate = a * CapacityFactor + b`

where `a` is the slope and `b` is the intercept.
"""
function read_affine_heatrates()
    file_source = joinpath(ISP_DATA_DIR, "affine_heat_rates.csv")
    return @chain file_source begin
        CSV.read(DataFrame)
        transform!(
            :technology => ByRow(x -> PM_MAPPING[x]) => :primemovers,
        )
    end
end

"""
    read_coal_prices()

Read coal prices from ISP 2025 data.
"""
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

"""
    read_gas_prices()

Read gas prices from ISP 2025 data.
"""
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

"""
    read_biomass_prices()

Read biomass prices from ISP 2025 data.
"""
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

"""
    read_isp_thermal_costs_parameters(year::Int, scenario::String)

Read thermal costs parameters from ISP 2025 data for a given `year` and `scenario`.

# Arguments
- `year::Int`: The year to read data for.
- `scenario::String`: The scenario to read data for.
"""
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


"""
    read_isp_renewable_costs_parameters()

Read renewable variable OPEX parameters from ISP 2025 data via nemdb.

Returns a `DataFrame` with columns:
- `unit`: DUID (or IASR ID) of the generator
- `variable_opex_aud_mwh`: variable OPEX in AUD/MWh sent out

Per ISP 2025, Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
because O&M costs are captured entirely in the Fixed O&M component.
"""
function read_isp_renewable_costs_parameters()
    isp = pyimport("nemdb.isp.isp2025")
    pl = pyimport("polars")
    df = isp.variable_opex()
    renewable_techs = ["Wind", "Large scale Solar PV"]
    df_ren = df.filter(pl.col("technology").is_in(renewable_techs))
    return DataFrame(
        unit = pyconvert(Vector{String}, df_ren["iasr_id"].to_list()),
        variable_opex_aud_mwh = pyconvert(Vector{Float64}, df_ren["variable_opex_aud_mwh_sent_out"].to_list()),
    )
end


"""
    read_isp_fixed_opex()

Read fixed OPEX (AUD/kW/year) per generator from ISP 2025 data via nemdb.

Returns a `DataFrame` with columns:
- `unit`: IASR ID of the generator
- `isp_technology`: ISP technology category (e.g. "Steam Sub Critical", "Wind")
- `fixed_opex_aud_kw_year`: fixed OPEX in AUD/kW of installed capacity per year

To convert to AUD/h for a unit with `base_power` in MVA:
    `fixed_opex_aud_kw_year * base_power * 1000 / 8760`
"""
function read_isp_fixed_opex()
    isp = pyimport("nemdb.isp.isp2025")
    df = isp.fixed_opex()
    return DataFrame(
        unit = pyconvert(Vector{String}, df["iasr_id"].to_list()),
        isp_technology = pyconvert(Vector{String}, df["technology"].to_list()),
        fixed_opex_aud_kw_year = pyconvert(Vector{Float64}, df["fixed_opex_aud_kw_year"].to_list()),
    )
end


"""
    read_isp_variable_opex()

Read variable OPEX (AUD/MWh sent out) per generator from ISP 2025 data via nemdb.

Returns a `DataFrame` with columns:
- `unit`: IASR ID of the generator
- `isp_technology`: ISP technology category (e.g. "Steam Sub Critical", "Wind")
- `variable_opex_aud_mwh`: variable OPEX in AUD/MWh sent out

Covers all technology types (thermal, hydro, renewable, storage).
Per ISP 2025, Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
because O&M costs are captured entirely in the Fixed O&M component.
"""
function read_isp_variable_opex()
    isp = pyimport("nemdb.isp.isp2025")
    df = isp.variable_opex()
    return DataFrame(
        unit = pyconvert(Vector{String}, df["iasr_id"].to_list()),
        isp_technology = pyconvert(Vector{String}, df["technology"].to_list()),
        variable_opex_aud_mwh = pyconvert(Vector{Float64}, df["variable_opex_aud_mwh_sent_out"].to_list()),
    )
end


end
