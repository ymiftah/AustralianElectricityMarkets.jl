# `NEMInterconnectorLoss`, a `PSY.AreaInterchange` device formulation putting the loss curve from
# a `PSY.SupplementalAttribute`-attached `InterconnectorLossModel` (root package) into the
# from/to area power balance. Built against `augmented_pscb_system()`
# (`test/integration/pscb_fixture.jl`), which `runtests.jl` loads.

using HiGHS
using DataFrames: subset, ByRow
using TimeSeries: TimeArray, timestamp
import PowerSimulations as PSI
import PowerSystems as PSY
const AEMS = AustralianElectricityMarketsSimulations

"""
    _loss_test_system(; loss_flow_coefficient, from_region_loss_share, breakpoints)

`augmented_pscb_system()` with area 2's own generation (`Solitude`, `SOLAR1`) disabled so its
demand is served only through `IC1`, its `PowerLoad`s' native (unknown-scale) forecast replaced
with a flat multiplier of `1.0` at every native timestamp - so area 2's total demand is exactly
`Σ get_max_active_power(load)`, hand-computable rather than dependent on
`5_bus_hydro_ed_sys`'s own demand profile - and `IC1` carrying a hand-built
[`InterconnectorLossModel`](@ref) (already per-unit of the system's base power - the same
convention `attach_interconnector_losses!` uses) instead of one read from a database, so the
expected loss is hand-computable too. Thermal floors are zeroed the same way
`template_helpers.jl`'s `_fix_thermal_floor!` does, so no minimum-load floor forces infeasible
dispatch.
"""
function _loss_test_system(;
        loss_flow_coefficient::Float64 = 0.0,
        from_region_loss_share::Float64 = 0.4,
        loss_constant::Float64 = 1.05,
        breakpoints::Vector{Float64} = [-100.0, 100.0],
        demand_coefficients::Dict{String, Float64} = Dict{String, Float64}(),
        pin_multiplier::Bool = true,
        priced_supply_only::Bool = false,
        negative_cost::Bool = false,
    )
    sys = augmented_pscb_system()
    for gen in PSY.get_components(PSY.ThermalStandard, sys)
        limits = PSY.get_active_power_limits(gen)
        PSY.set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Solitude"), false)
    PSY.set_available!(PSY.get_component(PSY.RenewableDispatch, sys, "SOLAR1"), false)
    # Zero-cost hydro makes every marginal price zero, so the LP is indifferent to how loss
    # segments fill; thermal units carry a positive cost.
    priced_supply_only && foreach(h -> PSY.set_available!(h, false), PSY.get_components(PSY.HydroDispatch, sys))

    if negative_cost
        # Surplus supply with negative cost drives the receiving region's price below zero.
        foreach(h -> PSY.set_available!(h, false), PSY.get_components(PSY.HydroDispatch, sys))
        for gen in PSY.get_components(PSY.ThermalStandard, sys)
            PSY.set_operation_cost!(
                gen,
                PSY.ThermalGenerationCost(;
                    variable = PSY.CostCurve(PSY.LinearCurve(-50.0)), fixed = 0.0,
                    start_up = 0.0, shut_down = 0.0,
                ),
            )
        end
    end

    for load in PSY.get_components(PSY.PowerLoad, sys)
        raw = PSY.get_time_series(PSY.SingleTimeSeries, load, "max_active_power")
        stamps = timestamp(PSY.get_data(raw))
        data = TimeArray(stamps, ones(length(stamps)))
        # The DeterministicSingleTimeSeries view must go first: PSY refuses to remove a
        # SingleTimeSeries a Deterministic view still depends on.
        PSY.remove_time_series!(sys, PSY.DeterministicSingleTimeSeries, load, "max_active_power")
        PSY.remove_time_series!(sys, PSY.SingleTimeSeries, load, "max_active_power")
        multiplier = pin_multiplier ? PSY.get_max_active_power : nothing
        PSY.add_time_series!(
            sys, load,
            PSY.SingleTimeSeries(; name = "max_active_power", data = data, scaling_factor_multiplier = multiplier),
        )
    end
    # Regenerate the Deterministic views removed above, on the fixture's own hourly grid; PSI
    # finds no load parameter to add when no PowerLoad carries one.
    PSY.transform_single_time_series!(sys, Hour(2), Hour(1))

    base_power = PSY.get_base_power(sys)
    model = AEMS.InterconnectorLossModel(;
        interconnector = "IC1", from_region = "1", to_region = "2",
        from_region_loss_share = from_region_loss_share,
        loss_constant = loss_constant,
        loss_flow_coefficient = loss_flow_coefficient * base_power,
        demand_coefficients = Dict(k => v * base_power for (k, v) in demand_coefficients),
        breakpoints = breakpoints ./ base_power,
    )
    ic1 = PSY.get_component(PSY.AreaInterchange, sys, "IC1")
    PSY.add_supplemental_attribute!(sys, ic1, model)
    return sys
end

"`_area_balance_template()` (`template_helpers.jl`) with `IC1` under `NEMInterconnectorLoss`."
function _loss_template()
    template = _area_balance_template()
    PSI.set_device_model!(template, PSY.AreaInterchange, AEMS.NEMInterconnectorLoss)
    return template
end

@testset "NEMInterconnectorLoss <: PSI.AbstractBranchFormulation" begin
    @test AEMS.NEMInterconnectorLoss <: PSI.AbstractBranchFormulation
end

@testset "missing/ambiguous InterconnectorLossModel throws" begin
    sys = augmented_pscb_system()
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    PSI.set_output_dir!(model, mktempdir())
    err = try
        PSI.build_impl!(model)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("IC1", sprint(showerror, err))
end

@testset "non-ascending segment slopes throw at construction" begin
    # A negative loss_flow_coefficient makes the quadratic concave: chord slopes descend.
    sys = _loss_test_system(; loss_flow_coefficient = -1.0e-3, breakpoints = [-100.0, 0.0, 100.0])
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    PSI.set_output_dir!(model, mktempdir())
    err = try
        PSI.build_impl!(model)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("concave", sprint(showerror, err))
end

@testset "hand-computed loss for a known flow and a linear (single-segment) loss model" begin
    # loss_flow_coefficient = 0.0 makes the quadratic degenerate to a straight line with slope
    # loss_constant - 1 everywhere, so the chord linearisation is exact off the breakpoints too -
    # the arithmetic below is closed-form, not just consistent with the LP's own segments.
    share = 0.4
    sys = _loss_test_system(; from_region_loss_share = share)
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    res = PSI.OptimizationProblemResults(model)
    flow_df = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    loss_df = PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange")
    t1 = minimum(flow_df.DateTime)
    flow = only(subset(flow_df, :DateTime => ByRow(==(t1)), :name => ByRow(==("IC1")))).value
    loss = only(subset(loss_df, :DateTime => ByRow(==(t1)), :name => ByRow(==("IC1")))).value

    # `flow` is the only nonzero source for area 2's demand (Solitude/SOLAR1 disabled), so at
    # optimum `flow == load2 + (1 - share) * loss` exactly (area 2's own balance equation), and
    # `loss == 0.05 * flow` exactly (linear loss factor, loss_constant = 1.05).
    @test loss ≈ 0.05 * flow atol = 1.0e-6
    # `_loss_test_system` pinned area 2's `"max_active_power"` multiplier to `1.0` at every
    # timestamp, so the dispatched demand is exactly the static rating - no time-series lookup
    # needed to reconstruct it. `PSI.build!` leaves `sys` in `UnitSystem.SYSTEM_BASE`, under
    # which `get_max_active_power` reads per-unit, not MW - read it back in `NATURAL_UNITS`.
    load2 = PSY.with_units_base(sys, "NATURAL_UNITS") do
        sum(
            PSY.get_max_active_power(l)
                for l in PSY.get_components(PSY.PowerLoad, sys)
                if PSY.get_name(PSY.get_area(PSY.get_bus(l))) == "2"
        )
    end
    @test flow ≈ load2 + (1.0 - share) * loss atol = 1.0e-6

    @testset "loss split balances the from-area: generation = load + flow + share * loss" begin
        # Every generator is on area 1 (Solitude/SOLAR1, area 2's own generation, are disabled),
        # so area 1's own balance equation pins its total generation directly - not a tautological
        # restatement of the split fractions, but a genuine physical balance check.
        thermal = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
        hydro = PSI.read_variable(res, "ActivePowerVariable__HydroDispatch")
        gen1 = sum(subset(thermal, :DateTime => ByRow(==(t1))).value) +
            sum(subset(hydro, :DateTime => ByRow(==(t1))).value)
        load1 = PSY.with_units_base(sys, "NATURAL_UNITS") do
            sum(
                PSY.get_max_active_power(l)
                    for l in PSY.get_components(PSY.PowerLoad, sys)
                    if PSY.get_name(PSY.get_area(PSY.get_bus(l))) == "1"
            )
        end
        @test gen1 ≈ load1 + flow + share * loss atol = 1.0e-6
    end
end

@testset "multi-segment quadratic curve fills segments cheapest-first" begin
    # A genuine quadratic (loss_flow_coefficient > 0) needs at least two segments to linearise,
    # and their chord slopes strictly ascend - cost minimisation (positive marginal generation
    # cost everywhere here) must fill the lower-slope segment fully before touching the next.
    sys = _loss_test_system(;
        loss_flow_coefficient = 2.0e-4, breakpoints = [-100.0, -25.0, 0.0, 25.0, 100.0],
        priced_supply_only = true,
    )
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    gaps = interconnector_loss_gaps(PSI.OptimizationProblemResults(model), sys)
    @test !isempty(gaps)
    # Positive marginal cost everywhere in this toy system, so the LP has no incentive to
    # over-dissipate - the solved loss must land exactly on the curve at the solved flow.
    @test all(abs(gap) < 1.0e-6 for gap in values(gaps))

    res = PSI.OptimizationProblemResults(model)
    flow_df = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    loss_df = PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange")
    comparison = innerjoin(
        select(flow_df, :DateTime, :name, :value => :flow),
        select(loss_df, :DateTime, :name, :value => :loss);
        on = [:DateTime, :name], validate = (true, true),
    )
    for row in eachrow(comparison)
        breakpoints = [-100.0, -25.0, 0.0, 25.0, 100.0]
        segment = clamp(searchsortedlast(breakpoints, row.flow), 1, 4)
        lo, hi = breakpoints[segment:(segment + 1)]
        # Chord of 0.05 * flow + 0.0001 * flow^2 between lo and hi, in natural MW.
        expected = 0.05 * row.flow + 0.0001 * ((lo + hi) * row.flow - lo * hi)
        @test row.loss ≈ expected atol = 1.0e-6
    end
    seg_df = PSI.read_variable(res, "InterconnectorLossSegmentVariable__AreaInterchange")
    t1 = minimum(seg_df.DateTime)
    widths = [75.0, 25.0, 25.0, 75.0]  # breakpoints [-100,-25,0,25,100], segment widths in order
    rows = subset(seg_df, :DateTime => ByRow(==(t1)), :name => ByRow(==("IC1")))
    values_by_segment = Dict(parse(Int, r.name2) => r.value for r in eachrow(rows))
    segment_values = [values_by_segment[s] for s in 1:4]
    # Cheapest-first (contiguous fill from segment 1): every fully-used segment precedes any
    # partially- or un-used one - no segment is used while a strictly cheaper one sits idle.
    first_not_full = findfirst(i -> !isapprox(segment_values[i], widths[i]; atol = 1.0e-6), 1:4)
    if !isnothing(first_not_full)
        @test all(isapprox(segment_values[i], 0.0; atol = 1.0e-6) for i in (first_not_full + 1):4)
    end
end

@testset "negative weighted price cannot burn energy on out-of-order segments" begin
    # Negative-cost supply makes extra loss profitable, so only the segment encoding keeps
    # the solved loss on the curve at the solved flow.
    sys = _loss_test_system(;
        loss_flow_coefficient = 2.0e-4, breakpoints = [-100.0, -25.0, 0.0, 25.0, 100.0],
        negative_cost = true,
    )
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    res = PSI.OptimizationProblemResults(model)
    gaps = interconnector_loss_gaps(res, sys)
    @test !isempty(gaps)
    @test all(abs(gap) < 1.0e-6 for gap in values(gaps))
    prices = PSI.read_dual(res, PSI.CopperPlateBalanceConstraint, PSY.Area)
    price = Dict((r.name, r.DateTime) => r.value for r in eachrow(prices))
    share = 0.4
    for stamp in unique(prices.DateTime)
        @test share * price[("1", stamp)] + (1 - share) * price[("2", stamp)] < 0.0
    end
    @test PSI.is_milp(PSI.get_optimization_container(model))
end

@testset "single-segment loss models add no fill indicators" begin
    sys = _loss_test_system()
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, AEMS.InterconnectorLossSegmentFullVariable, PSY.AreaInterchange)
end

@testset "FlowLimitConstraint bounds the flow from static flow_limits" begin
    sys = _loss_test_system()
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    con_ub = PSI.get_constraint(container, PSI.FlowLimitConstraint(), PSY.AreaInterchange, "ub")
    @test !isnothing(con_ub)
end

@testset "per-interval flow-limit series bound the flow as a fraction of the static limit" begin
    # `negative` makes area 1 the deficient side (its loads tripled, area 2's supply restored), so
    # the flow runs to-from-negative and the from_to series is the one that binds.
    function solved_flow(; negative::Bool, from_to_static, to_from_static, from_to_ratio, to_from_ratio)
        sys = _loss_test_system()
        if negative
            PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Solitude"), true)
            PSY.set_available!(PSY.get_component(PSY.RenewableDispatch, sys, "SOLAR1"), true)
            for load in PSY.get_components(l -> PSY.get_name(PSY.get_area(PSY.get_bus(l))) == "1", PSY.PowerLoad, sys)
                PSY.set_max_active_power!(load, 3 * PSY.get_max_active_power(load))
            end
        end
        ic1 = PSY.get_component(PSY.AreaInterchange, sys, "IC1")
        PSY.with_units_base(sys, "NATURAL_UNITS") do
            PSY.set_flow_limits!(ic1, (from_to = from_to_static, to_from = to_from_static))
        end
        load = first(PSY.get_components(PSY.PowerLoad, sys))
        grid = collect(timestamp(PSY.get_data(PSY.get_time_series(PSY.SingleTimeSeries, load, "max_active_power"))))
        for (name, ratio) in (("from_to_flow_limit", from_to_ratio), ("to_from_flow_limit", to_from_ratio))
            PSY.add_time_series!(
                sys, ic1, PSY.SingleTimeSeries(; name = name, data = TimeArray(grid, fill(ratio, length(grid)))),
            )
        end
        PSY.transform_single_time_series!(sys, Hour(2), Hour(1))
        model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        flow_df = PSI.read_variable(PSI.OptimizationProblemResults(model), "FlowActivePowerVariable__AreaInterchange")
        return flow_df.value[argmax(abs.(flow_df.value))]
    end
    wide = 1.0e4
    positive = solved_flow(; negative = false, from_to_static = wide, to_from_static = wide, from_to_ratio = 1.0, to_from_ratio = 1.0)
    @test positive > 0
    # Asymmetric statics (to_from 10x from_to): halving the to_from limit caps the positive flow.
    capped = solved_flow(;
        negative = false, from_to_static = wide / 10, to_from_static = wide,
        from_to_ratio = 1.0, to_from_ratio = 0.5 * positive / wide,
    )
    @test capped ≈ 0.5 * positive atol = 1.0e-4

    negative = solved_flow(; negative = true, from_to_static = wide, to_from_static = wide, from_to_ratio = 1.0, to_from_ratio = 1.0)
    @test negative < 0
    # Asymmetric statics (from_to 10x to_from): the from_to series caps the negative flow, and a
    # swapped from_to/to_from convention would leave it free.
    capped_negative = solved_flow(;
        negative = true, from_to_static = wide, to_from_static = wide / 10,
        from_to_ratio = 0.5 * abs(negative) / wide, to_from_ratio = 1.0,
    )
    @test capped_negative ≈ 0.5 * negative atol = 1.0e-4
end

@testset "scaling_factor_multiplier demand and nonzero demand_coefficients: LP loss matches the curve" begin
    # Regression for the double-scaling bug: area loads carry a real scaling_factor_multiplier
    # (PSY.get_max_active_power), and the loss model's demand_coefficients are nonzero, so
    # get_time_series_values's own scaling must not be re-applied inside _area_demand.
    sys = _loss_test_system(;
        demand_coefficients = Dict("1" => 1.0e-4, "2" => -2.0e-4), pin_multiplier = true,
    )
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    gaps = interconnector_loss_gaps(PSI.OptimizationProblemResults(model), sys)
    @test !isempty(gaps)
    @test all(abs(gap) < 1.0e-6 for gap in values(gaps))
end

@testset "recurrent solves require rebuilding demand-dependent losses" begin
    sys = _loss_test_system(; demand_coefficients = Dict("2" => 1.0e-4))
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    container = PSI.get_optimization_container(model)
    container.built_for_recurrent_solves = true
    err = try
        PSI.construct_device!(
            container, sys, PSI.ArgumentConstructStage(),
            PSI.DeviceModel(PSY.AreaInterchange, AEMS.NEMInterconnectorLoss),
            PSI.NetworkModel(PSI.AreaBalancePowerModel),
        )
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("rebuild", sprint(showerror, err))
    @test occursin("demand", sprint(showerror, err))
end

@testset "rebuilt models refresh demand coefficients and exclude disabled loads" begin
    # A linear loss curve makes this a closed-form check independent of interpolation.
    for (multiplier, disable_load) in ((1.0, false), (2.0, false), (1.0, true))
        sys = _loss_test_system(; demand_coefficients = Dict("2" => 1.0e-4))
        area2_loads = collect(
            PSY.get_components(
                l -> PSY.get_name(PSY.get_area(PSY.get_bus(l))) == "2", PSY.PowerLoad, sys,
            )
        )
        for load in area2_loads
            PSY.set_max_active_power!(load, multiplier * PSY.get_max_active_power(load))
        end
        disable_load && PSY.set_available!(first(area2_loads), false)
        expected_demand = sum(
            PSY.get_max_active_power(l) for l in area2_loads if PSY.get_available(l); init = 0.0,
        )
        model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        container = PSI.get_optimization_container(model)
        demand = AEMS._area_demand(container, sys)
        base = PSY.get_base_power(sys)
        @test get(demand, "2", zeros(2)) .* base ≈ fill(expected_demand, 2)
        @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        res = PSI.OptimizationProblemResults(model)
        flow_df = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
        loss_df = PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange")
        slope = 0.05 + 1.0e-4 * expected_demand
        definitions = PSI.get_constraint(container, AEMS.InterconnectorLossDefinitionConstraint(), PSY.AreaInterchange)
        segments = PSI.get_variable(container, AEMS.InterconnectorLossSegmentVariable(), PSY.AreaInterchange)
        for (t, stamp) in enumerate(sort(unique(flow_df.DateTime)))
            @test PSI.JuMP.normalized_coefficient(definitions["IC1", t], segments["IC1", "1", t]) ≈ -slope
            flow = only(subset(flow_df, :DateTime => ByRow(==(stamp)), :name => ByRow(==("IC1")))).value
            loss = only(subset(loss_df, :DateTime => ByRow(==(stamp)), :name => ByRow(==("IC1")))).value
            @test flow ≈ expected_demand / (1.0 - 0.6 * slope) atol = 1.0e-6
            @test loss ≈ slope * flow atol = 1.0e-6
        end
    end
end

@testset "NEMInterconnectorLoss rejects network models other than AreaBalancePowerModel" begin
    sys = _loss_test_system()
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaPTDFPowerModel; use_slacks = false))
    PSI.set_device_model!(template, PSY.AreaInterchange, AEMS.NEMInterconnectorLoss)
    model = _decision_model(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "area demand rejects a load on an area-less bus" begin
    sys = _loss_test_system()
    load = first(PSY.get_components(PSY.PowerLoad, sys))
    PSY.set_area!(PSY.get_bus(load), nothing)
    err = try
        AEMS._area_demand(Dates.DateTime(2000, 1, 1), 2, sys)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin(PSY.get_name(load), sprint(showerror, err))
end

@testset "no available AreaInterchange builds without loss variables" begin
    sys = _loss_test_system()
    foreach(d -> PSY.set_available!(d, false), PSY.get_components(PSY.AreaInterchange, sys))
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, AEMS.InterconnectorLossVariable, PSY.AreaInterchange)
end

"""
    _attach_mnsp_offers!(sys; forward, reverse, forward_tlf = 1.0, reverse_tlf = 1.0)

Gives `IC1` (area `"1"` to `"2"`) an MNSP offer per link, constant over the model horizon. `forward` and
`reverse` are `(max_avail_mw, [(band_mw, price), ...])`.
"""
function _attach_mnsp_offers!(
        sys; forward, reverse, forward_tlfs = (1.0, 1.0), reverse_tlfs = (1.0, 1.0),
    )
    ic = PSY.get_component(PSY.AreaInterchange, sys, "IC1")
    t0 = first(PSY.get_forecast_initial_times(sys))
    interval = PSY.get_forecast_interval(sys)
    windows = PSY.get_forecast_window_count(sys)
    resolution = only(PSY.get_time_series_resolutions(sys))
    n_steps = Int(Dates.value(PSY.get_forecast_horizon(sys)) ÷ Dates.value(resolution))
    for (dir, (max_avail, bands), tlfs) in (
            ("forward", forward, forward_tlfs), ("reverse", reverse, reverse_tlfs),
        )
        x = [0.0; cumsum(Float64[b[1] for b in bands])]
        curve = PSY.PiecewiseStepData(x, Float64[b[2] for b in bands])
        for (name, values) in (
                ("mnsp_$(dir)_offer", fill(curve, n_steps)), ("mnsp_$(dir)_max_avail", fill(Float64(max_avail), n_steps)),
            )
            PSY.add_time_series!(
                sys, ic,
                PSY.Deterministic(;
                    name = name, data = Dict(t0 + (k - 1) * interval => values for k in 1:windows), resolution = resolution,
                    interval = interval,
                ),
            )
        end
        PSY.get_ext(ic)["mnsp_$dir"] = Dict{String, Any}("from_region_tlf" => tlfs[1], "to_region_tlf" => tlfs[2])
    end
    return ic
end

"Solves `sys` under the loss template and returns `(flow, forward, reverse, slack)` at the first timestep, in MW."
function _solve_mnsp(sys; zero_flow::Bool = false)
    model = _decision_model(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    if zero_flow  # a zero-flow generic constraint on the interconnector's net flow
        container = PSI.get_optimization_container(model)
        flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
        for t in PSI.get_time_steps(container)
            PSI.JuMP.@constraint(PSI.get_jump_model(container), flow_var["IC1", t] == 0.0)
        end
    end
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    res = PSI.OptimizationProblemResults(model)
    first_value(df) = begin
        t1 = minimum(df.DateTime)
        sum(subset(df, :DateTime => ByRow(==(t1))).value)
    end
    flow = first_value(PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange"))
    duals = PSI.read_dual(res, PSI.CopperPlateBalanceConstraint, PSY.Area)
    t_first = minimum(duals.DateTime)
    dual(area) = only(subset(duals, :DateTime => ByRow(==(t_first)), :name => ByRow(==(area)))).value
    PSI.has_container_key(PSI.get_optimization_container(model), MNSPLinkFlowVariable, PSY.AreaInterchange) ||
        return (flow = flow, forward = missing, reverse = missing, dual1 = dual("1"), dual2 = dual("2"))
    links = PSI.read_variable(res, "MNSPLinkFlowVariable__AreaInterchange")
    t1 = minimum(links.DateTime)
    link(dir) = only(subset(links, :DateTime => ByRow(==(t1)), :name2 => ByRow(==(dir)))).value
    return (flow = flow, forward = link("forward"), reverse = link("reverse"), dual1 = dual("1"), dual2 = dual("2"))
end

@testset "MNSP link offers bound and price the interconnector flow" begin
    free = _solve_mnsp(_loss_test_system(; breakpoints = [-1000.0, 1000.0]))
    @test ismissing(free.forward)  # no offers: no link variables, the free-flow model
    @test free.flow > 40.0  # free-flow baseline: area 2's demand is served through IC1

    @testset "flow is limited by the link's MAXAVAIL" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        _attach_mnsp_offers!(sys; forward = (30.0, [(100.0, 10.0)]), reverse = (30.0, [(100.0, 10.0)]))
        out = _solve_mnsp(sys)
        @test out.flow ≈ 30.0 atol = 1.0e-6
        @test out.forward ≈ 30.0 atol = 1.0e-6
        @test out.reverse ≈ 0.0 atol = 1.0e-6
    end

    @testset "flow follows the offered bands when availability exceeds demand" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        _attach_mnsp_offers!(sys; forward = (500.0, [(500.0, 10.0)]), reverse = (500.0, [(500.0, 10.0)]))
        out = _solve_mnsp(sys)
        @test out.flow ≈ free.flow atol = 1.0e-6
        @test out.forward ≈ out.flow atol = 1.0e-6
    end

    @testset "a dear offer loses to area 2's own unit" begin
        # Solitude is available again; the link only covers what it cannot.
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Solitude"), true)
        _attach_mnsp_offers!(sys; forward = (500.0, [(500.0, 5000.0)]), reverse = (500.0, [(500.0, 5000.0)]))
        out = _solve_mnsp(sys)
        @test out.flow < 0.5 * free.flow
    end

    @testset "a reverse-only offer cannot export into area 2" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        _attach_mnsp_offers!(sys; forward = (0.0, [(100.0, 10.0)]), reverse = (500.0, [(500.0, 10.0)]))
        out = _solve_mnsp(sys)
        @test out.flow ≈ 0.0 atol = 1.0e-6
        @test out.forward ≈ 0.0 atol = 1.0e-6
    end

    @testset "negative offers on both links do not circulate" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        _attach_mnsp_offers!(sys; forward = (500.0, [(500.0, -50.0)]), reverse = (500.0, [(500.0, -50.0)]))
        out = _solve_mnsp(sys)
        @test out.flow ≈ free.flow atol = 1.0e-6
        @test min(out.forward, out.reverse) ≈ 0.0 atol = 1.0e-6
    end
    @testset "link loss factors scale the delivered MW and the dispatch condition holds" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        _attach_mnsp_offers!(
            sys; forward = (500.0, [(500.0, 10.0)]), reverse = (500.0, [(500.0, 10.0)]),
            forward_tlfs = (1.0, 0.9907), reverse_tlfs = (0.9907, 1.0),
        )
        out = _solve_mnsp(sys)
        # Linear loss 0.05 * flow, share 0.4: area 2 balance is TLF * q - 0.6 * loss = load.
        load2 = free.flow * (1 - 0.6 * 0.05)
        @test out.forward * 0.9907 - 0.6 * 0.05 * out.forward ≈ load2 atol = 1.0e-6
        # The offer is inframarginal, so its reduced cost is zero: offer price = to_tlf * price_to - from_tlf *
        # price_from less the loss charge (slope 0.05, share 0.4). Duals are per-unit objective values of an
        # hourly interval.
        marginal = 0.9907 * out.dual2 - 1.0 * out.dual1 - 0.05 * (0.4 * out.dual1 + 0.6 * out.dual2)
        @test marginal ≈ PSY.get_base_power(sys) * 10.0 rtol = 1.0e-6
    end

    @testset "a zero net flow zeroes both links even when circulation would create energy" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        # Reverse link with to_tlf > from_tlf: circulating both links delivers free energy at both ends.
        _attach_mnsp_offers!(
            sys; forward = (500.0, [(500.0, 0.01)]), reverse = (500.0, [(500.0, 0.01)]),
            forward_tlfs = (1.0, 1.0), reverse_tlfs = (0.9, 1.1),
        )
        out = _solve_mnsp(sys; zero_flow = true)
        @test out.forward ≈ 0.0 atol = 1.0e-6
        @test out.reverse ≈ 0.0 atol = 1.0e-6
    end

    @testset "negative offers on both links still give finite balance duals" begin
        sys = _loss_test_system(; breakpoints = [-1000.0, 1000.0])
        _attach_mnsp_offers!(sys; forward = (500.0, [(500.0, -50.0)]), reverse = (500.0, [(500.0, -50.0)]))
        out = _solve_mnsp(sys)
        @test isfinite(out.dual1) && isfinite(out.dual2)
    end
end
