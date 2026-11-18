# Thinning an interchange's loss curve with the `loss_breakpoints` keyword of `template_nemde` and the loss
# presets: the segments built, the solved flow against the full curve, the System left unchanged, and the
# argument checks. Built on the toy loss sentinel of `toy_fixture.jl`.

using HiGHS
import PowerSimulations as PSI
import PowerSystems as PSY
using AustralianElectricityMarkets: InterconnectorLossModel, loss_segments

const LB_BREAKPOINTS = collect(-1000.0:100.0:1000.0)   # 21 breakpoints, including 0.0
const LB_CAP = 5                                        # keeps -1000, -500, 0, 500 and 1000

# The loss sentinel of `loss_curve_sentinel_system` with IC1's loss curve on `breakpoints` (MW). The loss is
# charged to the to-area (share 0), so the flow is the area 2 load plus the loss and thinning moves the flow.
function _lb_system(breakpoints; loss_flow_coefficient = 1.0e-4)
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(;
            load_mw = [50.0, 100.0], demand_coefficient = 1.0e-3, share = 0.0,
            loss_constant = 1.05, loss_flow_coefficient, breakpoints,
        ),
    )
end

# The energy template of the loss presets' dispatch participants with IC1 under `NEMInterconnectorLoss`.
_lb_template(; loss_breakpoints = nothing) = template_nemde(;
    interconnectors = :losses, fcas = false, constraints = false, tie_break = false, loss_breakpoints,
)

# The interchange device model of `template`.
_lb_interchange_model(template) = only(m for m in values(PSI.get_branch_models(template)) if PSI.get_component_type(m) == PSY.AreaInterchange)

# Builds and solves `sys` under `template`; returns the model and IC1's flow in the first interval (MW).
function _lb_solve(sys, template)
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    res = PSI.OptimizationProblemResults(model)
    flow_df = PSI.read_variable(res, "FlowActivePowerVariable__AreaInterchange")
    t1 = minimum(flow_df.DateTime)
    flow = only(filter(r -> r.DateTime == t1 && r.name == TOY_INTERCHANGE, flow_df)).value
    return model, flow
end

# The piecewise-linear loss curve of `model` (MW) at flow `f`, with zero demand.
function _lb_curve(model::InterconnectorLossModel, f::Real)
    values = AustralianElectricityMarkets.loss_curve_vertex_values(model, Dict{String, Float64}())
    bps = model.breakpoints
    s = clamp(searchsortedlast(bps, f), 1, length(bps) - 1)
    return values[s] + (f - bps[s]) * (values[s + 1] - values[s]) / (bps[s + 1] - bps[s])
end

@testset "the thinned curve keeps the endpoints, takes the interior evenly, and stays convex" begin
    full = InterconnectorLossModel(;
        interconnector = TOY_INTERCHANGE, from_region = "1", to_region = "2", from_region_loss_share = 0.0,
        loss_constant = 1.05, loss_flow_coefficient = 1.0e-4, demand_coefficients = Dict{String, Float64}(),
        breakpoints = LB_BREAKPOINTS,
    )
    @test AEMS._thin_loss_model(full, LB_CAP).breakpoints == [-1000.0, -500.0, 0.0, 500.0, 1000.0]
    @test AEMS._thin_loss_model(full, 2).breakpoints == [-1000.0, 1000.0]
    @test AEMS._thin_loss_model(full, nothing) === full
    @test AEMS._thin_loss_model(full, length(LB_BREAKPOINTS)) === full
    @test AEMS._thin_loss_model(full, 100) === full
    for n in 2:length(LB_BREAKPOINTS)
        thin = AEMS._thin_loss_model(full, n)
        @test length(thin.breakpoints) == n
        @test issubset(thin.breakpoints, full.breakpoints)
        @test issorted(thin.breakpoints)
        @test issorted(s.slope for s in loss_segments(thin, Dict{String, Float64}()))
    end
    @test_throws ArgumentError AEMS._thin_loss_model(full, 1)
    @test_throws ArgumentError AEMS._thin_loss_model(full, 0)
end

@testset "the loss segments in the container are the cap" begin
    sys = _lb_system(LB_BREAKPOINTS)
    model, _ = _lb_solve(sys, _lb_template(; loss_breakpoints = LB_CAP))
    segments = PSI.get_variable(PSI.get_optimization_container(model), AEMS.InterconnectorLossSegmentVariable(), PSY.AreaInterchange)
    @test length(axes(segments, 2)) == LB_CAP - 1

    full_model, _ = _lb_solve(_lb_system(LB_BREAKPOINTS), _lb_template())
    full_segments = PSI.get_variable(PSI.get_optimization_container(full_model), AEMS.InterconnectorLossSegmentVariable(), PSY.AreaInterchange)
    @test length(axes(full_segments, 2)) == length(LB_BREAKPOINTS) - 1
end

@testset "the solved flow stays within the loss-curve error of the full curve" begin
    _, flow_full = _lb_solve(_lb_system(LB_BREAKPOINTS), _lb_template())
    _, flow_thin = _lb_solve(_lb_system(LB_BREAKPOINTS), _lb_template(; loss_breakpoints = LB_CAP))

    full = InterconnectorLossModel(;
        interconnector = TOY_INTERCHANGE, from_region = "1", to_region = "2", from_region_loss_share = 0.0,
        loss_constant = 1.05, loss_flow_coefficient = 1.0e-4, demand_coefficients = Dict{String, Float64}(),
        breakpoints = LB_BREAKPOINTS,
    )
    thin = AEMS._thin_loss_model(full, LB_CAP)
    # The loss at flow f is the curve at f, so the flow moves by at most the curve error divided by one minus the
    # largest marginal loss over the flows the run takes: loss factor 0.05, area 2 demand term up to 0.1, 1e-4 per MW up to 200 MW.
    curve_error = maximum(abs(_lb_curve(thin, f) - _lb_curve(full, f)) for f in 0.0:1.0:200.0)
    marginal = 0.05 + 0.1 + 1.0e-4 * 200.0
    @test curve_error > 0.0
    @test abs(flow_thin - flow_full) <= curve_error / (1 - marginal) + TOY_TOLERANCE
end

@testset "the System keeps its loss model when the template thins it" begin
    sys = _lb_system(LB_BREAKPOINTS)
    ic = PSY.get_component(PSY.AreaInterchange, sys, TOY_INTERCHANGE)
    before = [copy(m.breakpoints) for m in PSY.get_supplemental_attributes(InterconnectorLossModel, ic)]
    _lb_solve(sys, _lb_template(; loss_breakpoints = LB_CAP))
    after = PSY.get_supplemental_attributes(InterconnectorLossModel, ic)
    @test length(after) == 1
    @test [m.breakpoints for m in after] == before
    @test length(only(after).breakpoints) == length(LB_BREAKPOINTS)
end

@testset "the cap is an attribute of the interchange model and nothing changes without it" begin
    @test PSI.get_attribute(_lb_interchange_model(_lb_template(; loss_breakpoints = LB_CAP)), "loss_breakpoints") == LB_CAP
    @test PSI.get_attribute(_lb_interchange_model(_lb_template()), "loss_breakpoints") === nothing
    @test PSI.get_attribute(_lb_interchange_model(template_losses(; loss_breakpoints = LB_CAP)), "loss_breakpoints") == LB_CAP
    @test PSI.get_attribute(_lb_interchange_model(template_fcas(; loss_breakpoints = LB_CAP)), "loss_breakpoints") == LB_CAP
    @test PSI.get_attribute(_lb_interchange_model(template_constraints(; loss_breakpoints = LB_CAP)), "loss_breakpoints") == LB_CAP
    @test PSI.get_attribute(_lb_interchange_model(template_losses()), "loss_breakpoints") === nothing
end

@testset "the cap keeps the convexity check on the full curve" begin
    # A concave curve stays rejected with a cap of two, whose single segment would pass a slope check on its own.
    sys = _lb_system(LB_BREAKPOINTS; loss_flow_coefficient = -1.0e-4)
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, _lb_template(; loss_breakpoints = 2), sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    PSI.set_output_dir!(model, mktempdir())
    @test_throws r"concave" PSI.build_impl!(model)
end

@testset "argument checks: a cap below two and a cap without the loss model throw" begin
    @test_throws ArgumentError template_nemde(; interconnectors = :losses, loss_breakpoints = 1)
    @test_throws ArgumentError template_nemde(; interconnectors = :losses, loss_breakpoints = 0)
    @test_throws ArgumentError template_losses(; loss_breakpoints = 1)
    @test_throws ArgumentError template_nemde(; interconnectors = :lossless, loss_breakpoints = 3)
    @test_throws ArgumentError template_nemde(; interconnectors = :none, loss_breakpoints = 3)
end
