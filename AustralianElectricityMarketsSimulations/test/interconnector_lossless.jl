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

# Whether both flow slacks of `res` are zero at every interval.
_lossless_flow_slacks_zero(res) = all(
    all(abs.(PSI.read_variable(res, PSI.VariableKey(AEMS.InterconnectorFlowSlack, PSY.AreaInterchange, meta)).value) .< TOY_TOLERANCE)
        for meta in ("surplus", "deficit")
)

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

    @test _lossless_flow_slacks_zero(res)
end

@testset "lossless interchange rejects network models other than AreaBalancePowerModel" begin
    sys = _lossless_sentinel_system()
    template = _lossless_template()
    PSI.set_network_model!(template, PSI.NetworkModel(PSI.CopperPlatePowerModel; use_slacks = false))
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    PSI.set_output_dir!(model, mktempdir())
    @test_throws r"NEMInterconnectorLossless supports PSI.AreaBalancePowerModel only" PSI.build_impl!(model)
end

# Area 2 imports its 50 MW load over `TOY_INTERCHANGE`, whose flow limit into area 2 (to_from) is 30 MW. The
# limit is static, or a series of the interchange's `NEMInterconnectorLimits` when `series` is true.
function _lossless_limited_system(; series::Bool)
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(; load_mw = [50.0, 50.0]),
        mutate! = function (sys, stamps)
            ic = PSY.get_component(PSY.AreaInterchange, sys, TOY_INTERCHANGE)
            PSY.set_flow_limits!(ic, (from_to = 1000.0, to_from = 30.0))
            series || return
            PSY.add_supplemental_attribute!(
                sys, ic,
                AustralianElectricityMarkets.NEMInterconnectorLimits(;
                    from_to_limit = _toy_series_key(sys, ic, AustralianElectricityMarkets.NEM_INTERCONNECTOR_SERIES.from_to_limit, fill(1000.0, 2)),
                    to_from_limit = _toy_series_key(sys, ic, AustralianElectricityMarkets.NEM_INTERCONNECTOR_SERIES.to_from_limit, fill(30.0, 2)),
                ),
            )
            return
        end,
    )
end

# Solves `sys` under the lossless energy template; `use_slacks = false` leaves the area balances without slacks,
# so the flow slacks carry any shortfall.
function _lossless_solve(sys; use_slacks::Bool = true)
    template = _lossless_template()
    use_slacks || PSI.set_network_model!(template, PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = false))
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    return PSI.OptimizationProblemResults(model)
end

# The value of `name` (a variable's `name` column) at `TOY_START` in `frame`.
_lossless_value(frame, name::AbstractString) = only(frame[(frame.name .== name) .& (frame.DateTime .== TOY_START), :value])

@testset "lossless flow limits bind on the static and the series path" begin
    for series in (false, true)
        # The balance slack carries the 20 MW that the 30 MW limit leaves short; the flow slacks stay at zero.
        res = _lossless_solve(_lossless_limited_system(; series))
        flow = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
        @test _lossless_value(flow, TOY_INTERCHANGE) ≈ 30.0 atol = TOY_TOLERANCE
        @test _lossless_flow_slacks_zero(res)
        @test _lossless_value(PSI.read_variable(res, "SystemBalanceSlackUp__Area"), "2") ≈ 20.0 atol = TOY_TOLERANCE
    end
    # Without area-balance slacks the flow surplus slack is the only relief: the flow runs at 50 MW, 20 MW above the limit.
    res = _lossless_solve(_lossless_limited_system(; series = false); use_slacks = false)
    @test _lossless_value(PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange"), TOY_INTERCHANGE) ≈ 50.0 atol = TOY_TOLERANCE
    surplus = PSI.read_variable(res, PSI.VariableKey(AEMS.InterconnectorFlowSlack, PSY.AreaInterchange, "surplus"))
    @test _lossless_value(surplus, TOY_INTERCHANGE) ≈ 20.0 atol = TOY_TOLERANCE
    deficit = PSI.read_variable(res, PSI.VariableKey(AEMS.InterconnectorFlowSlack, PSY.AreaInterchange, "deficit"))
    @test all(abs.(deficit.value) .< TOY_TOLERANCE)
end

@testset "lossless MNSP is a regulated flow within its limits, with no offers or direction" begin
    # The forward and reverse offers cap the link at 30 MW, which a lossless MNSP does not apply: the 50 MW load is served
    # by the flow alone, within the 1000 MW interchange limits.
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    sys = nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(; load_mw = [50.0, 50.0], mnsp = ((30.0, [(30.0, 10.0)]), (30.0, [(30.0, 10.0)]))),
    )
    res = _lossless_solve(sys)
    flow = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    @test _lossless_value(flow, TOY_INTERCHANGE) ≈ 50.0 atol = TOY_TOLERANCE
    entries = Set(PSI.IS.Optimization.get_entry_type(k) for k in PSI.list_variable_keys(res))
    @test isdisjoint(
        entries,
        [AEMS.MNSPLinkFlowVariable, AEMS.MNSPLinkDirectionVariable, AEMS.MNSPLinkBandVariable, AEMS.MNSPLinkLossVariable],
    )
end
