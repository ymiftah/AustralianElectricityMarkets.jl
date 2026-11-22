const ISP_DATA_DIR = joinpath(@__DIR__, "..", "..", "data", "isp2025")


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


# An ISP price table in long format: `id_cols`, `year` (first year of the financial year) and
# `price_aud`.
function _read_isp_prices(file_name::String, id_cols)
    return @chain joinpath(ISP_DATA_DIR, file_name) begin
        CSV.read(DataFrame)
        stack(Not(id_cols); variable_name = :year, value_name = :price_aud)
        transform!(
            :year => ByRow(x -> parse(Int, split(x, "-")[1])) => :year,
            :price_aud => ByRow(x -> parse(Float64, strip(x, ['$', ' ']))) => :price_aud,
        )
    end
end


"""
    read_coal_prices()

Reads coal prices from ISP 2025 data.

# Returns
A `DataFrame` with `station`, `scenario`, `year` and `price_aud`.
"""
read_coal_prices() = _read_isp_prices("coal_prices.csv", [:station, :scenario])


"""
    read_gas_prices()

Reads gas prices from ISP 2025 data.

# Returns
A `DataFrame` with `station`, `scenario`, `year` and `price_aud`.
"""
read_gas_prices() = _read_isp_prices("gas_prices.csv", [:station, :scenario])


"""
    read_biomass_prices()

Reads biomass prices from ISP 2025 data.

# Returns
A `DataFrame` with `scenario`, `year` and `price_aud`.
"""
read_biomass_prices() = _read_isp_prices("biomass_prices.csv", [:scenario])


"""
    read_isp_thermal_costs_parameters(year::Int, scenario::String)

Read thermal costs parameters from ISP 2025 data for a given `year` and `scenario`.

# Arguments
- `year::Int`: The year to read data for.
- `scenario::String`: The scenario to read data for.
"""
function read_isp_thermal_costs_parameters(year::Int, scenario::String)
    prices = vcat(read_coal_prices(), read_gas_prices())
    available_scenarios = unique(prices.scenario)
    available_years = unique(prices.year)
    scenario in available_scenarios || throw(ArgumentError("scenario value must be one of $available_scenarios"))
    year in available_years || throw(ArgumentError("year value must be one of $available_years"))
    biomass_price = @chain read_biomass_prices() begin
        subset(:year => ByRow(==(year)), :scenario => ByRow(==(scenario)))
        only(_.price_aud)
    end
    return @chain prices begin
        subset(:year => ByRow(==(year)), :scenario => ByRow(==(scenario)))
        select(Not(:year, :scenario))
        leftjoin(read_affine_heatrates(), _, on = :station)
        # biomass units take the biomass price
        transform([:technology, :price_aud] => ByRow((tech, price) -> tech == "Biomass" ? biomass_price : price) => :price_aud)
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
    return @chain joinpath(ISP_DATA_DIR, "fixed_opex.csv") begin
        CSV.read(DataFrame)
        select(:iasr_id => :unit, :technology => :isp_technology, :fixed_opex_aud_kw_year)
    end
end


"""
    read_isp_variable_opex()

Read variable OPEX (AUD/MWh sent out) per generator from ISP 2025 data.

Returns a `DataFrame` with columns:
- `unit`: IASR ID of the generator
- `isp_technology`: ISP technology category (e.g. "Steam Sub Critical", "Wind")
- `variable_opex_aud_mwh`: variable OPEX in AUD/MWh sent out

Covers all technology types; Wind and Large-scale Solar PV have 0 AUD/MWh.
"""
function read_isp_variable_opex()
    return @chain joinpath(ISP_DATA_DIR, "variable_opex.csv") begin
        CSV.read(DataFrame)
        select(
            :iasr_id => :unit, :technology => :isp_technology,
            :variable_opex_aud_mwh_sent_out => :variable_opex_aud_mwh,
        )
    end
end


"""
    read_isp_renewable_costs_parameters()

Read renewable variable OPEX parameters from ISP 2025 data.

Returns a `DataFrame` with columns:
- `unit`: DUID (or IASR ID) of the generator
- `variable_opex_aud_mwh`: variable OPEX in AUD/MWh sent out (0 for Wind and Large-scale Solar PV)
"""
function read_isp_renewable_costs_parameters()
    renewable_techs = ["Wind", "Large scale Solar PV"]
    df = read_isp_variable_opex()
    subset!(df, :isp_technology => ByRow(in(renewable_techs)))
    select!(df, Not(:isp_technology))
    return df
end
