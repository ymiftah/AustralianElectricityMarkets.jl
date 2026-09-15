export read_affine_heatrates, read_coal_prices, read_gas_prices, read_biomass_prices, read_isp_thermal_costs_parameters
export read_isp_renewable_costs_parameters
export read_isp_fixed_opex, read_isp_variable_opex

const ISP_DATA_DIR = joinpath(@__DIR__, "data")

"""
    read_affine_heatrates()

Read affine heat rate model parameters from ISP 2025 data.

The affine heat rate model is of the form:

`HeatRate = a * CapacityFactor + b`

where `a` is the slope and `b` is the intercept.
"""
function read_affine_heatrates()
    file_source = joinpath(ISP_DATA_DIR, "affine_heat_rates.csv")
    return CSV.read(file_source, DataFrame)
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
    !in(available_years)(year) && throw(ArgumentError("year value must be one of $available_years"))
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
    read_isp_fixed_opex()

Read fixed OPEX (AUD/kW/year) per generator from ISP 2025 data.

Returns a `DataFrame` with columns:
- `unit`: IASR ID of the generator
- `isp_technology`: ISP technology category (e.g. "Steam Sub Critical", "Wind")
- `fixed_opex_aud_kw_year`: fixed OPEX in AUD/kW of installed capacity per year

To convert to AUD/h for a unit with `base_power` in MVA:
    `fixed_opex_aud_kw_year * base_power * 1000 / 8760`
"""
function read_isp_fixed_opex()
    file_source = joinpath(ISP_DATA_DIR, "fixed_opex.csv")
    df = CSV.read(file_source, DataFrame)
    return DataFrame(
        unit = df.iasr_id,
        isp_technology = df.technology,
        fixed_opex_aud_kw_year = df.fixed_opex_aud_kw_year,
    )
end

"""
    read_isp_variable_opex()

Read variable OPEX (AUD/MWh sent out) per generator from ISP 2025 data.

Returns a `DataFrame` with columns:
- `unit`: IASR ID of the generator
- `isp_technology`: ISP technology category (e.g. "Steam Sub Critical", "Wind")
- `variable_opex_aud_mwh`: variable OPEX in AUD/MWh sent out

Covers all technology types (thermal, hydro, renewable, storage).
Per ISP 2025, Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
because O&M costs are captured entirely in the Fixed O&M component.
"""
function read_isp_variable_opex()
    file_source = joinpath(ISP_DATA_DIR, "variable_opex.csv")
    df = CSV.read(file_source, DataFrame)
    return DataFrame(
        unit = df.iasr_id,
        isp_technology = df.technology,
        variable_opex_aud_mwh = df.variable_opex_aud_mwh_sent_out,
    )
end

"""
    read_isp_renewable_costs_parameters()

Read renewable variable OPEX parameters from ISP 2025 data.

Returns a `DataFrame` with columns:
- `unit`: DUID (or IASR ID) of the generator
- `variable_opex_aud_mwh`: variable OPEX in AUD/MWh sent out

Per ISP 2025, Wind and Large-scale Solar PV have 0 AUD/MWh variable OPEX
because O&M costs are captured entirely in the Fixed O&M component.
"""
function read_isp_renewable_costs_parameters()
    renewable_techs = ["Wind", "Large scale Solar PV"]
    df = read_isp_variable_opex()
    subset!(df, :isp_technology => ByRow(in(renewable_techs)))
    select!(df, Not(:isp_technology))
    return df
end
