begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsSimulations
    using PowerSystems
    using PowerSimulations
    using JuMP
    using HiGHS
    using DataFrames
    using Dates
    using InteractiveUtils: subtypes
    using CairoMakie
end;

import PowerSystems as PSY
import PowerSimulations as PSI
import AustralianElectricityMarketsSimulations as AEMSim

include(joinpath(@__DIR__, "..", "..", "literate", "toy_market.jl"))  # @__DIR__ is docs/src/examples when Literate executes
include(joinpath(@__DIR__, "..", "..", "literate", "toy_jump.jl"));

# # [Building it with AEM and AEMSim](@id nemde-aem)
#
# [Page 3](@ref nemde-psi) showed how PowerSimulations.jl (PSI) turns a `PowerSystems.jl` (PSY)
# `System` and a template into a JuMP model. PSI knows nothing about the NEM, so the NEM
# itself comes from two packages in this repository:
#
# | Package | Adds to PSY / PSI | Examples |
# | --- | --- | --- |
# | `AustralianElectricityMarkets` (**AEM**) | NEM *data*: the `System` that holds a market, built from NEMWEB tables | `nem_system`, `FCASService`, `FCASTrapezium`, [`GenericConstraint`](@ref) and its terms, [`InterconnectorLossModel`](@ref), the time-series setters |
# | `AustralianElectricityMarketsSimulations` (**AEMSim**) | NEM *formulations*: the variables, constraints and costs of NEMDE for those components | `NEMReplayDispatch`, `FCASMarket`, `LinearFactorLimit`, `NEMInterconnectorLoss`, elastic slacks, pre-flight checks |
#
# AEM never mentions JuMP, and AEMSim is the only package that mentions both the NEM and PSI.
# This page rebuilds the toy market of [page 2](@ref nemde-jump) with them and checks that the
# result matches the hand-written JuMP model.
#
# !!! note "References"
#     The market rules behind each formulation are in AEMO's
#     [*FCAS Model in NEMDE*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf)
#     and *Constraint Violation Penalty Factors*; see [References](@ref nemde-aem-references).

# ## Step 1: the market as a `System`
#
# For real markets `nem_system(db, ConstrainedNetworkConfiguration(); date_range)` builds this
# from NEMWEB (see [Overview of the NEM](@ref)). Here the same structure is assembled from the
# toy market by hand, to show what each piece is. Areas, buses, generators and loads are plain
# PSY components:

function toy_system(market)
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
        bus = buses[region(u)]
        device = if is_semi_scheduled(u)
            PSY.RenewableDispatch(;
                name = String(unit_name(u)), available = true, bus, active_power = 0.0, reactive_power = 0.0,
                rating = u.capacity / BASE_POWER, prime_mover_type = PSY.PrimeMovers.WT,
                reactive_power_limits = nothing, power_factor = 1.0,
                operation_cost = PSY.RenewableGenerationCost(nothing), base_power = BASE_POWER,
            )
        else
            PSY.ThermalStandard(;
                name = String(unit_name(u)), available = true, status = true, bus, active_power = 0.0,
                reactive_power = 0.0, rating = u.capacity / BASE_POWER,
                active_power_limits = (min = 0.0, max = u.capacity / BASE_POWER),
                reactive_power_limits = nothing, ramp_limits = nothing,
                operation_cost = PSY.ThermalGenerationCost(nothing), base_power = BASE_POWER,
                time_limits = nothing,
                prime_mover_type = unit_name(u) == :COAL1 ? PSY.PrimeMovers.ST : PSY.PrimeMovers.GT,
                fuel = unit_name(u) == :COAL1 ? PSY.ThermalFuels.COAL : PSY.ThermalFuels.NATURAL_GAS,
            )
        end
        PSY.add_component!(sys, device)
    end
    for r in market.regions
        mw = region_demand(market, r)
        PSY.add_component!(
            sys,
            PSY.PowerLoad(;
                name = "$(r)-load", available = true, bus = buses[r],
                active_power = mw / BASE_POWER, reactive_power = 0.0, base_power = BASE_POWER,
                max_active_power = mw / BASE_POWER, max_reactive_power = 0.0,
            ),
        )
    end
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

sys = toy_system(market)

# ### The interconnector's loss model
#
# AEM stores NEMDE's loss model as a supplemental attribute of the `AreaInterchange`:
# [`InterconnectorLossModel`](@ref) holds the loss-factor coefficients, the breakpoints the
# quadratic is linearised on and the share of the loss charged to the sending region. For real
# markets `attach_interconnector_losses!` reads it from `LOSSFACTORMODEL` and `LOSSMODEL`. It is
# per-unit of the system base, hence the scaling by `BASE_POWER`. The toy has 5 loss segments; a
# real interconnector has 60 to 120.

function attach_loss_model!(sys, market)
    ic = market.interconnector
    model = InterconnectorLossModel(;
        interconnector = ic.name, from_region = ic.from, to_region = ic.to,
        from_region_loss_share = ic.from_loss_share, loss_constant = 1.0,
        loss_flow_coefficient = ic.loss_coefficient * BASE_POWER,
        demand_coefficients = Dict{String, Float64}(), breakpoints = ic.breakpoints ./ BASE_POWER,
    )
    PSY.add_supplemental_attribute!(sys, PSY.get_component(PSY.AreaInterchange, sys, ic.name), model)
    return model
end

loss_model = attach_loss_model!(sys, market)

# ### Market data as time series
#
# The offers, availability, ramp rates and initial MW are time series on the components. The
# *names* of the series are the contract between AEM, which writes them from NEMWEB tables, and
# AEMSim, which reads them:
#
# | Series | Meaning | Written by |
# | --- | --- | --- |
# | `"variable_cost"` (a `MarketBidCost`) | the offer bands | `set_market_bids!` |
# | `"max_active_power"` | availability (`MAXAVAIL`, or `UIGF` for a semi-scheduled unit) as a fraction of the rating | `set_nem_dispatch_limits!` |
# | `"ramp_up_rate"`, `"ramp_down_rate"` | ramp rates, per-unit per minute | `set_nem_dispatch_limits!` |
# | `"initial_mw"` | the unit's `INITIALMW` | `set_nem_dispatch_limits!` |
# | `"fcas_trapezium_<service>"`, `"fcas_curve_<service>"` | the FCAS trapezium and offer | `set_fcas_bids!` |
#
# A forecast needs at least two points, so every series carries two timestamps and the model
# horizon is a single interval.

function attach_energy_data!(sys, market)
    stamps = [T0, T0 + RESOLUTION]
    series(name, value; multiplier = nothing) = PSY.SingleTimeSeries(;
        name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps))),
        scaling_factor_multiplier = multiplier,
    )
    for u in market.units
        device = PSY.get_component(PSY.StaticInjection, sys, String(unit_name(u)))
        offer = PSY.PiecewiseStepData([0.0; cumsum(quantity.(bids(u)))], price.(bids(u)))
        AustralianElectricityMarkets._set_incremental_bid_cost!(
            sys, device, (piecewise_step_data = fill(offer, length(stamps)),), T0, RESOLUTION,
        )
        PSY.add_time_series!(
            sys, device, series("max_active_power", availability(u) / u.capacity; multiplier = PSY.get_max_active_power),
        )
        PSY.add_time_series!(sys, device, series("ramp_up_rate", u.ramp_up_mwh / 60 / BASE_POWER))
        PSY.add_time_series!(sys, device, series("ramp_down_rate", u.ramp_down_mwh / 60 / BASE_POWER))
        PSY.add_time_series!(sys, device, series("initial_mw", initial_mw(u) / BASE_POWER))
    end
    for load in PSY.get_components(PSY.PowerLoad, sys)
        PSY.add_time_series!(sys, load, series("max_active_power", 1.0; multiplier = PSY.get_max_active_power))
    end
    return sys
end

attach_energy_data!(sys, market);

# ### FCAS as a service
#
# A [`FCASService`](@ref) is a `PSY.Service` grouping the units that offer one `(region,
# service)` market. The trapezium and the offer are series on the offering unit.

function attach_fcas_data!(sys, market)
    for u in fcas_units(market)
        device = PSY.get_component(PSY.StaticInjection, sys, String(unit_name(u)))
        t = trapezium(u)
        trapezium_pu = Tuple(
            FCASTrapezium(;
                enablement_min = t.enablement_min / BASE_POWER, low_breakpoint = t.low_breakpoint / BASE_POWER,
                high_breakpoint = t.high_breakpoint / BASE_POWER, enablement_max = t.enablement_max / BASE_POWER,
                max_avail = t.max_avail / BASE_POWER,
            ),
        )
        curve = PSY.PiecewiseStepData([0.0; cumsum(quantity.(fcas_bids(u)))] ./ BASE_POWER, price.(fcas_bids(u)))
        for (series_name, value) in ("fcas_trapezium_RAISE6SEC" => trapezium_pu, "fcas_curve_RAISE6SEC" => curve)
            PSY.add_time_series!(
                sys, device,
                PSY.Deterministic(;
                    name = series_name, data = Dict(T0 => fill(value, 2)),
                    resolution = RESOLUTION, interval = RESOLUTION,
                ),
            )
        end
        service = FCASService(;
            name = "$(region(u))_RAISE6SEC", region = region(u), bid_type = BidType.RAISE6SEC,
        )
        PSY.add_service!(sys, service, [device])
    end
    return sys
end

attach_fcas_data!(sys, market);

# ### Generic constraints
#
# A [`GenericConstraint`](@ref) is a `PSY.Service` too: a list of terms (`UnitTerm`,
# `InterconnectorTerm`, `RegionTerm`), a sense, a right-hand side and a penalty factor. The
# `RAISE6SEC` requirements are generic constraints whose terms are the FCAS enablement of a unit
# (`BidType.RAISE6SEC`) and which are tagged with the `(region, service)` price they govern
# ([`FCASRequirement`](@ref)), so the FCAS price can be read off their dual.

function constraint_term(market, t::Term)
    t.kind == :energy && return UnitTerm(String(t.id), BidType.ENERGY, t.factor)
    t.kind == :raise6 && return UnitTerm(String(t.id), BidType.RAISE6SEC, t.factor)
    return InterconnectorTerm(String(t.id), t.factor)
end

const SENSES = Dict(:LE => ConstraintSense.LE, :GE => ConstraintSense.GE, :EQ => ConstraintSense.EQ)

function attach_generic_constraints!(sys, market)
    stamps = [T0, T0 + RESOLUTION]
    for gc in market.constraints
        requirements = [
            FCASRequirement(; region = region(find_unit(market, t.id)), service = BidType.RAISE6SEC)
                for t in gc.terms if t.kind == :raise6
        ]
        constraint = GenericConstraint(;
            name = gc.name, sense = SENSES[gc.sense],
            rhs = gc.rhs / BASE_POWER, constraint_weight = gc.weight,
            terms = ConstraintTerm[constraint_term(market, t) for t in gc.terms],
            fcas_requirements = FCASRequirement[requirements...],
        )
        devices = [PSY.get_component(PSY.StaticInjection, sys, String(t.id)) for t in gc.terms]
        PSY.add_service!(sys, constraint, devices)
        for (series_name, value) in ("rhs" => gc.rhs / BASE_POWER, "invoked" => 1.0)
            PSY.add_time_series!(
                sys, constraint,
                PSY.SingleTimeSeries(; name = series_name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps)))),
            )
        end
    end
    return sys
end

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
# The template chooses a formulation for each component type. AEMSim provides one for each
# NEM-specific part:
#
# | Component | Formulation | Builds |
# | --- | --- | --- |
# | generators, batteries | `NEMReplayDispatch` (a subtype of `AbstractNEMDispatch`) | offer-band variables, availability and ramp rows from `"initial_mw"`, elastic ramp slacks |
# | `AreaInterchange` | `NEMInterconnectorLoss` | the segment, fill and loss variables of the loss curve, and the loss terms in both regional balances |
# | `FCASService` | `FCASMarket` | `FCASCapacityVariable`, the trapezium rows, the FCAS offer cost |
# | `GenericConstraint` | `LinearFactorLimit` | one row of terms, its elastic slack and its dual |
#
# `set_nem_dispatch_models!` inspects the `System` for every generator type that carries the
# NEM dispatch series and assigns `NEMReplayDispatch` to it. "Replay" means each interval's ramp
# is measured from that interval's own `"initial_mw"` series.

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

# For a whole `System` built by `nem_system`, `replication_template(sys)` does all of this at
# once and also leaves out the generic constraints the template cannot model.
#
# Note what the template does *not* say: nothing about bands, ramps, trapezia or loss
# segments. Those live in the methods that PSI calls on the pair *(component type,
# formulation)*, which AEMSim defines:

strip_modules(x) = replace(string(x), r"\b(?:[A-Z][A-Za-z]*\.)+" => "")

function hooks(f, needle)
    rows = NamedTuple{(:hook, :stage, :model_type), Tuple{String, String, String}}[]
    for m in methods(f)
        params = Base.unwrap_unionall(m.sig).parameters
        any(p -> occursin(needle, string(p)), params) || continue
        stage_index = findfirst(p -> occursin("ConstructStage", string(p)), params)
        isnothing(stage_index) && continue
        model_params = Base.unwrap_unionall(params[stage_index + 1]).parameters
        bound(p) = p isa TypeVar ? p.ub : p
        model_type = join(strip_modules.(bound.(model_params)), " / ")
        push!(rows, (; hook = string(nameof(f)), stage = replace(strip_modules(params[stage_index]), "ConstructStage" => ""), model_type))
    end
    return sort!(DataFrame(rows), :stage)
end
vcat(
    hooks(PSI.construct_device!, "AbstractNEMDispatch"),
    hooks(PSI.construct_device!, "NEMInterconnectorLoss"),
    hooks(PSI.construct_service!, "FCASMarket"),
    hooks(PSI.construct_service!, "LinearFactorLimit"),
)

# The formulation types of the dispatch family:

subtypes(AbstractNEMDispatch)

# `NEMLookaheadDispatch` measures the first ramp against a solved initial condition and later
# ones against the previous interval's variable, where `NEMReplayDispatch` reads `"initial_mw"` for
# every interval.

# ## Step 3: build, inspect, solve

model_psi = PSI.DecisionModel(
    template, sys;
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0),
    horizon = RESOLUTION, resolution = RESOLUTION, interval = RESOLUTION,
    initial_time = T0, name = "nemde_aem", store_variable_names = true,
)
build_status = PSI.build!(model_psi; output_dir = mktempdir())

# The container holds typed, named pieces of the problem written by hand on page 2:

container = PSI.get_optimization_container(model_psi)
jump_psi = PSI.get_jump_model(container)

function container_summary(container)
    kinds = (
        "variables" => PSI.get_variables(container), "expressions" => PSI.get_expressions(container),
        "parameters" => PSI.get_parameters(container), "constraints" => PSI.get_constraints(container),
    )
    return DataFrame(
        kind = [k for (k, _) in kinds],
        keys = [length(d) for (_, d) in kinds],
        entries = [
            join(sort!(unique([string(nameof(PSI.IS.Optimization.get_entry_type(k))) for k in keys(d)])), ", ")
                for (_, d) in kinds
        ],
    )
end
container_summary(container)

# | Page 2 (JuMP) | PSI container key | Built by |
# | --- | --- | --- |
# | `dispatch[u]` | variable `ActivePowerVariable` | `NEMReplayDispatch` |
# | `cleared[u, j]`, offer cost | variable `PiecewiseLinearBlockIncrementalOffer`, expression `ProductionCostExpression` | PSI's market-bid cost path, called from `NEMReplayDispatch` |
# | availability, ramp rows | constraints `ActivePowerVariableTimeSeriesLimitsConstraint`, `RampConstraint` (meta `up`/`down`) and slacks `UnitRampUpSlack`/`UnitRampDownSlack` | `NEMReplayDispatch` |
# | `balance[r]` | constraint `CopperPlateBalanceConstraint` on `Area`, expression `ActivePowerBalance` | PSI network model |
# | `flow`, `segment_flow`, `filled`, `loss` | variables `FlowActivePowerVariable`, `InterconnectorLossSegmentVariable`, `InterconnectorLossSegmentFullVariable`, `InterconnectorLossVariable` | `NEMInterconnectorLoss` |
# | `raise[u]` | variable `FCASCapacityVariable` (meta: the service) | `FCASMarket` |
# | trapezium rows | expression `FCASJointCapacityLHS`, constraint `FCASJointCapacityConstraint` | `FCASMarket` |
# | `generic[name]`, `violation[name]` | expression `NEMConstraintLHS`, constraint `NEMConstraintLimit`, slacks `GenericConstraintSlackUp`/`Down` | `LinearFactorLimit` |
#
# The mapping is checked rather than assumed: each of these keys exists in the built container.

expected_keys = [
    (PSI.ActivePowerVariable, PSY.ThermalStandard, ""),
    (PSI.ActivePowerVariable, PSY.RenewableDispatch, ""),
    (PSI.PiecewiseLinearBlockIncrementalOffer, PSY.ThermalStandard, ""),
    (PSI.FlowActivePowerVariable, PSY.AreaInterchange, ""),
    (InterconnectorLossVariable, PSY.AreaInterchange, ""),
    (FCASCapacityVariable, FCASService, "NSW1_RAISE6SEC"),
]
all(PSI.has_container_key(container, entry, component, meta) for (entry, component, meta) in expected_keys)

solve_status = PSI.solve!(model_psi)

# ## Step 4: results, checked against page 2
#
# Variables are in MW. Duals are per unit of the system base and per interval, so
# `dual / (BASE_POWER * DISPATCH_INTERVAL_HOURS)` is \$/MWh. FCAS prices come from
# `compute_fcas_prices`, which sums the duals of the generic constraints that carry an
# FCAS requirement.

results = PSI.OptimizationProblemResults(model_psi)
to_dollars_per_mwh(dual) = dual / (BASE_POWER * DISPATCH_INTERVAL_HOURS)

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
# The template asked for `use_slacks = true` on the network, the FCAS markets and the generic
# constraints, and `NEMReplayDispatch` and `NEMInterconnectorLoss` add slacks on unit ramps and
# interconnector flow limits unconditionally. Each slack is a variable paid at a *constraint
# violation penalty factor* times the Market Price Cap (AEMO, *Constraint Violation Penalty
# Factors*), so an infeasible interval is solved at a violation price instead of failing, as in NEMDE.
# Their sizes at the solution:

slack_types = unique(
    string(nameof(PSI.IS.Optimization.get_entry_type(k))) for k in PSI.list_variable_keys(results)
        if occursin("Slack", string(PSI.IS.Optimization.get_entry_type(k)))
)
slack_total = sum(
    sum(PSI.read_variable(results, k).value)
        for k in PSI.list_variable_keys(results) if occursin("Slack", string(PSI.IS.Optimization.get_entry_type(k)))
)
(slack_types, slack_total)

# Nothing is violated in the toy market, so all slacks are zero and the solution equals the JuMP
# model of page 2, which carries only the generic constraint violations.
#
# ## From the toy to the real market
#
# Everything above was assembled by hand to show the pieces. For real intervals:
#
# 1. `db = aem_connect()` and `populate(db, table, start, stop)` cache the NEMWEB tables.
# 2. `nem_system(db, ConstrainedNetworkConfiguration(); date_range)` builds the `System`: areas,
#    buses, generators, loads, interconnectors with their `InterconnectorLossModel`, one
#    `FCASService` per market and the invoked `GenericConstraint`s.
# 3. The setters `set_demand!`, `set_market_bids!`, `set_nem_dispatch_limits!`,
#    `set_fcas_bids!` and `set_fcas_scaling_inputs!` write the time series of the contract above
#    (`replication_system` does the whole sequence for one interval).
# 4. `replication_template(sys)` builds the template of Step 2 for every component.
# 5. `replicate_interval(db, settlement_date)` builds, solves and compares prices, dispatch,
#    interconnector flows and FCAS prices with AEMO's published outcome.
#
# Checks name what is wrong instead of failing inside PSI: `check_fcas_services(sys, template)`
# before a build verifies that every FCAS service has a model in the template,
# `interconnector_loss_gaps` reports interconnectors with no loss data, and
# `check_interconnector_loss_segments(results, sys)` after a solve verifies that each solved loss
# lies on the loss curve at the solved flow.

check_fcas_services(sys, template)
check_interconnector_loss_segments(results, sys)

# ## What is not covered
#
# - **Multi-interval problems.** `NEMReplayDispatch` solves single intervals measured from
#   `"initial_mw"`; `NEMLookaheadDispatch` chains intervals, and `NEMInterconnectorLoss` and
#   `FCASMarket` support a standalone `DecisionModel` only.
# - **Fast start.** The fast-start profile inputs are read from NEMWEB, but no formulation
#   enforces the inflexibility profile on this branch. Pending #184 adds thermal two-pass
#   replay and separate profile, availability and offer slacks; see [Fast-start dispatch](@ref nemde-fast-start).

# ## [References](@id nemde-aem-references)
#
# - AEMO, [*FCAS Model in NEMDE*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf):
#   the trapezium (§2-3), joint constraints and prices.
# - AEMO, *Constraint Violation Penalty Factors*: the penalty of each constraint family.
# - AEMO, *Marginal Loss Factors* and *Loss Factor Methodology*: the interconnector loss equations.
# - [PowerSimulations.jl documentation](https://nrel-sienna.github.io/PowerSimulations.jl/stable/)
#   and [PowerSystems.jl documentation](https://nrel-sienna.github.io/PowerSystems.jl/stable/).
