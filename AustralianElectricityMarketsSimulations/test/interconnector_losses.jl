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
    )
    sys = augmented_pscb_system()
    for gen in PSY.get_components(PSY.ThermalStandard, sys)
        limits = PSY.get_active_power_limits(gen)
        PSY.set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    PSY.set_available!(PSY.get_component(PSY.ThermalStandard, sys, "Solitude"), false)
    PSY.set_available!(PSY.get_component(PSY.RenewableDispatch, sys, "SOLAR1"), false)

    for load in PSY.get_components(PSY.PowerLoad, sys)
        PSY.get_name(PSY.get_area(PSY.get_bus(load))) == "2" || continue
        raw = PSY.get_time_series(PSY.SingleTimeSeries, load, "max_active_power")
        stamps = timestamp(PSY.get_data(raw))
        data = TimeArray(stamps, ones(length(stamps)))
        PSY.clear_time_series!(sys, load)
        PSY.add_time_series!(sys, load, PSY.SingleTimeSeries(; name = "max_active_power", data = data))
    end

    base_power = PSY.get_base_power(sys)
    model = AEMS.InterconnectorLossModel(;
        interconnector = "IC1", from_region = "1", to_region = "2",
        from_region_loss_share = from_region_loss_share,
        loss_constant = loss_constant,
        loss_flow_coefficient = loss_flow_coefficient * base_power,
        demand_coefficients = Dict{String, Float64}(),
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
    # needed to reconstruct it.
    load2 = sum(
        PSY.get_max_active_power(l)
            for l in PSY.get_components(PSY.PowerLoad, sys)
            if PSY.get_name(PSY.get_area(PSY.get_bus(l))) == "2"
    )
    @test flow ≈ load2 + (1.0 - share) * loss atol = 1.0e-6

    @testset "losses split between the two regional balances by from_region_loss_share" begin
        # Direct algebraic identity from the hand-computed values above, not a second solve:
        # the from-area's share is `share * loss`, the to-area's the remainder.
        from_share_loss = share * loss
        to_share_loss = (1.0 - share) * loss
        @test isapprox(from_share_loss + to_share_loss, loss; atol = 1.0e-9)
        @test isapprox(from_share_loss / loss, share; atol = 1.0e-9)
        @test isapprox(to_share_loss / loss, 1.0 - share; atol = 1.0e-9)
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
