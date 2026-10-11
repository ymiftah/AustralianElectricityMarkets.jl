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

include(joinpath(@__DIR__, "..", "..", "literate", "toy_market.jl"))  # @__DIR__ is docs/src/examples when Literate executes
include(joinpath(@__DIR__, "..", "..", "literate", "toy_jump.jl"));

# # [From JuMP to PowerSimulations.jl](@id nemde-psi)
#
# [Page 2](@ref nemde-jump) wrote the NEMDE model for a toy market as one JuMP script. That does not
# scale: every new unit type, service or constraint touches the same objective, the same balance
# rows and the same bookkeeping. [PowerSimulations.jl](https://nrel-sienna.github.io/PowerSimulations.jl/stable/)
# (PSI) separates *what the system is* from *how it is modelled*, and builds the JuMP model in
# fixed phases. This page walks through those phases, starting from the lines of page 2 that each
# one produces.
#
# | | Holds | Package |
# | --- | --- | --- |
# | **Data** | components (units, loads, areas, interconnectors), their parameters and time series | `PowerSystems.jl` (PSY): a `System` |
# | **Formulation** | which variables, constraints and costs a *component type* produces | `PowerSimulations.jl` (PSI): a formulation type per component |
# | **Template** | the mapping *(component type, formulation)* for one problem, and the network model | PSI: a `ProblemTemplate` |
#
# A `DecisionModel` takes a `System` and a template and writes the JuMP problem into an
# `OptimizationContainer`: a typed registry of variables, expressions, parameters and constraints
# wrapping the JuMP model. Which JuMP code runs for a component is decided by Julia's
# **multiple dispatch** on the pair *(component type, formulation type)*. The template only names
# the formulation; the methods hold the equations.
#
# ## The model, as a `System`
#
# To stay on stock PSI, this page uses the part of the toy market that PSI's own formulations can
# express: bid stacks, availability and the ramp envelope, regional balance and a lossless
# interconnector (`energy_market(market)`). Ramp limits become the unit's active power bounds,
# which is what a PSI user without a NEM-specific formulation would do. FCAS, interconnector
# losses and the generic constraints need the formulations of [page 4](@ref nemde-aem).

function stock_system(market)
    sys = PSY.System(BASE_POWER)
    areas = Dict(r => PSY.Area(; name = r) for r in market.regions)
    PSY.add_components!(sys, collect(values(areas)))
    buses = Dict(
        r => PSY.ACBus(;
            number = i, name = "$(r)-node", base_voltage = 330.0, bustype = PSY.ACBusTypes.PQ,
            area = areas[r], available = true, angle = 0.0, magnitude = 1.0,
            voltage_limits = (min = 0.9, max = 1.1),
        ) for (i, r) in enumerate(market.regions)
    )
    PSY.add_components!(sys, collect(values(buses)))
    for u in market.units
        floor_mw = max(0.0, initial_mw(u) - ramp_down(u))
        ceiling_mw = min(availability(u), initial_mw(u) + ramp_up(u))
        offer = PSY.CostCurve(
            PSY.PiecewiseIncrementalCurve(0.0, [0.0; cumsum(quantity.(bids(u)))], price.(bids(u))),
        )
        device = if is_semi_scheduled(u)
            PSY.RenewableDispatch(;
                name = String(unit_name(u)), available = true, bus = buses[region(u)], active_power = 0.0,
                reactive_power = 0.0, rating = ceiling_mw / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT,
                reactive_power_limits = nothing, power_factor = 1.0,
                operation_cost = PSY.RenewableGenerationCost(offer), base_power = BASE_POWER,
            )
        else
            PSY.ThermalStandard(;
                name = String(unit_name(u)), available = true, status = true, bus = buses[region(u)],
                active_power = 0.0, reactive_power = 0.0, rating = u.capacity / BASE_POWER,
                active_power_limits = (min = floor_mw / BASE_POWER, max = ceiling_mw / BASE_POWER),
                reactive_power_limits = nothing, ramp_limits = nothing,
                operation_cost = PSY.ThermalGenerationCost(; variable = offer, fixed = 0.0, start_up = 0.0, shut_down = 0.0),
                base_power = BASE_POWER, time_limits = nothing,
                prime_mover_type = PSY.PrimeMovers.GT, fuel = PSY.ThermalFuels.NATURAL_GAS,
            )
        end
        PSY.add_component!(sys, device)
    end
    for r in market.regions
        mw = region_demand(market, r)
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
    ic = market.interconnector
    PSY.add_component!(
        sys,
        PSY.AreaInterchange(;
            name = ic.name, available = true, active_power_flow = 0.0,
            from_area = areas[ic.from], to_area = areas[ic.to],
            flow_limits = (from_to = ic.max_flow / BASE_POWER, to_from = ic.max_flow / BASE_POWER),
        ),
    )
    return sys
end

sys = stock_system(energy_market(market))

# Each unit's offer is its `variable` cost: a piecewise *incremental* curve whose x-coordinates are
# the cumulative band quantities and whose slopes are the band prices, exactly the bid stack of page 2.

PSY.get_variable(PSY.get_operation_cost(PSY.get_component(PSY.ThermalStandard, sys, "COAL1")))

# ## The template
#
# One formulation per component type, and a network model. `AreaBalancePowerModel` is PSI's
# regional network: one balance row per `Area`, with `AreaInterchange` flows moving power between
# areas, which is the NEM's regional market.

network = PSI.NetworkModel(PSI.AreaBalancePowerModel; duals = [PSI.CopperPlateBalanceConstraint])
template = PSI.ProblemTemplate(network)
PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
template

# ## The build, in order
#
# `PSI.build!` runs the construction phases below in a fixed order, handing the same container to
# each. Devices are built in two stages: the *argument* stage adds variables, parameters and
# expressions; the *model* stage adds the constraints and costs on them. The split exists so that
# a service (such as FCAS) can add its terms to an expression a device declared, *before* the
# device writes the constraint on that expression.
#
# | # | Phase | Hook | Adds |
# | --- | --- | --- | --- |
# | 0 | System | `initialize_system_expressions!` | one `ActivePowerBalance` expression per `Area` |
# | 1 | Devices | `construct_device!`, `ArgumentConstructStage` | variables, parameters, expressions |
# | 2 | Services | `construct_services!`, `ArgumentConstructStage` | service variables and expressions |
# | 3 | Branches | `construct_device!`, `ArgumentConstructStage` | flow variables |
# | 4 | Devices | `construct_device!`, `ModelConstructStage` | constraints and costs |
# | 5 | Network | `construct_network!` | balance constraints |
# | 6 | Branches | `construct_device!`, `ModelConstructStage` | flow limits |
# | 7 | Services | `construct_services!`, `ModelConstructStage` | service constraints |
# | 8 | Objective | `update_objective_function!` | the sum of every registered cost term |

function plot_phases()
    fig = Figure(size = (1000, 260))
    ax = Axis(fig[1, 1]; yreversed = true, backgroundcolor = :transparent)
    hidedecorations!(ax); hidespines!(ax)
    xlims!(ax, -0.1, 10.9); ylims!(ax, 1.7, -0.1)
    color = Makie.wong_colors()[1]
    shapes = [
        ("0", "System", "expressions"), ("1", "Devices", "arguments"), ("2", "Services", "arguments"),
        ("3", "Branches", "arguments"), ("4", "Devices", "model"), ("5", "Network", "model"),
        ("6", "Branches", "model"), ("7", "Services", "model"), ("8", "Objective", "assembly"),
    ]
    for (i, (number, title, stage)) in enumerate(shapes)
        x = (i - 1) * 1.2
        poly!(ax, Rect2f(x, 0.2, 1.05, 1.3); color = (color, 0.55), strokecolor = color, strokewidth = 2)
        text!(ax, x + 0.52, 0.5; text = number, align = (:center, :center), fontsize = 22, font = :bold)
        text!(ax, x + 0.52, 0.95; text = title, align = (:center, :center), fontsize = 13)
        text!(ax, x + 0.52, 1.2; text = stage, align = (:center, :center), fontsize = 12, color = (:gray, 1.0))
        i < length(shapes) && arrows2d!(ax, [x + 1.06], [0.85], [0.13], [0.0]; color = :gray)
    end
    return fig
end
plot_phases()

# Each phase is shown next to the lines of page 2 that it replaces. Highlighted lines are the
# ones the phase generates.
#
# ### Phase 0 and 1: variables, expressions and the balance terms
#
# On page 2 the dispatch of every unit is declared, summed into an expression, and the regional
# balance sums those expressions. In PSI the second step is split: the balance is an
# `ActivePowerBalance` expression per area created up front (phase 0), and each device adds its
# own power into it when it declares its variables (phase 1). A device never sees the balance row.
#
# ```julia
# @variable(model, 0 <= cleared[u in market.units, j in 1:n_bids(u)] <= quantity(bid(u, j)))  # [!code highlight]
# @expression(model, dispatch[u in market.units], sum(cleared[u, j] for j in 1:n_bids(u)))  # [!code highlight]
# generation(r) = sum(dispatch[u] for u in units_in(market, r))  # [!code focus]
# ```
#
# In PSI a formulation is a type, and the argument-stage method of `construct_device!` is a list
# of calls, each adding one kind of object to the container. This is the method of the NEM
# dispatch formulation of [page 4](@ref nemde-aem), abridged:
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
# Which method runs is decided by the type parameters: `T` (the component type) and `D` (the
# formulation). A different `D` runs a different method on the same `System`.

# ### Phase 3: the interconnector variable
#
# The flow is a variable of the branch model, declared in the branches' argument stage and added
# to the two area balances with opposite signs:
#
# ```julia
# @variable(model, flow)  # [!code highlight]
# exported(r) = r == ic.from ? flow : -flow  # [!code focus]
# ```

# ### Phase 4: component-level constraints and costs
#
# Rows that involve a single component: availability and the ramp envelope on page 2, here the
# bounds on `ActivePowerVariable` (the unit's `active_power_limits`), and the piecewise cost. PSI
# turns the incremental curve into a convex combination of breakpoints, an equivalent of the band
# variables of page 2.
#
# ```julia
# @constraint(model, availability_limit[u in market.units], dispatch[u] <= availability(u))  # [!code highlight]
# @constraint(model, ramp_up_limit[u in market.units], dispatch[u] - initial_mw(u) <= ramp_up(u))  # [!code highlight]
# @constraint(model, ramp_down_limit[u in market.units], initial_mw(u) - dispatch[u] <= ramp_down(u))  # [!code highlight]
# ```
#
# The model-stage method of the same NEM formulation writes these rows (abridged):
#
# ```julia
# function PSI.construct_device!(
#         container, sys, ::PSI.ModelConstructStage,
#         model::PSI.DeviceModel{T, D}, network_model,
#     ) where {T <: PSY.StaticInjection, D <: AbstractNEMDispatch}
#     devices = PSI.get_available_components(model, sys)
#     PSI.add_constraints!(  # [!code highlight]
#         container, PSI.ActivePowerVariableLimitsConstraint, PSI.ActivePowerVariable,
#         devices, model, network_model,
#     )
#     PSI.add_constraints!(container, PSI.RampConstraint, PSI.ActivePowerVariable, devices, model, network_model)  # [!code highlight]
#     PSI.objective_function!(container, devices, model, PSI.get_network_formulation(network_model))  # [!code highlight]
#     return
# end
# ```

# ### Phase 5: the network
#
# The joint constraint across components: each area's balance expression, now complete with every
# device and branch term, is set equal to its demand. The dual of this row is the regional price.
#
# ```julia
# @constraint(  # [!code highlight]
#     model, balance[r in market.regions],  # [!code highlight]
#     generation(r) - exported(r) - loss_charged(r) == region_demand(market, r),  # [!code highlight]
# )  # [!code highlight]
# ```

# ### Phase 6 and 7: branch limits and services
#
# Branch flow limits are model-stage constraints of the branch. *Services* are the joint-component
# objects of PSI: a group of devices sharing a requirement, such as a reserve. Their constraints
# act on expressions several devices contribute to, so they come last. On page 2 the FCAS rows
# and the generic constraints are services in this sense:
#
# ```julia
# @constraint(model, flow_limit_up, flow <= ic.max_flow)  # [!code focus]
# @constraint(model, trapezium_upper[u in fcas_units(market)], dispatch[u] + upper_slope(trapezium(u)) * raise[u] <= trapezium(u).enablement_max)  # [!code highlight]
# add_generic_constraint!(model, gc)  # [!code highlight]
# ```

# ### Phase 8: the objective
#
# Every phase registers its cost terms (offers, slacks, penalties) in the container instead of
# writing an objective. `update_objective_function!` sums them at the end:
#
# ```julia
# @objective(model, Min, offer_cost)  # [!code highlight]
# set_objective_function(model, objective_function(model) + fcas_cost)  # [!code highlight]
# ```
#
# ## Build, inspect and solve

model_psi = PSI.DecisionModel(
    template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
    horizon = RESOLUTION, resolution = RESOLUTION, interval = RESOLUTION,
    initial_time = T0, name = "nemde_psi", store_variable_names = true,
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

# The container now holds the typed pieces of the problem, addressed by *(entry type, component
# type, meta)* instead of by a variable name:

container = PSI.get_optimization_container(model_psi)

function container_keys(container)
    rows = NamedTuple{(:kind, :entry, :component), Tuple{String, String, String}}[]
    for (kind, dict) in (
            "variable" => PSI.get_variables(container), "expression" => PSI.get_expressions(container),
            "parameter" => PSI.get_parameters(container), "constraint" => PSI.get_constraints(container),
        )
        for k in keys(dict)
            push!(
                rows, (;
                    kind, entry = string(nameof(PSI.IS.Optimization.get_entry_type(k))),
                    component = string(nameof(PSI.IS.Optimization.get_component_type(k))),
                ),
            )
        end
    end
    return sort!(DataFrame(rows), [:kind, :entry])
end
container_keys(container)

# Each page 2 object has a typed home:
#
# | Page 2 (JuMP) | PSI container key | Phase |
# | --- | --- | --- |
# | `dispatch[u]` | variable `ActivePowerVariable` | 1 |
# | `cleared[u, j]` and the offer cost | variable `PiecewiseLinearCostVariable`, constraint `PiecewiseLinearCostConstraint`, expression `ProductionCostExpression` | 1 and 4 |
# | availability and ramp envelope | the bounds of `ActivePowerVariable` and the expressions behind `ActivePowerVariableLimitsConstraint` | 1 and 4 |
# | `flow` | variable `FlowActivePowerVariable` | 3 |
# | `balance[r]` | expression `ActivePowerBalance` and constraint `CopperPlateBalanceConstraint` on `Area` | 0, 1 and 5 |
# | flow limits | constraint `FlowLimitConstraint` | 6 |

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

# ## What PSI does not know
#
# PSI knows nothing about the NEM: not the ramp rate measured from `INITIALMW`, the `UIGF`
# availability, the FCAS trapezium, the loss curve split between the two regions, the generic
# constraints with violation penalties, nor the price of a violated constraint. Each is a
# formulation: a type plus methods on the hooks above, and the [next page](@ref nemde-aem)
# shows the ones this repository adds.
