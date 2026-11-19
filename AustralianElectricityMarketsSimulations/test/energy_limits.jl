# A 60 MW conformance target competes with separate 40 MW bid and 45 MW forecast limits.
function energy_limit_system(; max_avail = 100.0, uigf = 45.0, target = 60.0, weight = 1160.0, fixed_load = nothing, fixed_invoked = 1.0, initial = 60.0, down = 100.0, price = 20.0, rating = 100.0, start = TOY_START)
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, price)]; initial, ramp_up = 100.0, ramp_down = down, availability = 45.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 80.0)]; initial = 20.0, ramp_up = 100.0),
        ],
        80.0; horizon = TOY_RESOLUTION, start,
        mutate! = function (sys, stamps)
            cheap = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
            PSY.set_active_power_limits!(cheap, (min = 0.0, max = rating))
            # The bid's MAXAVAIL (MW) is what the derivation turns into energy_availability.
            AustralianElectricityMarkets.replace_single_series!(
                sys, cheap,
                AustralianElectricityMarkets.single_series(
                    AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.GEN),
                    stamps[1], _toy_values(max_avail, 2), TOY_RESOLUTION,
                ),
            )
            set_registration!(cheap, _toy_registration(; schedule_type = isnothing(uigf) ? ScheduleType.SCHEDULED : ScheduleType.SEMI_SCHEDULED))
            if !isnothing(uigf)
                set_toy_unit_field!(sys, cheap, stamps, :uigf, _toy_values(uigf, 2))
            end
            if !isnothing(fixed_load)
                _toy_energy_bid!(
                    sys, cheap, AustralianElectricityMarkets.BidDirection.GEN, stamps,
                    fill(PSY.PiecewiseStepData([0.0, 100.0], [price]), 2), _toy_values(max_avail, 2);
                    fixed_load = _toy_values(fixed_load, 2),
                )
                # A fast-start profile (mode 1) leaves the loading uninvoked while the bid still carries it.
                if iszero(fixed_invoked)
                    set_toy_unit_field!(sys, cheap, stamps, :dispatch_mode, fill(1.0, 2))
                end
            end
            if !isnothing(target)
                add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, target; sense = ConstraintSense.EQ)
                only(PSY.get_components(GenericConstraint, sys)).constraint_weight = weight
            end
            return
        end,
    )
end

function energy_limit_solve(sys)
    model = PSI.DecisionModel(
        AEMS.NEMDispatchProblem, problem_template(sys), sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false), initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    results = PSI.OptimizationProblemResults(model)
    dispatch = PSI.read_variable(results, "ActivePowerVariable__ThermalStandard")
    return (; results, objective = PSI.JuMP.objective_value(PSI.get_jump_model(PSI.get_optimization_container(model))), power = only(r.value for r in eachrow(dispatch) if r.name == TOY_CHEAP), violations = read_constraint_violations(results, sys))
end

function energy_slack(out, meta)
    return only(r.value for r in eachrow(PSI.read_variable(out.results, "NEMUnitSlack__ThermalStandard__" * meta)) if r.name == TOY_CHEAP)
end

# `(case, system keywords, Alta's MW, MAXAVAIL slack, UIGF slack)`; a `nothing` slack is not checked.
const ENERGY_LIMIT_CASES = [
    ("a static rating does not defeat the separate energy limits", (; max_avail = 70.0, uigf = 65.0, rating = 30.0), 60.0, 0.0, 0.0),
    ("non-conformance can violate both distinct energy limits", (; max_avail = 40.0), 60.0, 20.0, 15.0),
    ("fixed loading beats MaxAvail but does not beat UIGF", (; max_avail = 40.0, target = nothing, fixed_load = 60.0), 45.0, 5.0, 0.0),
    ("an uninvoked fixed loading never binds", (; max_avail = 40.0, target = nothing, fixed_load = 60.0, fixed_invoked = 0.0), 40.0, 0.0, 0.0),
    ("ramping beats the combined availability and UIGF penalties", (; max_avail = 40.0, target = nothing, initial = 65.0, down = 1.0), 60.0, 20.0, 15.0),
    ("an ordinary forecast stays binding with negative bids", (; max_avail = 40.0, uigf = 30.0, target = nothing, price = -1000.0), 30.0, 0.0, 0.0),
    ("a zero forecast stays binding with negative bids", (; max_avail = 40.0, uigf = 0.0, target = nothing, price = -1000.0), 0.0, 0.0, 0.0),
    ("a scheduled unit is held at MAXAVAIL", (; max_avail = 40.0, uigf = nothing, target = nothing), 40.0, 0.0, nothing),
]

@testset "energy limits against conformance, fixed loading and ramping" begin
    outs = Dict{String, Any}()
    for (name, kwargs, power, max_avail_slack, uigf_slack) in ENERGY_LIMIT_CASES
        @testset "$name" begin
            out = outs[name] = energy_limit_solve(energy_limit_system(; kwargs...))
            @test out.power ≈ power atol = 1.0e-6
            # The violation reader reports exactly the solved energy-limit slacks, and no ramp or conformance row breaks first.
            for (meta, family, slack) in (("energy_limit|max_avail", "energy_max_avail", max_avail_slack), ("energy_limit|uigf", "energy_uigf", uigf_slack))
                isnothing(slack) && continue
                @test energy_slack(out, meta) ≈ slack atol = 1.0e-6
                @test sum(filter(:family => ==(family), out.violations).MW; init = 0.0) ≈ slack atol = 1.0e-6
            end
            @test !any(in(("generic_constraint", "unit_ramp")), out.violations.family)
        end
    end
    @test outs["non-conformance can violate both distinct energy limits"].objective ≈ 19213775.0 atol = 1.0e-4
    fixed = only(filter(:family => ==("fixed_load"), outs["fixed loading beats MaxAvail but does not beat UIGF"].violations))
    @test fixed.MW ≈ 15.0 atol = 1.0e-6
    @test fixed.direction == "down"
    @test !any(==("fixed_load"), outs["an uninvoked fixed loading never binds"].violations.family)
end


@testset "recurrent energy limits update step by step" begin
    sys = energy_limit_system(; max_avail = [100.0, 35.0], uigf = [45.0, 25.0], target = [60.0, 20.0])
    out = run_problem(sys, TOY_START:TOY_RESOLUTION:(TOY_START + TOY_RESOLUTION); optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false))
    dispatch = read_solved_interval(out.results, sys).dispatch
    sort!(dispatch, :SETTLEMENTDATE)
    power = filter(:DUID => ==(TOY_CHEAP), dispatch).TOTALCLEARED
    @test power ≈ [60.0, 20.0] atol = 1.0e-6
    violations = read_constraint_violations(out.results, sys)
    forecast = filter(:family => ==("energy_uigf"), violations)
    @test only(forecast.MW) ≈ 15.0 atol = 1.0e-6
    @test only(forecast.DateTime) == TOY_START
end

@testset "missing and non-finite forecasts are rejected before solving" begin
    sys = energy_limit_system()
    cheap = PSY.get_component(ThermalStandard, sys, TOY_CHEAP)
    clear_toy_uigf!(sys, cheap)
    @test_throws ArgumentError problem_template(sys)
    invalid = energy_limit_system(; uigf = [45.0, NaN])
    template = problem_template(invalid)
    @test_throws r"interval 2: invalid UIGF" check_dispatch_envelope(template, invalid)
end

@testset "a simulation across 1 July is refused, and each side of the boundary prices at its own Market Price Cap" begin
    start = DateTime(2025, 7, 1)
    steps = start:TOY_RESOLUTION:(start + TOY_RESOLUTION)
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
    sys = energy_limit_system(; max_avail = 40.0, start)
    # The financial-year rule is `nem_system`'s: a range whose dispatch intervals cross 1 July is refused.
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    crossing = (start - Minute(5)):TOY_RESOLUTION:(start + 3 * TOY_RESOLUTION)
    @test_throws r"more than one financial year" nem_system(db, NEMDEConfiguration(); date_range = crossing)
    # The max-availability slack of TOY_CHEAP: 370 CVP x Market Price Cap x 100 MW base x 5 minutes.
    for (t, expected) in ((steps[1], 370.0 * 17_500.0 * 100.0 / 12), (steps[2], 370.0 * 20_300.0 * 100.0 / 12))
        model = PSI.DecisionModel(AEMS.NEMDispatchProblem, problem_template(sys), sys; optimizer, initial_time = t)
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        container = PSI.get_optimization_container(model)
        objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
        slack = PSI.get_variable(container, AEMS.NEMUnitSlack(), ThermalStandard, "energy_limit|max_avail")
        @test PSI.JuMP.coefficient(objective, slack[TOY_CHEAP, 1]) ≈ expected
    end
end
