# `NEMInterconnectorLoss` (`src/devices/interconnector_losses.jl`): NEMDE's interconnector
# losses on `PSY.AreaInterchange`. Built against a small hand-built two-area system, not the PSCB
# fixture, for exact numeric control: `GEN1` (cheap, area "AREA1") is the only generation, `LOAD2`
# (area "AREA2") the only load, so `IC1`'s flow is pinned exactly by `AREA2`'s own balance
# equation - every test here predicts the solved flow/loss in closed form from that equation
# rather than approximating it.

using HiGHS
import JuMP
import PowerSimulations as PSI
import PowerSystems as PSY
const AEMS = AustralianElectricityMarketsSimulations

const IL_START = DateTime(2025, 1, 1, 0, 0)

# LOSSCONSTANT = 1.0 zeroes the linear term, demand_coefficients is empty, so
# `interconnector_losses(model, flow, demand) == 0.5 * loss_flow_coefficient * flow^2`
# independent of demand or load1/load2 - every test below computes its target flow/loss from
# this closed form directly instead of solving the coupled area-balance system numerically.
const IL_MODEL = InterconnectorLossModel(
    "IC1", "AREA1", "AREA2", 0.4, 1.0, 1.0e-4, Dict{String, Float64}(),
    [0.0, 100.0, 200.0, 300.0],
)
_il_losses(flow) = interconnector_losses(IL_MODEL, flow, Dict{String, Float64}())

"""
    _first_value(df) -> Float64

`df`'s `value` at its earliest `DateTime` - every scenario in this file is flat (constant
`"max_active_power"` over both hourly steps), so every variable is (near-)identical at every
timestep; this picks one row deterministically instead of assuming `nrow(df) == 1`.
"""
function _first_value(df)
    t1 = minimum(df.DateTime)
    return only(subset(df, :DateTime => ByRow(==(t1))).value)
end

"""
    _two_area_system(; base_power=100.0, load2_mw, gen1_max_mw=1000.0) -> System

Two-`Area` `System` (`"AREA1"`/`"AREA2"`) built directly, not from `PowerSystemCaseBuilder`:
`GEN1` (`ThermalStandard`, cheap linear cost) in `"AREA1"`; `LOAD2` (`PowerLoad`, flat
`load2_mw` demand over 2 hourly steps) in `"AREA2"`; `AreaInterchange` `"IC1"`
(`from_area = AREA1, to_area = AREA2`, wide-open flow limits) joining them. `AREA2` carries no
generation, so `IC1`'s flow is pinned by `AREA2`'s own balance, not by cost optimisation - see
the module comment.

A freshly-constructed `PSY` component's raw numeric fields are stored per-unit of `base_power`
(the device's own for `ThermalStandard`/`PowerLoad`, the system's for `AreaInterchange`, which
carries no `base_power` of its own) regardless of the system's current display mode at
`add_component!` time - dividing every natural-MW quantity by `base_power` before construction
is what makes it read back as natural MW once `PSI` finishes building against this system (this
package's own `pscb_fixture.jl` exhibits the identical behaviour for its hand-added
`AreaInterchange`). `LOAD2`'s `"max_active_power"` time series is a flat `1.0` - PSI's
`StaticPowerLoad` reads it as a `[0,1]` multiplier of the `max_active_power` field, not an
absolute MW value ([`_area_demand`](@ref)'s docstring).
"""
function _two_area_system(;
        base_power::Float64 = 100.0, load2_mw::Float64, gen1_max_mw::Float64 = 1000.0,
    )
    sys = PSY.System(base_power)
    PSY.set_units_base_system!(sys, "NATURAL_UNITS")

    area1 = PSY.Area("AREA1")
    area2 = PSY.Area("AREA2")
    PSY.add_component!(sys, area1)
    PSY.add_component!(sys, area2)

    bus1 = PSY.ACBus(;
        number = 1, name = "bus1", available = true, bustype = PSY.ACBusTypes.REF,
        angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = 230.0, area = area1,
    )
    bus2 = PSY.ACBus(;
        number = 2, name = "bus2", available = true, bustype = PSY.ACBusTypes.REF,
        angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1),
        base_voltage = 230.0, area = area2,
    )
    PSY.add_component!(sys, bus1)
    PSY.add_component!(sys, bus2)

    PSY.add_component!(
        sys,
        PSY.ThermalStandard(;
            name = "GEN1", available = true, status = true, bus = bus1,
            active_power = 0.0, reactive_power = 0.0, rating = gen1_max_mw / base_power,
            active_power_limits = (min = 0.0, max = gen1_max_mw / base_power),
            reactive_power_limits = nothing, ramp_limits = nothing,
            operation_cost = PSY.ThermalGenerationCost(;
                variable = PSY.CostCurve(PSY.LinearCurve(10.0)),
                fixed = 0.0, start_up = 0.0, shut_down = 0.0,
            ),
            base_power = base_power,
        ),
    )

    load2 = PSY.PowerLoad(;
        name = "LOAD2", available = true, bus = bus2, active_power = load2_mw / base_power,
        reactive_power = 0.0, base_power = base_power, max_active_power = load2_mw / base_power,
        max_reactive_power = 0.0,
    )
    PSY.add_component!(sys, load2)

    PSY.add_component!(
        sys,
        PSY.AreaInterchange(;
            name = "IC1", available = true, active_power_flow = 0.0,
            from_area = area1, to_area = area2,
            flow_limits = (from_to = 1.0e4 / base_power, to_from = 1.0e4 / base_power),
        ),
    )

    # A genuine `Deterministic` (not `SingleTimeSeries` + `transform_single_time_series!`, which
    # produces a `DeterministicSingleTimeSeries` - `_resolve_fcas_series`/`get_data` don't support
    # that lazily-windowed type), matching how `fcas_market.jl`'s own test fixtures build FCAS
    # series directly. Flat `1.0`: always at `max_active_power`, i.e. constant `load2_mw`.
    PSY.add_time_series!(
        sys, load2,
        PSY.Deterministic(;
            name = "max_active_power", data = Dict(IL_START => fill(1.0, 2)),
            resolution = Hour(1), interval = Hour(1),
        ),
    )
    return sys
end

"""
    _il_template(loss_models) -> ProblemTemplate

`AreaBalancePowerModel` + `NEMInterconnectorLoss` on `AreaInterchange`, for `_two_area_system`.
"""
function _il_template(loss_models::Dict{String, InterconnectorLossModel})
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
    PSI.set_network_model!(template, PSI.NetworkModel(PSI.AreaBalancePowerModel))
    PSI.set_device_model!(
        template,
        PSI.DeviceModel(
            PSY.AreaInterchange, AEMS.NEMInterconnectorLoss;
            attributes = Dict{String, Any}("loss_models" => loss_models),
        ),
    )
    return template
end

"Same as [`_il_template`](@ref) but lossless `PSI.StaticBranch` - Step 3's baseline."
function _baseline_template()
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
    PSI.set_network_model!(template, PSI.NetworkModel(PSI.AreaBalancePowerModel))
    PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
    return template
end

"""
    _build_and_solve(sys, template) -> OptimizationProblemResults

Builds and solves `template` against `sys`, asserting both steps succeed, and returns the
results object every test below reads variables from.
"""
function _build_and_solve(sys, template)
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer,
        horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    return PSI.OptimizationProblemResults(model)
end

@testset "Step 1: solved loss matches interconnector_losses(model, flow, demand) at a breakpoint" begin
    # losses(200) = 0.5e-4 * 200^2 = 2.0 exactly; share = 0.4 so area2's balance
    # (0 - load2 + flow - 0.6*loss = 0) is solved by load2 = 200 - 0.6*2.0 = 198.8, landing the
    # flow exactly on IL_MODEL's middle breakpoint - the chord segments reconstruct it exactly.
    load2_mw = 200.0 - 0.6 * _il_losses(200.0)
    sys = _two_area_system(; load2_mw = load2_mw)
    res = _build_and_solve(sys, _il_template(Dict("IC1" => IL_MODEL)))

    flow = _first_value(PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange"))
    loss = _first_value(PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange"))

    @test isapprox(flow, 200.0; atol = 1.0e-3)
    @test isapprox(loss, _il_losses(200.0); atol = 1.0e-3)
    # The property under test: read back at the *solved* flow, not the hand-computed target.
    @test isapprox(loss, _il_losses(flow); atol = 1.0e-6)
end

@testset "Step 2: loss segments fill in ascending-slope order, not out of order" begin
    # Target flow = 150 (mid-way through segment 2 of 3): losses(150) = 1.125, so
    # load2 = 150 - 0.6*1.125 = 149.325.
    target_flow = 150.0
    load2_mw = target_flow - 0.6 * _il_losses(target_flow)
    sys = _two_area_system(; load2_mw = load2_mw)
    res = _build_and_solve(sys, _il_template(Dict("IC1" => IL_MODEL)))

    seg = PSI.read_variable(res, "InterconnectorLossSegmentVariable__AreaInterchange")
    t1 = minimum(seg.DateTime)
    row = seg_label -> only(
        subset(
            seg, :DateTime => ByRow(==(t1)), :name => ByRow(==("IC1")),
            :name2 => ByRow(==(seg_label)),
        ),
    ).value
    seg1, seg2, seg3 = row("1"), row("2"), row("3")

    # Predicted directly from IL_MODEL's own segment widths: 100 MW wide each, target flow 150.
    @test isapprox(seg1, 100.0; atol = 0.2)  # segment 1 fully filled first (cheapest slope)
    @test isapprox(seg2, 50.0; atol = 0.2)   # segment 2 partially filled
    @test isapprox(seg3, 0.0; atol = 0.2)    # segment 3 (priciest slope) untouched

    # Generic ascending-order check: a later segment is only nonzero once every earlier one is
    # already at its upper bound - never a partial fill skipped over for a later segment.
    widths = [100.0, 100.0, 100.0]
    values = [seg1, seg2, seg3]
    for i in 1:(length(values) - 1)
        values[i + 1] > 1.0e-6 && @test isapprox(values[i], widths[i]; atol = 0.2)
    end
end

@testset "Step 3: the area balance actually loses power - generation exceeds load by the modeled losses" begin
    load2_mw = 150.0
    sys = _two_area_system(; load2_mw = load2_mw)

    res = _build_and_solve(sys, _il_template(Dict("IC1" => IL_MODEL)))
    total_gen = sum(PSI.read_variable(res, "ActivePowerVariable__ThermalStandard").value)
    total_loss = sum(PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange").value)
    total_load = 2 * load2_mw  # LOAD2 only, flat over 2 hourly steps; AREA1 carries no load.

    @test total_loss > 1.0e-3  # otherwise this test would pass vacuously
    @test isapprox(total_gen - total_load, total_loss; atol = 1.0e-2)

    baseline_sys = _two_area_system(; load2_mw = load2_mw)
    baseline_res = _build_and_solve(baseline_sys, _baseline_template())
    baseline_gen = sum(PSI.read_variable(baseline_res, "ActivePowerVariable__ThermalStandard").value)
    @test isapprox(baseline_gen, total_load; atol = 1.0e-2)  # lossless: generation == load exactly
end

@testset "Step 4: from_region_loss_share splits the loss between the two areas' balances" begin
    load2_mw = 150.0

    model0 = InterconnectorLossModel(
        "IC1", "AREA1", "AREA2", 0.0, 1.0, 1.0e-4, Dict{String, Float64}(),
        [0.0, 100.0, 200.0, 300.0],
    )
    sys0 = _two_area_system(; load2_mw = load2_mw)
    res0 = _build_and_solve(sys0, _il_template(Dict("IC1" => model0)))
    flow0 = _first_value(PSI.read_variable(res0, "FlowActivePowerVariable__AreaInterchange"))
    loss0 = _first_value(PSI.read_variable(res0, "InterconnectorLossVariable__AreaInterchange"))
    gen0 = _first_value(PSI.read_variable(res0, "ActivePowerVariable__ThermalStandard"))

    model1 = InterconnectorLossModel(
        "IC1", "AREA1", "AREA2", 1.0, 1.0, 1.0e-4, Dict{String, Float64}(),
        [0.0, 100.0, 200.0, 300.0],
    )
    sys1 = _two_area_system(; load2_mw = load2_mw)
    res1 = _build_and_solve(sys1, _il_template(Dict("IC1" => model1)))
    flow1 = _first_value(PSI.read_variable(res1, "FlowActivePowerVariable__AreaInterchange"))
    loss1 = _first_value(PSI.read_variable(res1, "InterconnectorLossVariable__AreaInterchange"))
    gen1 = _first_value(PSI.read_variable(res1, "ActivePowerVariable__ThermalStandard"))

    # share = 0: AREA2 (to-area) bears the full loss, so it must import extra flow to cover it;
    # AREA1's own generation then exactly matches that flow (no local loss burden of its own).
    @test isapprox(flow0 - loss0, load2_mw; atol = 1.0e-3)
    @test isapprox(gen0, flow0; atol = 1.0e-3)

    # share = 1: AREA1 (from-area) bears the full loss instead, so AREA2 needs no extra import -
    # flow exactly equals its own load - while AREA1 generates flow *plus* the whole loss.
    @test isapprox(flow1, load2_mw; atol = 1.0e-3)
    @test isapprox(gen1 - flow1, loss1; atol = 1.0e-3)

    @test flow0 > flow1  # share = 0 pushes the loss burden into extra required flow
end

@testset "Step 5: an interconnector missing from loss_models throws ArgumentError, never silently lossless" begin
    sys = _two_area_system(; load2_mw = 100.0)
    ic1 = PSY.get_component(PSY.AreaInterchange, sys, "IC1")

    @test_throws ArgumentError AEMS._validate_loss_models([ic1], Dict{String, InterconnectorLossModel}())
    @test_throws ArgumentError AEMS._loss_models(
        PSI.DeviceModel(PSY.AreaInterchange, AEMS.NEMInterconnectorLoss),
    )

    model = PSI.DecisionModel(
        _il_template(Dict{String, InterconnectorLossModel}()), sys;
        optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "Step 6: per-unit conversion is correct - natural-MW losses are base-power independent" begin
    load2_mw = 200.0 - 0.6 * _il_losses(200.0)  # same breakpoint-exact target as Step 1
    sys = _two_area_system(; base_power = 250.0, load2_mw = load2_mw)
    res = _build_and_solve(sys, _il_template(Dict("IC1" => IL_MODEL)))

    flow = _first_value(PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange"))
    loss = _first_value(PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange"))

    @test isapprox(flow, 200.0; atol = 1.0e-3)
    @test isapprox(loss, _il_losses(200.0); atol = 1.0e-3)
    @test isapprox(loss, _il_losses(flow); atol = 1.0e-6)
end

@testset "Step 7: demand contributes to the loss curve, not just flow" begin
    # Every model above (IL_MODEL, model0, model1) uses an empty demand_coefficients, so the
    # demand term contributes exactly 0.0 to every prior assertion - _area_demand runs but its
    # return value never affects a single outcome. This model puts a coefficient on "AREA2" (the
    # only area with a PowerLoad in _two_area_system) so demand actually has to feed through
    # correctly - wrong by the base_power factor, wrong by the peak_mw multiplier, or all zeros
    # would all land far from the closed-form target below and fail every assertion.
    c = 1.0e-3
    demand_model = InterconnectorLossModel(
        "IC1", "AREA1", "AREA2", 0.4, 1.0, 1.0e-4, Dict("AREA2" => c),
        [0.0, 100.0, 200.0, 300.0],
    )

    # Solving AREA2's balance (flow == load2_mw + 0.6 * losses(flow)) in closed form for a target
    # flow of 200 (a breakpoint, so the chords reconstruct losses(200) exactly), with
    # losses(f) = c * load2_mw * f + 0.5e-4 * f^2 (loss_constant = 1.0 zeroes the flow-independent
    # constant, demand = load2_mw itself since AREA2 carries only LOAD2):
    #   load2_mw * (1 + 0.6 * c * 200) = 200 - 0.6 * 0.5e-4 * 200^2
    #   load2_mw * 1.12 = 198.8  =>  load2_mw = 177.5
    # The demand term (c * 177.5 * 200 = 35.5) is ~95% of the total loss (37.5) at that flow - the
    # sensitivity this test is designed to catch.
    load2_mw = 177.5
    demand = Dict("AREA1" => 0.0, "AREA2" => load2_mw)
    expected_loss = interconnector_losses(demand_model, 200.0, demand)
    @test isapprox(expected_loss, 37.5; atol = 1.0e-9)  # sanity check on the hand computation

    sys = _two_area_system(; load2_mw = load2_mw)
    template = _il_template(Dict("IC1" => demand_model))
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer,
        horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    # Direct unit test on _area_demand itself, not just end-to-end inference through the solve:
    # AREA2's resolved demand must equal LOAD2's own flat load2_mw, in natural MW, at every
    # timestep. AREA1 carries no PowerLoad at all, so it never appears as a key (_area_demand's
    # own docstring).
    container = PSI.get_optimization_container(model)
    demand_by_area = AEMS._area_demand(container, sys)
    @test Set(keys(demand_by_area)) == Set(["AREA2"])
    @test isapprox(demand_by_area["AREA2"], fill(load2_mw, 2); atol = 1.0e-6)

    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    res = PSI.OptimizationProblemResults(model)
    flow = _first_value(PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange"))
    loss = _first_value(PSI.read_variable(res, "InterconnectorLossVariable__AreaInterchange"))

    @test isapprox(flow, 200.0; atol = 1.0e-3)
    @test isapprox(loss, expected_loss; atol = 1.0e-3)
    @test isapprox(loss, interconnector_losses(demand_model, flow, demand); atol = 1.0e-6)
end

@testset "Step 8: a non-convex loss model (loss_flow_coefficient <= 0) throws ArgumentError, never silently understating losses" begin
    bad_model = InterconnectorLossModel(
        "IC1", "AREA1", "AREA2", 0.4, 1.0, -1.0e-4, Dict{String, Float64}(),
        [0.0, 100.0, 200.0, 300.0],
    )
    @test_throws ArgumentError AEMS._validate_convex_segments("IC1", bad_model)

    sys = _two_area_system(; load2_mw = 100.0)
    model = PSI.DecisionModel(
        _il_template(Dict("IC1" => bad_model)), sys;
        optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "Step 9: a loss model narrower than the interconnector's flow limits warns once, naming it" begin
    # IL_MODEL's breakpoints ([0, 100, 200, 300]) are strictly narrower, on both ends, than IC1's
    # own flow_limits (+/- 1.0e4/base_power in _two_area_system).
    sys = _two_area_system(; load2_mw = 100.0)
    ic1 = PSY.get_component(PSY.AreaInterchange, sys, "IC1")
    base_power = PSY.get_base_power(sys)

    # _narrow_breakpoint_interconnectors is only ever called from construct_device!, where `sys`
    # is in UnitSystem.SYSTEM_BASE (PSI.init_optimization_container! sets it before any device is
    # constructed) - mirror that here so PSY.get_flow_limits reads back the same per-unit way it
    # does in production, rather than natural MW.
    PSY.set_units_base_system!(sys, "SYSTEM_BASE")
    narrow = AEMS._narrow_breakpoint_interconnectors([ic1], Dict("IC1" => IL_MODEL), base_power)
    @test narrow == ["IC1"]

    # A model whose breakpoints match flow_limits exactly (in natural MW) is not flagged.
    limits_pu = PSY.get_flow_limits(ic1)
    wide_model = InterconnectorLossModel(
        "IC1", "AREA1", "AREA2", 0.4, 1.0, 1.0e-4, Dict{String, Float64}(),
        [-limits_pu.from_to * base_power, 0.0, limits_pu.to_from * base_power],
    )
    @test isempty(
        AEMS._narrow_breakpoint_interconnectors([ic1], Dict("IC1" => wide_model), base_power),
    )

    # _warn_narrow_breakpoints is tested directly, not by wrapping a full PSI.build! in
    # @test_logs: build!'s own logger setup (IS.configure_logging + Logging.with_logger) filters
    # @warn below its console_level = Logging.Error default and doesn't propagate to whatever
    # logger was active before the call, so a @test_logs wrapped around build! never sees
    # anything - confirmed empirically (raising console_level to Logging.Warn didn't help either).
    @test_logs (:warn, r"breakpoint range narrower") match_mode = :any begin
        AEMS._warn_narrow_breakpoints(["IC1"])
    end
    @test_logs min_level = Base.CoreLogging.Warn begin
        AEMS._warn_narrow_breakpoints(String[])  # empty: no warning at all
    end

    # End-to-end: the full build (still through this exact code path) does succeed with a narrow
    # loss model - the point is just that its @warn isn't independently observable here.
    model = PSI.DecisionModel(
        _il_template(Dict("IC1" => IL_MODEL)), sys;
        optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
end
