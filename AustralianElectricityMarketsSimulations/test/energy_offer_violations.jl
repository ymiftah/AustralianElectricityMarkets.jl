function offered_band_system(; bands = [(40.0, 20.0)], target = 60.0, weight = 1160.0, max_avail = 100.0)
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, bands; initial = 60.0, ramp_up = 100.0, availability = max_avail),
            TOY_EXPENSIVE => toy_unit(200.0, [(200.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
        ],
        80.0; horizon = TOY_RESOLUTION,
        mutate! = function (sys, stamps)
            add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, target; sense = ConstraintSense.EQ)
            only(PSY.get_components(GenericConstraint, sys)).constraint_weight = weight
            return
        end,
    )
end

@testset "an energy offer curve must start at 0 MW" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(40.0, 20.0)]; initial = 10.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
        ],
        80.0;
        mutate! = function (sys, stamps)
            cheap = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            curve = PSY.PiecewiseStepData([10.0, 50.0], [20.0])
            _toy_energy_bid!(sys, cheap, AustralianElectricityMarkets.BidDirection.GEN, stamps, fill(curve, length(stamps)), fill(100.0, length(stamps)))
            return
        end,
    )
    status, log = _toy_build_log(toy_model(sys; template = replay_template(sys)))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("energy offer curves must start at 0 MW", log)
end

@testset "non-conformance may exceed the total offered energy bands" begin
    sys = offered_band_system()
    out = solve_toy(sys; generic_slacks = true)
    @test out.dispatch_mw[TOY_CHEAP] ≈ 60.0 atol = 1.0e-6
    @test out.band_mw[(TOY_CHEAP, 1)] ≈ 40.0 atol = 1.0e-6
    rows = filter(:family => ==("energy_offer"), read_constraint_violations(out.results, sys))
    @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
    @test only(rows.direction) == "up"
    expected = (40.0 * 20.0 + 20.0 * 80.0 + 20.0 * 1135.0 * 17500.0) * interval_hours(DISPATCH_INTERVAL)
    @test out.objective ≈ expected atol = 1.0e-4
end

@testset "total-band priority and cumulative availability penalties" begin
    for (weight, availability, expected) in ((1130.0, 100.0, 40.0), (1160.0, 30.0, 40.0), (1600.0, 30.0, 60.0))
        sys = offered_band_system(; weight, max_avail = availability)
        out = solve_toy(sys; generic_slacks = true)
        @test out.dispatch_mw[TOY_CHEAP] ≈ expected atol = 1.0e-6
    end
end

@testset "zero total offered quantity remains an elastic boundary" begin
    sys = offered_band_system(; bands = [(0.0, 20.0)])
    out = solve_toy(sys; generic_slacks = true)
    @test out.dispatch_mw[TOY_CHEAP] ≈ 60.0 atol = 1.0e-6
    @test only(filter(:family => ==("energy_offer"), read_constraint_violations(out.results, sys)).MW) ≈ 60.0 atol = 1.0e-6
end

@testset "recurrent offered-band widths update step by step" begin
    sys = offered_band_system(; bands = [[(40.0, 20.0)], [(80.0, 20.0)]])
    out = run_replay(sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))
    rows = filter(:family => ==("energy_offer"), read_constraint_violations(out.results, sys))
    @test nrow(rows) == 1
    @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
    @test only(rows.DateTime) == TOY_START
end

@testset "scheduled-load and both storage energy directions have elastic offer totals" begin
    for (kind, target) in ((:load, 60.0), (:storage_gen, 60.0), (:storage_load, -60.0))
        name = kind == :load ? "LD1" : TOY_BATTERY
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 80.0, ramp_up = 100.0)],
            80.0; horizon = TOY_RESOLUTION,
            loads = kind == :load ? [name => toy_load(40.0, 1.0; initial = 0.0, ramp_up = 100.0, availability = 100.0)] : Pair{String, Any}[],
            batteries = kind == :load ? Pair{String, Any}[] : [name => toy_battery(40.0, 50.0, 40.0, 1.0; initial = 0.0, ramp_up = 100.0, gen_avail = 100.0, load_avail = 100.0)],
            mutate! = function (sys, stamps)
                device = PSY.get_component(kind == :load ? InterruptiblePowerLoad : EnergyReservoirStorage, sys, name)
                gc = GenericConstraint(; name = "NC_OFFER", sense = ConstraintSense.EQ, rhs = target, terms = ConstraintTerm[UnitTerm(name, BidType.ENERGY, 1.0)])
                gc.constraint_weight = 1160.0
                PSY.add_service!(sys, gc, [device])
                add_toy_constraint_series!(sys, gc, stamps, fill(target, length(stamps)), fill(1.0, length(stamps)))
                return
            end,
        )
        out = solve_toy(sys; generic_slacks = true)
        actual = kind == :load ? out.load_mw[name] : out.dispatch_mw[name]
        @test actual ≈ target atol = 1.0e-6
        rows = filter(:family => ==("energy_offer"), read_constraint_violations(out.results, sys))
        @test only(rows.MW) ≈ 20.0 atol = 1.0e-6
        @test only(rows.name) == name
    end
end

@testset "every slack variant's key meta reads back as its violation family" begin
    kinds = Dict(AEMS._VIOLATION_FAMILIES)
    family(S, meta) = AEMS._violation_kind(kinds, S, meta)
    unit(tag) = (AEMS.NEMUnitSlack, AEMS._nem_unit_slack_meta(tag))
    mnsp(tag, link = nothing) = (AEMS.MNSPSlack, isnothing(link) ? AEMS._mnsp_slack_meta(tag) : AEMS._mnsp_slack_meta(tag, link))
    fcas(tag) = (AEMS.FCASSlack, AEMS._fcas_slack_meta(tag, "NSW1_RAISEREG"))
    flow(tag) = (AEMS.InterconnectorFlowSlack, AEMS._interconnector_flow_meta(tag))
    cases = [
        unit(AEMS.EnergyOfferSurplusVariant()) => ("energy_offer", "up"),
        unit(AEMS.EnergyOfferDeficitVariant()) => ("energy_offer", "down"),
        unit(AEMS.EnergyOfferDecrementalSurplusVariant()) => ("energy_offer", "up"),
        unit(AEMS.EnergyOfferDecrementalDeficitVariant()) => ("energy_offer", "down"),
        unit(AEMS.EnergyLimitMaxAvailVariant()) => ("energy_max_avail", "up"),
        unit(AEMS.EnergyLimitUIGFVariant()) => ("energy_uigf", "up"),
        unit(AEMS.EnergyLimitMaxAvailOutVariant()) => ("energy_max_avail", "up"),
        unit(AEMS.EnergyLimitMaxAvailInVariant()) => ("energy_max_avail", "down"),
        unit(AEMS.FixedLoadSurplusVariant()) => ("fixed_load", "up"),
        unit(AEMS.FixedLoadDeficitVariant()) => ("fixed_load", "down"),
        unit(AEMS.UnitRampUpVariant()) => ("unit_ramp", "up"),
        unit(AEMS.UnitRampDownVariant()) => ("unit_ramp", "down"),
        mnsp(AEMS.MNSPMaxAvailVariant(), AEMS.MNSPForwardLink()) => ("mnsp_max_avail", "up"),
        mnsp(AEMS.MNSPOfferVariant(), AEMS.MNSPReverseLink()) => ("mnsp_offer", "up"),
        mnsp(AEMS.MNSPRampUpVariant()) => ("mnsp_ramp", "up"),
        mnsp(AEMS.MNSPRampDownVariant()) => ("mnsp_ramp", "down"),
        mnsp(AEMS.MNSPFixedLoadSurplusVariant(), AEMS.MNSPForwardLink()) => ("mnsp_fixed_load", "up"),
        mnsp(AEMS.MNSPFixedLoadDeficitVariant(), AEMS.MNSPReverseLink()) => ("mnsp_fixed_load", "down"),
        fcas(AEMS.FCASJointCapacityVariant()) => ("fcas_enablement", "up"),
        fcas(AEMS.FCASJointRampingVariant()) => ("fcas_joint_ramping", "up"),
        fcas(AEMS.FCASMaxAvailVariant()) => ("fcas_max_avail", "up"),
        fcas(AEMS.FCASBDURampingVariant()) => ("fcas_bdu_ramping", "up"),
        flow(AEMS.InterconnectorFlowSurplus()) => ("interconnector_flow", "up"),
        flow(AEMS.InterconnectorFlowDeficit()) => ("interconnector_flow", "down"),
    ]
    @test [family(key...) for (key, _) in cases] == last.(cases)
end

@testset "energy band prices are build-time objective coefficients, not parameters" begin
    sys = nem_toy_system(
        Dict(TOY_CHEAP => toy_unit(50.0, [(20.0, 10.0), (30.0, 25.0)]; initial = 0.0, ramp_up = 100.0)), 10.0;
        horizon = TOY_RESOLUTION,
        batteries = ["BAT" => toy_battery(20.0, 75.0, 20.0, 25.0; initial = 0.0, ramp_up = 100.0)],
        loads = ["LOAD" => toy_load(20.0, 40.0; initial = 0.0, ramp_up = 100.0)],
    )
    model = toy_model(sys; template = replay_template(sys))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    invariant = PSI.get_invariant_terms(PSI.get_objective_expression(container))
    scale = 100.0 * interval_hours(PSI.get_resolution(container))
    gen = PSI.get_variable(container, EnergyOfferBandVariable(), ThermalStandard, "gen")
    @test PSI.JuMP.coefficient(invariant, gen[TOY_CHEAP, "1", 1]) == scale * 10.0
    @test PSI.JuMP.coefficient(invariant, gen[TOY_CHEAP, "2", 1]) == scale * 25.0
    for (T, name, meta, price) in (
            (EnergyReservoirStorage, "BAT", "gen", 75.0),
            (EnergyReservoirStorage, "BAT", "load", -25.0),
            (InterruptiblePowerLoad, "LOAD", "load", -40.0),
        )
        band = PSI.get_variable(container, EnergyOfferBandVariable(), T, meta)[name, "1", 1]
        @test PSI.JuMP.coefficient(invariant, band) ≈ price * scale
    end
end
