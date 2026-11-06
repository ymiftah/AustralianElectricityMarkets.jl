begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsSimulations
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
import AustralianElectricityMarketsSimulations as AEMSim

include(joinpath(@__DIR__, "..", "..", "literate", "shared", "toy_market.jl")) #hide
include(joinpath(@__DIR__, "..", "..", "literate", "shared", "toy_jump.jl")); #hide

# # [Building it with AEM and AEMSim](@id nemde-aem)
#
# [The previous page](@ref nemde-psi) solves an energy-only market using PowerSimulations.jl (PSI).
# This page includes FCAS, losses and generic constraints in the toy market of
# [the JuMP model](@ref nemde-jump), using `AustralianElectricityMarkets` and
# `AustralianElectricityMarketsSimulations`. It then compares dispatch, flows and prices
# with the JuMP example.
#
# !!! note "References"
#     The market rules behind each formulation are in AEMO's
#     [*FCAS Model in NEMDE*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
#     and *Constraint Violation Penalty Factors*; see [References](@ref nemde-aem-references).

# ## Step 1: the market as a `System`
#
# For real markets, [`nem_system`](@ref) reads NEMWEB data into a `PowerSystems.jl` `System`
# (see [The National Electricity Market](@ref)). Here we use the tutorial's two-region toy system.

sys = toy_system(market; nem = true)

# ### The interconnector's loss model
#
# Interconnector losses are shared between the two regions. The toy loss model uses a
# quadratic curve with five linear segments.

function attach_loss_model!(sys, market) #hide
    ic = market.interconnector #hide
    model = InterconnectorLossModel( #hide
        interconnector = ic.name, from_region = ic.from, to_region = ic.to, #hide
        from_region_loss_share = ic.from_loss_share, loss_constant = 1.0, #hide
        loss_flow_coefficient = ic.loss_coefficient * BASE_POWER, #hide
        demand_coefficients = Dict{String, Float64}(), breakpoints = ic.breakpoints ./ BASE_POWER, #hide
    ) #hide
    PSY.add_supplemental_attribute!(sys, PSY.get_component(PSY.AreaInterchange, sys, ic.name), model) #hide
    return model #hide
end #hide

attach_loss_model!(sys, market);

# ### Market data as time series
#
# Energy offers, availability, ramp rates and metered initial output specify the unit's
# feasible dispatch for the interval. For NEMWEB data, use `set_market_bids!`,
# `set_nem_dispatch_limits!` and `set_nem_energy_limits!` to attach these inputs.

function attach_energy_data!(sys, market) #hide
    stamps = [T0, T0 + RESOLUTION] #hide
    series(name, value; multiplier = nothing) = PSY.SingleTimeSeries( #hide
        name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps))), #hide
        scaling_factor_multiplier = multiplier, #hide
    ) #hide
    bid_key(device, name) = only(k for k in PSY.get_time_series_keys(device) if PSY.IS.get_name(k) == name) #hide
    for u in market.units #hide
        device = PSY.get_component(PSY.Generator, sys, String(u.name)) #hide
        offer = PSY.PiecewiseStepData([0.0; cumsum(quantity.(u.bids))], price.(u.bids)) #hide
        PSY.add_time_series!( #hide
            sys, device, PSY.SingleTimeSeries(name = "bid_energy_offer_curves_gen", data = PSY.TimeSeries.TimeArray(stamps, fill(offer, length(stamps)))), #hide
        ) #hide
        PSY.add_time_series!(sys, device, series("bid_energy_max_avail_gen", u.max_avail)) #hide
        PSY.add_time_series!(sys, device, series("bid_energy_roc_up_gen", NaN)) #hide
        PSY.add_time_series!(sys, device, series("bid_energy_roc_down_gen", NaN)) #hide
        push!( #hide
            get_energy_bids(PSY.get_operation_cost(device)), #hide
            NEMEnergyBid( #hide
                direction = BidDirection.GEN, offer_curves = bid_key(device, "bid_energy_offer_curves_gen"), #hide
                max_avail = bid_key(device, "bid_energy_max_avail_gen"), roc_up = bid_key(device, "bid_energy_roc_up_gen"), #hide
                roc_down = bid_key(device, "bid_energy_roc_down_gen"), #hide
            ), #hide
        ) #hide
        PSY.get_ext(device)["nem_gen_loss_factor"] = 1.0 #hide
        PSY.get_ext(device)["nem_load_loss_factor"] = 1.0 #hide
        PSY.add_time_series!( #hide
            sys, device, series("max_active_power", availability(u) / u.capacity; multiplier = PSY.get_max_active_power), #hide
        ) #hide
        PSY.add_time_series!(sys, device, series("ramp_up_rate", u.ramp_up_mwh / 60 / BASE_POWER)) #hide
        PSY.add_time_series!(sys, device, series("ramp_down_rate", u.ramp_down_mwh / 60 / BASE_POWER)) #hide
        PSY.add_time_series!(sys, device, series("initial_mw", u.initial_mw / BASE_POWER)) #hide
        PSY.get_ext(device)["nem_semi_scheduled"] = is_semi_scheduled(u) #hide
        if is_semi_scheduled(u) #hide
            PSY.add_time_series!(sys, device, series("uigf", u.uigf / BASE_POWER)) #hide
        end #hide
    end #hide
    for load in PSY.get_components(PSY.PowerLoad, sys) #hide
        PSY.add_time_series!(sys, load, series("loss_demand", 1.0; multiplier = PSY.get_max_active_power)) #hide
    end #hide
    return sys #hide
end #hide
attach_energy_data!(sys, market);

# ### FCAS as a service
#
# The thermal units offer `RAISE6SEC`. Each offer includes price bands and a trapezium
# describing the FCAS capacity available at each energy dispatch level.

function attach_fcas_data!(sys, market) #hide
    series(name, value) = PSY.SingleTimeSeries(name = name, data = PSY.TimeSeries.TimeArray([T0, T0 + RESOLUTION], fill(value, 2))) #hide
    bid_key(device, name) = only(k for k in PSY.get_time_series_keys(device) if PSY.IS.get_name(k) == name) #hide
    for n in fcas_names(market) #hide
        device = PSY.get_component(PSY.Generator, sys, n) #hide
        t = trapezium(market, n) #hide
        points = (t.enablement_min, t.low_breakpoint, t.high_breakpoint, t.enablement_max) #hide
        curve = PSY.PiecewiseStepData([0.0; cumsum(quantity.(fcas_bids(market, n)))], price.(fcas_bids(market, n))) #hide
        stamps = [T0, T0 + RESOLUTION] #hide
        PSY.add_time_series!( #hide
            sys, device, #hide
            PSY.SingleTimeSeries(name = "bid_raise6sec_trapezium_gen", data = PSY.TimeSeries.TimeArray(stamps, fill(points, 2))), #hide
        ) #hide
        PSY.add_time_series!(sys, device, series("bid_raise6sec_max_avail_gen", t.max_avail)) #hide
        PSY.add_time_series!( #hide
            sys, device, #hide
            PSY.SingleTimeSeries(name = "bid_raise6sec_offer_curves_gen", data = PSY.TimeSeries.TimeArray(stamps, fill(curve, 2))), #hide
        ) #hide
        service = FCASService( #hide
            name = "$(generator_region(sys, n))_RAISE6SEC", region = generator_region(sys, n), bid_type = BidType.RAISE6SEC, #hide
        ) #hide
        PSY.add_service!(sys, service, [device]) #hide
        push!( #hide
            get_fcas_bids(PSY.get_operation_cost(device)), #hide
            NEMFCASBid( #hide
                service = BidType.RAISE6SEC, direction = BidDirection.GEN, #hide
                offer_curves = bid_key(device, "bid_raise6sec_offer_curves_gen"), #hide
                max_avail = bid_key(device, "bid_raise6sec_max_avail_gen"), #hide
                trapezium = bid_key(device, "bid_raise6sec_trapezium_gen"), #hide
            ), #hide
        ) #hide
    end #hide
    return sys #hide
end #hide
attach_fcas_data!(sys, market);

# ### Generic constraints
#
# Generic constraints impose linear limits on energy dispatch, FCAS enablement and
# interconnector flows. This example includes two regional FCAS requirements and a coal
# dispatch limit.

function constraint_term(market, t::Term) #hide
    t.kind == :energy && return UnitTerm(String(t.id), BidType.ENERGY, t.factor) #hide
    t.kind == :raise6 && return UnitTerm(String(t.id), BidType.RAISE6SEC, t.factor) #hide
    return InterconnectorTerm(String(t.id), t.factor) #hide
end #hide

const SENSES = Dict(:LE => ConstraintSense.LE, :GE => ConstraintSense.GE, :EQ => ConstraintSense.EQ) #hide

function attach_generic_constraints!(sys, market) #hide
    stamps = [T0, T0 + RESOLUTION] #hide
    for gc in market.constraints #hide
        requirements = [ #hide
            FCASRequirement(; region = generator_region(sys, String(t.id)), service = BidType.RAISE6SEC) #hide
                for t in gc.terms if t.kind == :raise6 #hide
        ] #hide
        constraint = GenericConstraint( #hide
            name = gc.name, sense = SENSES[gc.sense], #hide
            rhs = gc.rhs / BASE_POWER, constraint_weight = gc.weight, #hide
            terms = ConstraintTerm[constraint_term(market, t) for t in gc.terms], #hide
            fcas_requirements = FCASRequirement[requirements...], #hide
        ) #hide
        devices = [PSY.get_component(PSY.StaticInjection, sys, String(t.id)) for t in gc.terms] #hide
        PSY.add_service!(sys, constraint, devices) #hide
        for (series_name, value) in ("rhs" => gc.rhs / BASE_POWER, "invoked" => 1.0) #hide
            PSY.add_time_series!( #hide
                sys, constraint, #hide
                PSY.SingleTimeSeries(; name = series_name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps)))), #hide
            ) #hide
        end #hide
    end #hide
    return sys #hide
end #hide
attach_generic_constraints!(sys, market)
set_loss_demand_coefficients!(sys)
AEMSim.set_effective_offers!(sys)
PSY.transform_single_time_series!(sys, 2 * RESOLUTION, RESOLUTION);

# The `System` now holds the whole market:

DataFrame(
    type = [
        string(nameof(T)) for T in (
                PSY.Area, PSY.ACBus, NEMThermalGen, NEMRenewableGen, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
    count = [
        length(PSY.get_components(T, sys)) for T in (
                PSY.Area, PSY.ACBus, NEMThermalGen, NEMRenewableGen, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
)

# ## Step 2: the template
#
# `template_nemde` builds the data-free replay template: `NEMReplayDispatch` for each dispatch
# device type, the regional balance with slacks, the interconnector losses, and one service model per
# FCAS service and per generic constraint. `exclude_unmodeled_services!` marks what the replay leaves
# out as unavailable on `sys` and returns the skipped constraints, and `check_template_against_sys`
# verifies the inputs and that the template models every participant.

template = template_nemde()
skipped = exclude_unmodeled_services!(sys, template)
check_template_against_sys(template, sys)
isempty(skipped)

# ## Step 3: build and solve
#
# `AEMSim.NEMDispatchProblem` prices the regional balance slacks and every penalty at one Market
# Price Cap, dated by the first interval.

model_psi = PSI.DecisionModel(
    AEMSim.NEMDispatchProblem, template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0),
    initial_time = T0,
    name = "nemde_aem",
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

solve_status = PSI.solve!(model_psi)

# ## Step 4: results, checked against the JuMP model
#
# Variables are in MW. Duals are per unit of the system base and per interval, so
# `dual / (BASE_POWER * INTERVAL_H)` is \$/MWh. FCAS prices come from
# `read_fcas_prices`, which sums the duals of the generic constraints that carry an
# FCAS requirement.

results = PSI.OptimizationProblemResults(model_psi)
to_dollars_per_mwh(dual) = dual / (BASE_POWER * INTERVAL_H)

value_by_name(df) = Dict(Symbol(r.name) => r.value for r in eachrow(df))
psi_dispatch = merge(
    value_by_name(read_variable(results, "ActivePowerVariable__NEMThermalGen")),
    value_by_name(read_variable(results, "ActivePowerVariable__NEMRenewableGen")),
)
psi_price = Dict(
    r.name => to_dollars_per_mwh(r.value) for r in eachrow(read_dual(results, "CopperPlateBalanceConstraint__Area"))
)
psi_flow = only(read_variable(results, "FlowActivePowerVariable__AreaInterchange").value)
psi_loss = only(read_variable(results, "InterconnectorLossVariable__AreaInterchange").value)
psi_fcas_price = read_fcas_prices(results, sys; resolution = RESOLUTION)
limit_key = only(k for k in keys(read_duals(results)) if occursin("N_COAL_LIMIT", k))
psi_limit_dual = to_dollars_per_mwh(only(read_dual(results, limit_key).value))
psi_objective = only(values(PSI.get_objective_value(results)))

reference = solve_toy_jump(toy_system(market), market);

comparison = DataFrame(
    quantity = [
        "COAL1 (MW)", "WIND1 (MW)", "GAS1 (MW)", "Flow NSW1 to VIC1 (MW)", "Loss (MW)",
        "NSW1 price (\$/MWh)", "VIC1 price (\$/MWh)",
        "NSW1 RAISE6SEC price (\$/MW/h)", "VIC1 RAISE6SEC price (\$/MW/h)",
        "N_COAL_LIMIT dual (\$/MWh)", "Objective (\$)",
    ],
    JuMP = [
        reference.dispatch[:COAL1], reference.dispatch[:WIND1], reference.dispatch[:GAS1],
        reference.flow, reference.loss, reference.price["NSW1"], reference.price["VIC1"],
        reference.generic["F_NSW_R6"], reference.generic["F_VIC_R6"], reference.generic["N_COAL_LIMIT"],
        reference.objective,
    ],
    AEMSim = [
        psi_dispatch[:COAL1], psi_dispatch[:WIND1], psi_dispatch[:GAS1], psi_flow, psi_loss,
        psi_price["NSW1"], psi_price["VIC1"],
        only(psi_fcas_price[psi_fcas_price.REGIONID .== "NSW1", :ROP]),
        only(psi_fcas_price[psi_fcas_price.REGIONID .== "VIC1", :ROP]),
        psi_limit_dual, psi_objective,
    ],
)
comparison.difference = comparison.AEMSim .- comparison.JuMP
comparison

# Both models are the same program, so they agree: every dispatch, flow, price and the objective match to solver
# tolerance.

@assert build_status == PSI.ModelBuildStatus.BUILT
@assert solve_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED
@assert maximum(abs, comparison.difference) < 1.0e-4

# ## Elastic constraints
#
# Constraint violations incur a penalty based on the constraint violation penalty factor and
# the Market Price Cap (AEMO, *Schedule of Constraint Violation Penalty Factors*, §1, pp. 3-4).
# This prioritises which limits to relax if the inputs conflict. The total violation in the
# toy solution is:

slack_types = unique( #hide
    string(nameof(PSI.IS.Optimization.get_entry_type(k))) for k in PSI.list_variable_keys(results) #hide
        if occursin("Slack", string(PSI.IS.Optimization.get_entry_type(k))) #hide
) #hide
slack_total = sum( #hide
    sum(PSI.read_variable(results, k).value) #hide
        for k in PSI.list_variable_keys(results) if occursin("Slack", string(PSI.IS.Optimization.get_entry_type(k))) #hide
) #hide
slack_total

# Nothing is violated in the toy market, so the solution equals the JuMP
# model of [the JuMP model](@ref nemde-jump), which carries only the generic constraint violations.
#
# ## From the toy to the real market
#
# Everything above was assembled by hand to show the pieces. For real intervals:
#
# 1. `db = aem_connect()` and `populate(db, table, start, stop)` cache the NEMWEB tables.
# 2. `nem_system(db, NEMDEConfiguration(); date_range)` builds the populated `System`,
#    including energy and FCAS offers, dispatch and energy limits, generic constraints and losses.
# 3. `prepare_replay!(sys, template, steps)` transforms the attached interval inputs into five-minute
#    forecast windows and runs the replay pre-flight checks. The effective FCAS parameters and
#    tie-break scales are already derived by `nem_system`.
# 4. Construct, build and run a PSI simulation of the interval range `steps`:
#
#    ```julia
#    skipped = prepare_replay!(sys, template, steps)
#    model = PSI.DecisionModel(
#        AEMSim.NEMDispatchProblem, template, sys;
#        optimizer = AEMSim.nemde_optimizer(), initial_time = first(steps), name = "dispatch",
#    )
#    models = PSI.SimulationModels(; decision_models = [model])
#    sequence = PSI.SimulationSequence(; models, ini_cond_chronology = PSI.InterProblemChronology())
#    simulation = PSI.Simulation(;
#        name = "replication", steps = length(steps), models, sequence,
#        simulation_folder = mktempdir(), initial_time = first(steps),
#    )
#    PSI.build!(simulation; store_systems_in_results = false)
#    PSI.execute!(simulation)
#    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
#    ```
# 5. `read_solved_interval(results, sys)` and `read_constraint_violations(results, sys)` extract the
#    solved quantities and constraint violations. The repository scripts compare the solved tables with
#    `read_published_interval` from the cache.
#
# Validate the study inputs before solving. `check_fcas_services(template, sys)`
# verifies that every FCAS service has a corresponding model in the template,
# `read_interconnector_loss_gaps(results, sys)` after a solve verifies that each solved loss lies on
# the loss curve at the solved flow: its `gap_mw` column is zero.

check_fcas_services(template, sys)
read_interconnector_loss_gaps(results, sys)

# !!! note "Example scope"
#     This tutorial solves a single interval with thermal and wind generation, one contingency
#     FCAS service and a toy loss curve. It omits scheduled consumption, batteries, regulation
#     FCAS scaling, fast-start profiles and price processing. See
#     [Fast-start dispatch](@ref nemde-fast-start) and the [formulation overview](@ref nemde-model)
#     for those market concepts.

# ## [References](@id nemde-aem-references)
#
# - AEMO, [*FCAS Model in NEMDE*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf):
#   the trapezium (§2-3), joint constraints and prices.
# - AEMO, *Constraint Violation Penalty Factors*: the penalty of each constraint family.
# - AEMO, *Marginal Loss Factors* and *Loss Factor Methodology*: the interconnector loss equations.
# - [PowerSimulations.jl documentation](https://nrel-sienna.github.io/PowerSimulations.jl/stable/)
#   and [PowerSystems.jl documentation](https://nrel-sienna.github.io/PowerSystems.jl/stable/).
