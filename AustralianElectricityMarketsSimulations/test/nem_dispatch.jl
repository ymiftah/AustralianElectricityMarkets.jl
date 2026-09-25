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

# The bid series is a `Deterministic` and the dispatch limits are `SingleTimeSeries`, so the
# transform must produce the one forecast window the bids already have.
function nem_dispatch_system(; mutate! = identity, data_span = NEM_DISPATCH_HORIZON)
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys = nem_system(db, RegionalNetworkConfiguration())
    date_range = NEM_DISPATCH_START:NEM_DISPATCH_RESOLUTION:(NEM_DISPATCH_START + data_span)
    set_demand!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_market_bids!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_nem_dispatch_limits!(sys, db, date_range)
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

# Overwrites one battery's per-direction energy-availability `Deterministic` series with a flat
# value, mirroring `flatten_series!` for the `SingleTimeSeries` ramp/initial series.
function flatten_storage_avail!(sys, duid, name, value)
    device = PSY.get_component(PSY.EnergyReservoirStorage, sys, duid)
    stamps = PSY.get_time_series_timestamps(PSY.Deterministic, device, name)
    PSY.remove_time_series!(sys, PSY.Deterministic, device, name)
    PSY.add_time_series!(
        sys, device,
        PSY.Deterministic(;
            name = name,
            data = Dict(first(stamps) => fill(value, length(stamps))),
            resolution = NEM_DISPATCH_RESOLUTION,
            interval = NEM_DISPATCH_RESOLUTION,
        ),
    )
    return sys
end

function solved_pu(model, sys, duid)
    results = PSI.OptimizationProblemResults(model)
    dispatch = read_variable(results, "ActivePowerVariable__ThermalStandard")
    stamps = sort(unique(dispatch.DateTime))
    values = [
        only(row.value for row in eachrow(dispatch) if row.name == duid && row.DateTime == t)
            for t in stamps
    ]
    return values ./ PSY.get_base_power(sys)
end

function nem_dispatch_model(sys; formulation = NEMReplayDispatch, horizon = NEM_DISPATCH_HORIZON)
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys; formulation = formulation)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    return DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = horizon,
        resolution = NEM_DISPATCH_RESOLUTION,
        interval = NEM_DISPATCH_RESOLUTION,
        initial_time = NEM_DISPATCH_START,
        name = "nem_dispatch_test",
        store_variable_names = true,
    )
end

entry_types(keys_) = Set(IS.Optimization.get_entry_type(k) for k in keys_)

# The variables a constraint's affine expression actually references.
constraint_vars(ref) = Set(keys(JuMP.constraint_object(ref).func.terms))

component_keys(container_keys, ::Type{T}) where {T} =
    [k for k in container_keys if IS.Optimization.get_component_type(k) === T]

@testset "formulation types" begin
    @test AbstractNEMDispatch <: PSI.AbstractDeviceFormulation
    @test NEMReplayDispatch <: AbstractNEMDispatch
    @test NEMLookaheadDispatch <: AbstractNEMDispatch

    @testset "both modes are concrete, so a DeviceModel is buildable from either" begin
        @test isconcretetype(NEMReplayDispatch) && isconcretetype(NEMLookaheadDispatch)
        @test isabstracttype(AbstractNEMDispatch)
        for F in (NEMReplayDispatch, NEMLookaheadDispatch)
            @test PSI.get_formulation(PSI.DeviceModel(PSY.ThermalStandard, F)) === F
        end
    end

    @testset "only the lookahead mode requires an initial-conditions sub-solve" begin
        @test PSI.requires_initialization(NEMReplayDispatch()) == false
        @test PSI.requires_initialization(NEMLookaheadDispatch()) == true
    end
end

@testset "the formulation is not gated on device type" begin
    # A type the current System does not contain must still resolve every hook.
    for T in (
            PSY.ThermalStandard, PSY.ThermalMultiStart, PSY.HydroDispatch,
            PSY.RenewableDispatch, PSY.EnergyReservoirStorage,
        )
        @test haskey(
            PSI.get_default_time_series_names(T, NEMReplayDispatch),
            RampUpRateTimeSeriesParameter,
        )
        @test PSI.get_default_attributes(T, NEMReplayDispatch) == Dict{String, Any}()
        @test PSI.get_variable_binary(PSI.ActivePowerVariable(), T, NEMReplayDispatch()) == false
    end

    @testset "the market-bid hooks resolve to our override, for a non-Generator injector too" begin
        # PSI defines no `Any` fallback, so a non-Generator participant would MethodError.
        for T in (
                PSY.ThermalStandard, PSY.ThermalMultiStart, PSY.HydroDispatch,
                PSY.RenewableDispatch, PSY.EnergyReservoirStorage,
            )
            for hook in (
                    PSI._include_min_gen_power_in_constraint,
                    PSI._include_constant_min_gen_power_in_constraint,
                )
                signature = (T, PSI.ActivePowerVariable, NEMReplayDispatch)
                @test hasmethod(hook, signature)
                @test which(hook, signature).sig.parameters[4] <: AbstractNEMDispatch
            end
        end
    end

    @testset "both modes register initial_mw, for the initial-conditions sub-model" begin
        # PSI copies the parent model's time_series_names onto the initial-conditions model,
        # which runs NEMReplayDispatch and reads "initial_mw" whatever the parent was.
        for F in (NEMReplayDispatch, NEMLookaheadDispatch)
            names = PSI.get_default_time_series_names(PSY.ThermalStandard, F)
            @test haskey(names, InitialPowerTimeSeriesParameter)
            @test names[InitialPowerTimeSeriesParameter] == "initial_mw"
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
        generator_participants = filter(!=(PSY.EnergyReservoirStorage), participants)
        variable_sets = [entry_types(component_keys(variable_keys, T)) for T in generator_participants]
        constraint_sets = [entry_types(component_keys(constraint_keys, T)) for T in generator_participants]
        @test allequal(variable_sets)
        @test allequal(constraint_sets)
        @test PSI.ActivePowerVariable in first(variable_sets)
        @test PSI.RampConstraint in first(constraint_sets)

        @testset "a battery gets the per-direction shape instead of a single ActivePowerVariable" begin
            battery_variables = entry_types(component_keys(variable_keys, PSY.EnergyReservoirStorage))
            battery_constraints = entry_types(component_keys(constraint_keys, PSY.EnergyReservoirStorage))
            @test PSI.ActivePowerOutVariable in battery_variables
            @test PSI.ActivePowerInVariable in battery_variables
            @test !(PSI.ActivePowerVariable in battery_variables)
            @test PSI.RampConstraint in battery_constraints
        end
    end

    @testset "the bid stack becomes per-band variables" begin
        @test PSI.PiecewiseLinearBlockIncrementalOffer in entry_types(variable_keys)
        @test PSI.PiecewiseLinearBlockIncrementalOfferConstraint in entry_types(constraint_keys)
    end

    @testset "the availability envelope bounds active power" begin
        @test PSI.ActivePowerVariableTimeSeriesLimitsConstraint in entry_types(constraint_keys)
    end

    @testset "the objective is non-trivial" begin
        @test JuMP.objective_function(jump_model) != JuMP.AffExpr(0.0)
    end

    @testset "it solves" begin
        @test solve!(model) == IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED
    end
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

    @testset "the rate varies per interval rather than being a scalar" begin
        # The bound moves with t.
        bounds = [initial_mw[t] + up_rate[t] * 5 for t in eachindex(solved)]
        @test length(unique(round.(bounds; digits = 9))) > 1
    end

    @testset "the ramp, not the availability envelope, is what binds in this fixture" begin
        # ER02's 5-minute ramp band (under 1.1 MW) is far tighter than its 75-80 MW ceiling.
        envelope = PSY.get_time_series_values(
            PSY.SingleTimeSeries, device, "max_active_power"; len = 12,
        ) .* PSY.get_max_active_power(device)
        ramp_bound = [initial_mw[t] + up_rate[t] * 5 for t in eachindex(solved)]
        @test all(ramp_bound .< envelope .- 1.0e-9)
        @test all(solved .<= ramp_bound .+ 1.0e-6)
    end

    @testset "both ramp directions are built for every participant and interval" begin
        model2 = nem_dispatch_model(sys)
        build!(model2; output_dir = mktempdir())
        container = PSI.get_optimization_container(model2)
        for T in nem_dispatch_participants(sys), meta in ("up", "down")
            constraint = PSI.get_constraint(container, PSI.RampConstraint(), T, meta)
            names, steps = axes(constraint)
            @test length(names) == length(collect(PSY.get_components(T, sys)))
            @test length(steps) == 12
        end
    end
end

@testset "a tightened ramp rate changes the answer" begin
    # Tighten one unit's rate until the ramp binds, then compare against the untightened solve.
    tight_rate = 0.001
    base_sys = nem_dispatch_system()
    tight_sys = nem_dispatch_system(;
        mutate! = sys -> flatten_series!(sys, "ER02", "ramp_up_rate", tight_rate),
    )

    base_model = nem_dispatch_model(base_sys)
    build!(base_model; output_dir = mktempdir())
    solve!(base_model)
    base_solved = solved_pu(base_model, base_sys, "ER02")

    tight_model = nem_dispatch_model(tight_sys)
    @test build!(tight_model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    solve!(tight_model)
    tight_solved = solved_pu(tight_model, tight_sys, "ER02")

    device = PSY.get_component(PSY.ThermalStandard, tight_sys, "ER02")
    initial_mw = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "initial_mw"; len = 12)
    envelope = PSY.get_time_series_values(
        PSY.SingleTimeSeries, device, "max_active_power"; len = 12,
    ) .* PSY.get_max_active_power(device)

    @testset "the unit is held at INITIALMW + rate * interval" begin
        for t in eachindex(tight_solved)
            @test tight_solved[t] ≈ initial_mw[t] + tight_rate * 5 atol = 1.0e-6
        end
    end

    @testset "that is strictly below both the envelope and the untightened answer" begin
        @test all(tight_solved .< envelope .- 1.0e-6)
        @test all(tight_solved .< base_solved .- 1.0e-6)
    end
end

@testset "an inconsistent envelope is reported at build, not left to the solver" begin
    # Zero availability with a positive INITIALMW and a tiny down rate: an unmeetable floor.
    sys = nem_dispatch_system(;
        mutate! = function (s)
            flatten_series!(s, "ER02", "ramp_down_rate", 0.0)
            flatten_series!(s, "ER02", "max_active_power", 0.0)
            return s
        end,
    )
    model = nem_dispatch_model(sys)
    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "the envelope check also names an inconsistent battery" begin
    # Zero generation availability with a positive net INITIALMW and a zero down rate: the
    # battery cannot ramp down to meet a ceiling of zero.
    sys = nem_dispatch_system(;
        mutate! = function (s)
            flatten_series!(s, PSY.EnergyReservoirStorage, "BW01", "ramp_down_rate", 0.0)
            flatten_storage_avail!(s, "BW01", "energy_max_avail", 0.0)
            return s
        end,
    )
    model = nem_dispatch_model(sys)
    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "skip_uncovered excludes a device with no rates instead of failing the build" begin
    # Strip through the fixture's hook: a series cannot be removed once the transform has
    # wrapped it in a DeterministicSingleTimeSeries.
    sys = nem_dispatch_system(;
        mutate! = function (s)
            device = PSY.get_component(PSY.ThermalStandard, s, "ER02")
            for name in ("ramp_up_rate", "ramp_down_rate", "initial_mw")
                PSY.remove_time_series!(s, PSY.SingleTimeSeries, device, name)
            end
            return s
        end,
    )
    stripped = PSY.get_component(PSY.ThermalStandard, sys, "ER02")

    @test !AEMS._has_nem_dispatch_limits(stripped, NEMReplayDispatch)
    # The type stays a participant: its other components are still covered.
    @test PSY.ThermalStandard in nem_dispatch_participants(sys)

    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    @test_logs (:warn, r"ER02") set_nem_dispatch_models!(template, sys; skip_uncovered = true)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)

    model = DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = NEM_DISPATCH_HORIZON,
        resolution = NEM_DISPATCH_RESOLUTION,
        interval = NEM_DISPATCH_RESOLUTION,
        initial_time = NEM_DISPATCH_START,
        name = "nem_dispatch_skip_uncovered",
        store_variable_names = true,
    )
    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    container = PSI.get_optimization_container(model)
    power = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    dispatched = first(axes(power))
    @test "ER02" ∉ dispatched
    @test !isempty(dispatched)
end

@testset "a missing ramp series is reported, naming the setter" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    sys = nem_system(db, RegionalNetworkConfiguration())
    date_range = NEM_DISPATCH_START:NEM_DISPATCH_RESOLUTION:(NEM_DISPATCH_START + NEM_DISPATCH_HORIZON)
    set_demand!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_market_bids!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_nem_dispatch_limits!(sys, db, date_range)

    # Strip one device's rates after the template is derived, so the type is still a
    # participant but that device has nothing to read.
    stripped = PSY.get_component(PSY.ThermalStandard, sys, "ER02")
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    for name in ("ramp_up_rate", "ramp_down_rate")
        PSY.remove_time_series!(sys, PSY.SingleTimeSeries, stripped, name)
    end
    PSY.transform_single_time_series!(sys, NEM_DISPATCH_HORIZON, NEM_DISPATCH_RESOLUTION)

    model = DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = NEM_DISPATCH_HORIZON,
        resolution = NEM_DISPATCH_RESOLUTION,
        interval = NEM_DISPATCH_RESOLUTION,
        initial_time = NEM_DISPATCH_START,
        name = "nem_dispatch_missing_rates",
    )
    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "NEMReplayDispatch solves a single dispatch interval" begin
    # PSY rejects a one-point time series, so the System spans two intervals and the model
    # horizon takes the first. That is the NEMDE case: one interval, decoupled from any other.
    sys = nem_dispatch_system(; data_span = Minute(10))
    model = nem_dispatch_model(sys; formulation = NEMReplayDispatch, horizon = Minute(5))

    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test length(PSI.get_time_steps(container)) == 1

    power = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    @test size(power, 2) == 1
    @test solve!(model) == IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED

    device = PSY.get_component(PSY.ThermalStandard, sys, "ER02")
    initial_mw = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "initial_mw"; len = 2)
    up_rate = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "ramp_up_rate"; len = 2)
    down_rate = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "ramp_down_rate"; len = 2)
    solved = only(solved_pu(model, sys, "ER02"))

    @testset "the single interval is held within its own rates of its own INITIALMW" begin
        @test solved <= initial_mw[1] + up_rate[1] * 5 + 1.0e-6
        @test solved >= initial_mw[1] - down_rate[1] * 5 - 1.0e-6
    end

    @testset "no interval is chained: the ramp references one variable only" begin
        for meta in ("up", "down")
            constraint = PSI.get_constraint(
                container, PSI.RampConstraint(), PSY.ThermalStandard, meta,
            )
            @test size(constraint, 2) == 1
            @test constraint_vars(constraint["ER02", 1]) == Set([power["ER02", 1]])
        end
    end
end

@testset "NEMLookaheadDispatch solves two chained dispatch intervals" begin
    sys = nem_dispatch_system(; data_span = Minute(10))
    model = nem_dispatch_model(sys; formulation = NEMLookaheadDispatch, horizon = Minute(10))

    @test build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test length(PSI.get_time_steps(container)) == 2

    power = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    @test size(power, 2) == 2
    @test solve!(model) == IS.Simulation.RunStatus.SUCCESSFULLY_FINALIZED

    @testset "the initialisation sub-solve populated a DevicePower condition per device" begin
        ics = PSI.get_initial_condition(container, PSI.DevicePower(), PSY.ThermalStandard)
        @test length(ics) == length(collect(PSY.get_components(PSY.ThermalStandard, sys)))
        @test all(isfinite(PSI.get_value(ic)) for ic in ics)
        @test "ER02" in [PSI.get_component_name(ic) for ic in ics]
    end

    @testset "interval 1 measures against the initial condition, interval 2 against interval 1" begin
        for meta in ("up", "down")
            constraint = PSI.get_constraint(
                container, PSI.RampConstraint(), PSY.ThermalStandard, meta,
            )
            @test size(constraint, 2) == 2
            # t = 1: the initial condition is a number, folded into the RHS.
            @test constraint_vars(constraint["ER02", 1]) == Set([power["ER02", 1]])
            # t = 2: the base is the previous interval's variable, so both appear.
            @test constraint_vars(constraint["ER02", 2]) ==
                Set([power["ER02", 1], power["ER02", 2]])
        end
    end

    @testset "the solved second interval is within its rates of the solved first" begin
        solved = solved_pu(model, sys, "ER02")
        @test length(solved) == 2
        device = PSY.get_component(PSY.ThermalStandard, sys, "ER02")
        up_rate = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "ramp_up_rate"; len = 2)
        down_rate = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "ramp_down_rate"; len = 2)
        @test solved[2] - solved[1] <= up_rate[2] * 5 + 1.0e-6
        @test solved[1] - solved[2] <= down_rate[2] * 5 + 1.0e-6
    end
end
