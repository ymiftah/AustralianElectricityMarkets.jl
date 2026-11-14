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

@testset "every slack variant's key meta parses back to its variant and keeps its violation family" begin
    kinds = Dict(AEMS._VIOLATION_FAMILIES)
    nem_unit = [
        (AEMS.EnergyOfferSurplusVariant(), "energy_offer|surplus", ("energy_offer", "up")),
        (AEMS.EnergyOfferDeficitVariant(), "energy_offer|deficit", ("energy_offer", "down")),
        (AEMS.EnergyOfferDecrementalSurplusVariant(), "energy_offer|decremental_surplus", ("energy_offer", "up")),
        (AEMS.EnergyOfferDecrementalDeficitVariant(), "energy_offer|decremental_deficit", ("energy_offer", "down")),
        (AEMS.EnergyLimitMaxAvailVariant(), "energy_limit|max_avail", ("energy_max_avail", "up")),
        (AEMS.EnergyLimitUIGFVariant(), "energy_limit|uigf", ("energy_uigf", "up")),
        (AEMS.EnergyLimitMaxAvailOutVariant(), "energy_limit|max_avail_out", ("energy_max_avail", "up")),
        (AEMS.EnergyLimitMaxAvailInVariant(), "energy_limit|max_avail_in", ("energy_max_avail", "down")),
        (AEMS.FixedLoadSurplusVariant(), "fixed_load|surplus", ("fixed_load", "up")),
        (AEMS.FixedLoadDeficitVariant(), "fixed_load|deficit", ("fixed_load", "down")),
        (AEMS.UnitRampUpVariant(), "unit_ramp|up", ("unit_ramp", "up")),
        (AEMS.UnitRampDownVariant(), "unit_ramp|down", ("unit_ramp", "down")),
    ]
    for (tag, meta, family) in nem_unit
        @test AEMS._nem_unit_slack_meta(tag) == meta
        @test AEMS._nem_unit_slack_variant(meta) === tag
        @test AEMS._violation_kind(kinds, AEMS.NEMUnitSlack, meta) == family
    end

    # Ramp variants take no link; every other MNSP variant is composed with the link direction.
    mnsp = [
        (AEMS.MNSPMaxAvailVariant(), AEMS.MNSPForwardLink(), ("mnsp_max_avail", "up")),
        (AEMS.MNSPOfferVariant(), AEMS.MNSPReverseLink(), ("mnsp_offer", "up")),
        (AEMS.MNSPRampUpVariant(), AEMS.MNSPForwardLink(), ("mnsp_ramp", "up")),
        (AEMS.MNSPRampDownVariant(), AEMS.MNSPForwardLink(), ("mnsp_ramp", "down")),
        (AEMS.MNSPFixedLoadSurplusVariant(), AEMS.MNSPForwardLink(), ("mnsp_fixed_load", "up")),
        (AEMS.MNSPFixedLoadDeficitVariant(), AEMS.MNSPReverseLink(), ("mnsp_fixed_load", "down")),
    ]
    for (tag, link, family) in mnsp
        meta = tag isa AEMS._MNSPRampVariant ? AEMS._mnsp_slack_meta(tag) : AEMS._mnsp_slack_meta(tag, link)
        @test AEMS._mnsp_slack_variant(meta) === tag
        @test AEMS._violation_kind(kinds, AEMS.MNSPSlack, meta) == family
    end

    # Each FCAS row family is joined to a service meta with `|`.
    fcas = [
        (AEMS.FCASJointCapacityVariant(), ("fcas_enablement", "up")),
        (AEMS.FCASJointRampingVariant(), ("fcas_joint_ramping", "up")),
        (AEMS.FCASMaxAvailVariant(), ("fcas_max_avail", "up")),
        (AEMS.FCASBDURampingVariant(), ("fcas_bdu_ramping", "up")),
    ]
    for (tag, family) in fcas
        meta = AEMS._fcas_slack_meta(tag, "NSW1_RAISEREG")
        @test AEMS._fcas_slack_variant(meta) === tag
        @test AEMS._violation_kind(kinds, AEMS.FCASSlack, meta) == family
    end

    interconnector = [
        (AEMS.InterconnectorFlowSurplus(), ("interconnector_flow", "up")),
        (AEMS.InterconnectorFlowDeficit(), ("interconnector_flow", "down")),
    ]
    for (tag, family) in interconnector
        meta = AEMS._interconnector_flow_meta(tag)
        @test AEMS._interconnector_flow_variant(meta) === tag
        @test AEMS._violation_kind(kinds, AEMS.InterconnectorFlowSlack, meta) == family
    end
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
    @test !isdefined(AEMS, :EnergyBandPriceParameter)
    @test all(k -> nameof(PSI.IS.Optimization.get_entry_type(k)) != :EnergyBandPriceParameter, Base.keys(PSI.get_parameters(model)))
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
