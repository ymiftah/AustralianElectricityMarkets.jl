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
import AustralianElectricityMarkets as AEM

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

# A replay `System` holds its inputs as raw five-minute series with one point beyond the last
# dispatch interval, as `nem_system` reads them from NEMWEB. The toy clears the one interval `T0`,
# so its series cover two stamps.

const STAMPS = [T0, T0 + RESOLUTION]
PSY.clear_time_series!(sys) #hide
for load in PSY.get_components(PSY.PowerLoad, sys) #hide
    PSY.add_time_series!(sys, load, single_series("max_active_power", T0, fill(1.0, length(STAMPS)), RESOLUTION; scaling_factor_multiplier = PSY.get_max_active_power)) #hide
end #hide

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
# Energy offers, availability, telemetered ramp rates and metered initial output specify the unit's
# feasible dispatch for the interval. For NEMWEB data, `set_market_bids!` and `set_unit_conditions!`
# attach these inputs.

series(name, value) = single_series(name, T0, fill(value, length(STAMPS)), RESOLUTION) #hide
series_key(device, name) = only(k for k in PSY.get_time_series_keys(device) if PSY.IS.get_name(k) == name) #hide
function attach_series!(sys, device, name, value) #hide
    PSY.add_time_series!(sys, device, series(name, value)) #hide
    return series_key(device, name) #hide
end #hide

function attach_energy_data!(sys, market) #hide
    for u in market.units #hide
        device = PSY.get_component(PSY.Generator, sys, String(u.name)) #hide
        offer = PSY.PiecewiseStepData([0.0; cumsum(quantity.(u.bids))], price.(u.bids)) #hide
        bid(field, value) = attach_series!(sys, device, bid_series_name(BidType.ENERGY, field, BidDirection.GEN), value) #hide
        push!( #hide
            get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(device)), #hide
            NEMEnergyBid( #hide
                direction = BidDirection.GEN, offer_curves = bid(:offer_curves, offer), max_avail = bid(:max_avail, u.max_avail), #hide
                roc_up = bid(:roc_up, NaN), roc_down = bid(:roc_down, NaN), #hide
            ), #hide
        ) #hide
        set_registration!( #hide
            device, #hide
            NEMRegistration( #hide
                schedule_type = is_semi_scheduled(u) ? ScheduleType.SEMI_SCHEDULED : ScheduleType.SCHEDULED, #hide
                gen_loss_factor = 1.0, load_loss_factor = 1.0, #hide
                registered_from = DateTime(2000), registered_until = DateTime(2999, 12, 31), #hide
            ), #hide
        ) #hide
        PSY.add_time_series!( #hide
            sys, device, #hide
            single_series("max_active_power", T0, fill(availability(u) / u.capacity, length(STAMPS)), RESOLUTION; scaling_factor_multiplier = PSY.get_max_active_power), #hide
        ) #hide
        telemetry(field, value) = attach_series!(sys, device, getproperty(NEM_TELEMETRY_SERIES, field), value) #hide
        set_telemetry!( #hide
            device, #hide
            NEMTelemetry( #hide
                agc_status = false, uigf = is_semi_scheduled(u) ? telemetry(:uigf, u.uigf) : nothing, #hide
                ramp_up_limit = telemetry(:ramp_up_limit, u.ramp_up_mwh), ramp_down_limit = telemetry(:ramp_down_limit, u.ramp_down_mwh), #hide
                raise_reg_enablement = telemetry(:raise_reg_enablement, (NaN, NaN)), #hide
                lower_reg_enablement = telemetry(:lower_reg_enablement, (NaN, NaN)), #hide
                raise_reg_max_avail = telemetry(:raise_reg_max_avail, NaN), lower_reg_max_avail = telemetry(:lower_reg_max_avail, NaN), #hide
            ), #hide
        ) #hide
        set_observed_state!( #hide
            device, #hide
            NEMObservedState(initial_mw = attach_series!(sys, device, NEM_OBSERVED_SERIES.initial_mw, u.initial_mw), dispatch_mode = 0), #hide
        ) #hide
    end #hide
    for load in PSY.get_components(PSY.PowerLoad, sys) #hide
        PSY.add_time_series!(sys, load, single_series("loss_demand", T0, fill(1.0, length(STAMPS)), RESOLUTION; scaling_factor_multiplier = PSY.get_max_active_power)) #hide
    end #hide
    return sys #hide
end #hide
attach_energy_data!(sys, market);

# ### FCAS as a service
#
# The thermal units offer `RAISE6SEC`. Each offer includes price bands and a trapezium
# describing the FCAS capacity available at each energy dispatch level.

function attach_fcas_data!(sys, market) #hide
    for n in fcas_names(market) #hide
        device = PSY.get_component(PSY.Generator, sys, n) #hide
        t = trapezium(market, n) #hide
        points = (t.enablement_min, t.low_breakpoint, t.high_breakpoint, t.enablement_max) #hide
        curve = PSY.PiecewiseStepData([0.0; cumsum(quantity.(fcas_bids(market, n)))], price.(fcas_bids(market, n))) #hide
        bid(field, value) = attach_series!(sys, device, bid_series_name(BidType.RAISE6SEC, field, BidDirection.GEN), value) #hide
        offer_curves, max_avail_key, trapezium_key = bid(:offer_curves, curve), bid(:max_avail, t.max_avail), bid(:trapezium, points) #hide
        service = FCASService( #hide
            name = "$(generator_region(sys, n))_RAISE6SEC", region = generator_region(sys, n), bid_type = BidType.RAISE6SEC, #hide
        ) #hide
        PSY.add_service!(sys, service, [device]) #hide
        push!( #hide
            get_fcas_bids(AustralianElectricityMarkets._nem_offer_cost(device)), #hide
            NEMFCASBid( #hide
                service = BidType.RAISE6SEC, direction = BidDirection.GEN, #hide
                offer_curves = offer_curves, max_avail = max_avail_key, trapezium = trapezium_key, #hide
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
    for gc in market.constraints #hide
        requirements = [ #hide
            FCASRequirement(; region = generator_region(sys, String(t.id)), service = BidType.RAISE6SEC) #hide
                for t in gc.terms if t.kind == :raise6 #hide
        ] #hide
        constraint = GenericConstraint( #hide
            name = gc.name, sense = SENSES[gc.sense], #hide
            rhs = gc.rhs, constraint_weight = gc.weight, #hide
            terms = ConstraintTerm[constraint_term(market, t) for t in gc.terms], #hide
            fcas_requirements = FCASRequirement[requirements...], #hide
        ) #hide
        devices = [PSY.get_component(PSY.StaticInjection, sys, String(t.id)) for t in gc.terms] #hide
        PSY.add_service!(sys, constraint, devices) #hide
        constraint.rhs = attach_series!(sys, constraint, NEM_CONSTRAINT_SERIES.rhs, gc.rhs) #hide
        constraint.invoked = attach_series!(sys, constraint, NEM_CONSTRAINT_SERIES.invoked, 1.0) #hide
    end #hide
    return sys #hide
end #hide
attach_generic_constraints!(sys, market);

# ### The derived replay inputs
#
# `nem_system` ends by deriving the inputs the replay reads from the raw ones: the offers referred to
# the regional reference node, the effective FCAS trapeziums, the loss demand coefficients, the
# tie-break scales, the starting output of each unit, and the five-minute forecast windows. That
# stage has no public entry point, because `nem_system` always runs it; the toy calls the internal
# function directly on its hand-built `System`, which then replays the one interval `T0`.

AEM._set_replay_inputs!(sys)
replay_intervals(sys)

# The `System` now holds the whole market:

DataFrame(
    type = [
        string(nameof(T)) for T in (
                PSY.Area, PSY.ACBus, PSY.ThermalStandard, PSY.RenewableDispatch, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
    count = [
        length(PSY.get_components(T, sys)) for T in (
                PSY.Area, PSY.ACBus, PSY.ThermalStandard, PSY.RenewableDispatch, PSY.PowerLoad,
                PSY.AreaInterchange, FCASService, GenericConstraint,
            )
    ],
)

# ## Step 2: the template
#
# `template_nemde` builds the data-free replay template: `NEMReplayDispatch` for each dispatch
# device type, the regional balance with slacks, the interconnector losses, and one service model per
# FCAS service and per generic constraint. `replay_skipped_constraints` reports, without changing `sys`,
# the constraints the replay leaves out, and `PSI.validate_template` verifies the inputs and that the
# template models every participant when the model is built.

template = template_nemde()
skipped = replay_skipped_constraints(sys, template)
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
    value_by_name(read_variable(results, "ActivePowerVariable__ThermalStandard")),
    value_by_name(read_variable(results, "ActivePowerVariable__RenewableDispatch")),
)
psi_price = Dict(
    r.name => to_dollars_per_mwh(r.value) for r in eachrow(read_dual(results, "CopperPlateBalanceConstraint__Area"))
)
psi_flow = only(read_variable(results, "FlowActivePowerVariable__AreaInterchange").value)
psi_loss = only(read_variable(results, "InterconnectorLossVariable__AreaInterchange").value)
psi_fcas_price = read_fcas_prices(results, sys; resolution = RESOLUTION)
constraint_duals = read_dual(results, "NEMConstraintLimit__GenericConstraint")
psi_limit_dual = to_dollars_per_mwh(only(constraint_duals[constraint_duals.name .== "N_COAL_LIMIT", :value]))
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
#    It ends with the replay input stage the toy called above, so the derived inputs and the
#    five-minute forecast windows are already in place, and `replay_intervals(sys)` lists the
#    intervals it can replay.
# 3. The replay pre-flight checks run when the model is built, and
#    `replay_skipped_constraints(sys, template)` reports the constraints left out.
# 4. Construct, build and run a PSI simulation of the replay intervals. `nem_dispatch_sequence`
#    adds NEMDE's second, fast-start run to each interval when the `System` has a fast-start unit:
#
#    ```julia
#    steps = replay_intervals(sys)
#    template = template_nemde()
#    (; models, sequence) = nem_dispatch_sequence(
#        AEMSim.NEMDispatchProblem, template, sys;
#        optimizer = AEMSim.nemde_optimizer(), initial_time = first(steps),
#    )
#    simulation = PSI.Simulation(;
#        name = "replication", steps = length(steps), models, sequence,
#        simulation_folder = mktempdir(), initial_time = first(steps),
#    )
#    PSI.build!(simulation; store_systems_in_results = false)
#    PSI.execute!(simulation)
#    results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
#    ```
# 5. `read_solved_interval(results, sys)` and `read_constraint_violations(results, sys)` extract the
#    solved quantities and constraint violations, and `compare_intervals` joins them with
#    `read_published_interval` from the cache. [Replaying NEMDE dispatch](@ref replay-nemde) runs
#    these steps on real intervals.
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
