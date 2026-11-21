# The `template_nemde` presets on the toy fixtures: the models each one carries, and that a DecisionModel
# builds, solves and reads back under it. The sentinel system has an interchange with the loss curve of
# `stock_simulation.jl` (area 2 imports its 50 MW load); the FCAS system has FCAS requirements and an energy
# constraint, and no interchange.

using HiGHS
import PowerSimulations as PSI
import PowerSystems as PSY

# Area 1 has one cheap unit; area 2 has no generation and imports its load over `TOY_INTERCHANGE`.
function _tpl_sentinel_system()
    units = [TOY_CHEAP => toy_unit(300.0, [(300.0, 20.0)]; initial = 100.0, ramp_up = 200.0)]
    return nem_toy_system(
        units, 50.0; horizon = TOY_RESOLUTION,
        interchange = toy_interchange(;
            load_mw = [50.0, 100.0], demand_coefficient = 1.0e-3, share = 1.0,
            loss_constant = 1.05, loss_flow_coefficient = 1.0e-4,
        ),
    )
end

# `fcas_toy_system` with a non-binding energy constraint on Alta, which only the full and constraint presets model.
function _tpl_fcas_system()
    return fcas_toy_system(; extra! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, 90.0))
end

# The interchange formulations, and whether the FCAS, generic-constraint and tie-break service models are present.
function _tpl_models(template::PSI.ProblemTemplate)
    interchange = [
        PSI.get_formulation(m) for m in values(PSI.get_branch_models(template)) if PSI.get_component_type(m) <: PSY.AreaInterchange
    ]
    return (;
        interchange,
        fcas = AEMS._has_service_model(template, FCASService),
        constraints = AEMS._has_service_model(template, GenericConstraint),
        tie_break = AEMS._has_service_model(template, EnergyTieBreak),
    )
end

# The variable entry types of the results of a solve.
_tpl_entries(results) = Set(PSI.IS.Optimization.get_entry_type(k) for k in PSI.list_variable_keys(results))

# The names of the `NEMConstraintLimit` duals of the results of a solve.
function _tpl_constrained(results)
    keys = [k for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit]
    return Set(name for k in keys for name in PSI.read_dual(results, k).name)
end

# The names of the constraints of `sys` that carry FCAS requirements.
_tpl_fcas_names(sys) = Set(PSY.get_name(gc) for gc in PSY.get_components(GenericConstraint, sys) if !isempty(AustralianElectricityMarkets.get_fcas_requirements(gc)))

# Builds and solves one interval of `sys` under `template` with HiGHS, after the template's checks. Returns the results.
function _tpl_solve(sys, template::PSI.ProblemTemplate)
    problem_template(sys; template)
    model = PSI.DecisionModel(AEMS.NEMDispatchProblem, template, sys; optimizer = HiGHS.Optimizer, initial_time = TOY_START)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    return PSI.OptimizationProblemResults(model)
end

# The regional balance price (`ROP`) of `area` at the first interval.
_tpl_price(frame, area) = only(frame[(frame.REGIONID .== area) .& (frame.SETTLEMENTDATE .== TOY_START), :ROP])

@testset "presets carry the models they document" begin
    templates = [
        template_energy_only(), template_interconnected(), template_losses(), template_fcas(), template_constraints(), template_nemde(),
    ]
    @test [_tpl_models(t) for t in templates] == [
        (; interchange = [], fcas = false, constraints = false, tie_break = false),
        (; interchange = [AEMS.NEMInterconnectorLossless], fcas = false, constraints = false, tie_break = false),
        (; interchange = [AEMS.NEMInterconnectorLoss], fcas = false, constraints = false, tie_break = false),
        (; interchange = [AEMS.NEMInterconnectorLoss], fcas = true, constraints = true, tie_break = false),
        (; interchange = [AEMS.NEMInterconnectorLoss], fcas = false, constraints = true, tie_break = false),
        (; interchange = [AEMS.NEMInterconnectorLoss], fcas = true, constraints = true, tie_break = true),
    ]
    @test all(t -> count(m -> PSI.get_formulation(m) <: AEMS.AbstractNEMDispatch, values(PSI.get_device_models(t))) == length(NEM_DISPATCH_DEVICE_TYPES), templates)
end

@testset "the builder rejects inconsistent keywords" begin
    @test_throws ArgumentError template_nemde(; interconnectors = :bogus)
    @test_throws ArgumentError template_nemde(; constraints = :fcas_requirements, fcas = false)
    @test_throws ArgumentError template_nemde(; constraints = false, exclude_constraints = Dict("N_TOY_LIMIT" => :manual))
end

@testset "energy only: no interchange, FCAS or constraint model, and no FCAS prices or warning" begin
    sys = _tpl_sentinel_system()
    results = _tpl_solve(sys, template_energy_only())
    @test isdisjoint(
        _tpl_entries(results),
        [PSI.FlowActivePowerVariable, AEMS.InterconnectorLossVariable, AEMS.MNSPLinkFlowVariable, AEMS.FCASCapacityVariable, AEMS.TieBreakSlackUp],
    )
    @test isempty(_tpl_constrained(results))
    # Energy-only runs have no NEMConstraintLimit dual, so nothing is left out and nothing is warned about.
    fcas_prices = @test_logs read_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
    @test isempty(fcas_prices)
    prices = read_prices(results, sys)
    @test _tpl_price(prices, "1") ≈ 20.0 atol = TOY_TOLERANCE
    @test _tpl_price(prices, "2") > 20.0
end

@testset "fcas: the FCAS market clears against the FCAS requirements only" begin
    sys = _tpl_fcas_system()
    results = _tpl_solve(sys, template_fcas())
    @test AEMS.FCASCapacityVariable in _tpl_entries(results)
    @test isdisjoint(_tpl_entries(results), [AEMS.InterconnectorLossVariable, AEMS.TieBreakSlackUp])
    # The energy constraint is out of the requirement scope: it has no dual and is not reported as skipped.
    @test _tpl_constrained(results) == _tpl_fcas_names(sys)
    @test isempty(template_skipped_constraints(sys, template_fcas()))
    fcas_prices = @test_logs read_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
    @test any(>(0.0), fcas_prices.ROP)
end

@testset "constraints: every constraint is modeled, FCAS terms are skipped, and there is no FCAS market" begin
    sys = _tpl_fcas_system()
    template = template_constraints()
    results = _tpl_solve(sys, template)
    @test !(AEMS.FCASCapacityVariable in _tpl_entries(results))
    @test _tpl_constrained(results) == Set(["N_TOY_LIMIT"])
    skipped = template_skipped_constraints(sys, template)
    @test Set(skipped.constraint[skipped.reason .== :unmodeled_fcas_service]) == _tpl_fcas_names(sys)
    # The FCAS requirements are skipped, so their prices are left out with the warning that the constraint carries no dual.
    solved = @test_logs (:warn, r"have no NEMConstraintLimit dual") read_solved_interval(results, sys)
    @test isempty(solved.fcas_prices)
    excluded = template_skipped_constraints(sys, template_constraints(; exclude_constraints = Dict("N_TOY_LIMIT" => :manual)))
    @test "N_TOY_LIMIT" in excluded.constraint && :manual in excluded.reason
end

@testset "full: every model is present, and the full run solves with FCAS and constraints" begin
    sys = _tpl_fcas_system()
    results = _tpl_solve(sys, template_nemde())
    @test AEMS.FCASCapacityVariable in _tpl_entries(results)
    # Tie-break containers are added only for price-tied energy bands, and no band of this fixture is tied.
    @test !(AEMS.TieBreakSlackUp in _tpl_entries(results))
    @test _tpl_constrained(results) == union(_tpl_fcas_names(sys), Set(["N_TOY_LIMIT"]))
    solved = read_solved_interval(results, sys)
    @test any(>(0.0), solved.fcas_prices.ROP)
end
