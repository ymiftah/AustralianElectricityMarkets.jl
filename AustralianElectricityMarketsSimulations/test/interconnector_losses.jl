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
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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

@testset "FlowLimitConstraint bounds the flow from static flow_limits" begin
    sys = _loss_test_system()
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    con_ub = PSI.get_constraint(container, PSI.FlowLimitConstraint(), PSY.AreaInterchange, "ub")
    @test !isnothing(con_ub)
end

@testset "scaling_factor_multiplier demand and nonzero demand_coefficients: LP loss matches the curve" begin
    # Regression for the double-scaling bug: area loads carry a real scaling_factor_multiplier
    # (PSY.get_max_active_power), and the loss model's demand_coefficients are nonzero, so
    # get_time_series_values's own scaling must not be re-applied inside _area_demand.
    sys = _loss_test_system(;
        demand_coefficients = Dict("1" => 1.0e-4, "2" => -2.0e-4), pin_multiplier = true,
    )
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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
        model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
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

function _meshed_loss_system(ab_limit)
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(200.0, [(200.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(200.0, [(200.0, 100.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        100.0,
    )
    area_a = PSY.get_component(PSY.Area, sys, "1")
    area_b = PSY.Area(; name = "B")
    area_c = PSY.Area(; name = "C")
    PSY.add_component!(sys, area_b)
    PSY.add_component!(sys, area_c)
    buses = Dict(i => PSY.get_component(PSY.ACBus, sys, "bus$i") for i in 1:5)
    PSY.set_area!(buses[2], area_b)
    PSY.set_area!(buses[3], area_c)
    PSY.set_bus!(PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE), buses[2])
    PSY.set_bus!(PSY.get_component(PSY.PowerLoad, sys, "bus4"), buses[2])
    for line in collect(PSY.get_components(PSY.ACTransmission, sys))
        PSY.remove_component!(sys, line)
    end
    # Equal reactances give AB=2/3 of A's injection; BC is negative for A-to-B transfer.
    for (name, f, t) in (("AB", 1, 2), ("AC", 1, 3), ("BC", 2, 3), ("A4", 1, 4), ("A5", 1, 5))
        PSY.add_component!(
            sys, PSY.Line(;
                name, available = true, active_power_flow = 0.0, reactive_power_flow = 0.0,
                arc = PSY.Arc(; from = buses[f], to = buses[t]), r = 0.0, x = 0.1,
                b = (from = 0.0, to = 0.0), rating = 500.0 / PSY.get_base_power(sys),
                angle_limits = (min = -pi, max = pi),
            )
        )
    end
    for (name, from_area, to_area) in (("AB", area_a, area_b), ("AC", area_a, area_c), ("BC", area_b, area_c))
        limit = name == "AB" ? ab_limit : 200.0
        ic = PSY.AreaInterchange(;
            name, available = true, active_power_flow = 0.0, from_area, to_area,
            flow_limits = (from_to = limit, to_from = limit),
        )
        PSY.add_component!(sys, ic)
        PSY.set_flow_limits!(ic, (from_to = limit, to_from = limit))
        PSY.add_supplemental_attribute!(
            sys, ic, AEMS.InterconnectorLossModel(;
                interconnector = name, from_region = PSY.get_name(from_area),
                to_region = PSY.get_name(to_area), from_region_loss_share = 0.5,
                loss_constant = 1.0, loss_flow_coefficient = 0.0,
                demand_coefficients = Dict{String, Float64}(),
                breakpoints = [-200.0, 200.0] ./ PSY.get_base_power(sys),
            )
        )
    end
    return sys
end

@testset "AreaPTDF losses link signed physical boundary flows and enforce interchange limits" begin
    for (limit, cheap_dispatch) in ((200.0, 100.0), (20.0, 30.0))
        sys = _meshed_loss_system(limit)
        template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaPTDFPowerModel; use_slacks = false))
        set_nem_dispatch_models!(template, sys)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        PSI.set_device_model!(template, PSY.Line, PSI.StaticBranch)
        PSI.set_device_model!(template, PSY.AreaInterchange, AEMS.NEMInterconnectorLoss)
        model = PSI.DecisionModel(
            template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
            resolution = TOY_RESOLUTION, initial_time = TOY_START,
        )
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        res = PSI.OptimizationProblemResults(model)
        flow_df = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
        generation_df = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
        cheap = only(subset(generation_df, :name => ByRow(==(TOY_CHEAP)))).value
        @test cheap ≈ cheap_dispatch atol = 1.0e-6
        for (name, fraction) in (("AB", 2 / 3), ("AC", 1 / 3), ("BC", -1 / 3))
            flow = only(subset(flow_df, :name => ByRow(==(name)))).value
            @test flow ≈ fraction * cheap_dispatch atol = 1.0e-6
        end
    end
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
    model = PSI.DecisionModel(_loss_template(), sys; optimizer = HiGHS.Optimizer, horizon = Hour(2))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, AEMS.InterconnectorLossVariable, PSY.AreaInterchange)
end
