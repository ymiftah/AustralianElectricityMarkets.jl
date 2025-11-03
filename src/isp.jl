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
