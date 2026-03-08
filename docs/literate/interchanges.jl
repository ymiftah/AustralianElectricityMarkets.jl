using AustralianElectricityMarkets
import AustralianElectricityMarkets.RegionModel as RM
using PowerSystems
using PowerSimulations
using HydroPowerSimulations
using Chain
using DataFrames
using AlgebraOfGraphics, CairoMakie
using TidierDB
using Dates
using HiGHS

# # The impact of network constraints
#
# We previously ignored the network constraints by adopting a "Copper Plate" model.
# In this zonal model, we will treat each region as a single node (the "Regional Reference Node")
# and the interconnectors as links between them. This will limit the energy that can be transferred
# between regions, and lead to different prices across regions once the market is cleared.
#
# While this captures inter-regional congestion, it does not model intra-regional constraints
# (congestion within a state), which AEMO manages through a process called "Constraint Equations."
#
# ## Setup the system
#
# !!! note "Get the data first!"
#     You will first need to download the data from the monthly archive, saving them locally
#     in parquet files.
#
# ```julia
# tables = table_requirements(RegionalNetworkConfiguration())
# map(tables) do table
#     fetch_table_data(table, Date(2025, 1, 1):Date(2025,1,31))
# end;
# ```

db = aem_connect(duckdb());

# Instantiate the system.

sys = nem_system(db, RegionalNetworkConfiguration())

# Set the horizon to consider for the simulation.

interval = Minute(5)
horizon = Hour(24)
start_date = DateTime(2025, 1, 2, 0, 0)
date_range = start_date:interval:(start_date + horizon)
@show date_range

# Set deterministic time series.

set_demand!(sys, db, date_range; resolution = interval)
set_renewable_pv!(sys, db, date_range; resolution = interval)
set_renewable_wind!(sys, db, date_range; resolution = interval)
set_hydro_limits!(sys, db, date_range; resolution = interval)
set_market_bids!(sys, db, date_range; resolution = interval)

# Derive forecasts from the deterministic time series.

transform_single_time_series!(sys, horizon, interval);
@show sys

# ## Set up the problem

begin
    template = ProblemTemplate()
    set_device_model!(template, Line, StaticBranch)
    set_device_model!(template, PowerLoad, StaticPowerLoad)
    set_device_model!(template, RenewableDispatch, RenewableFullDispatch)
    set_device_model!(template, ThermalStandard, ThermalBasicUnitCommitment)
    set_device_model!(template, HydroDispatch, HydroDispatchRunOfRiver)
    set_network_model!(template, NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_device_model!(template, AreaInterchange, StaticBranch)
    template
end

# The dispatch problem will be solved with open source solver HiGHS.

solver = optimizer_with_attributes(HiGHS.Optimizer, "mip_rel_gap" => 0.1)
problem = DecisionModel(template, sys; optimizer = solver, horizon = horizon)
build!(problem; output_dir = joinpath(tempdir(), "out"))

# Solve the problem.

solve!(problem)

# Observe the results.

res = OptimizationProblemResults(problem)

# Let's observe how the units are dispatched.

begin
    function filter_non_all_zero(df, group_by)
        gdf = groupby(df, group_by)
        is_all_zero = combine(gdf, :value => (x -> all(x == 0)) => :all_zero)
        subset!(is_all_zero, :all_zero => x -> .!x)
        return innerjoin(df, is_all_zero, on = group_by)
    end

    renewables = read_variable(res, "ActivePowerVariable__RenewableDispatch")
    thermal = read_variable(res, "ActivePowerVariable__ThermalStandard")
    hydro = read_variable(res, "ActivePowerVariable__HydroDispatch")
    gens_long = vcat(renewables, thermal, hydro)
    select!(gens_long, :DateTime, :name => :DUID, :value)

    by_fuel = @chain select(
        read_units(db),
        [:DUID, :STATIONID, :CO2E_ENERGY_SOURCE, :REGIONID]
    ) begin
        rightjoin(gens_long, on = :DUID)
        groupby([:CO2E_ENERGY_SOURCE, :REGIONID, :DateTime])
        combine(:value => sum => :value)
        dropmissing!
        select!(:DateTime, :REGIONID, :CO2E_ENERGY_SOURCE => :Source, :value)
        filter_non_all_zero([:REGIONID, :Source])
    end

    loads = @chain res begin
        read_parameter("ActivePowerTimeSeriesParameter__PowerLoad")
        transform!(:name => ByRow(x -> split(x, " ")[1]) => :REGIONID)
        subset!(:REGIONID => ByRow(!=("SNOWY1")))
        insertcols!(:Source => "Region demand")
        select!(:DateTime, :REGIONID, :Source, :value => ByRow(-) => :value)
    end

    demand = data(loads) * mapping(:DateTime, :value, color = :Source, layout = :REGIONID) * visual(Lines, linestyle = (:dash, :dense))
    generation = data(by_fuel) * mapping(:DateTime, :value, color = :Source, layout = :REGIONID) * visual(Lines)
    draw(demand + generation; figure = (; size = (1000, 800)), legend = (; position = :bottom))
end

# Let's observe the dispatch of a few thermal generators.

begin
    thermals_non_zero = filter_non_all_zero(thermal, :name)
    sample = first(unique(thermals_non_zero.name), 5)
    sample = subset!(thermals_non_zero, :name => ByRow(in(sample)))
    spec = data(sample) * mapping(:DateTime, :value, color = :name) * visual(Lines)
    draw(spec; figure = (; size = (500, 500)))
end

# Let's observe the dispatch of a few renewable generators.

begin
    renewables_non_zero = filter_non_all_zero(renewables, :name)
    sample = first(unique(renewables_non_zero.name), 5)
    sample = subset!(renewables_non_zero, :name => ByRow(in(sample)))
    data(sample) * mapping(:DateTime, :value, color = :name) * visual(Lines) |> draw
end

# Notice that most solar generators are actually **not** dispatched during the day here even
# though the solar output is definitely non-zero.

begin
    ren = get_component(RenewableDispatch, sys, "COLEASF1")
    ts = get_time_series_array(Deterministic, ren, "max_active_power") |> DataFrame
    index, values = ts.timestamp, ts.A * 100
    fig = Figure()
    ax = Axis(fig[1, 1], xlabel = "timestamp", title = "Max active power [MW]", ylabel = "MW")
    lines!(index, values; label = "COLEASF1")
    axislegend(ax)
    fig
end

# In the NEM, interconnectors are vital for sharing resources between states. However, when
# an interconnector reaches its limit (becomes saturated), the regions on either side can
# have different clearing prices. This **Price Separation** is a key feature of the NEM's
# regional structure. Let's observe the interchange flows and how close they operate to their limits.

begin
    interchange_flow = read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    spec = data(interchange_flow) * mapping(:DateTime, :value => "Interchange flow (MW)", color = :name) * visual(Lines)
    draw(spec; figure = (; size = (500, 500)))
end

# We see that a few lines are often saturated: V-S-MNSP1 connecting Victoria and South Australia,
# or T-V-MSP1 connecting Victoria and Tasmania. The interfaces between New South Wales and Queensland,
# and New South Wales and Victoria are operated within their bounds and the power flows in both
# directions depending on the time of the day and resources available.
