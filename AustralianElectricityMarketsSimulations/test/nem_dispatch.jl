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
    sys = first(nem_network(db))
    date_range = NEM_DISPATCH_START:NEM_DISPATCH_RESOLUTION:(NEM_DISPATCH_START + data_span)
    attach_demand!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    set_market_bids!(sys, db, date_range; resolution = NEM_DISPATCH_RESOLUTION)
    attach_dispatch_limits!(sys, db, date_range)
    set_effective_offers!(sys)
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
flatten_series!(sys, duid, name, value) = flatten_series!(sys, ThermalStandard, duid, name, value)

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

# The metas of the NEMUnitConstraint rows of component type `T`.
constraint_metas(constraint_keys, ::Type{T}) where {T} =
    [k.meta for k in component_keys(constraint_keys, T) if IS.Optimization.get_entry_type(k) === NEMUnitConstraint]

@testset "participants are discovered from the data, not a fixed type list" begin
    sys = nem_dispatch_system()
    types = nem_dispatch_participants(sys)
    @test ThermalStandard in types
    @test HydroDispatch in types
    @test RenewableDispatch in types
    @test EnergyReservoirStorage in types
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
        bare = first(nem_network(db))
        template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
        err = try
            set_nem_dispatch_models!(template, bare)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("nem_system(db, NEMDEConfiguration()", err.msg)
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
        @test EnergyReservoirStorage in participants
        @test InterruptiblePowerLoad in participants
        generator_participants = filter(!in((EnergyReservoirStorage, InterruptiblePowerLoad)), participants)
        # The UIGF and fixed-loading rows are added per device that carries the input, so a participant
        # without one carries a narrower shape; the energy and ramp shape is the same for every participant.
        # The UIGF and fixed-loading slacks are NEMUnitSlack keys under their own metas, left out of the shape.
        optional_slack_metas = ["energy_limit|uigf", "fixed_load|surplus", "fixed_load|deficit"]
        variable_sets = [
            entry_types(
                [
                    k for k in component_keys(variable_keys, T)
                        if !(IS.Optimization.get_entry_type(k) === NEMUnitSlack && k.meta in optional_slack_metas)
                ]
            )
                for T in generator_participants
        ]
        # NEMUnitSlack is one entry type, so the slack shape is compared by its metas.
        slack_meta_sets = [
            Set(k.meta for k in component_keys(variable_keys, T) if IS.Optimization.get_entry_type(k) === NEMUnitSlack && !(k.meta in optional_slack_metas))
                for T in generator_participants
        ]
        @test allequal(slack_meta_sets)
        for meta in ("energy_limit|max_avail", "energy_offer|surplus", "energy_offer|deficit", "unit_ramp|up", "unit_ramp|down")
            @test meta in first(slack_meta_sets)
        end
        # NEMUnitConstraint is one entry type, so the unit row shape is compared by (entry type, meta) pairs.
        optional_constraint_metas = ["uigf", "fixed_load|upper", "fixed_load|lower"]
        constraint_sets = [
            Set(
                (IS.Optimization.get_entry_type(k), k.meta) for k in component_keys(constraint_keys, T)
                    if !(IS.Optimization.get_entry_type(k) === NEMUnitConstraint && k.meta in optional_constraint_metas)
            )
                for T in generator_participants
        ]
        @test allequal(variable_sets)
        @test allequal(constraint_sets)
        @test PSI.ActivePowerVariable in first(variable_sets)
        @test (PSI.RampConstraint, "up") in first(constraint_sets)
        # The mock hive bids a fixed loading for one generator, which registers the fixed-loading rows.
        @test any(
            all(m in constraint_metas(constraint_keys, T) for m in ("fixed_load|upper", "fixed_load|lower"))
                for T in generator_participants
        )

        @testset "a scheduled load gets the single-variable shape priced on its decremental offer" begin
            load_variables = entry_types(component_keys(variable_keys, InterruptiblePowerLoad))
            load_constraints = entry_types(component_keys(constraint_keys, InterruptiblePowerLoad))
            @test PSI.ActivePowerVariable in load_variables
            @test EnergyOfferBandVariable in load_variables
            band_metas = [k.meta for k in component_keys(variable_keys, InterruptiblePowerLoad) if IS.Optimization.get_entry_type(k) === EnergyOfferBandVariable]
            @test band_metas == ["load"]
            @test PSI.RampConstraint in load_constraints
            @test "max_avail" in constraint_metas(constraint_keys, InterruptiblePowerLoad)
        end

        @testset "a battery gets the per-direction shape instead of a single ActivePowerVariable" begin
            battery_variables = entry_types(component_keys(variable_keys, EnergyReservoirStorage))
            battery_constraints = entry_types(component_keys(constraint_keys, EnergyReservoirStorage))
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

    device = PSY.get_component(ThermalStandard, sys, "ER02")
    base_power = PSY.get_base_power(sys)
    initial_mw = PSY.get_time_series_values(
        PSY.SingleTimeSeries, device, AustralianElectricityMarkets.NEM_OBSERVED_SERIES.initial_mw; len = 12,
    ) ./ base_power
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
    sys = nem_dispatch_system(; mutate! = s -> flatten_series!(s, "ER02", AustralianElectricityMarkets.bid_series_name(BidType.ENERGY, :max_avail, AustralianElectricityMarkets.BidDirection.GEN), -1.0))
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    @test_throws ArgumentError check_dispatch_envelope(template, sys, NEM_DISPATCH_START, 6)
end


@testset "a missing ramp series is reported, naming the setter" begin
    # Strip one device's rates before the System is transformed, so the type is still a
    # participant but that device has nothing to read.
    sys = nem_dispatch_system(;
        mutate! = function (s)
            device = PSY.get_component(ThermalStandard, s, "ER02")
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

    power = PSI.get_variable(container, PSI.ActivePowerVariable(), ThermalStandard)
    @test size(power, 2) == 1
    for meta in ("up", "dn")
        constraint = PSI.get_constraint(
            container, PSI.RampConstraint(), ThermalStandard, meta,
        )
        @test size(constraint, 2) == 1
        @test constraint_vars(constraint["ER02", 1]) == Set([power["ER02", 1]])
        slack_meta = meta == "up" ? "unit_ramp|up" : "unit_ramp|down"
        other_meta = meta == "up" ? "unit_ramp|down" : "unit_ramp|up"
        func = JuMP.constraint_object(constraint["ER02", 1]).func
        slack = PSI.get_variable(container, AEMS.NEMUnitSlack(), ThermalStandard, slack_meta)["ER02", 1]
        other = PSI.get_variable(container, AEMS.NEMUnitSlack(), ThermalStandard, other_meta)["ER02", 1]
        @test JuMP.coefficient(func, slack) == -1.0
        @test JuMP.coefficient(func, other) == 0.0
    end
end

@testset "a unit carrying NEM unit data under a stock formulation is rejected" begin
    sys = nem_dispatch_system()
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    PSI.set_device_model!(template, ThermalStandard, PSI.ThermalBasicDispatch)
    err = try
        check_template_against_sys(template, sys)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("ThermalStandard", err.msg) && occursin("AbstractNEMDispatch", err.msg)
end

@testset "a stock unit without NEM unit data under a stock formulation is accepted" begin
    sys = PSY.System(100.0)
    bus = PSY.ACBus(;
        number = 1, name = "bus1", available = true, bustype = PSY.ACBusTypes.REF, angle = 0.0,
        magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
    )
    PSY.add_component!(sys, bus)
    PSY.add_component!(
        sys, ThermalStandard(;
            name = "stock", available = true, status = true, bus = bus, active_power = 0.0,
            reactive_power = 0.0, rating = 1.0, active_power_limits = (min = 0.0, max = 1.0),
            reactive_power_limits = nothing, ramp_limits = nothing,
            operation_cost = ThermalGenerationCost(nothing), base_power = 100.0, time_limits = nothing,
            must_run = false, prime_mover_type = PSY.PrimeMovers.ST, fuel = PSY.ThermalFuels.COAL,
        ),
    )
    template = ProblemTemplate(NetworkModel(AreaBalancePowerModel; use_slacks = true))
    PSI.set_device_model!(template, ThermalStandard, PSI.ThermalBasicDispatch)
    @test check_template_against_sys(template, sys) === nothing
end

@testset "the series the formulation reads is the energy bid's MAXAVAIL per unit" begin
    sys = nem_dispatch_system()
    checked = 0
    for device in PSY.get_components(PSY.StaticInjection, sys)
        cost = AustralianElectricityMarkets._nem_offer_cost(device)
        isnothing(cost) && continue
        for bid in AustralianElectricityMarkets.get_energy_bids(cost)
            side = AustralianElectricityMarkets._energy_offer_side(bid.direction)
            inputs = only(PSY.get_supplemental_attributes(NEMDispatchInputs, device))
            key = device isa PSY.Storage && side == OfferSide.LOAD ? inputs.energy_availability_decremental : inputs.energy_availability
            @test PSY.get_name(key) == bid.max_avail.name
            @test PSI.get_multiplier_value(
                device isa PSY.Storage ? (side == OfferSide.GEN ? PSI.ActivePowerOutTimeSeriesParameter() : PSI.ActivePowerInTimeSeriesParameter()) : EnergyLimitTimeSeriesParameter(),
                device, NEMReplayDispatch(),
            ) ≈ 1 / PSY.get_base_power(sys)
            checked += 1
        end
    end
    @test checked > 0
    @test any(d -> d isa InterruptiblePowerLoad && !isempty(AustralianElectricityMarkets.get_energy_bids(AustralianElectricityMarkets._nem_offer_cost(d))), PSY.get_components(PSY.StaticInjection, sys))
end
