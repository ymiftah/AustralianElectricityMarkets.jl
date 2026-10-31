begin
    using PowerSystems
    using PowerSimulations
    using JuMP
    using HiGHS
    using DataFrames
    using Dates
    using CairoMakie
    using InteractiveUtils
end;

import PowerSystems as PSY
import PowerSimulations as PSI

include(joinpath(@__DIR__, "..", "..", "literate", "shared", "toy_market.jl")) #hide
include(joinpath(@__DIR__, "..", "..", "literate", "shared", "toy_jump.jl")); #hide

# # [From JuMP to PowerSimulations.jl](@id nemde-psi)
#
# [Page 2](@ref nemde-jump) wrote the dispatch of a toy market as one JuMP script. Every unit
# type, service and constraint in that script touches the same objective, the same balance rows
# and the same bookkeeping, so it does not grow into a model of the whole NEM.
# [PowerSimulations.jl](https://nrel-sienna.github.io/PowerSimulations.jl/stable/) (PSI) is the
# framework this repository builds its NEMDE replica on. This page introduces its concepts by
# rebuilding the energy-only part of the toy market with them, and shows which lines of page 2
# each concept produces.
#
# PSI splits a model into three layers:
#
# | Layer | Answers | Package and object | On this page |
# | --- | --- | --- | --- |
# | **Data** | What is the market? | `PowerSystems.jl` (PSY): a `System` of components and time series | regions, units, offers, demand, the interconnector |
# | **Formulation** | How is one kind of component modelled? | PSI: a formulation type, with methods that write its variables, constraints and costs | "a scheduled unit is dispatched between bounds at its offer cost" |
# | **Problem** | Which formulation applies to which component, over which horizon? | PSI: a `ProblemTemplate` and a `DecisionModel` | one 5-minute dispatch interval |
#
# `build!` turns the three into a JuMP model, held inside an `OptimizationContainer`. No line of
# the JuMP model is written by hand: Julia's **multiple dispatch** on the pair *(component type,
# formulation type)* picks the methods that write it. Replicating NEMDE is then a matter of
# adding formulations, not of editing one large script.
#
# !!! note "Example scope"
#     Stock PSI formulations express energy offers, availability, regional balance and a lossless
#     interconnector, so this page solves that part of the toy market (`energy_market(market)`).
#     FCAS, interconnector losses and generic constraints need the NEM formulations of the
#     [next page](@ref nemde-aem).
#
# ## Data: the market as a `System`
#
# A `System` is a typed collection of components. Each NEM object of page 2 maps onto a PSY
# component type:
#
# | Toy market | PSY component | Fields used |
# | --- | --- | --- |
# | region | `Area` | name |
# | regional reference node | `ACBus` in that `Area` | |
# | scheduled unit (`COAL1`, `GAS1`) | `ThermalStandard` | `active_power_limits`, `operation_cost` |
# | semi-scheduled unit (`WIND1`) | `RenewableDispatch` | `rating`, `operation_cost` |
# | regional demand | `PowerLoad` | `max_active_power` and a time series |
# | interconnector | `AreaInterchange` between two `Area`s | `flow_limits` |
#
# Values are stored per unit of the system base, `BASE_POWER` MVA.

m = energy_market(market)
sys = PSY.System(BASE_POWER)

areas = Dict(r => PSY.Area(; name = r) for r in m.regions)
PSY.add_components!(sys, collect(values(areas)))
buses = Dict(
    r => PSY.ACBus(;
        number = i, name = "$(r)-node", base_voltage = 330.0, bustype = PSY.ACBusTypes.PQ,
        area = areas[r], available = true, angle = 0.0, magnitude = 1.0,
        voltage_limits = (min = 0.9, max = 1.1),
    ) for (i, r) in enumerate(m.regions)
)
PSY.add_components!(sys, collect(values(buses)));

# ### Units and their offers
#
# A unit's energy offer is its `variable` cost: a `PiecewiseIncrementalCurve` whose x-coordinates
# are the cumulative band quantities and whose slopes are the band prices, the bid stack of page 2.
#
# The dispatch envelope of page 2 (availability, and the ramp from `INITIALMW` over one interval)
# has no direct field here: PSI's stock formulations ramp between consecutive time steps of the
# problem, not from a metered initial output. For a single interval the envelope is a pair of
# bounds, so it goes into `active_power_limits` (and `rating` for the renewable unit).

function psy_unit(u::Unit, bus::PSY.ACBus)
    floor_mw = max(0.0, initial_mw(u) - ramp_down(u))
    ceiling_mw = min(availability(u), initial_mw(u) + ramp_up(u))
    offer = PSY.CostCurve(
        PSY.PiecewiseIncrementalCurve(0.0, [0.0; cumsum(quantity.(bids(u)))], price.(bids(u))),
    )
    is_semi_scheduled(u) && return PSY.RenewableDispatch(;
        name = String(unit_name(u)), available = true, bus, active_power = 0.0,
        reactive_power = 0.0, rating = ceiling_mw / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT,
        reactive_power_limits = nothing, power_factor = 1.0,
        operation_cost = PSY.RenewableGenerationCost(offer), base_power = BASE_POWER,
    )
    return PSY.ThermalStandard(;
        name = String(unit_name(u)), available = true, status = true, bus,
        active_power = 0.0, reactive_power = 0.0, rating = u.capacity / BASE_POWER,
        active_power_limits = (min = floor_mw / BASE_POWER, max = ceiling_mw / BASE_POWER),
        reactive_power_limits = nothing, ramp_limits = nothing,
        operation_cost = PSY.ThermalGenerationCost(; variable = offer, fixed = 0.0, start_up = 0.0, shut_down = 0.0),
        base_power = BASE_POWER, time_limits = nothing,
        prime_mover_type = PSY.PrimeMovers.GT, fuel = PSY.ThermalFuels.NATURAL_GAS,
    )
end

for u in m.units
    PSY.add_component!(sys, psy_unit(u, buses[region(u)]))
end
PSY.get_variable(PSY.get_operation_cost(PSY.get_component(PSY.ThermalStandard, sys, "COAL1")))

# ### Demand as a time series
#
# A component field is a constant. Anything that changes from one interval to the next (demand,
# a forecast, a bid) is a **time series** attached to a component. PSI reads it into the model as
# a *parameter*, so the same built model can be re-solved for the next interval by updating
# parameter values instead of rebuilding. Here the series is a multiplier on `max_active_power`.
#
# PSI solves over forecast windows, so the single series is turned into windows of two intervals
# that advance by one: the shortest window PSI accepts.

for r in m.regions
    mw = region_demand(m, r)
    load = PSY.PowerLoad(;
        name = "$(r)-load", available = true, bus = buses[r], active_power = mw / BASE_POWER,
        reactive_power = 0.0, base_power = BASE_POWER, max_active_power = mw / BASE_POWER,
        max_reactive_power = 0.0,
    )
    PSY.add_component!(sys, load)
    PSY.add_time_series!(
        sys, load,
        PSY.SingleTimeSeries(;
            name = "max_active_power",
            data = PSY.TimeSeries.TimeArray([T0, T0 + RESOLUTION], [1.0, 1.0]),
            scaling_factor_multiplier = PSY.get_max_active_power,
        ),
    )
end
PSY.transform_single_time_series!(sys, 2 * RESOLUTION, RESOLUTION)

# ### The interconnector

ic = m.interconnector
PSY.add_component!(
    sys,
    PSY.AreaInterchange(;
        name = ic.name, available = true, active_power_flow = 0.0,
        from_area = areas[ic.from], to_area = areas[ic.to],
        flow_limits = (from_to = ic.max_flow / BASE_POWER, to_from = ic.max_flow / BASE_POWER),
    ),
)
sys

# Nothing in the `System` says how a unit is dispatched or what a region's balance looks like.
# That is the job of the next two layers.
#
# ## Formulations: how a component is modelled
#
# A formulation is an empty Julia type. It carries no data and no equations; it is a *name* for a
# way of modelling a component type. PSI ships several for thermal units, from a linear dispatch
# to unit commitment:

subtypes(PSI.AbstractThermalDispatchFormulation)

# The equations live in methods of PSI's construction functions, and Julia chooses the method
# from the types it is called with. A `DeviceModel{ThermalStandard, ThermalBasicDispatch}`
# reaches the method PSI wrote for that pair:

function construction_method(T, D)
    method = which(
        PSI.construct_device!,
        Tuple{
            PSI.OptimizationContainer, PSY.System, PSI.ArgumentConstructStage,
            PSI.DeviceModel{T, D}, PSI.NetworkModel{PSI.AreaBalancePowerModel},
        },
    )
    return "$(method.module): $(basename(String(method.file))), line $(method.line)"
end
construction_method(PSY.ThermalStandard, PSI.ThermalBasicDispatch)

# Choosing another formulation for the same `System` runs other methods and writes a different
# model. The NEM formulations of the next page work the same way: `NEMReplayDispatch` is a new
# formulation type, and this repository adds `construct_device!` methods for it. PSI does not
# need to know it exists.
#
# ## The problem: a template and a decision model
#
# A `ProblemTemplate` pairs each component type with a formulation, and fixes the **network
# model**: how the components' injections are balanced. `AreaBalancePowerModel` writes one
# balance row per `Area`, with `AreaInterchange` flows moving power between areas. With one area
# per region, that is the NEM's regional market.

network = PSI.NetworkModel(PSI.AreaBalancePowerModel; duals = [PSI.CopperPlateBalanceConstraint])
template = PSI.ProblemTemplate(network)
PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
template

# Duals are opt-in: the `duals` keyword asks PSI to keep the dual of each regional balance row,
# the regional price. Without it no price can be read back.
#
# A `DecisionModel` adds what the template leaves open: the solver, the first interval and the
# horizon. A NEMDE dispatch run clears one 5-minute interval, so horizon, resolution and the step
# between solves are all `RESOLUTION`.

model_psi = PSI.DecisionModel(
    template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    horizon = RESOLUTION, resolution = RESOLUTION, interval = RESOLUTION,
    initial_time = T0, name = "nemde_psi", store_variable_names = true,
);

# ## Building: how PSI writes the JuMP model
#
# `build!` runs the construction phases below in a fixed order, handing the same container to
# each. Devices, services and branches are each visited twice. The **argument stage** adds
# variables, parameters and expressions. The **model stage** adds the constraints and costs on
# them. The split lets every component contribute to a shared expression, such as a region's
# balance, before any constraint is written on it.
#
# | # | Phase | Hook | Adds |
# | --- | --- | --- | --- |
# | 0 | System | `initialize_system_expressions!` | an empty `ActivePowerBalance` expression per `Area` |
# | 1 | Devices | `construct_device!`, `ArgumentConstructStage` | unit and load variables, parameters, expressions |
# | 2 | Services | `construct_services!`, `ArgumentConstructStage` | service variables and expressions |
# | 3 | Branches | `construct_device!`, `ArgumentConstructStage` | interconnector flow variables |
# | 4 | Devices | `construct_device!`, `ModelConstructStage` | unit constraints and costs |
# | 5 | Network | `construct_network!` | the regional balance constraints |
# | 6 | Branches | `construct_device!`, `ModelConstructStage` | interconnector flow limits |
# | 7 | Services | `construct_services!`, `ModelConstructStage` | service constraints |
# | 8 | Objective | `update_objective_function!` | the sum of every registered cost term |

function plot_phases() #hide
    fig = Figure(size = (1000, 260)) #hide
    ax = Axis(fig[1, 1]; yreversed = true, backgroundcolor = :transparent) #hide
    hidedecorations!(ax); hidespines!(ax) #hide
    xlims!(ax, -0.1, 10.9); ylims!(ax, 1.7, -0.1) #hide
    palette = Makie.wong_colors() #hide
    stage_color = Dict("expressions" => palette[3], "arguments" => palette[1], "model" => palette[2], "assembly" => palette[3]) #hide
    shapes = [ #hide
        ("0", "System", "expressions"), ("1", "Devices", "arguments"), ("2", "Services", "arguments"), #hide
        ("3", "Branches", "arguments"), ("4", "Devices", "model"), ("5", "Network", "model"), #hide
        ("6", "Branches", "model"), ("7", "Services", "model"), ("8", "Objective", "assembly"), #hide
    ] #hide
    for (i, (number, title, stage)) in enumerate(shapes) #hide
        x = (i - 1) * 1.2 #hide
        color = stage_color[stage] #hide
        poly!(ax, Rect2f(x, 0.2, 1.05, 1.3); color = (color, 0.55), strokecolor = color, strokewidth = 2) #hide
        text!(ax, x + 0.52, 0.5; text = number, align = (:center, :center), fontsize = 22, font = :bold) #hide
        text!(ax, x + 0.52, 0.95; text = title, align = (:center, :center), fontsize = 13) #hide
        text!(ax, x + 0.52, 1.2; text = stage, align = (:center, :center), fontsize = 12, color = (:gray, 1.0)) #hide
        i < length(shapes) && arrows2d!(ax, [x + 1.06], [0.85], [0.13], [0.0]; color = :gray) #hide
    end #hide
    return fig #hide
end #hide
plot_phases() #hide

# Each phase is shown below next to the lines of page 2 it replaces. Highlighted lines are the
# ones the phase generates.
#
# ### Phase 0 and 1: variables and the balance terms
#
# On page 2 each unit's dispatch is declared, then each region's balance sums the dispatch of its
# units. In PSI the balance is an `ActivePowerBalance` expression per area, created empty in
# phase 0. In phase 1 each unit declares its variables and adds its own power to the
# expression of its area, and each load subtracts its demand parameter. A device never sees the
# balance row, so a new device type needs no change to it.
#
# ```julia
# @variable(model, 0 <= cleared[u in market.units, j in 1:n_bids(u)] <= quantity(bid(u, j)))  # [!code highlight]
# @expression(model, dispatch[u in market.units], sum(cleared[u, j] for j in 1:n_bids(u)))  # [!code highlight]
# generation(r) = sum(dispatch[u] for u in units_in(market, r))  # [!code focus]
# ```
#
# The argument-stage method is a list of calls, each adding one kind of object to the container.
# This is the method this repository writes for its NEM dispatch formulations, abridged:
#
# ```julia
# function PSI.construct_device!(
#         container, sys, ::PSI.ArgumentConstructStage,
#         model::PSI.DeviceModel{T, D}, network_model,
#     ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
#     devices = PSI.get_available_components(model, sys)
#     PSI.add_variables!(container, PSI.ActivePowerVariable, devices, D())  # [!code highlight]
#     PSI.add_parameters!(container, InitialPowerTimeSeriesParameter, devices, model)
#     PSI.add_cost_expressions!(container, devices, model)
#     PSI.add_to_expression!(  # [!code highlight]
#         container, PSI.ActivePowerBalance, PSI.ActivePowerVariable, devices, model, network_model,
#     )
#     return
# end
# ```
#
# The `where` clause is the dispatch rule: the method runs for any component type `T` modelled
# with any formulation `D` under `AbstractNEMDispatch`.
#
# ### Phase 3: the interconnector flow
#
# The flow is a variable of the branch, declared in the branches' argument stage and added to the
# two area balances with opposite signs:
#
# ```julia
# @variable(model, flow)  # [!code highlight]
# exported(r) = r == ic.from ? flow : -flow  # [!code highlight]
# ```
#
# ### Phase 4: component constraints and costs
#
# Rows that involve one component: on page 2, availability and the ramp envelope. Here they are
# the limits of `ActivePowerVariable` read from `active_power_limits`. The offer cost is
# registered with the container rather than written into an objective.
#
# ```julia
# @constraint(model, availability_limit[u in market.units], dispatch[u] <= availability(u))  # [!code highlight]
# @constraint(model, ramp_up_limit[u in market.units], dispatch[u] - initial_mw(u) <= ramp_up(u))  # [!code highlight]
# @constraint(model, ramp_down_limit[u in market.units], initial_mw(u) - dispatch[u] <= ramp_down(u))  # [!code highlight]
# ```
#
# The model-stage method of the NEM formulation writes these rows from per-interval parameters,
# with the ramp measured from the metered initial output (abridged):
#
# ```julia
# function PSI.construct_device!(
#         container, sys, ::PSI.ModelConstructStage,
#         model::PSI.DeviceModel{T, D}, network_model,
#     ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
#     devices = PSI.get_available_components(model, sys)
#     PSI.add_constraints!(container, EnergyMaxAvailConstraint, PSI.ActivePowerVariable, devices, model, network_model)  # [!code highlight]
#     PSI.add_constraints!(container, PSI.RampConstraint, PSI.ActivePowerVariable, devices, model, network_model)  # [!code highlight]
#     PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))  # [!code highlight]
#     return
# end
# ```
#
# `add_constraints!` is itself dispatched on the constraint type, so `PSI.RampConstraint` for a
# NEM formulation runs this repository's ramp rows, while the same call for a stock formulation
# runs PSI's.
#
# ### Phase 5: the network
#
# The constraint joining components: each area's balance expression, now complete with every
# device and branch term, is set equal to zero. Demand entered it in phase 1 as a negative term
# from each `PowerLoad`. The dual of this row is the regional price.
#
# ```julia
# @constraint(  # [!code highlight]
#     model, balance[r in market.regions],  # [!code highlight]
#     generation(r) - exported(r) - loss_charged(r) == region_demand(market, r),  # [!code highlight]
# )  # [!code highlight]
# ```
#
# ### Phase 6 and 7: branch limits and services
#
# Flow limits are model-stage constraints of the branch. **Services** are PSI's objects for
# requirements shared by a group of devices, such as a reserve. Their constraints act on
# variables of several devices, and sometimes on flows, so they are written last. On page 2 the
# FCAS rows and the generic constraints play this role; on the next page they are services.
#
# ```julia
# @constraint(model, flow_limit_up, flow <= ic.max_flow)  # [!code highlight]
# @constraint(model, flow_limit_down, flow >= -ic.max_flow)  # [!code highlight]
# @constraint(model, trapezium_upper[u in fcas_units(market)], dispatch[u] + upper_slope(trapezium(u)) * raise[u] <= trapezium(u).enablement_max)  # [!code focus]
# add_generic_constraint!(model, gc)  # [!code focus]
# ```
#
# ### Phase 8: the objective
#
# Every phase registers its cost terms (offers, slacks, penalties) in the container instead of
# writing an objective. `update_objective_function!` sums them once, at the end:
#
# ```julia
# @objective(model, Min, offer_cost)  # [!code highlight]
# set_objective_function(model, objective_function(model) + fcas_cost)  # [!code focus]
# ```

build_status = PSI.build!(model_psi; output_dir = mktempdir())

# ## The container: where the model lives
#
# The `OptimizationContainer` is a typed registry of everything the phases added. An entry is
# addressed by a key *(entry type, component type)* instead of a variable name:

container = PSI.get_optimization_container(model_psi)

function container_keys(container)
    rows = NamedTuple{(:kind, :entry, :component, :meta), NTuple{4, String}}[]
    for (kind, entries) in (
            "variable" => PSI.get_variables(container), "expression" => PSI.get_expressions(container),
            "parameter" => PSI.get_parameters(container), "constraint" => PSI.get_constraints(container),
        )
        for key in keys(entries)
            push!(
                rows, (;
                    kind, entry = string(nameof(PSI.IS.Optimization.get_entry_type(key))),
                    component = string(nameof(PSI.IS.Optimization.get_component_type(key))),
                    key.meta,
                ),
            )
        end
    end
    return sort!(DataFrame(rows), [:kind, :entry])
end
container_keys(container)

# The component type in a key is the domain the entry is indexed over: `ActivePowerVariable` is
# kept separately for `ThermalStandard` and `RenewableDispatch`, while the balance is indexed by
# `Area` because the network model is area-based. The `meta` part tells apart entries of the same
# type, such as the lower (`lb`) and upper (`ub`) limit rows. Each object of page 2 has a typed home:
#
# | Page 2 (JuMP) | PSI container entry | Phase |
# | --- | --- | --- |
# | `dispatch[u]` | variable `ActivePowerVariable` | 1 |
# | `cleared[u, j]` and the offer cost | variable `PiecewiseLinearCostVariable`, constraint `PiecewiseLinearCostConstraint`, expression `ProductionCostExpression` | 1 and 4 |
# | `region_demand(market, r)` | parameter `ActivePowerTimeSeriesParameter` on `PowerLoad` | 1 |
# | availability and ramp envelope | constraint `ActivePowerVariableLimitsConstraint` (`lb`, `ub`) on the range expressions of `ActivePowerVariable` | 4 |
# | `flow` | variable `FlowActivePowerVariable` | 3 |
# | `balance[r]` | expression `ActivePowerBalance` and constraint `CopperPlateBalanceConstraint` on `Area` | 0, 1 and 5 |
# | `flow_limit_up`, `flow_limit_down` | constraint `FlowLimitConstraint` (`lb`, `ub`) | 6 |
#
# The cost expressions PSI registers for fuel, start-up and other terms are created for every
# thermal unit and stay empty here: the toy offers have no such components.
#
# Underneath is an ordinary JuMP model, reachable with `get_jump_model`. Every JuMP tool (fixing
# a variable, writing an LP file, printing the model) works on it:

print(PSI.get_jump_model(container))

# Three differences from page 2 show in the printout:
#
# - Values are per unit of the system base: `NSW1`'s 450 MW of demand is `4.5`.
# - The offer is written as weights on the breakpoints of the cost curve
#   (`PiecewiseLinearCostVariable`, summing to 1), not as MW per band. For an offer whose prices
#   rise with quantity the two give the same dispatch and cost. `WIND1` offers only at \$0, so it
#   adds no cost variables.
# - Demand, a parameter, appears as the right-hand side of each balance row.

# ## Solving and reading results
#
# Results are read back by the same keys, written as `"Entry__Component"`. Variables are in MW.
# Duals are per unit of the system base and per interval, so `dual / (BASE_POWER * interval hours)`
# is \$/MWh.

solve_status = PSI.solve!(model_psi)
results = PSI.OptimizationProblemResults(model_psi)

psi_dispatch = Dict(
    Symbol(r.name) => r.value for key in ("ThermalStandard", "RenewableDispatch")
        for r in eachrow(PSI.read_variable(results, "ActivePowerVariable__$key"))
)
psi_price = Dict(
    r.name => r.value / (BASE_POWER * INTERVAL_H)
        for r in eachrow(PSI.read_dual(results, "CopperPlateBalanceConstraint__Area"))
)
psi_flow = only(PSI.read_variable(results, "FlowActivePowerVariable__AreaInterchange").value);

# The JuMP script of page 2, solved for the same lossless market without FCAS or generic
# constraints, gives the same dispatch, flow and prices:

reference = solve_toy_jump(m; fcas = false)

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
@assert build_status == PSI.ModelBuildStatus.BUILT #hide
@assert solve_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
@assert maximum(abs, comparison.difference) < 1.0e-4 #hide
comparison

# ## What PSI does not know
#
# PSI knows nothing about the NEM. Each NEMDE feature left out of this page becomes a formulation:
# a new type, and methods on the hooks of the build order above. The [next page](@ref nemde-aem)
# uses the ones this repository adds:
#
# | NEMDE feature | Stock PSI | PSI concept used | Formulation on the next page |
# | --- | --- | --- | --- |
# | ramp from `INITIALMW`, `MAXAVAIL` and `UIGF` limits read per interval | ramps between time steps, fixed limits | device formulation, time-series parameters | `NEMReplayDispatch` |
# | interconnector losses shared between regions | lossless branch | branch formulation | `NEMInterconnectorLoss` |
# | FCAS trapezium co-optimised with energy | reserves without a trapezium | service formulation | `FCASMarket` |
# | generic constraints with violation penalties | none | service formulation with slacks | `LinearFactorLimit` |
#
# None of these change PSI itself. They are types and methods in this repository, selected in the
# template exactly as `ThermalBasicDispatch` was selected here.
