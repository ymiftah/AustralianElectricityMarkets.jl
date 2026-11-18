# `NEMInterconnectorLossless`, the `PSY.AreaInterchange` formulation with the flow, flow limits and priced
# flow slacks of `NEMInterconnectorLoss` and no loss terms. Built on the loss sentinel system of
# `stock_simulation.jl`, with area 2 importing its load through `TOY_INTERCHANGE`.

using HiGHS
import PowerSimulations as PSI
import PowerSystems as PSY

# Same construction as `loss_curve_sentinel_system` in `stock_simulation.jl`, which this group does not load.
function _lossless_sentinel_system(; area2_mw = [50.0, 100.0])
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(;
            load_mw = area2_mw, demand_coefficient = 1.0e-3, share = 1.0,
            loss_constant = 1.05, loss_flow_coefficient = 1.0e-4,
        ),
    )
end

# `energy_template()` (the `template_nemde` dispatch participants) with `TOY_INTERCHANGE` lossless.
function _lossless_template()
    template = energy_template()
    PSI.set_device_model!(template, PSY.AreaInterchange, AEMS.NEMInterconnectorLossless)
    return template
end

@testset "lossless interchange: flow equals area 2 load, no loss terms, area prices equal" begin
    sys = _lossless_sentinel_system()
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, _lossless_template(), sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, AEMS.InterconnectorLossVariable, PSY.AreaInterchange)
    @test !PSI.has_container_key(container, AEMS.InterconnectorLossSegmentVariable, PSY.AreaInterchange)
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    res = PSI.OptimizationProblemResults(model)

    flow_df = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    t1 = minimum(flow_df.DateTime)
    flow = only(filter(r -> r.DateTime == t1 && r.name == TOY_INTERCHANGE, flow_df)).value
    @test flow ≈ 50.0 atol = TOY_TOLERANCE

    # The balance dual is scaled by base power times the interval length, as in `read_prices`.
    scale = PSY.get_base_power(sys) * AEMS.interval_hours(AEMS.DISPATCH_INTERVAL)
    prices = PSI.read_dual(res, "CopperPlateBalanceConstraint__Area")
    price_at(area) = only(filter(r -> r.DateTime == t1 && r.name == area, prices)).value / scale
    @test price_at("1") ≈ 20.0 atol = TOY_TOLERANCE
    @test price_at("2") ≈ 20.0 atol = TOY_TOLERANCE

    tables = AEMS.read_solved_interval(res, sys)
    @test nrow(tables.interconnectors) > 0
    @test all(ismissing, tables.interconnectors.MWLOSSES)
    @test nrow(AEMS.read_interconnector_loss_gaps(res, sys)) == 0

    for meta in ("surplus", "deficit")
        slack = PSI.read_variable(res, PSI.VariableKey(AEMS.InterconnectorFlowSlack, PSY.AreaInterchange, meta))
        @test all(abs.(slack.value) .< TOY_TOLERANCE)
    end
end

@testset "lossless interchange rejects network models other than AreaBalancePowerModel" begin
    sys = _lossless_sentinel_system()
    template = _lossless_template()
    PSI.set_network_model!(template, PSI.NetworkModel(PSI.CopperPlatePowerModel; use_slacks = false))
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    PSI.set_output_dir!(model, mktempdir())
    @test_throws r"NEMInterconnectorLossless supports PSI.AreaBalancePowerModel only" PSI.build_impl!(model)
end
