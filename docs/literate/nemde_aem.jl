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

include(joinpath(@__DIR__, "..", "..", "literate", "toy_market.jl")) #hide
include(joinpath(@__DIR__, "..", "..", "literate", "toy_jump.jl")); #hide

# # [Building it with AEM and AEMSim](@id nemde-aem)
#
# [Page 3](@ref nemde-psi) solves an energy-only market using PowerSimulations.jl (PSI).
# This page includes FCAS, losses and generic constraints in the toy market of
# [page 2](@ref nemde-jump), using `AustralianElectricityMarkets` and
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

function toy_system(market) #hide
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
        bus = buses[region(u)] #hide
        device = if is_semi_scheduled(u) #hide
            PSY.RenewableDispatch( #hide
                name = String(unit_name(u)), available = true, bus = bus, active_power = 0.0, reactive_power = 0.0, #hide
                rating = u.capacity / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT, #hide
                reactive_power_limits = nothing, power_factor = 1.0, #hide
                operation_cost = PSY.RenewableGenerationCost(nothing), base_power = BASE_POWER, #hide
            ) #hide
        else #hide
            PSY.ThermalStandard( #hide
                name = String(unit_name(u)), available = true, status = true, bus = bus, active_power = 0.0, #hide
                reactive_power = 0.0, rating = u.capacity / BASE_POWER, #hide
                active_power_limits = (min = 0.0, max = u.capacity / BASE_POWER), #hide
                reactive_power_limits = nothing, ramp_limits = nothing, #hide
                operation_cost = PSY.ThermalGenerationCost(nothing), base_power = BASE_POWER, #hide
                time_limits = nothing, #hide
                prime_mover_type = unit_name(u) == :COAL1 ? PSY.PrimeMovers.ST : PSY.PrimeMovers.GT, #hide
                fuel = unit_name(u) == :COAL1 ? PSY.ThermalFuels.COAL : PSY.ThermalFuels.NATURAL_GAS, #hide
            ) #hide
        end #hide
        PSY.add_component!(sys, device) #hide
    end #hide
    for r in market.regions #hide
        mw = region_demand(market, r) #hide
        PSY.add_component!( #hide
            sys, #hide
            PSY.PowerLoad( #hide
                name = "$(r)-load", available = true, bus = buses[r], #hide
                active_power = mw / BASE_POWER, reactive_power = 0.0, base_power = BASE_POWER, #hide
                max_active_power = mw / BASE_POWER, max_reactive_power = 0.0, #hide
            ), #hide
        ) #hide
    end #hide
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

sys = toy_system(market)

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
# feasible dispatch for the interval. For NEMWEB data, use `set_market_bids!` and
# `set_nem_dispatch_limits!` and `set_nem_energy_limits!` to attach these inputs.

function attach_energy_data!(sys, market) #hide
    stamps = [T0, T0 + RESOLUTION] #hide
    series(name, value; multiplier = nothing) = PSY.SingleTimeSeries( #hide
        name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps))), #hide
        scaling_factor_multiplier = multiplier, #hide
    ) #hide
    for u in market.units #hide
        device = PSY.get_component(PSY.StaticInjection, sys, String(unit_name(u))) #hide
        offer = PSY.PiecewiseStepData([0.0; cumsum(quantity.(bids(u)))], price.(bids(u))) #hide
        AustralianElectricityMarkets._set_incremental_bid_cost!( #hide
            sys, device, (piecewise_step_data = fill(offer, length(stamps)),), T0, RESOLUTION, #hide
        ) #hide
        PSY.add_time_series!( #hide
            sys, device, series("max_active_power", availability(u) / u.capacity; multiplier = PSY.get_max_active_power), #hide
        ) #hide
        PSY.add_time_series!(sys, device, series("ramp_up_rate", u.ramp_up_mwh / 60 / BASE_POWER)) #hide
        PSY.add_time_series!(sys, device, series("ramp_down_rate", u.ramp_down_mwh / 60 / BASE_POWER)) #hide
        PSY.add_time_series!(sys, device, series("initial_mw", initial_mw(u) / BASE_POWER)) #hide
        PSY.add_time_series!(sys, device, series("energy_max_avail", u.max_avail / BASE_POWER)) #hide
        PSY.get_ext(device)["nem_semi_scheduled"] = is_semi_scheduled(u) #hide
        if is_semi_scheduled(u) #hide
            PSY.add_time_series!(sys, device, series("uigf", u.uigf / BASE_POWER)) #hide
        end #hide
    end #hide
    for load in PSY.get_components(PSY.PowerLoad, sys) #hide
        PSY.add_time_series!(sys, load, series("max_active_power", 1.0; multiplier = PSY.get_max_active_power)) #hide
    end #hide
    return sys #hide
end #hide
attach_energy_data!(sys, market);

# ### FCAS as a service
#
# The thermal units offer `RAISE6SEC`. Each offer includes price bands and a trapezium
# describing the FCAS capacity available at each energy dispatch level.

function attach_fcas_data!(sys, market) #hide
    for u in fcas_units(market) #hide
        device = PSY.get_component(PSY.StaticInjection, sys, String(unit_name(u))) #hide
        t = trapezium(u) #hide
        trapezium_pu = Tuple( #hide
            FCASTrapezium( #hide
                enablement_min = t.enablement_min / BASE_POWER, low_breakpoint = t.low_breakpoint / BASE_POWER, #hide
                high_breakpoint = t.high_breakpoint / BASE_POWER, enablement_max = t.enablement_max / BASE_POWER, #hide
                max_avail = t.max_avail / BASE_POWER, #hide
            ), #hide
        ) #hide
        curve = PSY.PiecewiseStepData([0.0; cumsum(quantity.(fcas_bids(u)))] ./ BASE_POWER, price.(fcas_bids(u))) #hide
        for (series_name, value) in ("fcas_trapezium_RAISE6SEC" => trapezium_pu, "fcas_curve_RAISE6SEC" => curve) #hide
            PSY.add_time_series!( #hide
                sys, device, #hide
                PSY.SingleTimeSeries( #hide
                    name = series_name, #hide
                    data = PSY.TimeSeries.TimeArray([T0, T0 + RESOLUTION], fill(value, 2)), #hide
                ), #hide
            ) #hide
        end #hide
        service = FCASService( #hide
            name = "$(region(u))_RAISE6SEC", region = region(u), bid_type = BidType.RAISE6SEC, #hide
        ) #hide
        PSY.add_service!(sys, service, [device]) #hide
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
            FCASRequirement(; region = region(find_unit(market, t.id)), service = BidType.RAISE6SEC) #hide
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
PSY.transform_single_time_series!(sys, 2 * RESOLUTION, RESOLUTION);

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
# Select the dispatch, network, interconnector and service formulations for the problem.
# For systems read from NEMWEB, `replication_template(sys)` supplies these selections.
#
# `set_nem_dispatch_models!` selects `NEMReplayDispatch` for the units with NEM dispatch
# inputs. Replay measures each interval's ramp from its metered initial output.

network = PSI.NetworkModel(
    PSI.AreaBalancePowerModel;
    use_slacks = true,
    duals = [PSI.CopperPlateBalanceConstraint],
)
template = PSI.ProblemTemplate(network)
types = set_nem_dispatch_models!(template, sys)
PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
PSI.set_device_model!(template, PSY.AreaInterchange, NEMInterconnectorLoss)
for service in PSY.get_components(FCASService, sys)
    service_name = PSY.get_name(service)
    PSI.set_service_model!(
        template, service_name,
        PSI.ServiceModel(FCASService, FCASMarket, service_name; duals = [FCASJointCapacityConstraint], use_slacks = true),
    )
end
for gc in PSY.get_components(GenericConstraint, sys)
    gc_name = PSY.get_name(gc)
    PSI.set_service_model!(
        template, gc_name,
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit, gc_name; duals = [NEMConstraintLimit], use_slacks = true),
    )
end
types

# ## Step 3: build and solve

model_psi = PSI.DecisionModel(
    template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0),
    horizon = RESOLUTION, resolution = RESOLUTION, interval = RESOLUTION,
    initial_time = T0, name = "nemde_aem", store_variable_names = true,
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

solve_status = PSI.solve!(model_psi)

# ## Step 4: results, checked against page 2
#
# Variables are in MW. Duals are per unit of the system base and per interval, so
# `dual / (BASE_POWER * INTERVAL_H)` is \$/MWh. FCAS prices come from
# `compute_fcas_prices`, which sums the duals of the generic constraints that carry an
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
psi_fcas_price = compute_fcas_prices(results, sys; resolution = RESOLUTION)
limit_key = only(k for k in keys(read_duals(results)) if occursin("N_COAL_LIMIT", k))
psi_limit_dual = to_dollars_per_mwh(only(read_dual(results, limit_key).value))
psi_objective = only(values(PSI.get_objective_value(results)))

reference = solve_toy_jump(market);

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
# model of page 2, which carries only the generic constraint violations.
#
# ## From the toy to the real market
#
# Everything above was assembled by hand to show the pieces. For real intervals:
#
# 1. `db = aem_connect()` and `populate(db, table, start, stop)` cache the NEMWEB tables.
# 2. `nem_system(db, NEMDEConfiguration(); date_range)` builds the populated `System`,
#    including energy and FCAS offers, dispatch and energy limits, generic constraints and losses.
# 3. `prepare_replication!(sys)` derives effective FCAS parameters and tie-break scales and
#    prepares forecast windows from the attached interval inputs.
# 4. `replication_simulation(sys, steps; folder)` creates a PSI simulation. Build it with
#    `PSI.build!` and run it with `PSI.execute!`.
# 5. `replication_results(results, sys)` extracts solved quantities and constraint violations.
#    The repository scripts compare these with `read_published_interval` from the cache.
#    See [Run a dispatch simulation from a system](../dispatch_replay.md) for the full workflow.
#
# Validate the study inputs before solving. `check_fcas_services(sys, template)`
# verifies that every FCAS service has a corresponding model in the template,
# `interconnector_loss_gaps` reports interconnectors with no loss data, and
# `check_interconnector_loss_segments(results, sys)` after a solve verifies that each solved loss
# lies on the loss curve at the solved flow.

check_fcas_services(sys, template)
check_interconnector_loss_segments(results, sys)

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
