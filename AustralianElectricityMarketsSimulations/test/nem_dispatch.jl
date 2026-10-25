using HiGHS
using PowerSimulations
import PowerSimulations as PSI
import PowerSystems as PSY

const AEMS = AustralianElectricityMarketsSimulations
# Reached through PSI so the test environment needs no extra dependency.
const JuMP = PSI.JuMP
const MOI = PSI.MOI
const IS = AEMS.IS
const TimeSeries = PSY.TimeSeries

const NEM_DISPATCH_RESOLUTION = Minute(5)
const NEM_DISPATCH_START = DateTime(2025, 1, 1, 0, 0)
const NEM_DISPATCH_HORIZON = Hour(1)

# Bids and dispatch limits are all `SingleTimeSeries`; the transform below turns them into the
# forecast windows the model reads.
function nem_dispatch_system(; mutate! = identity, data_span = NEM_DISPATCH_HORIZON)
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys = nem_system(db, RegionalNetworkConfiguration())
    date_range = NEM_DISPATCH_START:NEM_DISPATCH_RESOLUTION:(NEM_DISPATCH_START + data_span)
    set_demand!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_market_bids!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_nem_dispatch_limits!(sys, db, date_range)
    set_nem_energy_limits!(sys, db, date_range)
    mutate!(sys)
    # One window spanning the whole span, matching the single window the bid forecast carries.
    PSY.transform_single_time_series!(sys, data_span, NEM_DISPATCH_RESOLUTION)
    return sys
end

# Overwrites one device's series with a flat value, to make a chosen limit the binding one.
function flatten_series!(sys, ::Type{T}, duid, name, value) where {T}
    device = PSY.get_component(T, sys, duid)
    stamps = PSY.get_time_series_timestamps(PSY.SingleTimeSeries, device, name)
    existing = PSY.get_time_series(PSY.SingleTimeSeries, device, name)
    multiplier = IS.get_scaling_factor_multiplier(existing)
    PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, name)
    PSY.add_time_series!(
        sys, device,
        PSY.SingleTimeSeries(;
            name = name,
            data = TimeSeries.TimeArray(stamps, fill(value, length(stamps))),
            scaling_factor_multiplier = multiplier,
        ),
    )
    return sys
end
flatten_series!(sys, duid, name, value) = flatten_series!(sys, PSY.ThermalStandard, duid, name, value)

function nem_dispatch_model(sys; horizon = NEM_DISPATCH_HORIZON, name = "nem_dispatch_test")
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    return DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = horizon,
        resolution = NEM_DISPATCH_RESOLUTION,
        interval = NEM_DISPATCH_RESOLUTION,
        initial_time = NEM_DISPATCH_START,
        name = name,
        store_variable_names = true,
    )
end

entry_types(keys_) = Set(IS.Optimization.get_entry_type(k) for k in keys_)

# The variables a constraint's affine expression actually references.
# Power variables of a ramp row, ignoring its elastic slack.
function constraint_vars(ref)
    return Set(v for v in keys(JuMP.constraint_object(ref).func.terms) if !startswith(JuMP.name(v), "UnitRamp"))
end

component_keys(container_keys, ::Type{T}) where {T} =
    [k for k in container_keys if IS.Optimization.get_component_type(k) === T]

@testset "the formulation is not gated on device type" begin
    @testset "the market-bid constraint hook resolves to our override, for a non-Generator injector too" begin
        for T in (PSY.ThermalMultiStart, PSY.InterruptiblePowerLoad)
            signature = (
                PSI.OptimizationContainer, T, PSI.ActivePowerVariable, NEMReplayDispatch, Vector{Float64}, Int,
                Type{PSI.PiecewiseLinearBlockIncrementalOffer}, Type{PSI.PiecewiseLinearBlockIncrementalOfferConstraint},
            )
            @test which(PSI._add_pwl_constraint!, signature).module === AustralianElectricityMarketsSimulations
        end
    end
end

@testset "participants are discovered from the data, not a fixed type list" begin
    sys = nem_dispatch_system()
    types = nem_dispatch_participants(sys)
    @test PSY.ThermalStandard in types
    @test PSY.HydroDispatch in types
    @test PSY.RenewableDispatch in types
    @test PSY.EnergyReservoirStorage in types
    # A load carries no ramp series, so it is not a participant.
    @test !(PSY.PowerLoad in types)

    @testset "set_nem_dispatch_models! sets one formulation for every participant" begin
        template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
        set_nem_dispatch_models!(template, sys)
        models = PSI.get_device_models(template)
        @test !isempty(models)
        for (_, model) in models
            @test PSI.get_formulation(model) === NEMReplayDispatch
        end
    end

    @testset "a System with no dispatch limits throws, naming the setter" begin
        db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
        bare = nem_system(db, RegionalNetworkConfiguration())
        template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
        err = try
            set_nem_dispatch_models!(template, bare)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("set_nem_dispatch_limits!", err.msg)
    end
end

@testset "build and solve" begin
    sys = nem_dispatch_system()
    model = nem_dispatch_model(sys)
    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(model)
    jump_model = PSI.get_jump_model(container)
    variable_keys = collect(keys(PSI.get_variables(container)))
    constraint_keys = collect(keys(PSI.get_constraints(container)))

    @testset "the model is a pure LP with no commitment" begin
        @test JuMP.num_constraints(jump_model, JuMP.VariableRef, MOI.ZeroOne) == 0
        @test JuMP.num_constraints(jump_model, JuMP.VariableRef, MOI.Integer) == 0
        @test !(PSI.OnVariable in entry_types(variable_keys))
    end

    @testset "every generator participant gets identical variable and constraint entry types" begin
        participants = nem_dispatch_participants(sys)
        @test length(participants) >= 3
        @test PSY.EnergyReservoirStorage in participants
        @test PSY.InterruptiblePowerLoad in participants
        generator_participants = filter(!in((PSY.EnergyReservoirStorage, PSY.InterruptiblePowerLoad)), participants)
        variable_sets = [setdiff(entry_types(component_keys(variable_keys, T)), [EnergyUIGFSlack]) for T in generator_participants]
        constraint_sets = [setdiff(entry_types(component_keys(constraint_keys, T)), [EnergyUIGFConstraint]) for T in generator_participants]
        @test allequal(variable_sets)
        @test allequal(constraint_sets)
        @test PSI.ActivePowerVariable in first(variable_sets)
        @test PSI.RampConstraint in first(constraint_sets)

        @testset "a scheduled load gets the single-variable shape priced on its decremental offer" begin
            load_variables = entry_types(component_keys(variable_keys, PSY.InterruptiblePowerLoad))
            load_constraints = entry_types(component_keys(constraint_keys, PSY.InterruptiblePowerLoad))
            @test PSI.ActivePowerVariable in load_variables
            @test PSI.PiecewiseLinearBlockDecrementalOffer in load_variables
            @test !(PSI.PiecewiseLinearBlockIncrementalOffer in load_variables)
            @test PSI.RampConstraint in load_constraints
            @test EnergyMaxAvailConstraint in load_constraints
        end

        @testset "a battery gets the per-direction shape instead of a single ActivePowerVariable" begin
            battery_variables = entry_types(component_keys(variable_keys, PSY.EnergyReservoirStorage))
            battery_constraints = entry_types(component_keys(constraint_keys, PSY.EnergyReservoirStorage))
            @test PSI.ActivePowerOutVariable in battery_variables
            @test PSI.ActivePowerInVariable in battery_variables
            @test !(PSI.ActivePowerVariable in battery_variables)
            @test PSI.RampConstraint in battery_constraints
        end
    end

    @test solve!(model) == IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED
end

@testset "the ramp constraint binds against the metered base" begin
    sys = nem_dispatch_system()
    model = nem_dispatch_model(sys)
    build!(model; output_dir = mktempdir())
    solve!(model)

    results = PSI.OptimizationProblemResults(model)
    dispatch = read_variable(results, "ActivePowerVariable__ThermalStandard")
    solved_mw = [
        only(row.value for row in eachrow(dispatch) if row.name == "ER02" && row.DateTime == t)
            for t in sort(unique(dispatch.DateTime))
    ]

    device = PSY.get_component(PSY.ThermalStandard, sys, "ER02")
    base_power = PSY.get_base_power(sys)
    initial_mw = PSY.get_time_series_values(
        PSY.SingleTimeSeries, device, "initial_mw"; len = 12,
    )
    up_rate = PSY.get_time_series_values(
        PSY.SingleTimeSeries, device, "ramp_up_rate"; len = 12,
    )
    down_rate = PSY.get_time_series_values(
        PSY.SingleTimeSeries, device, "ramp_down_rate"; len = 12,
    )

    solved = solved_mw ./ base_power
    @testset "each interval stays within its own rate of its own INITIALMW" begin
        for t in eachindex(solved)
            @test solved[t] <= initial_mw[t] + up_rate[t] * 5 + 1.0e-6
            @test solved[t] >= initial_mw[t] - down_rate[t] * 5 - 1.0e-6
        end
    end

    @testset "both ramp directions are built for every participant and interval" begin
        model2 = nem_dispatch_model(sys)
        build!(model2; output_dir = mktempdir())
        container = PSI.get_optimization_container(model2)
        for T in nem_dispatch_participants(sys), meta in ("up", "dn")
            constraint = PSI.get_constraint(container, PSI.RampConstraint(), T, meta)
            names, steps = axes(constraint)
            @test length(names) == length(collect(PSY.get_components(PSY.get_available, T, sys)))
            @test length(steps) == 12
        end
    end
end

@testset "energy-limit preflight validates raw inputs before a build" begin
    sys = nem_dispatch_system(; mutate! = s -> flatten_series!(s, "ER02", "energy_max_avail", -1.0))
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    @test_throws ArgumentError check_dispatch_envelope(sys, template, NEM_DISPATCH_START, 6)
end


@testset "a missing ramp series is reported, naming the setter" begin
    # Strip one device's rates before the System is transformed, so the type is still a
    # participant but that device has nothing to read.
    sys = nem_dispatch_system(;
        mutate! = function (s)
            device = PSY.get_component(PSY.ThermalStandard, s, "ER02")
            for name in ("ramp_up_rate", "ramp_down_rate")
                PSY.remove_time_series!(s, PSY.SingleTimeSeries, device, name)
            end
            return s
        end
    )
    model = nem_dispatch_model(sys; name = "nem_dispatch_missing_rates")
    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "a single dispatch interval chains no other interval into its ramp" begin
    # PSY rejects a one-point time series, so the System spans two intervals and the model
    # horizon takes the first.
    sys = nem_dispatch_system(; data_span = Minute(10))
    model = nem_dispatch_model(sys; horizon = Minute(5))

    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test length(PSI.get_time_steps(container)) == 1

    power = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    @test size(power, 2) == 1
    for meta in ("up", "dn")
        constraint = PSI.get_constraint(
            container, PSI.RampConstraint(), PSY.ThermalStandard, meta,
        )
        @test size(constraint, 2) == 1
        @test constraint_vars(constraint["ER02", 1]) == Set([power["ER02", 1]])
        slack_type = meta == "up" ? AEMS.UnitRampUpSlack : AEMS.UnitRampDownSlack
        other_type = meta == "up" ? AEMS.UnitRampDownSlack : AEMS.UnitRampUpSlack
        func = JuMP.constraint_object(constraint["ER02", 1]).func
        slack = PSI.get_variable(container, slack_type(), PSY.ThermalStandard)["ER02", 1]
        other = PSI.get_variable(container, other_type(), PSY.ThermalStandard)["ER02", 1]
        @test JuMP.coefficient(func, slack) == -1.0
        @test JuMP.coefficient(func, other) == 0.0
    end
end
