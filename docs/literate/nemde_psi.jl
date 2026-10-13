begin
    using PowerSystems
    using PowerSimulations
    using JuMP
    using HiGHS
    using DataFrames
    using Dates
    using CairoMakie
end;

import PowerSystems as PSY
import PowerSimulations as PSI

include(joinpath(@__DIR__, "..", "..", "literate", "toy_market.jl")) #hide
include(joinpath(@__DIR__, "..", "..", "literate", "toy_jump.jl")); #hide

# # [From JuMP to PowerSimulations.jl](@id nemde-psi)
#
# [Page 2](@ref nemde-jump) solves a small dispatch market with JuMP. This page solves its
# energy-only, lossless version using [PowerSimulations.jl](https://nrel-sienna.github.io/PowerSimulations.jl/stable/)
# (PSI). A `PowerSystems.jl` (PSY) `System` contains the units, demand, interconnector and offers.
# A `ProblemTemplate` selects the network and device formulations, and a `DecisionModel`
# provides the interval and solver settings.
#
# ## The model, as a `System`
#
# !!! note "Example scope"
#     This example includes energy offers, availability, ramp limits, regional balance and a
#     lossless interconnector. It omits FCAS, interconnector losses and generic constraints.
#     The [next page](@ref nemde-aem) includes those features.
#
# The example system uses the same energy offers and demand as the JuMP tutorial.

function stock_system(market) #hide
    sys = PSY.System(BASE_POWER) #hide
    areas = Dict(r => PSY.Area(; name = r) for r in market.regions) #hide
    PSY.add_components!(sys, collect(values(areas))) #hide
    buses = Dict( #hide
        r => PSY.ACBus( #hide
            number = i, name = "$(r)-node", base_voltage = 330.0, bustype = PSY.ACBusTypes.PQ, #hide
            area = areas[r], available = true, angle = 0.0, magnitude = 1.0, #hide
            voltage_limits = (min = 0.9, max = 1.1), #hide
        ) for (i, r) in enumerate(market.regions) #hide
    ) #hide
    PSY.add_components!(sys, collect(values(buses))) #hide
    for u in market.units #hide
        floor_mw = max(0.0, initial_mw(u) - ramp_down(u)) #hide
        ceiling_mw = min(availability(u), initial_mw(u) + ramp_up(u)) #hide
        offer = PSY.CostCurve( #hide
            PSY.PiecewiseIncrementalCurve(0.0, [0.0; cumsum(quantity.(bids(u)))], price.(bids(u))), #hide
        ) #hide
        device = if is_semi_scheduled(u) #hide
            PSY.RenewableDispatch( #hide
                name = String(unit_name(u)), available = true, bus = buses[region(u)], active_power = 0.0, #hide
                reactive_power = 0.0, rating = ceiling_mw / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT, #hide
                reactive_power_limits = nothing, power_factor = 1.0, #hide
                operation_cost = PSY.RenewableGenerationCost(offer), base_power = BASE_POWER, #hide
            ) #hide
        else #hide
            PSY.ThermalStandard( #hide
                name = String(unit_name(u)), available = true, status = true, bus = buses[region(u)], #hide
                active_power = 0.0, reactive_power = 0.0, rating = u.capacity / BASE_POWER, #hide
                active_power_limits = (min = floor_mw / BASE_POWER, max = ceiling_mw / BASE_POWER), #hide
                reactive_power_limits = nothing, ramp_limits = nothing, #hide
                operation_cost = PSY.ThermalGenerationCost(; variable = offer, fixed = 0.0, start_up = 0.0, shut_down = 0.0), #hide
                base_power = BASE_POWER, time_limits = nothing, #hide
                prime_mover_type = PSY.PrimeMovers.GT, fuel = PSY.ThermalFuels.NATURAL_GAS, #hide
            ) #hide
        end #hide
        PSY.add_component!(sys, device) #hide
    end #hide
    for r in market.regions #hide
        mw = region_demand(market, r) #hide
        load = PSY.PowerLoad( #hide
            name = "$(r)-load", available = true, bus = buses[r], active_power = mw / BASE_POWER, #hide
            reactive_power = 0.0, base_power = BASE_POWER, max_active_power = mw / BASE_POWER, #hide
            max_reactive_power = 0.0, #hide
        ) #hide
        PSY.add_component!(sys, load) #hide
        PSY.add_time_series!( #hide
            sys, load, #hide
            PSY.SingleTimeSeries( #hide
                name = "max_active_power", #hide
                data = PSY.TimeSeries.TimeArray([T0, T0 + RESOLUTION], [1.0, 1.0]), #hide
                scaling_factor_multiplier = PSY.get_max_active_power, #hide
            ), #hide
        ) #hide
    end #hide
    PSY.transform_single_time_series!(sys, 2 * RESOLUTION, RESOLUTION) #hide
    ic = market.interconnector #hide
    PSY.add_component!( #hide
        sys, #hide
        PSY.AreaInterchange( #hide
            name = ic.name, available = true, active_power_flow = 0.0, #hide
            from_area = areas[ic.from], to_area = areas[ic.to], #hide
            flow_limits = (from_to = ic.max_flow / BASE_POWER, to_from = ic.max_flow / BASE_POWER), #hide
        ), #hide
    ) #hide
    return sys #hide
end #hide

sys = stock_system(energy_market(market)) #hide

# Each unit's offer is its `variable` cost: a piecewise *incremental* curve whose x-coordinates are
# the cumulative band quantities and whose slopes are the band prices, exactly the bid stack of page 2.

PSY.get_variable(PSY.get_operation_cost(PSY.get_component(PSY.ThermalStandard, sys, "COAL1")))

# ## The template
#
# One formulation per component type, and a network model. `AreaBalancePowerModel` is PSI's
# regional network: one balance row per `Area`, with `AreaInterchange` flows moving power between
# areas. This example uses one area for each region.

network = PSI.NetworkModel(PSI.AreaBalancePowerModel; duals = [PSI.CopperPlateBalanceConstraint])
template = PSI.ProblemTemplate(network)
PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
template

# ## Build and solve

model_psi = PSI.DecisionModel(
    template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    horizon = RESOLUTION, resolution = RESOLUTION, interval = RESOLUTION,
    initial_time = T0, name = "nemde_psi", store_variable_names = true,
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

solve_status = PSI.solve!(model_psi)
results = PSI.OptimizationProblemResults(model_psi)

# ## Checking against page 2
#
# Variables are in MW and duals are per unit of the system base and per interval, so
# `dual / (BASE_POWER * interval hours)` is \$/MWh. The same market with a lossless interconnector
# and no FCAS or generic constraints, solved with the JuMP script of page 2, gives the same answer:

psi_dispatch = Dict(
    Symbol(r.name) => r.value for key in ("ThermalStandard", "RenewableDispatch")
        for r in eachrow(PSI.read_variable(results, "ActivePowerVariable__$key"))
)
psi_price = Dict(
    r.name => r.value / (BASE_POWER * INTERVAL_H)
        for r in eachrow(PSI.read_dual(results, "CopperPlateBalanceConstraint__Area"))
)
psi_flow = only(PSI.read_variable(results, "FlowActivePowerVariable__AreaInterchange").value)

reference = solve_toy_jump(energy_market(market); fcas = false)

comparison = DataFrame(
    quantity = [
        "COAL1 (MW)", "WIND1 (MW)", "GAS1 (MW)", "Flow NSW1 to VIC1 (MW)",
        "NSW1 price (\$/MWh)", "VIC1 price (\$/MWh)",
    ],
    JuMP = [
        reference.dispatch[:COAL1], reference.dispatch[:WIND1], reference.dispatch[:GAS1], reference.flow,
        reference.price["NSW1"], reference.price["VIC1"],
    ],
    PSI = [
        psi_dispatch[:COAL1], psi_dispatch[:WIND1], psi_dispatch[:GAS1], psi_flow,
        psi_price["NSW1"], psi_price["VIC1"],
    ],
)
comparison.difference = comparison.PSI .- comparison.JuMP
comparison

@assert build_status == PSI.ModelBuildStatus.BUILT
@assert solve_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
@assert maximum(abs, comparison.difference) < 1.0e-4

# ## Adding NEM features
#
# The [next page](@ref nemde-aem) solves the toy market with FCAS, interconnector losses and
# generic constraints using `AustralianElectricityMarkets` and
# `AustralianElectricityMarketsSimulations`.
