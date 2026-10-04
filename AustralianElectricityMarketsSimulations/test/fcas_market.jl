using HiGHS
using PowerSimulations
import PowerSimulations as PSI
import PowerSystems as PSY

const FCAS_TOY_TOLERANCE = 1.0e-4

"""
    fcas_trapezium_tuple(sys, values_mw) -> NTuple{7,Float64}

Packs `values_mw` (`enablement_min, low_breakpoint, high_breakpoint, enablement_max, max_avail`,
in MW) into the per-unit-of-system-base wire tuple [`set_fcas_bids!`](@ref) stores.
"""
function fcas_trapezium_tuple(sys, values_mw::NTuple{5, Float64})
    base_power = PSY.get_base_power(sys)
    emin, lowbp, highbp, emax, maxavail = values_mw ./ base_power
    return Tuple(
        FCASTrapezium(;
            enablement_min = emin, low_breakpoint = lowbp, high_breakpoint = highbp,
            enablement_max = emax, max_avail = maxavail,
        ),
    )
end

"""
    add_toy_fcas!(sys, device, initial_timestamp, n, bid_type, trapezium_mw, bands_mw_price; decremental = false)

Attaches `"fcas_trapezium_<bid_type>[_decremental]"`/`"fcas_curve_<bid_type>[_decremental]"`
`Deterministic` series on `device`, one window of `n` steps at `initial_timestamp`, flat over
the horizon, mirroring [`set_fcas_bids!`](@ref)'s shape and per-unit convention.
"""
function add_toy_fcas!(
        sys, device, initial_timestamp, n::Integer, bid_type::BidType,
        trapezium_mw::NTuple{5, Float64}, bands_mw_price::Vector{Tuple{Float64, Float64}};
        decremental::Bool = false, resolution = TOY_RESOLUTION, interval = resolution,
    )
    base_power = PSY.get_base_power(sys)
    suffix = decremental ? "$(string(bid_type))_decremental" : string(bid_type)
    trap_tuple = fcas_trapezium_tuple(sys, trapezium_mw)
    curve = PSY.PiecewiseStepData(
        [0.0; cumsum(first.(bands_mw_price))] ./ base_power, last.(bands_mw_price),
    )
    PSY.add_time_series!(
        sys, device,
        PSY.Deterministic(;
            name = "fcas_trapezium_$suffix", data = Dict(initial_timestamp => fill(trap_tuple, n)),
            resolution = resolution, interval = interval,
        ),
    )
    PSY.add_time_series!(
        sys, device,
        PSY.Deterministic(;
            name = "fcas_curve_$suffix", data = Dict(initial_timestamp => fill(curve, n)),
            resolution = resolution, interval = interval,
        ),
    )
    return
end

"""
    add_toy_fcas_scaling!(sys, device, initial_timestamp, n, bid_type; agc_enablement_min = nothing,
        agc_enablement_max = nothing, agc_max_avail = nothing, uigf = nothing)

Attaches [`set_fcas_scaling_inputs!`](@ref)'s per-device `"fcas_agc_enablement_min_<bid_type>"`/
`"fcas_agc_enablement_max_<bid_type>"`/`"fcas_agc_ramp_rate_<bid_type>"`/`"fcas_uigf"`
`SingleTimeSeries`, one flat window of `n` steps at `initial_timestamp`, mirroring its
per-unit-of-system-base convention. `agc_max_avail` is the AGC ramping capability in MW over one
`resolution` interval, stored as the equivalent MW/h ramp rate. A `nothing` keyword leaves the
matching series unattached.
"""
function add_toy_fcas_scaling!(
        sys, device, initial_timestamp, n::Integer, bid_type::BidType;
        agc_enablement_min::Union{Nothing, Float64} = nothing,
        agc_enablement_max::Union{Nothing, Float64} = nothing,
        agc_max_avail::Union{Nothing, Float64} = nothing,
        uigf::Union{Nothing, Float64} = nothing,
        resolution = TOY_RESOLUTION,
    )
    base_power = PSY.get_base_power(sys)
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    bid_type_str = string(bid_type)
    for (value, name) in (
            (agc_enablement_min, "fcas_agc_enablement_min_$bid_type_str"),
            (agc_enablement_max, "fcas_agc_enablement_max_$bid_type_str"),
            (isnothing(agc_max_avail) ? nothing : agc_max_avail / (Dates.value(Minute(resolution)) / 60), "fcas_agc_ramp_rate_$bid_type_str"),
            (uigf, "fcas_uigf"),
        )
        isnothing(value) && continue
        PSY.add_time_series!(
            sys, device,
            PSY.SingleTimeSeries(;
                name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(value / base_power, n)),
            ),
        )
    end
    return
end

"""
    add_toy_fcas_agc_status!(sys, device, initial_timestamp, n, status)

Attaches [`set_fcas_scaling_inputs!`](@ref)'s per-device `"fcas_agc_status"` `SingleTimeSeries`
(not per-unitized), one flat window of `n` steps at `initial_timestamp`.
"""
function add_toy_fcas_agc_status!(sys, device, initial_timestamp, n::Integer, status::Int; resolution = TOY_RESOLUTION)
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    PSY.add_time_series!(
        sys, device,
        PSY.SingleTimeSeries(; name = "fcas_agc_status", data = PSY.TimeSeries.TimeArray(stamps, fill(Float64(status), n))),
    )
    return
end

"""
    add_toy_storage_initial_mw!(sys, device, initial_timestamp, n, initial_mw)

Attaches [`set_nem_dispatch_limits!`](@ref)'s per-device `"initial_mw"` `SingleTimeSeries` (net
MW, per-unit of the system base), one flat window of `n` steps at `initial_timestamp`.
"""
function add_toy_storage_initial_mw!(sys, device, initial_timestamp, n::Integer, initial_mw::Float64; resolution = TOY_RESOLUTION)
    base_power = PSY.get_base_power(sys)
    stamps = [initial_timestamp + (i - 1) * resolution for i in 1:n]
    PSY.add_time_series!(
        sys, device,
        PSY.SingleTimeSeries(; name = "initial_mw", data = PSY.TimeSeries.TimeArray(stamps, fill(initial_mw / base_power, n))),
    )
    return
end

"""
    _add_toy_battery_nem_dispatch_inputs!(sys, bat, stamps)

Attaches `bat`'s `NEMReplayDispatch` requirements over `stamps`: a cheap generation-side and
worthless load-side `MarketBidCost` (so charging is never attractive), generous ramp rates, and
a zero net `"initial_mw"` - none of these ever bind in these tests, which fix the energy
variables directly. Callers that need a specific `"initial_mw"` overwrite it afterwards, e.g.
via [`add_toy_storage_initial_mw!`](@ref).
"""
function _add_toy_battery_nem_dispatch_inputs!(sys, bat, stamps)
    rating = PSY.get_output_active_power_limits(bat).max
    PSY.set_operation_cost!(
        bat, PSY.MarketBidCost(; no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0),
    )
    PSY.set_incremental_variable_cost!(
        sys, bat, PSY.SingleTimeSeries(;
            name = "variable_cost",
            data = PSY.TimeSeries.TimeArray(stamps, fill(PSY.PiecewiseStepData([0.0, rating], [1.0]), length(stamps))),
        ), PSY.UnitSystem.NATURAL_UNITS,
    )
    PSY.set_incremental_initial_input!(
        sys, bat, PSY.SingleTimeSeries(; name = "incremental_initial_input", data = PSY.TimeSeries.TimeArray(stamps, fill(0.0, length(stamps)))),
    )
    PSY.set_decremental_variable_cost!(
        sys, bat, PSY.SingleTimeSeries(;
            name = "decremental_variable_cost",
            data = PSY.TimeSeries.TimeArray(stamps, fill(PSY.PiecewiseStepData([0.0, rating], [0.0]), length(stamps))),
        ), PSY.UnitSystem.NATURAL_UNITS,
    )
    PSY.set_decremental_initial_input!(
        sys, bat, PSY.SingleTimeSeries(; name = "decremental_initial_input", data = PSY.TimeSeries.TimeArray(stamps, fill(0.0, length(stamps)))),
    )
    base_power = PSY.get_base_power(sys)
    for name in ("ramp_up_rate", "ramp_down_rate")
        PSY.add_time_series!(
            sys, bat, PSY.SingleTimeSeries(; name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(1.0e4 / base_power, length(stamps)))),
        )
    end
    PSY.add_time_series!(
        sys, bat, PSY.SingleTimeSeries(; name = "initial_mw", data = PSY.TimeSeries.TimeArray(stamps, fill(0.0, length(stamps)))),
    )
    return
end

"""
    fcas_toy_template(sys, service_names)

`NEMReplayDispatch`/`StaticPowerLoad` for the toy's devices, plus [`FCASMarket`](@ref) for each
named [`FCASService`](@ref).
"""
function fcas_toy_template(sys, service_names; use_slacks = false)
    network = PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true)
    template = PSI.ProblemTemplate(network)
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    for name in service_names
        PSI.set_service_model!(
            template, name,
            PSI.ServiceModel(FCASService, FCASMarket, name; duals = [FCASJointCapacityConstraint], use_slacks),
        )
    end
    return template
end

"A single-unit toy `System` whose sole `ThermalStandard` can be fixed to `energy_mw`."
function fcas_energy_toy_system(energy_mw; mutate! = nothing)
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(
                100.0, [(100.0, 20.0)]; initial = energy_mw, ramp_up = 100.0, ramp_down = 100.0,
                availability = max(energy_mw, 1.0),
            ),
        ],
        energy_mw;
        mutate! = mutate!,
    )
end

"Builds a `steps`-interval `PSI.DecisionModel` for `sys`/`service_names` and returns its `PSI.OptimizationContainer`."
function build_fcas(sys, service_names; steps = 1, use_slacks = false)
    template = fcas_toy_template(sys, service_names; use_slacks)
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = steps * TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        initial_time = TOY_START, name = "fcas_toy", store_variable_names = true,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    return PSI.get_optimization_container(model)
end

"Fixes `duid`'s `ActivePowerVariable` at `energy_mw`, so FCAS reward can't shift energy off it."
function fix_energy!(container, duid, energy_mw)
    base_power = PSI.get_base_power(container)
    var = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)
    PSI.JuMP.fix(var[duid, 1], energy_mw / base_power; force = true)
    return
end

"Maximises `reward_fn(container)` (added to the objective with a large negative weight) and solves."
function maximize_and_solve!(reward_fn, container)
    jm = PSI.get_jump_model(container)
    PSI.JuMP.set_objective_function(jm, PSI.JuMP.objective_function(jm) - 1.0e6 * reward_fn(container))
    PSI.JuMP.optimize!(jm)
    @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
    return
end

fcas_capacity(container, service_name) =
    PSI.get_variable(container, FCASCapacityVariable(), FCASService, service_name)

fcas_mw(container, service_name, duid) =
    PSI.JuMP.value(fcas_capacity(container, service_name)[duid, 1]) * PSI.get_base_power(container)

fcas_side_capacity(container, service_name, side::Symbol) =
    PSI.get_variable(container, FCASSideCapacityVariable(), FCASService, "$(service_name)_$side")

fcas_side_mw(container, service_name, side::Symbol, duid) =
    PSI.JuMP.value(fcas_side_capacity(container, service_name, side)[duid, 1]) * PSI.get_base_power(container)

fcas_unit_target(container, service_name) =
    PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, service_name)

fcas_unit_mw(container, service_name, duid) =
    PSI.JuMP.value(fcas_unit_target(container, service_name)[duid, 1]) * PSI.get_base_power(container)

@testset "FCASMarket reproduces docs/literate/fcas.jl's published Tungatinah/TAS1 numbers" begin
    # BIDPEROFFER_D trapeziums for DUID TUNGATIN, 2025-01-13 16:30, one row per market.
    duid = TOY_CHEAP
    trapeziums_mw = Dict(
        BidType.LOWER6SEC => (1.0, 5.0, 26.0, 27.0, 4.0),
        BidType.RAISE6SEC => (1.0, 1.0, 11.0, 27.0, 9.0),
        BidType.RAISE60SEC => (1.0, 1.0, 6.0, 27.0, 21.0),
        BidType.RAISE5MIN => (1.0, 2.0, 2.0, 26.0, 26.0),
        BidType.RAISEREG => (1.0, 1.0, 1.0, 26.0, 25.0),
    )
    bid_types = Tuple(keys(trapeziums_mw))
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            n = length(stamps)
            for (bid_type, trap_mw) in trapeziums_mw
                add_toy_fcas!(sys, device, stamps[1], n, bid_type, trap_mw, [(trap_mw[5], 10.0)])
                name = "TAS1_$(string(bid_type))"
                PSY.add_service!(
                    sys, FCASService(; name = name, region = "TAS1", bid_type = bid_type), [device],
                )
            end
        end,
    )
    service_names = ["TAS1_$(string(bt))" for bt in bid_types]
    container = build_fcas(sys, service_names)
    base_power = PSY.get_base_power(sys)
    fix_energy!(container, duid, 2.0)

    # No AGC ramp rate series is attached here, so §6.1 builds a placeholder row for RAISEREG;
    # fix it directly to the published target instead.
    raisereg_var = fcas_capacity(container, "TAS1_RAISEREG")
    PSI.JuMP.fix(raisereg_var[duid, 1], 9.0 / base_power; force = true)

    # Reward capacity so the solve settles on the trapezium limit rather than zero.
    maximize_and_solve!(container) do container
        sum(fcas_capacity(container, name)[duid, 1] for name in service_names)
    end

    @test PSI.JuMP.value(PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)[duid, 1]) * base_power ≈
        2.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_LOWER6SEC", duid) ≈ 1.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_RAISE6SEC", duid) ≈ 9.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_RAISE60SEC", duid) ≈ 16.0 atol = FCAS_TOY_TOLERANCE
    @test fcas_mw(container, "TAS1_RAISE5MIN", duid) ≈ 16.25 atol = FCAS_TOY_TOLERANCE

    @testset "per-unit bounds correct under a non-1.0 base power" begin
        @test base_power != 1.0
        lower6sec_var = fcas_capacity(container, "TAS1_LOWER6SEC")
        @test PSI.JuMP.upper_bound(lower6sec_var[duid, 1]) ≈ 4.0 / base_power atol = 1.0e-9
        raise60sec_var = fcas_capacity(container, "TAS1_RAISE60SEC")
        @test PSI.JuMP.upper_bound(raise60sec_var[duid, 1]) ≈ 21.0 / base_power atol = 1.0e-9
    end
end

@testset "a scaled regulation trapezium changes the solved cap" begin
    duid = TOY_CHEAP
    service_name = "TAS1_RAISEREG_SCALED"
    # Fully flat trapezium (LowBreakpoint == EnablementMin, HighBreakpoint == EnablementMax):
    # only MaxAvail bounds the capacity variable at any energy level in [0, 100].
    trapezium_mw = (0.0, 0.0, 100.0, 100.0, 25.0)

    function raisereg_cap(; agc_max_avail::Union{Nothing, Float64})
        sys = fcas_energy_toy_system(
            2.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                n = length(stamps)
                add_toy_fcas!(sys, device, stamps[1], n, BidType.RAISEREG, trapezium_mw, [(25.0, 10.0)])
                isnothing(agc_max_avail) || add_toy_fcas_scaling!(
                    sys, device, stamps[1], n, BidType.RAISEREG; agc_max_avail = agc_max_avail,
                )
                PSY.add_service!(
                    sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISEREG),
                    [device],
                )
            end,
        )
        container = build_fcas(sys, [service_name])
        fix_energy!(container, duid, 2.0)
        maximize_and_solve!(container) do container
            fcas_capacity(container, service_name)[duid, 1]
        end
        return fcas_mw(container, service_name, duid)
    end

    # Unscaled: MaxAvail (25.0) is the bound.
    @test raisereg_cap(; agc_max_avail = nothing) ≈ 25.0 atol = FCAS_TOY_TOLERANCE
    # AGC ramping capability (15.0) is more restrictive than the bid MaxAvail: the effective
    # trapezium's MaxAvail - not the bid's - bounds the solved capacity.
    @test raisereg_cap(; agc_max_avail = 15.0) ≈ 15.0 atol = FCAS_TOY_TOLERANCE
    # AGC ramping capability (40.0) is less restrictive than the bid MaxAvail: no impact.
    @test raisereg_cap(; agc_max_avail = 40.0) ≈ 25.0 atol = FCAS_TOY_TOLERANCE

    @testset "the AGC ramping capability is taken over the model's resolution" begin
        sys = fcas_energy_toy_system(
            2.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                n = length(stamps)
                add_toy_fcas!(sys, device, stamps[1], n, BidType.RAISEREG, trapezium_mw, [(25.0, 10.0)])
                add_toy_fcas_scaling!(sys, device, stamps[1], n, BidType.RAISEREG; agc_max_avail = 10.0)
                PSY.add_service!(
                    sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISEREG), [device],
                )
            end,
        )
        container = build_fcas(sys, [service_name])
        device = PSY.get_component(PSY.ThermalStandard, sys, duid)
        replay = Dict{Symbol, PSI.DeviceModel}(:ThermalStandard => PSI.DeviceModel(PSY.ThermalStandard, NEMReplayDispatch))
        max_avail_mw() = get_max_avail(
            only(AustralianElectricityMarketsSimulations._fcas_series(container, replay, device, BidType.RAISEREG, false)[1]),
        ) * PSI.get_base_power(container)
        @test max_avail_mw() ≈ 10.0  # 120 MW/h over 5 minutes
        PSI.set_resolution!(container.settings, Minute(10))
        @test max_avail_mw() ≈ 20.0  # the same rate over 10 minutes
    end

    @testset "under NEMLookaheadDispatch, AGC scaling follows AEMO's pre-dispatch timing" begin
        # 24 MW/h AGC ramp rate (2 MW per 5 minutes) and a 50 MW AGC EnablementMax.
        sys = fcas_energy_toy_system(
            2.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                n = length(stamps)
                add_toy_fcas!(sys, device, stamps[1], n, BidType.RAISEREG, trapezium_mw, [(25.0, 10.0)])
                add_toy_fcas_scaling!(sys, device, stamps[1], n, BidType.RAISEREG; agc_max_avail = 2.0, agc_enablement_max = 50.0)
                PSY.add_service!(
                    sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISEREG), [device],
                )
            end,
        )
        container = build_fcas(sys, [service_name]; steps = 2)
        device = PSY.get_component(PSY.ThermalStandard, sys, duid)
        lookahead = Dict{Symbol, PSI.DeviceModel}(:ThermalStandard => PSI.DeviceModel(PSY.ThermalStandard, NEMLookaheadDispatch))
        replay = Dict{Symbol, PSI.DeviceModel}(:ThermalStandard => PSI.DeviceModel(PSY.ThermalStandard, NEMReplayDispatch))
        base_power = PSI.get_base_power(container)
        traps(template) = AustralianElectricityMarketsSimulations._fcas_series(container, template, device, BidType.RAISEREG, false)[1]

        # Dispatch (Table 1): AGC enablement and ramp scaling at every interval.
        @test get_max_avail.(traps(replay)) .* base_power ≈ [2.0, 2.0]
        @test get_enablement_max.(traps(replay)) .* base_power ≈ [50.0, 50.0]
        # 5-minute pre-dispatch: both, first interval only.
        @test get_max_avail.(traps(lookahead)) .* base_power ≈ [2.0, 25.0]
        @test get_enablement_max.(traps(lookahead)) .* base_power ≈ [50.0, 100.0]
        # 30-minute pre-dispatch: AGC enablement scaling first interval only, no ramp scaling.
        PSI.set_resolution!(container.settings, Minute(30))
        @test get_max_avail.(traps(lookahead)) .* base_power ≈ [25.0, 25.0]
        @test get_enablement_max.(traps(lookahead)) .* base_power ≈ [50.0, 100.0]
    end
end

@testset "AGC enablement scaling (§4.1) narrows the solved cap, and an empty window disables" begin
    duid = TOY_CHEAP
    service_name = "TAS1_RAISEREG_AGC_ENABLEMENT"
    # Upper slope coefficient (100 - 90) / 25 = 0.4; energy is fixed at 45 MW.
    trapezium_mw = (0.0, 0.0, 90.0, 100.0, 25.0)
    function agc_container(; agc_enablement_min = nothing, agc_enablement_max = nothing)
        sys = fcas_energy_toy_system(
            45.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                n = length(stamps)
                add_toy_fcas!(sys, device, stamps[1], n, BidType.RAISEREG, trapezium_mw, [(25.0, 10.0)])
                add_toy_fcas_scaling!(
                    sys, device, stamps[1], n, BidType.RAISEREG;
                    agc_enablement_min = agc_enablement_min, agc_enablement_max = agc_enablement_max,
                )
                PSY.add_service!(
                    sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISEREG), [device],
                )
            end,
        )
        return build_fcas(sys, [service_name])
    end
    function solved_cap(container)
        fix_energy!(container, duid, 45.0)
        maximize_and_solve!(container) do container
            fcas_capacity(container, service_name)[duid, 1]
        end
        return fcas_mw(container, service_name, duid)
    end

    @test solved_cap(agc_container()) ≈ 25.0 atol = FCAS_TOY_TOLERANCE
    # AGC EnablementMax 50: HighBreakpoint slides to 50 - 0.4 × 25 = 40, so at 45 MW the upper
    # slope allows (50 - 45) / 0.4 = 12.5 MW.
    @test solved_cap(agc_container(; agc_enablement_max = 50.0)) ≈ 12.5 atol = FCAS_TOY_TOLERANCE
    # An inverted AGC window leaves EnablementMax < EnablementMin: §5 disables the bid.
    empty_window = agc_container(; agc_enablement_min = 60.0, agc_enablement_max = 40.0)
    @test PSI.JuMP.upper_bound(fcas_capacity(empty_window, service_name)[duid, 1]) == 0.0
end

@testset "the LOWER6SEC trapezium genuinely binds as energy moves" begin
    function lower6sec_cap(energy_mw)
        duid = TOY_CHEAP
        sys = fcas_energy_toy_system(
            energy_mw;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                add_toy_fcas!(
                    sys, device, stamps[1], length(stamps), BidType.LOWER6SEC,
                    (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)],
                )
                PSY.add_service!(
                    sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC),
                    [device],
                )
            end,
        )
        container = build_fcas(sys, ["TAS1_LOWER6SEC"])
        fix_energy!(container, duid, energy_mw)
        maximize_and_solve!(container) do container
            fcas_capacity(container, "TAS1_LOWER6SEC")[duid, 1]
        end
        return fcas_mw(container, "TAS1_LOWER6SEC", duid)
    end

    # LOWER6SEC <= energy - EnablementMin, on the trapezium's rising edge (energy < LowBreakpoint).
    @test lower6sec_cap(2.0) ≈ 1.0 atol = FCAS_TOY_TOLERANCE
    @test lower6sec_cap(3.5) ≈ 2.5 atol = FCAS_TOY_TOLERANCE
    # Past LowBreakpoint (5.0), the trapezium's own MaxAvail (4.0) is the binding cap instead.
    @test lower6sec_cap(5.5) ≈ 4.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a regulation term enters a LOWER service's upper form" begin
    # RaiseReg enters a LOWER service's upper form; the lower form never binds here.
    duid = TOY_CHEAP

    function lower6sec_cap(; with_raisereg::Bool)
        sys = fcas_energy_toy_system(
            2.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                n = length(stamps)
                add_toy_fcas!(
                    sys, device, stamps[1], n, BidType.LOWER6SEC,
                    (-100.0, -90.0, 10.0, 20.0, 10.0), [(10.0, 10.0)],
                )
                PSY.add_service!(
                    sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC),
                    [device],
                )
                if with_raisereg
                    add_toy_fcas!(
                        sys, device, stamps[1], n, BidType.RAISEREG,
                        (0.0, 0.0, 100.0, 100.0, 9.0), [(9.0, 10.0)],
                    )
                    PSY.add_service!(
                        sys, FCASService(; name = "TAS1_RAISEREG", region = "TAS1", bid_type = BidType.RAISEREG),
                        [device],
                    )
                end
            end,
        )
        service_names = with_raisereg ? ["TAS1_LOWER6SEC", "TAS1_RAISEREG"] : ["TAS1_LOWER6SEC"]
        container = build_fcas(sys, service_names)
        fix_energy!(container, duid, 2.0)
        base_power = PSY.get_base_power(sys)
        with_raisereg && PSI.JuMP.fix(
            fcas_capacity(container, "TAS1_RAISEREG")[duid, 1], 9.0 / base_power; force = true,
        )
        maximize_and_solve!(container) do container
            fcas_capacity(container, "TAS1_LOWER6SEC")[duid, 1]
        end
        return fcas_mw(container, "TAS1_LOWER6SEC", duid)
    end

    # Without RaiseReg: 2 + 1.0×L <= 20 gives L <= 18, clipped to MaxAvail = 10.
    @test lower6sec_cap(; with_raisereg = false) ≈ 10.0 atol = FCAS_TOY_TOLERANCE
    # With a fixed RaiseReg = 9.0 MW added to the same upper form: 2 + 1.0×L + 9 <= 20 gives L <= 9.
    @test lower6sec_cap(; with_raisereg = true) ≈ 9.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a malformed offered trapezium is rejected before the build" begin
    duid = TOY_CHEAP
    service_name = "TAS1_RAISE6SEC"
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            # HighBreakpoint (110) above EnablementMax (100).
            add_toy_fcas!(
                sys, device, stamps[1], length(stamps), BidType.RAISE6SEC,
                (0.0, 0.0, 110.0, 100.0, 10.0), [(10.0, 10.0)],
            )
            PSY.add_service!(
                sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC),
                [device],
            )
        end,
    )
    device = PSY.get_component(PSY.ThermalStandard, sys, duid)
    err = try
        get_fcas_trapezium(device, BidType.RAISE6SEC, TOY_START, 1)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("Malformed FCAS trapezium", err.msg)
    @test occursin(duid, err.msg)
end

@testset "offer cost equals the hand-worked band cost" begin
    duid = TOY_CHEAP
    service_name = "TAS1_RAISE6SEC"
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            # HighBreakpoint == EnablementMax: the upper form never binds, so only the
            # band-sum cost and the 10 MW MaxAvail bound are in play.
            add_toy_fcas!(
                sys, device, stamps[1], length(stamps), BidType.RAISE6SEC,
                (0.0, 0.0, 100.0, 100.0, 10.0), [(2.0, 10.0), (2.0, 30.0)],
            )
            PSY.add_service!(
                sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC),
                [device],
            )
        end,
    )
    base_power = PSY.get_base_power(sys)
    @test base_power != 1.0

    function objective_at(capacity_mw)
        container = build_fcas(sys, [service_name])
        fix_energy!(container, duid, 2.0)
        var = fcas_capacity(container, service_name)[duid, 1]
        PSI.JuMP.fix(var, capacity_mw / base_power; force = true)
        jm = PSI.get_jump_model(container)
        PSI.JuMP.optimize!(jm)
        @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
        return PSI.JuMP.objective_value(jm)
    end

    o0 = objective_at(0.0)
    o2 = objective_at(2.0)  # fills the $10/MW band exactly
    o3 = objective_at(3.0)  # 2 MW @ $10/MW + 1 MW @ $30/MW

    @test (o2 - o0) ≈ interval_cost_coefficient(10.0) * 2.0 atol = FCAS_TOY_TOLERANCE
    @test (o3 - o2) ≈ interval_cost_coefficient(30.0) * 1.0 atol = FCAS_TOY_TOLERANCE

    # The band cost follows the container's resolution, not a fixed 5 minutes.
    container = build_fcas(sys, [service_name])
    PSI.set_resolution!(container.settings, Minute(30))
    jm = PSI.get_jump_model(container)
    capacity = PSI.JuMP.@variable(jm)
    curve = PSY.PiecewiseStepData([0.0, 2.0 / base_power], [10.0])
    AustralianElectricityMarketsSimulations._add_fcas_offer_cost!(container, service_name, duid, 1, capacity, curve)
    band_var = last(PSI.JuMP.all_variables(jm))
    invariant = PSI.get_invariant_terms(PSI.get_objective_expression(container))
    @test PSI.JuMP.coefficient(invariant, band_var) ≈ base_power * 10.0 * 0.5
end

"""
    storage_fcas_toy_model(service_name, bid_type, trapezium_mw; decremental = false, energy_max_avail_mw = nothing, initial_mw = 0.0, scaling = nothing)

Builds the toy PSCB `DecisionModel` with BAT1, under `NEMReplayDispatch`, as the only
contributor to one [`FCASService`](@ref) bidding `trapezium_mw`. `energy_max_avail_mw = (gen,
load)` attaches BAT1's energy `MAXAVAIL` series in MW, as [`set_market_bids!`](@ref) does;
`initial_mw` is BAT1's net `INITIALMW` in MW. `scaling`, a `NamedTuple`, is passed to
[`add_toy_fcas_scaling!`](@ref) as keywords.

# Returns
`(model, sys)`, with `model` built.
"""
function storage_fcas_toy_model(
        service_name, bid_type, trapezium_mw; decremental = false, energy_max_avail_mw = nothing, initial_mw = 0.0,
        scaling = nothing,
    )
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    bat = get_component(EnergyReservoirStorage, sys, "BAT1")

    # Every forecast in a System shares one window count and horizon, so rebuild them to match the FCAS window.
    PSY.clear_time_series!(sys)
    stamps = [TOY_START, TOY_START + TOY_RESOLUTION]
    for load in get_components(PowerLoad, sys)
        PSY.add_time_series!(
            sys, load,
            PSY.SingleTimeSeries(;
                name = "max_active_power", data = PSY.TimeSeries.TimeArray(stamps, fill(1.0, length(stamps))),
                scaling_factor_multiplier = PSY.get_max_active_power,
            ),
        )
    end
    for gen in get_components(RenewableDispatch, sys)
        PSY.add_time_series!(
            sys, gen,
            PSY.SingleTimeSeries(;
                name = "max_active_power", data = PSY.TimeSeries.TimeArray(stamps, fill(1.0, length(stamps))),
                scaling_factor_multiplier = PSY.get_max_active_power,
            ),
        )
    end
    # NEMReplayDispatch's own requirements: an energy MarketBidCost (cheap generation, worthless
    # decremental so charging isn't attractive) and generous ramp rates from a zero net initial_mw
    # - fixed thermal floor and generous ratings mean neither ever binds in these tests.
    rating = get_output_active_power_limits(bat).max
    set_operation_cost!(
        bat, MarketBidCost(; no_load_cost = 0.0, start_up = (hot = 0.0, warm = 0.0, cold = 0.0), shut_down = 0.0),
    )
    set_incremental_variable_cost!(
        sys, bat, PSY.SingleTimeSeries(;
            name = "variable_cost",
            data = PSY.TimeSeries.TimeArray(stamps, fill(PiecewiseStepData([0.0, rating], [1.0]), length(stamps))),
        ), UnitSystem.NATURAL_UNITS,
    )
    set_incremental_initial_input!(
        sys, bat, PSY.SingleTimeSeries(; name = "incremental_initial_input", data = PSY.TimeSeries.TimeArray(stamps, fill(0.0, length(stamps)))),
    )
    set_decremental_variable_cost!(
        sys, bat, PSY.SingleTimeSeries(;
            name = "decremental_variable_cost",
            data = PSY.TimeSeries.TimeArray(stamps, fill(PiecewiseStepData([0.0, rating], [0.0]), length(stamps))),
        ), UnitSystem.NATURAL_UNITS,
    )
    set_decremental_initial_input!(
        sys, bat, PSY.SingleTimeSeries(; name = "decremental_initial_input", data = PSY.TimeSeries.TimeArray(stamps, fill(0.0, length(stamps)))),
    )
    base_power_bat = get_base_power(sys)
    for name in ("ramp_up_rate", "ramp_down_rate")
        PSY.add_time_series!(
            sys, bat, PSY.SingleTimeSeries(; name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(1.0e4 / base_power_bat, length(stamps)))),
        )
    end
    PSY.add_time_series!(
        sys, bat, PSY.SingleTimeSeries(;
            name = "initial_mw", data = PSY.TimeSeries.TimeArray(stamps, fill(initial_mw / base_power_bat, length(stamps))),
        ),
    )

    add_toy_fcas!(sys, bat, stamps[1], length(stamps), bid_type, trapezium_mw, [(10.0, 50.0)]; decremental = decremental)
    isnothing(scaling) || add_toy_fcas_scaling!(sys, bat, stamps[1], length(stamps), bid_type; scaling...)
    if !isnothing(energy_max_avail_mw)
        for (name, mw) in zip(("energy_max_avail", "energy_max_avail_decremental"), energy_max_avail_mw)
            PSY.add_time_series!(
                sys, bat,
                PSY.Deterministic(;
                    name = name, data = Dict(stamps[1] => fill(mw / get_base_power(sys), length(stamps))),
                    resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
                ),
            )
        end
    end
    add_service!(sys, FCASService(; name = service_name, region = "TAS1", bid_type = bid_type), [bat])
    PSY.transform_single_time_series!(sys, 2 * TOY_RESOLUTION, TOY_RESOLUTION)

    template = _area_balance_template()
    PSI.set_device_model!(template, EnergyReservoirStorage, NEMReplayDispatch)
    PSI.set_service_model!(
        template, service_name,
        PSI.ServiceModel(FCASService, FCASMarket, service_name; duals = [FCASJointCapacityConstraint]),
    )

    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    return model, sys
end

@testset "a Storage device's FCAS constraint reads its net (out - in) energy" begin
    # Battery contingency is bid BIDIRECTIONAL (the incremental series) on the net-MW axis, so
    # EnablementMin is negative.
    service_name = "TAS1_LOWER6SEC_STOR"
    model, sys = storage_fcas_toy_model(service_name, BidType.LOWER6SEC, (-8.0, 2.0, 5.0, 20.0, 10.0))
    base_power = get_base_power(sys)

    container = PSI.get_optimization_container(model)
    out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)
    in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)
    PSI.JuMP.fix(out_var["BAT1", 1], 0.0; force = true)
    PSI.JuMP.fix(in_var["BAT1", 1], 6.0 / base_power; force = true)  # net = -6 MW (charging)

    maximize_and_solve!(container) do container
        fcas_capacity(container, service_name)["BAT1", 1]
    end

    # LowerSlopeCoeff = (2 - (-8)) / 10 = 1.0; LOWER6SEC <= (net - EnablementMin) / 1.0
    #                 = (-6 - (-8)) / 1.0 = 2.0 MW, strictly below the 10 MW MaxAvail.
    @test fcas_mw(container, service_name, "BAT1") ≈ 2.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a Storage device's one-sided regulation reads that side's energy only" begin
    # GEN-side RAISEREG on [0, 20]: while charging, the generation side's energy is 0, so the
    # lower form 0 - 1.0×R >= 0 holds with R = 0 instead of forbidding the charge.
    service_name = "TAS1_RAISEREG_STOR"
    model, sys = storage_fcas_toy_model(service_name, BidType.RAISEREG, (0.0, 10.0, 15.0, 20.0, 10.0))
    base_power = get_base_power(sys)
    container = PSI.get_optimization_container(model)
    out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)
    in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)
    for side in ("upper", "lower")
        row = PSI.JuMP.constraint_object(
            PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, "$(service_name)_$side")["BAT1", 1],
        )
        @test haskey(row.func.terms, out_var["BAT1", 1])
        @test !haskey(row.func.terms, in_var["BAT1", 1])
    end
    PSI.JuMP.fix(out_var["BAT1", 1], 0.0; force = true)
    PSI.JuMP.fix(in_var["BAT1", 1], 6.0 / base_power; force = true)  # charging at 6 MW
    maximize_and_solve!(container) do container
        fcas_capacity(container, service_name)["BAT1", 1]
    end
    @test fcas_mw(container, service_name, "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a Storage device's energy bid availability gates FCAS per side" begin
    AEMS = AustralianElectricityMarketsSimulations
    bat = get_component(EnergyReservoirStorage, augmented_pscb_system(), "BAT1")
    trap(emin, emax) = FCASTrapezium(;
        enablement_min = emin, low_breakpoint = emin + 1.0, high_breakpoint = emax - 1.0,
        enablement_max = emax, max_avail = 1.0,
    )
    ok(is_regulation, decremental, t, avail) = AEMS._fcas_energy_max_avail_ok(bat, is_regulation, decremental, t, avail)

    # Generation side: Energy Max Availability_GEN >= EnablementMin.
    @test !ok(true, false, trap(2.0, 10.0), (gen = 1.0, load = 50.0))
    @test ok(true, false, trap(2.0, 10.0), (gen = 5.0, load = 50.0))
    # Load side: -Energy Max Availability_LOAD <= EnablementMax.
    @test !ok(true, true, trap(-10.0, -2.0), (gen = 0.0, load = 1.0))
    @test ok(true, true, trap(-10.0, -2.0), (gen = 0.0, load = 5.0))
    # Each regulation side checks only its own direction; contingency checks both.
    @test ok(true, false, trap(-5.0, -1.0), (gen = 0.0, load = 0.0))
    @test !ok(false, false, trap(-5.0, -1.0), (gen = 0.0, load = 0.0))
    @test !ok(false, false, trap(2.0, 10.0), (gen = 1.0, load = 50.0))
    @test ok(false, false, trap(2.0, 10.0), (gen = 5.0, load = 50.0))
    # Without the energy bid series, the static ratings stand in.
    rating = PSY.get_output_active_power_limits(bat).max
    @test ok(false, false, trap(rating - 1.0, rating + 10.0), nothing)
    @test !ok(false, false, trap(rating + 1.0, rating + 10.0), nothing)
end

@testset "FCASMarket disables a Storage FCAS bid its energy bid availability can't reach" begin
    service_name = "TAS1_RAISE6SEC_STOR"
    capacity_bound(gen_mw) = begin
        model, _ = storage_fcas_toy_model(
            service_name, BidType.RAISE6SEC, (2.0, 4.0, 15.0, 20.0, 10.0); energy_max_avail_mw = (gen_mw, 50.0),
            initial_mw = 3.0,
        )
        container = PSI.get_optimization_container(model)
        PSI.JuMP.upper_bound(fcas_capacity(container, service_name)["BAT1", 1])
    end
    # EnablementMin = 2 MW: a 1 MW energy bid can't reach the trapezium, a 5 MW one can.
    @test capacity_bound(1.0) == 0.0
    @test capacity_bound(5.0) > 0.0
end

"""
    _build_bdu_regulation(service_name, out_mw, in_mw; kwargs...) -> PSI.OptimizationContainer

Builds and solves BAT1 (`augmented_pscb_system()`) bidding RAISEREG on both sides - the
generation-side trapezium (`EnablementMin=0, LowBreakpoint=5, HighBreakpoint=20,
EnablementMax=25, MaxAvail=10`, on the net-MW axis) and the load-side trapezium
(`EnablementMin=-25, LowBreakpoint=-20, HighBreakpoint=-5, EnablementMax=0, MaxAvail=10`) -
with `ActivePowerOutVariable`/`ActivePowerInVariable` fixed at `out_mw`/`in_mw`, maximising the
unit's total RAISEREG target. With `solve = false`, returns the built, unsolved
`PSI.DecisionModel` instead.
"""
function _build_bdu_regulation(
        service_name, out_mw, in_mw;
        agc_status::Union{Nothing, Int} = nothing,
        agc_max_avail::Union{Nothing, Float64} = nothing,
        storage_initial_mw::Union{Nothing, Float64} = nothing,
        agc_enablement_min::Union{Nothing, Float64} = nothing,
        agc_enablement_max::Union{Nothing, Float64} = nothing,
        load_max_avail::Float64 = 10.0,
        solve::Bool = true,
        use_slacks::Bool = false,
    )
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    bat = get_component(EnergyReservoirStorage, sys, "BAT1")

    PSY.clear_time_series!(sys)
    stamps = [TOY_START, TOY_START + TOY_RESOLUTION]
    for load in get_components(PowerLoad, sys)
        PSY.add_time_series!(
            sys, load,
            PSY.SingleTimeSeries(;
                name = "max_active_power", data = PSY.TimeSeries.TimeArray(stamps, fill(1.0, length(stamps))),
                scaling_factor_multiplier = PSY.get_max_active_power,
            ),
        )
    end
    for gen in get_components(RenewableDispatch, sys)
        PSY.add_time_series!(
            sys, gen,
            PSY.SingleTimeSeries(;
                name = "max_active_power", data = PSY.TimeSeries.TimeArray(stamps, fill(1.0, length(stamps))),
                scaling_factor_multiplier = PSY.get_max_active_power,
            ),
        )
    end
    add_toy_fcas!(
        sys, bat, stamps[1], length(stamps), BidType.RAISEREG,
        (0.0, 5.0, 20.0, 25.0, 10.0), [(10.0, 15.0)],
    )
    add_toy_fcas!(
        sys, bat, stamps[1], length(stamps), BidType.RAISEREG,
        (-25.0, -20.0, -5.0, 0.0, load_max_avail), [(10.0, 12.0)]; decremental = true,
    )
    if !isnothing(agc_status)
        add_toy_fcas_agc_status!(sys, bat, stamps[1], length(stamps), agc_status)
    end
    _add_toy_battery_nem_dispatch_inputs!(sys, bat, stamps)
    if !isnothing(storage_initial_mw)
        PSY.remove_time_series!(sys, PSY.SingleTimeSeries, bat, "initial_mw")
        add_toy_storage_initial_mw!(sys, bat, stamps[1], length(stamps), storage_initial_mw)
    end
    if !isnothing(agc_max_avail) || !isnothing(agc_enablement_min) || !isnothing(agc_enablement_max)
        add_toy_fcas_scaling!(
            sys, bat, stamps[1], length(stamps), BidType.RAISEREG;
            agc_max_avail = agc_max_avail, agc_enablement_min = agc_enablement_min,
            agc_enablement_max = agc_enablement_max,
        )
    end
    add_service!(sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISEREG), [bat])
    PSY.transform_single_time_series!(sys, 2 * TOY_RESOLUTION, TOY_RESOLUTION)

    template = _area_balance_template()
    PSI.set_device_model!(template, EnergyReservoirStorage, NEMReplayDispatch)
    PSI.set_service_model!(
        template, service_name,
        PSI.ServiceModel(FCASService, FCASMarket, service_name; duals = [FCASJointCapacityConstraint], use_slacks),
    )

    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        initial_time = TOY_START,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    solve || return model

    container = PSI.get_optimization_container(model)
    base_power = PSY.get_base_power(sys)
    out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)
    in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)
    PSI.JuMP.fix(out_var["BAT1", 1], out_mw / base_power; force = true)
    PSI.JuMP.fix(in_var["BAT1", 1], in_mw / base_power; force = true)

    maximize_and_solve!(container) do container
        fcas_unit_target(container, service_name)["BAT1", 1]
    end
    return container
end

@testset "a Storage device's per-side regulation FCAS (§6.2/§6.3/§6.4/§5)" begin
    @testset "discharging: the generation side binds, the load side is zero" begin
        # Discharging near EnablementMax(Gen): the upper form binds on the generation-side's own
        # UpperSlopeCoeff = (25-20)/10 = 0.5: 22 + 0.5*Reg <= 25 gives Reg <= 6. The load side's
        # own energy term (-In) is 0, pinning its lower form's Reg to 0.
        container = _build_bdu_regulation("TAS1_RAISEREG_BDU_GEN", 22.0, 0.0)
        @test fcas_side_mw(container, "TAS1_RAISEREG_BDU_GEN", :gen, "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
        @test fcas_side_mw(container, "TAS1_RAISEREG_BDU_GEN", :load, "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_GEN", "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "charging: the load side binds, the generation side is zero" begin
        # Charging near EnablementMin(Load): the lower form binds on the load-side's own
        # LowerSlopeCoeff = (-20 - (-25))/10 = 0.5: -22 - 0.5*Reg >= -25 gives Reg <= 6. The
        # generation side's own energy term (Out) is 0, pinning its lower form's Reg to 0.
        container = _build_bdu_regulation("TAS1_RAISEREG_BDU_LOAD", 0.0, 22.0)
        @test fcas_side_mw(container, "TAS1_RAISEREG_BDU_LOAD", :load, "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
        @test fcas_side_mw(container, "TAS1_RAISEREG_BDU_LOAD", :gen, "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_LOAD", "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "§6.4: the BDU SCADA ramping cap binds on the unit total, not each side alone" begin
        # NEMReplayDispatch has no charge/discharge exclusivity, so Out and In are fixed to 15 MW
        # each - well inside each side's own plateau (gen: [5, 20], load: [-20, -5]), so neither
        # side's own §6.3 slope form binds and each side's own capacity is bounded only by its
        # bid MaxAvail (10 MW each, 20 MW combined). AGC ramping capability of 12 MW/interval
        # (agc_max_avail, less restrictive than either side's own 10 MW bid MaxAvail, so §4.2
        # does not scale either trapezium) caps the unit total at 12 MW.
        container = _build_bdu_regulation(
            "TAS1_RAISEREG_BDU_RAMP", 15.0, 15.0; agc_max_avail = 12.0,
        )
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_RAMP", "BAT1") ≈ 12.0 atol = FCAS_TOY_TOLERANCE
        @test fcas_side_mw(container, "TAS1_RAISEREG_BDU_RAMP", :gen, "BAT1") <= 10.0 + FCAS_TOY_TOLERANCE
        @test fcas_side_mw(container, "TAS1_RAISEREG_BDU_RAMP", :load, "BAT1") <= 10.0 + FCAS_TOY_TOLERANCE
    end

    @testset "§5: AGC status 0 disables regulation on both sides" begin
        container = _build_bdu_regulation("TAS1_RAISEREG_BDU_AGC", 22.0, 0.0; agc_status = 0)
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_AGC", "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "§5: a stranded battery (net InitialMW outside [EnablementMin_LOAD, EnablementMax_GEN]) is disabled" begin
        container = _build_bdu_regulation(
            "TAS1_RAISEREG_BDU_STRANDED", 22.0, 0.0; storage_initial_mw = -30.0,
        )
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_STRANDED", "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "an AGC enablement window outside both sides' spans disables regulation" begin
        # agc_enablement_min (368.39502) is above both sides' own EnablementMax (0 and 25 MW):
        # each scaled trapezium comes out with EnablementMin > EnablementMax, which §5 disables,
        # as AEMO's own scaling does.
        container = _build_bdu_regulation(
            "TAS1_RAISEREG_BDU_SCALED", 0.0, 22.0; agc_enablement_min = 368.39502, agc_enablement_max = 0.0,
        )
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_SCALED", "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "the combined stranded window applies only when both sides are really offered" begin
        # Load side offers MaxAvail 0, so the unit bids regulation on the generation side only:
        # InitialMW = -10 MW lies inside the combined window [-25, 25] but outside the generation
        # side's own [0, 25], so the generation side is stranded.
        stranded = _build_bdu_regulation(
            "TAS1_RAISEREG_BDU_ONESIDE", 22.0, 0.0; load_max_avail = 0.0, storage_initial_mw = -10.0,
        )
        @test fcas_unit_mw(stranded, "TAS1_RAISEREG_BDU_ONESIDE", "BAT1") ≈ 0.0 atol = FCAS_TOY_TOLERANCE
        inside = _build_bdu_regulation(
            "TAS1_RAISEREG_BDU_ONESIDE_OK", 22.0, 0.0; load_max_avail = 0.0, storage_initial_mw = 10.0,
        )
        @test fcas_unit_mw(inside, "TAS1_RAISEREG_BDU_ONESIDE_OK", "BAT1") ≈ 6.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "§6.4: a zero SCADA ramp rate imposes no cap" begin
        # Same 15/15 MW point as the binding-cap case: with the ramp rate zero ("absent"), the
        # unit total reaches both sides' combined bid MaxAvail.
        container = _build_bdu_regulation("TAS1_RAISEREG_BDU_ZERO_RAMP", 15.0, 15.0; agc_max_avail = 0.0)
        @test fcas_unit_mw(container, "TAS1_RAISEREG_BDU_ZERO_RAMP", "BAT1") ≈ 20.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "§6.4: the SCADA ramping cap follows AEMO's Table 3 timing" begin
        model = _build_bdu_regulation("TAS1_RAISEREG_BDU_TIMING", 15.0, 15.0; agc_max_avail = 12.0, solve = false)
        container = PSI.get_optimization_container(model)
        bat = PSY.get_component(EnergyReservoirStorage, PSI.get_system(model), "BAT1")
        model_for(formulation) = Dict{Symbol, PSI.DeviceModel}(
            :EnergyReservoirStorage => PSI.DeviceModel(EnergyReservoirStorage, formulation),
        )
        caps_mw(formulation) = AustralianElectricityMarketsSimulations._fcas_agc_ramp_caps(
            container, model_for(formulation), bat, BidType.RAISEREG,
        ) .* PSI.get_base_power(container)
        # Dispatch and 5-minute pre-dispatch apply it; 30-minute pre-dispatch does not.
        @test caps_mw(NEMReplayDispatch) ≈ [12.0]
        @test caps_mw(NEMLookaheadDispatch) ≈ [12.0]
        PSI.set_resolution!(container.settings, Minute(30))
        @test caps_mw(NEMLookaheadDispatch) == [0.0]
    end
end

@testset "a decremental bid on a non-Storage device throws" begin
    duid = TOY_CHEAP
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            add_toy_fcas!(
                sys, device, stamps[1], length(stamps), BidType.LOWER6SEC,
                (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)]; decremental = true,
            )
            PSY.add_service!(
                sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC),
                [device],
            )
        end,
    )
    template = fcas_toy_template(sys, ["TAS1_LOWER6SEC"])
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
        interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    PSI.set_output_dir!(model, mktempdir())
    err = try
        PSI.build_impl!(model)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("scheduled-load", sprint(showerror, err))
end

@testset "a device bidding both directions of the same service throws" begin
    duid = TOY_CHEAP
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            n = length(stamps)
            add_toy_fcas!(sys, device, stamps[1], n, BidType.LOWER6SEC, (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)])
            add_toy_fcas!(
                sys, device, stamps[1], n, BidType.LOWER6SEC, (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)];
                decremental = true,
            )
            PSY.add_service!(
                sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC),
                [device],
            )
        end,
    )
    template = fcas_toy_template(sys, ["TAS1_LOWER6SEC"])
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION,
        interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    PSI.set_output_dir!(model, mktempdir())
    err = try
        PSI.build_impl!(model)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("both", sprint(showerror, err))
end

@testset "check_fcas_services" begin
    duid = TOY_CHEAP
    service_name = "TAS1_LOWER6SEC"
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            add_toy_fcas!(
                sys, device, stamps[1], length(stamps), BidType.LOWER6SEC,
                (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)],
            )
            PSY.add_service!(
                sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.LOWER6SEC),
                [device],
            )
        end,
    )

    @testset "every contributing device modeled and bid: passes silently" begin
        template = fcas_toy_template(sys, [service_name])
        @test isnothing(check_fcas_services(sys, template))
    end

    @testset "a device type the template doesn't model throws, naming it" begin
        network = PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true)
        template = PSI.ProblemTemplate(network)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        PSI.set_service_model!(template, service_name, PSI.ServiceModel(FCASService, FCASMarket, service_name))
        err = try
            check_fcas_services(sys, template)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin(service_name, msg)
        @test occursin(duid, msg)
    end

    @testset "a decremental bid on a non-Storage device is reported, naming it" begin
        dec_sys = fcas_energy_toy_system(
            2.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                add_toy_fcas!(
                    sys, device, stamps[1], length(stamps), BidType.LOWER6SEC,
                    (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)]; decremental = true,
                )
                PSY.add_service!(
                    sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.LOWER6SEC),
                    [device],
                )
            end,
        )
        template = fcas_toy_template(dec_sys, [service_name])
        err = try
            check_fcas_services(dec_sys, template)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("scheduled-load", sprint(showerror, err))
    end
end

"""
    raise6sec_toy(; units, trapezium_mw, service_name = "TAS1_RAISE6SEC")

A toy `System` of `units` (`name => toy_unit(...)`), each bidding RAISE6SEC with `trapezium_mw`
and one 10 MW band, all contributing to one `FCASService`.
"""
function raise6sec_toy(; units, trapezium_mw, service_name = "TAS1_RAISE6SEC", extra! = nothing)
    return nem_toy_system(
        units, sum(u.initial for (_, u) in units);
        mutate! = (sys, stamps) -> begin
            devices = [PSY.get_component(PSY.ThermalStandard, sys, name) for (name, _) in units]
            for device in devices
                add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, trapezium_mw, [(10.0, 10.0)])
            end
            PSY.add_service!(
                sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC), devices,
            )
            isnothing(extra!) || extra!(sys, stamps)
        end,
    )
end

@testset "§5 enablement pre-conditions on a generator" begin
    service_name = "TAS1_RAISE6SEC"
    function gated_container(trapezium_mw, bands; initial = 20.0, availability = 100.0)
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(
                    100.0, [(100.0, 20.0)]; initial = initial, ramp_up = 1.0e4, ramp_down = 1.0e4,
                    availability = availability,
                ),
            ],
            initial;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
                add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, trapezium_mw, bands)
                PSY.add_service!(
                    sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC),
                    [device],
                )
            end,
        )
        return build_fcas(sys, [service_name])
    end
    capacity_bound_mw(container) =
        PSI.JuMP.upper_bound(fcas_capacity(container, service_name)[TOY_CHEAP, 1]) * PSI.get_base_power(container)
    joint_row(container, side) = PSI.JuMP.constraint_object(
        PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, "$(service_name)_$side")[TOY_CHEAP, 1],
    )

    trapezium = (5.0, 10.0, 90.0, 100.0, 10.0)
    bands = [(10.0, 10.0)]

    @testset "all pre-conditions met: enabled, bounded at MaxAvail, real joint rows" begin
        container = gated_container(trapezium, bands)
        @test capacity_bound_mw(container) ≈ 10.0
        @test !isempty(joint_row(container, "upper").func.terms)
        @test !isempty(joint_row(container, "lower").func.terms)
    end

    @testset "MaxAvail = 0: disabled, vacuous joint rows" begin
        container = gated_container((5.0, 10.0, 90.0, 100.0, 0.0), bands)
        @test capacity_bound_mw(container) == 0.0
        @test isempty(joint_row(container, "upper").func.terms)
        @test isempty(joint_row(container, "lower").func.terms)
    end

    @testset "no band with quantity: disabled" begin
        @test capacity_bound_mw(gated_container(trapezium, [(0.0, 10.0)])) == 0.0
    end

    @testset "stranded (InitialMW below EnablementMin): disabled" begin
        @test capacity_bound_mw(gated_container(trapezium, bands; initial = 2.0)) == 0.0
    end

    @testset "stranded (InitialMW above EnablementMax): disabled" begin
        @test capacity_bound_mw(gated_container((5.0, 10.0, 40.0, 50.0, 10.0), bands; initial = 60.0)) == 0.0
    end

    @testset "energy availability below EnablementMin: disabled" begin
        @test capacity_bound_mw(gated_container(trapezium, bands; initial = 6.0, availability = 4.0)) == 0.0
    end

    @testset "EnablementMax < 0 (sign pre-condition): disabled" begin
        @test capacity_bound_mw(gated_container((-20.0, -15.0, -10.0, -5.0, 10.0), bands)) == 0.0
    end
end

@testset "several devices over several intervals are gated independently" begin
    service_name = "TAS1_RAISE6SEC"
    unit(initial) = toy_unit(100.0, [(100.0, 20.0)]; initial = initial, ramp_up = 1.0e4, ramp_down = 1.0e4)
    sys = raise6sec_toy(;
        units = [TOY_CHEAP => unit(20.0), TOY_EXPENSIVE => unit(2.0)], trapezium_mw = (5.0, 10.0, 90.0, 100.0, 10.0),
        extra! = (sys, stamps) -> add_toy_fcas_agc_status!(
            sys, PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP), stamps[1], length(stamps), 0,
        ),
    )
    container = build_fcas(sys, [service_name]; steps = 2)
    base_power = PSI.get_base_power(container)
    var = fcas_capacity(container, service_name)
    bound(dname, t) = PSI.JuMP.upper_bound(var[dname, t]) * base_power
    # TOY_EXPENSIVE starts at 2 MW, below EnablementMin: stranded in both intervals.
    @test [bound(TOY_CHEAP, t) for t in 1:2] ≈ [10.0, 10.0]
    @test [bound(TOY_EXPENSIVE, t) for t in 1:2] == [0.0, 0.0]

    @testset "under NEMLookaheadDispatch, only the first interval checks the metered InitialMW" begin
        device = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
        lookahead = Dict{Symbol, PSI.DeviceModel}(:ThermalStandard => PSI.DeviceModel(PSY.ThermalStandard, NEMLookaheadDispatch))
        replay = Dict{Symbol, PSI.DeviceModel}(:ThermalStandard => PSI.DeviceModel(PSY.ThermalStandard, NEMReplayDispatch))
        AEMS = AustralianElectricityMarketsSimulations
        @test AEMS._fcas_enabled_mask(container, lookahead, device, BidType.RAISE6SEC, false) == [false, true]
        @test AEMS._fcas_enabled_mask(container, replay, device, BidType.RAISE6SEC, false) == [false, false]

        # AGC status is telemetry too: known in every interval under replay, the first only under lookahead.
        cheap = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
        _, _, agc_lookahead = AEMS._fcas_enablement_inputs(container, lookahead, cheap)
        _, _, agc_replay = AEMS._fcas_enablement_inputs(container, replay, cheap)
        @test [agc_lookahead(t) for t in 1:2] == [0, nothing]
        @test [agc_replay(t) for t in 1:2] == [0, 0]
    end
end

@testset "a LOWERREG term enters a contingency service's lower form" begin
    duid = TOY_CHEAP
    sys = fcas_energy_toy_system(
        50.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            for (bid_type, name) in ((BidType.RAISE6SEC, "TAS1_RAISE6SEC"), (BidType.LOWERREG, "TAS1_LOWERREG"))
                add_toy_fcas!(sys, device, stamps[1], length(stamps), bid_type, (0.0, 10.0, 90.0, 100.0, 10.0), [(10.0, 10.0)])
                PSY.add_service!(sys, FCASService(; name = name, region = "TAS1", bid_type = bid_type), [device])
            end
        end,
    )
    container = build_fcas(sys, ["TAS1_RAISE6SEC", "TAS1_LOWERREG"])
    lower_reg = fcas_capacity(container, "TAS1_LOWERREG")[duid, 1]
    row(side) = PSI.JuMP.constraint_object(
        PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, "TAS1_RAISE6SEC_$side")[duid, 1],
    )
    @test row("lower").func.terms[lower_reg] == -1.0
    @test !haskey(row("upper").func.terms, lower_reg)
end

@testset "a Storage device's LOAD-side regulation reads its charging energy only" begin
    service_name = "TAS1_LOWERREG_STOR"
    model, _ = storage_fcas_toy_model(service_name, BidType.LOWERREG, (-20.0, -15.0, -5.0, 0.0, 10.0); decremental = true)
    container = PSI.get_optimization_container(model)
    out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)
    in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)
    for side in ("upper", "lower")
        row = PSI.JuMP.constraint_object(
            PSI.get_constraint(container, FCASJointCapacityConstraint(), FCASService, "$(service_name)_$side")["BAT1", 1],
        )
        @test row.func.terms[in_var["BAT1", 1]] == -1.0
        @test !haskey(row.func.terms, out_var["BAT1", 1])
    end
end

@testset "a Storage device's LOAD-side regulation trapezium is scaled" begin
    # LOAD-side LOWERREG on [-20, 0], both slope coefficients 0.5. AGC EnablementMin -10 and a
    # 4 MW AGC ramping capability give (-10, -10 + 0.5 × 4, 0 - 0.5 × 4, 0, 4).
    service_name = "TAS1_LOWERREG_STOR_SCALED"
    model, sys = storage_fcas_toy_model(
        service_name, BidType.LOWERREG, (-20.0, -15.0, -5.0, 0.0, 10.0);
        decremental = true, scaling = (; agc_enablement_min = -10.0, agc_max_avail = 4.0),
    )
    container = PSI.get_optimization_container(model)
    bat = get_component(EnergyReservoirStorage, sys, "BAT1")
    replay = Dict{Symbol, PSI.DeviceModel}(:EnergyReservoirStorage => PSI.DeviceModel(EnergyReservoirStorage, NEMReplayDispatch))
    trap = only(AustralianElectricityMarketsSimulations._fcas_series(container, replay, bat, BidType.LOWERREG, true)[1])
    @test collect(Tuple(trap)[1:5]) .* PSI.get_base_power(container) ≈ [-10.0, -8.0, -2.0, 0.0, 4.0]
end

@testset "a Storage device's GEN-side regulation with a vertical lower slope" begin
    # GEN-side RAISEREG with EnablementMin = LowBreakpoint = 0: the generation side offers its
    # full MaxAvail at zero generation. Enabled from a net InitialMW of 0, the battery keeps it
    # while charging; stranded from a charging InitialMW, it is disabled.
    service_name = "TAS1_RAISEREG_STOR"
    function raise_reg_mw(initial_mw)
        model, sys = storage_fcas_toy_model(
            service_name, BidType.RAISEREG, (0.0, 0.0, 15.0, 20.0, 10.0); initial_mw = initial_mw,
        )
        base_power = get_base_power(sys)
        container = PSI.get_optimization_container(model)
        PSI.JuMP.fix(PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)["BAT1", 1], 0.0; force = true)
        PSI.JuMP.fix(
            PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)["BAT1", 1], 6.0 / base_power; force = true,
        )
        maximize_and_solve!(container) do container
            fcas_capacity(container, service_name)["BAT1", 1]
        end
        return fcas_mw(container, service_name, "BAT1")
    end
    @test raise_reg_mw(0.0) ≈ 10.0 atol = FCAS_TOY_TOLERANCE
    @test raise_reg_mw(-6.0) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
end

@testset "a device in two FCASServices of one market" begin
    duid = TOY_CHEAP
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISEREG, (0.0, 0.0, 100.0, 100.0, 9.0), [(9.0, 10.0)])
            add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])
            for name in ("TAS1_RAISEREG", "TAS1_RAISEREG_B")
                PSY.add_service!(sys, FCASService(; name = name, region = "TAS1", bid_type = BidType.RAISEREG), [device])
            end
            PSY.add_service!(
                sys, FCASService(; name = "TAS1_RAISE6SEC", region = "TAS1", bid_type = BidType.RAISE6SEC), [device],
            )
        end,
    )
    service_names = ["TAS1_RAISEREG", "TAS1_RAISEREG_B", "TAS1_RAISE6SEC"]
    template = fcas_toy_template(sys, service_names)

    @testset "check_fcas_services reports it, naming both services" begin
        err = try
            check_fcas_services(sys, template)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        msg = sprint(showerror, err)
        @test occursin("TAS1_RAISEREG, TAS1_RAISEREG_B", msg)
        @test occursin(duid, msg)
    end

    @testset "the build refuses it rather than counting only one regulation target" begin
        model = PSI.DecisionModel(
            template, sys;
            optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
            initial_time = TOY_START, name = "fcas_toy_dup",
        )
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
    end
end

@testset "check_fcas_services scope" begin
    duid = TOY_CHEAP
    service_name = "TAS1_RAISE6SEC"
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])
            # TOY_EXPENSIVE is unavailable in the toy system and carries no FCAS bid.
            offline = PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE)
            PSY.add_service!(
                sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC), [device, offline],
            )
            # A service the template doesn't model under FCASMarket, with an unbid contributor.
            PSY.add_service!(sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC), [device])
        end,
    )

    @testset "unavailable devices and services not modeled by FCASMarket are skipped" begin
        @test !PSY.get_available(PSY.get_component(PSY.ThermalStandard, sys, TOY_EXPENSIVE))
        @test isnothing(check_fcas_services(sys, fcas_toy_template(sys, [service_name])))
    end

    @testset "a contributor modeled as FixedOutput is reported" begin
        network = PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true)
        template = PSI.ProblemTemplate(network)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        PSI.set_device_model!(template, PSY.ThermalStandard, PSI.FixedOutput)
        PSI.set_service_model!(template, service_name, PSI.ServiceModel(FCASService, FCASMarket, service_name))
        err = try
            check_fcas_services(sys, template)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("FixedOutput", sprint(showerror, err))
    end
end

@testset "FCASMarket refuses unsupported duals and recurrent-solve containers" begin
    service_name = "TAS1_RAISE6SEC"
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            add_toy_fcas!(sys, device, stamps[1], length(stamps), BidType.RAISE6SEC, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])
            PSY.add_service!(
                sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISE6SEC), [device],
            )
        end,
    )
    container = build_fcas(sys, [service_name])
    function construct_error(service_model)
        try
            PSI.construct_service!(
                container, sys, PSI.ArgumentConstructStage(), service_model,
                Dict{Symbol, PSI.DeviceModel}(), Set{DataType}(), PSI.NetworkModel(PSI.CopperPlatePowerModel),
            )
            return nothing
        catch e
            return e
        end
    end

    err = construct_error(PSI.ServiceModel(FCASService, FCASMarket, service_name; duals = [PSI.CopperPlateBalanceConstraint]))
    @test err isa ArgumentError
    @test occursin("FCASJointCapacityConstraint and FCASJointRampingConstraint only", err.msg)

    container.built_for_recurrent_solves = true
    err = construct_error(PSI.ServiceModel(FCASService, FCASMarket, service_name))
    @test err isa ArgumentError
    @test occursin("DecisionModel", err.msg)
end

"""
    joint_ramping_toy(initial_mw; capacity = 1000.0, raise_agc = nothing, lower_agc = nothing, extra! = nothing)

A single `ThermalStandard` toy `System` (`InitialMW = initial_mw`, `capacity` MW) bidding flat
`(0, 0, capacity, capacity, capacity)` RAISEREG and LOWERREG trapeziums as `"TAS1_RAISEREG"`/
`"TAS1_LOWERREG"`, each with an AGC ramping capability of `raise_agc`/`lower_agc` MW over one
resolution interval when given, for AEMO *FCAS Model in NEMDE* §6.1 joint ramping tests.
"""
function joint_ramping_toy(
        initial_mw; capacity = 1000.0, raise_agc::Union{Nothing, Float64} = nothing,
        lower_agc::Union{Nothing, Float64} = nothing, extra! = nothing,
    )
    return nem_toy_system(
        [
            TOY_CHEAP => toy_unit(
                capacity, [(capacity, 20.0)]; initial = initial_mw, ramp_up = 1.0e4, ramp_down = 1.0e4,
                availability = capacity,
            ),
        ],
        max(initial_mw, 1.0);
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            n = length(stamps)
            trap = (0.0, 0.0, capacity, capacity, capacity)
            add_toy_fcas!(sys, device, stamps[1], n, BidType.RAISEREG, trap, [(capacity, 10.0)])
            add_toy_fcas!(sys, device, stamps[1], n, BidType.LOWERREG, trap, [(capacity, 10.0)])
            isnothing(raise_agc) ||
                add_toy_fcas_scaling!(sys, device, stamps[1], n, BidType.RAISEREG; agc_max_avail = raise_agc)
            isnothing(lower_agc) ||
                add_toy_fcas_scaling!(sys, device, stamps[1], n, BidType.LOWERREG; agc_max_avail = lower_agc)
            PSY.add_service!(sys, FCASService(; name = "TAS1_RAISEREG", region = "TAS1", bid_type = BidType.RAISEREG), [device])
            PSY.add_service!(sys, FCASService(; name = "TAS1_LOWERREG", region = "TAS1", bid_type = BidType.LOWERREG), [device])
            isnothing(extra!) || extra!(sys, device, stamps)
        end,
    )
end

"Whether `row` (a `JuMP.constraint_object`) is the gated placeholder `0.0 <= 1.0` row."
_is_placeholder_row(row) = isempty(row.func.terms) && row.set == PSI.MOI.LessThan(1.0)

@testset "AEMO §6.1 joint ramping constraint" begin
    duid = TOY_CHEAP

    @testset "A.2 numbers" begin
        # InitialMW = 450, AGC up 180 MW/h (15 MW/5min), down 120 MW/h (10 MW/5min).
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"])
        base_power = PSY.get_base_power(sys)
        energy_var = PSI.get_variable(container, PSI.ActivePowerVariable(), PSY.ThermalStandard)[duid, 1]
        raise_target = fcas_capacity(container, "TAS1_RAISEREG")[duid, 1]
        lower_target = fcas_capacity(container, "TAS1_LOWERREG")[duid, 1]
        raise_row = PSI.JuMP.constraint_object(
            PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_RAISEREG")[duid, 1],
        )
        lower_row = PSI.JuMP.constraint_object(
            PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_LOWERREG")[duid, 1],
        )
        @test raise_row.func.terms[energy_var] == 1.0
        @test raise_row.func.terms[raise_target] == 1.0
        @test raise_row.set.upper ≈ 465.0 / base_power atol = 1.0e-9
        @test lower_row.func.terms[energy_var] == 1.0
        @test lower_row.func.terms[lower_target] == -1.0
        @test lower_row.set.lower ≈ 440.0 / base_power atol = 1.0e-9
    end

    @testset "RAISEREG binding: §4.2 and the trapezium slope don't bind, §6.1 does" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"])
        fix_energy!(container, duid, 460.0)
        maximize_and_solve!(container) do container
            fcas_capacity(container, "TAS1_RAISEREG")[duid, 1]
        end
        # §4.2's scaled MaxAvail (15) and the flat trapezium's slope (unbounded) allow up to 15;
        # §6.1 restricts further to 465 - 460 = 5.
        @test fcas_mw(container, "TAS1_RAISEREG", duid) ≈ 5.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "A.2 end-to-end: energy at the joint ramp ceiling leaves no RaiseReg" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"])
        fix_energy!(container, duid, 465.0)
        maximize_and_solve!(container) do container
            fcas_capacity(container, "TAS1_RAISEREG")[duid, 1]
        end
        @test fcas_mw(container, "TAS1_RAISEREG", duid) ≈ 0.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "LOWERREG binding" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"])
        fix_energy!(container, duid, 445.0)
        maximize_and_solve!(container) do container
            fcas_capacity(container, "TAS1_LOWERREG")[duid, 1]
        end
        # 445 - (450 - 10) = 5.
        @test fcas_mw(container, "TAS1_LOWERREG", duid) ≈ 5.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "a two-sided BDU's row reads net energy and the combined regulation target" begin
        model = _build_bdu_regulation(
            "TAS1_RAISEREG_BDU_JOINT", 0.0, 20.0; storage_initial_mw = -20.0, agc_max_avail = 12.0, solve = false,
        )
        container = PSI.get_optimization_container(model)
        base_power = PSI.get_base_power(container)
        out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)["BAT1", 1]
        in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)["BAT1", 1]
        gen_var = fcas_side_capacity(container, "TAS1_RAISEREG_BDU_JOINT", :gen)["BAT1", 1]
        load_var = fcas_side_capacity(container, "TAS1_RAISEREG_BDU_JOINT", :load)["BAT1", 1]
        row = PSI.JuMP.constraint_object(
            PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_RAISEREG_BDU_JOINT")["BAT1", 1],
        )
        @test row.func.terms[out_var] == 1.0
        @test row.func.terms[in_var] == -1.0
        @test row.func.terms[gen_var] == 1.0
        @test row.func.terms[load_var] == 1.0
        # InitialMW (-20) + AGC ramping capability (12) = -8.
        @test row.set.upper ≈ -8.0 / base_power atol = 1.0e-9
    end

    @testset "a single-sided BDU's row reads net energy, not that side's own" begin
        service_name = "TAS1_RAISEREG_STOR_JOINT"
        model, sys = storage_fcas_toy_model(
            service_name, BidType.RAISEREG, (0.0, 0.0, 20.0, 20.0, 10.0); scaling = (; agc_max_avail = 5.0),
        )
        container = PSI.get_optimization_container(model)
        out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)["BAT1", 1]
        in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)["BAT1", 1]
        row = PSI.JuMP.constraint_object(
            PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, service_name)["BAT1", 1],
        )
        @test row.func.terms[out_var] == 1.0
        @test row.func.terms[in_var] == -1.0
    end

    @testset "gating: a placeholder row where §6.1 doesn't apply" begin
        @testset "no AGC ramp rate series attached" begin
            sys = joint_ramping_toy(450.0)
            container = build_fcas(sys, ["TAS1_RAISEREG"])
            row = PSI.JuMP.constraint_object(
                PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_RAISEREG")[duid, 1],
            )
            @test _is_placeholder_row(row)
        end

        @testset "a zero AGC ramp rate" begin
            sys = joint_ramping_toy(450.0; raise_agc = 0.0)
            container = build_fcas(sys, ["TAS1_RAISEREG"])
            row = PSI.JuMP.constraint_object(
                PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_RAISEREG")[duid, 1],
            )
            @test _is_placeholder_row(row)
        end

        @testset "not enabled (AGC status 0)" begin
            sys = joint_ramping_toy(
                450.0; raise_agc = 15.0,
                extra! = (sys, device, stamps) -> add_toy_fcas_agc_status!(sys, device, stamps[1], length(stamps), 0),
            )
            container = build_fcas(sys, ["TAS1_RAISEREG"])
            row = PSI.JuMP.constraint_object(
                PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_RAISEREG")[duid, 1],
            )
            @test _is_placeholder_row(row)
        end

        @testset "5-minute pre-dispatch: only the first interval, 30-minute pre-dispatch: never" begin
            sys = joint_ramping_toy(450.0; raise_agc = 15.0)
            template = fcas_toy_template(sys, ["TAS1_RAISEREG"])
            PSI.set_device_model!(template, PSY.ThermalStandard, NEMLookaheadDispatch)
            model = PSI.DecisionModel(
                template, sys;
                optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
                horizon = 2 * TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
                initial_time = TOY_START, name = "fcas_toy_gating", store_variable_names = true,
            )
            @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
            container = PSI.get_optimization_container(model)
            con = PSI.get_constraint(container, FCASJointRampingConstraint(), FCASService, "TAS1_RAISEREG")
            @test !_is_placeholder_row(PSI.JuMP.constraint_object(con[duid, 1]))
            @test _is_placeholder_row(PSI.JuMP.constraint_object(con[duid, 2]))

            PSI.set_resolution!(container.settings, Minute(30))
            # Rebuilding at a 30-minute resolution is out of scope here; §6.4's own Table 3 test
            # ("the SCADA ramping cap follows AEMO's Table 3 timing") already covers the shared
            # `_fcas_agc_ramp_caps` helper §6.1 reads, including the 30-minute predispatch case.
        end

        @testset "InitialMW unknown at an interval" begin
            # NEMReplayDispatch requires full "initial_mw" coverage for its own ramp constraint
            # (and NEMLookaheadDispatch's initial-conditions sub-model is always built as
            # NEMReplayDispatch - see `PSI.get_initial_conditions_device_model`), so a NaN gap
            # cannot reach a full `DecisionModel` build; a real gap is a build-time throw either
            # way, which `check_fcas_services` catches up front instead (next testset). Gate 3
            # itself - `isnan(mw)` in `_add_fcas_joint_ramping_constraints!` - is exercised
            # directly against `get_initial_mw`'s documented `NaN`-at-a-gap behavior.
            sys = joint_ramping_toy(450.0; raise_agc = 15.0)
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            initial_mw = get_initial_mw(device, TOY_START, 2)
            @test initial_mw == [450.0, 450.0]

            gapped_sys = joint_ramping_toy(
                450.0; raise_agc = 15.0,
                extra! = (sys, device, stamps) -> begin
                    base_power = PSY.get_base_power(sys)
                    PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, "initial_mw")
                    PSY.add_time_series!(
                        sys, device,
                        PSY.SingleTimeSeries(;
                            name = "initial_mw", data = PSY.TimeSeries.TimeArray(stamps, [450.0 / base_power, NaN]),
                        ),
                    )
                end,
            )
            gapped_device = PSY.get_component(PSY.ThermalStandard, gapped_sys, duid)
            gapped = get_initial_mw(gapped_device, TOY_START, 2)
            @test gapped[1] == 450.0
            @test isnan(gapped[2])
        end
    end

    @testset "duals: requesting FCASJointRampingConstraint builds and populates the container" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        network = PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true)
        template = PSI.ProblemTemplate(network)
        set_nem_dispatch_models!(template, sys)
        PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
        PSI.set_service_model!(
            template, "TAS1_RAISEREG",
            PSI.ServiceModel(
                FCASService, FCASMarket, "TAS1_RAISEREG";
                duals = [FCASJointCapacityConstraint, FCASJointRampingConstraint],
            ),
        )
        model = PSI.DecisionModel(
            template, sys;
            optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
            horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
            initial_time = TOY_START, name = "fcas_toy_duals", store_variable_names = true,
        )
        @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
        @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
        container = PSI.get_optimization_container(model)
        dual_key = only(
            k for k in PSI.get_constraint_keys(container)
                if PSI.IS.Optimization.get_entry_type(k) === FCASJointRampingConstraint
        )
        results = PSI.OptimizationProblemResults(model)
        dual_df = PSI.read_dual(results, dual_key)
        @test !isempty(dual_df)
        @test all(!isnan, dual_df.value)
    end
end

@testset "check_fcas_services reports a regulation contributor missing initial_mw" begin
    duid = TOY_CHEAP
    service_name = "TAS1_RAISEREG_CHECK"
    sys = fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, duid)
            n = length(stamps)
            add_toy_fcas!(sys, device, stamps[1], n, BidType.RAISEREG, (0.0, 0.0, 100.0, 100.0, 10.0), [(10.0, 10.0)])
            add_toy_fcas_scaling!(sys, device, stamps[1], n, BidType.RAISEREG; agc_max_avail = 5.0)
            PSY.remove_time_series!(sys, PSY.SingleTimeSeries, device, "initial_mw")
            PSY.add_service!(sys, FCASService(; name = service_name, region = "TAS1", bid_type = BidType.RAISEREG), [device])
        end,
    )
    network = PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true)
    template = PSI.ProblemTemplate(network)
    PSI.set_device_model!(template, PSY.ThermalStandard, NEMReplayDispatch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(
        template, service_name, PSI.ServiceModel(FCASService, FCASMarket, service_name),
    )
    err = try
        check_fcas_services(sys, template)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    msg = sprint(showerror, err)
    @test occursin(duid, msg)
    @test occursin("initial_mw", msg)
end

@testset "elastic FCAS rows (use_slacks)" begin
    duid = TOY_CHEAP
    # TOY_START is in FY2024-25, Market Price Cap $17,500/MWh.
    mpc = 17_500.0

    @testset "off by default: no slack variables" begin
        container = build_fcas(joint_ramping_toy(450.0; raise_agc = 15.0), ["TAS1_RAISEREG"])
        @test !PSI.has_container_key(container, FCASJointRampingSlack, FCASService, "TAS1_RAISEREG")
    end

    @testset "ramping slack absorbs a violated §6.1 row and is priced at 155 x MPC" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"]; use_slacks = true)
        base_power = PSI.get_base_power(container)
        fix_energy!(container, duid, 475.0)  # 10 MW above the 465 MW joint ramp ceiling
        jm = PSI.get_jump_model(container)
        PSI.JuMP.optimize!(jm)
        @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
        slack = PSI.get_variable(container, FCASJointRampingSlack(), FCASService, "TAS1_RAISEREG")[duid, 1]
        @test PSI.JuMP.value(slack) * base_power ≈ 10.0 atol = FCAS_TOY_TOLERANCE
        coefficient = PSI.JuMP.objective_function(jm).terms[slack]
        @test coefficient ≈ base_power * interval_cost_coefficient(FCAS_RAMPING_CVP_FACTOR * mpc, TOY_RESOLUTION)
    end

    @testset "capacity slack is built per row and priced at 70 x MPC" begin
        container = build_fcas(joint_ramping_toy(450.0; raise_agc = 15.0), ["TAS1_RAISEREG"]; use_slacks = true)
        base_power = PSI.get_base_power(container)
        jm = PSI.get_jump_model(container)
        for side in ("upper", "lower")
            slack = PSI.get_variable(
                container, FCASJointCapacitySlack(), FCASService, "TAS1_RAISEREG_$side",
            )[duid, 1]
            @test PSI.JuMP.objective_function(jm).terms[slack] ≈
                base_power * interval_cost_coefficient(FCAS_CAPACITY_CVP_FACTOR * mpc, TOY_RESOLUTION)
        end
    end
end

@testset "area-balance slack is priced at 150 x MPC in every interval, up and down" begin
    container = build_fcas(joint_ramping_toy(450.0), String[]; steps = 2)
    jm = PSI.get_jump_model(container)
    expected = PSI.get_base_power(container) *
        interval_cost_coefficient(AREA_BALANCE_CVP_FACTOR * 17_500.0, TOY_RESOLUTION)
    for var_type in (PSI.SystemBalanceSlackUp, PSI.SystemBalanceSlackDown)
        slack = PSI.get_variable(container, var_type(), PSY.Area)
        @test size(slack, 2) == 2
        @test all(v -> PSI.JuMP.objective_function(jm).terms[v] ≈ expected, slack)
    end
end

@testset "elastic FCAS rows absorb a violated row by exactly the excess" begin
    duid = TOY_CHEAP
    function lower6sec_slacks(energy_mw)
        # InitialMW 20 keeps the §5 gate open; the fixed dispatch then breaches the window.
        sys = nem_toy_system(
            [
                duid => toy_unit(
                    100.0, [(100.0, 20.0)]; initial = 20.0, ramp_up = 100.0, ramp_down = 100.0,
                    availability = 100.0,
                ),
            ],
            20.0;
            mutate! = (sys, stamps) -> begin
                device = PSY.get_component(PSY.ThermalStandard, sys, duid)
                add_toy_fcas!(
                    sys, device, stamps[1], length(stamps), BidType.LOWER6SEC,
                    (1.0, 5.0, 26.0, 27.0, 4.0), [(4.0, 10.0)],
                )
                PSY.add_service!(
                    sys, FCASService(; name = "TAS1_LOWER6SEC", region = "TAS1", bid_type = BidType.LOWER6SEC),
                    [device],
                )
            end,
        )
        container = build_fcas(sys, ["TAS1_LOWER6SEC"]; use_slacks = true)
        fix_energy!(container, duid, energy_mw)
        jm = PSI.get_jump_model(container)
        PSI.JuMP.optimize!(jm)
        @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
        base_power = PSI.get_base_power(container)
        return collect(
            map(("upper", "lower")) do side
                slack = PSI.get_variable(container, FCASJointCapacitySlack(), FCASService, "TAS1_LOWER6SEC_$side")
                PSI.JuMP.value(slack[duid, 1]) * base_power
            end
        )
    end

    # EnablementMax 27, EnablementMin 1.
    @test lower6sec_slacks(30.0) ≈ [3.0, 0.0] atol = FCAS_TOY_TOLERANCE
    @test lower6sec_slacks(0.5) ≈ [0.0, 0.5] atol = FCAS_TOY_TOLERANCE
    @test lower6sec_slacks(10.0) ≈ [0.0, 0.0] atol = FCAS_TOY_TOLERANCE

    @testset "a violated LOWERREG ramping row" begin
        sys = joint_ramping_toy(450.0; raise_agc = 15.0, lower_agc = 10.0)
        container = build_fcas(sys, ["TAS1_RAISEREG", "TAS1_LOWERREG"]; use_slacks = true)
        fix_energy!(container, duid, 435.0)  # 5 MW below InitialMW - lower ramp (440)
        jm = PSI.get_jump_model(container)
        PSI.JuMP.optimize!(jm)
        @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
        slack = PSI.get_variable(container, FCASJointRampingSlack(), FCASService, "TAS1_LOWERREG")[duid, 1]
        @test PSI.JuMP.value(slack) * PSI.get_base_power(container) ≈ 5.0 atol = FCAS_TOY_TOLERANCE
    end

    @testset "a two-sided BDU's generation-side rows" begin
        service_name = "TAS1_RAISEREG_BDU_SLACK"
        model = _build_bdu_regulation(service_name, 0.0, 20.0; storage_initial_mw = 10.0, solve = false, use_slacks = true)
        container = PSI.get_optimization_container(model)
        for side in ("gen_upper", "gen_lower", "load_upper", "load_lower")
            slack = PSI.get_variable(container, FCASJointCapacitySlack(), FCASService, "$(service_name)_$side")
            @test size(slack, 1) == 1
        end
        base_power = PSI.get_base_power(container)
        out_var = PSI.get_variable(container, PSI.ActivePowerOutVariable(), EnergyReservoirStorage)["BAT1", 1]
        in_var = PSI.get_variable(container, PSI.ActivePowerInVariable(), EnergyReservoirStorage)["BAT1", 1]
        PSI.JuMP.fix(out_var, 30.0 / base_power; force = true)  # above the generation-side EnablementMax (25)
        PSI.JuMP.fix(in_var, 0.0; force = true)
        jm = PSI.get_jump_model(container)
        PSI.JuMP.optimize!(jm)
        @test PSI.JuMP.termination_status(jm) == PSI.MOI.OPTIMAL
        gen_upper = PSI.get_variable(container, FCASJointCapacitySlack(), FCASService, "$(service_name)_gen_upper")
        @test PSI.JuMP.value(gen_upper["BAT1", 1]) * base_power ≈ 5.0 atol = FCAS_TOY_TOLERANCE
    end
end

# A toy system whose one unit bids `bid_type` at `price`, with a `>= rhs_mw` "F_TOY" GenericConstraint
# governing region "1"'s price through `term`, in the form `add_nem_constraints!` produces.
function fcas_requirement_toy_system(bid_type::BidType, term::ConstraintTerm, rhs_mw; price = 10.0)
    return fcas_energy_toy_system(
        2.0;
        mutate! = (sys, stamps) -> begin
            device = PSY.get_component(PSY.ThermalStandard, sys, TOY_CHEAP)
            add_toy_fcas!(sys, device, stamps[1], length(stamps), bid_type, (0.0, 0.0, 100.0, 100.0, 20.0), [(20.0, price)])
            PSY.add_service!(
                sys, FCASService(; name = "1_$(string(bid_type))", region = "1", bid_type = bid_type), [device],
            )
            rhs_pu = rhs_mw / PSY.get_base_power(sys)
            gc = GenericConstraint(;
                name = "F_TOY", sense = ConstraintSense.GE, rhs = rhs_pu, terms = ConstraintTerm[term],
                fcas_requirements = [FCASRequirement("1", bid_type)],
            )
            PSY.add_service!(sys, gc, [device])
            for (name, value) in (("rhs", rhs_pu), ("invoked", 1.0))
                PSY.add_time_series!(
                    sys, gc,
                    PSY.SingleTimeSeries(; name = name, data = PSY.TimeSeries.TimeArray(stamps, fill(value, length(stamps)))),
                )
            end
        end,
    )
end

function solve_fcas_requirement(sys, bid_type::BidType; gc_template = true)
    template = fcas_toy_template(sys, ["1_$(string(bid_type))"])
    gc_template && PSI.set_service_model!(
        template, "F_TOY",
        PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "F_TOY"; duals = [NEMConstraintLimit]),
    )
    model = PSI.DecisionModel(
        template, sys;
        optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false),
        horizon = TOY_RESOLUTION, resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION,
        initial_time = TOY_START, name = "fcas_req_toy", store_variable_names = true,
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    @test PSI.solve!(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED
    return PSI.OptimizationProblemResults(model), model
end

@testset "a UnitTerm/RegionTerm on FCAS enablement forces it and prices the region via the dual" begin
    for (bid_type, term) in (
            (BidType.RAISE6SEC, UnitTerm(TOY_CHEAP, BidType.RAISE6SEC, 1.0)),
            (BidType.RAISEREG, RegionTerm("1", BidType.RAISEREG, 1.0, [TOY_CHEAP])),
        )
        sys = fcas_requirement_toy_system(bid_type, term, 5.0)
        results, _ = solve_fcas_requirement(sys, bid_type)
        service_name = "1_$(string(bid_type))"
        enabled = PSI.read_variable(results, "FCASCapacityVariable__FCASService__$service_name")
        @test only(enabled.value) * PSY.get_base_power(sys) ≈ 5.0 atol = FCAS_TOY_TOLERANCE
        prices = compute_fcas_prices(results, sys)
        @test prices.REGIONID == ["1"]
        @test prices.BIDTYPE == [bid_type]
        @test prices.RRP ≈ [10.0] atol = 1.0e-4
    end
end

@testset "an FCAS term with no FCASMarket model for its service throws, naming the constraint" begin
    bid_type = BidType.RAISE6SEC
    sys = fcas_requirement_toy_system(bid_type, UnitTerm(TOY_CHEAP, bid_type, 1.0), 5.0)
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(
        template, "F_TOY", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "F_TOY"),
    )
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    PSI.set_output_dir!(model, mktempdir())
    err = try
        PSI.build_impl!(model)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("F_TOY", sprint(showerror, err))
    @test occursin("FCASMarket", sprint(showerror, err))
end

@testset "an FCAS term naming a service absent from the System warns" begin
    bid_type = BidType.RAISE6SEC
    sys = fcas_requirement_toy_system(bid_type, UnitTerm(TOY_CHEAP, bid_type, 1.0), 5.0)
    PSY.remove_component!(sys, PSY.get_component(FCASService, sys, "1_RAISE6SEC"))
    template = fcas_toy_template(sys, String[])
    PSI.set_service_model!(
        template, "F_TOY", PSI.ServiceModel(GenericConstraint, LinearFactorLimit, "F_TOY"),
    )
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer, horizon = TOY_RESOLUTION,
        resolution = TOY_RESOLUTION, interval = TOY_RESOLUTION, initial_time = TOY_START,
    )
    PSI.set_output_dir!(model, mktempdir())
    @test_logs (:warn, r"no FCASService \"1_RAISE6SEC\"") match_mode = :any PSI.build_impl!(model)
end
