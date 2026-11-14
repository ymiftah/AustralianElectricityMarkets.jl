using TimeSeries: TimeArray

const _RS_IS = PowerSystems.IS
const _RS_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 30))
_rs_series(name, values) = SingleTimeSeries(; name, data = TimeArray(_RS_STAMPS, values))
_rs_key(component, name::String) = only(k for k in _RS_IS.get_time_series_keys(component) if k.name == name)

_rs_bus() = ACBus(;
    number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
    magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
)

function _rs_thermal(name, bus)
    return ThermalStandard(;
        name, available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0,
        rating = 120.0, active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing), base_power = 100.0,
    )
end

_rs_registration(from) = AustralianElectricityMarkets.NEMRegistration(;
    schedule_type = AustralianElectricityMarkets.ScheduleType.SCHEDULED, gen_loss_factor = 1.0,
    load_loss_factor = 1.0, registered_from = from, registered_until = DateTime(2999, 12, 31),
)

# A thermal unit whose observed starting output and dispatch mode are keyed series on `_RS_STAMPS`.
function _rs_observed_unit(name; mw, modes)
    sys = System(100.0)
    bus = _rs_bus()
    add_component!(sys, bus)
    gen = _rs_thermal(name, bus)
    add_component!(sys, gen)
    AustralianElectricityMarkets.attach_nem_unit_data!(sys, gen)
    add_time_series!(sys, gen, _rs_series("initial_mw", mw))
    add_time_series!(sys, gen, _rs_series("dispatch_mode", modes))
    AustralianElectricityMarkets.set_observed_state!(
        gen,
        AustralianElectricityMarkets.NEMObservedState(;
            initial_mw = _rs_key(gen, "initial_mw"), dispatch_mode = _rs_key(gen, "dispatch_mode"),
        ),
    )
    return sys, gen
end

# The values of a field of an observed state or bid over `stamps`: a key is read over the window, a static value is repeated.
function _rs_raw(device, value::_RS_IS.StaticTimeSeriesKey, stamps)
    return Float64.(_RS_IS.get_time_series_values(device, value; start_time = first(stamps), len = length(stamps)))
end
_rs_raw(device, value, stamps) = fill(Float64(value), length(stamps))

@testset "observed_unit_states reads a key-backed observed state at each stamp" begin
    mw = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0]
    _, gen = _rs_observed_unit("keyed"; mw, modes = [0.0, 1.0, 2.0, 3.0, 4.0, 0.0, 1.0])
    states = AustralianElectricityMarkets.observed_unit_states(gen, _RS_STAMPS)
    @test all(s -> s isa AustralianElectricityMarkets.NEMUnitState, states)
    @test [s.initial_mw for s in states] == mw
    @test [s.dispatch_mode for s in states] == [0, 1, 2, 3, 4, 0, 1]
end

@testset "observed_unit_states reads a static observed state" begin
    sys = System(100.0)
    bus = _rs_bus()
    add_component!(sys, bus)
    gen = _rs_thermal("static", bus)
    add_component!(sys, gen)
    AustralianElectricityMarkets.attach_nem_unit_data!(sys, gen)
    AustralianElectricityMarkets.set_observed_state!(
        gen, AustralianElectricityMarkets.NEMObservedState(; initial_mw = 55, dispatch_mode = 1),
    )
    @test only(AustralianElectricityMarkets.observed_unit_states(gen, _RS_STAMPS[2:2])) ==
        AustralianElectricityMarkets.NEMUnitState(55.0, 1)
end

@testset "observed_unit_states rejects devices without NEM observed state" begin
    sys = System(100.0)
    bus = _rs_bus()
    add_component!(sys, bus)
    stock = ThermalStandard(;
        name = "stock_unit", available = true, status = true, bus = bus, active_power = 50.0,
        reactive_power = 0.0, rating = 120.0, active_power_limits = (min = 10.0, max = 100.0),
        reactive_power_limits = nothing, ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing),
        base_power = 100.0,
    )
    add_component!(sys, stock)
    @test_throws ArgumentError AustralianElectricityMarkets.observed_unit_states(stock, _RS_STAMPS[1:1])

    bare = _rs_thermal("bare", bus)
    add_component!(sys, bare)
    AustralianElectricityMarkets.attach_nem_unit_data!(sys, bare)
    @test_throws ArgumentError AustralianElectricityMarkets.observed_unit_states(bare, _RS_STAMPS[1:1])
end

@testset "a unit's first registered stamp starts in dispatch mode 0 when its previous interval is unregistered" begin
    _, gen = _rs_observed_unit(
        "first_stamp"; mw = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0], modes = [0.0, NaN, 2.0, 3.0, 4.0, 0.0, 1.0],
    )

    # Registered from the first stamp: the second stamp is the first registered one, and its mode is NaN.
    AustralianElectricityMarkets.set_registration!(gen, _rs_registration(_RS_STAMPS[1]))
    @test only(AustralianElectricityMarkets.observed_unit_states(gen, _RS_STAMPS[2:2])) ==
        AustralianElectricityMarkets.NEMUnitState(20.0, 0)

    # Registered earlier: the previous interval is registered, so a NaN mode is still an error.
    AustralianElectricityMarkets.set_registration!(gen, _rs_registration(_RS_STAMPS[1] - Minute(5)))
    @test_throws ArgumentError AustralianElectricityMarkets.observed_unit_states(gen, _RS_STAMPS[2:2])
end

@testset "the observed initial MW series is zero where the build does not observe the unit" begin
    sys, gen = _rs_observed_unit(
        "vectorised"; mw = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0], modes = [0.0, 1.0, 2.0, 3.0, 4.0, 0.0, 1.0],
    )
    # Registered from the second stamp, so the first stamp is unobserved.
    AustralianElectricityMarkets.set_registration!(gen, _rs_registration(_RS_STAMPS[2] - Minute(5)))
    AustralianElectricityMarkets._set_observed_state_inputs!(sys)
    written = PowerSystems.get_time_series_values(
        PowerSystems.SingleTimeSeries, gen, AustralianElectricityMarkets.NEM_STATE_INPUT_SERIES.initial_mw;
        ignore_scaling_factors = true,
    )
    @test written == [0.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0]
    @test !PowerSystems.has_time_series(gen, PowerSystems.SingleTimeSeries, AustralianElectricityMarkets.NEM_STATE_INPUT_SERIES.fixed_load)
end

@testset "the initial MW series needs the output, not the dispatch mode" begin
    # Registered at every stamp, and the dispatch mode is NaN from the second stamp: `observed_unit_states`
    # throws there, but the series reads only the output.
    sys, gen = _rs_observed_unit(
        "cheap"; mw = fill(50.0, 7), modes = [0.0, NaN, 0.0, 0.0, 0.0, 0.0, 0.0],
    )
    AustralianElectricityMarkets.set_registration!(gen, _rs_registration(_RS_STAMPS[1] - Minute(5)))
    @test_throws ArgumentError AustralianElectricityMarkets.observed_unit_states(gen, _RS_STAMPS)
    AustralianElectricityMarkets._set_observed_state_inputs!(sys)
    written = PowerSystems.get_time_series_values(
        PowerSystems.SingleTimeSeries, gen, AustralianElectricityMarkets.NEM_STATE_INPUT_SERIES.initial_mw;
        ignore_scaling_factors = true,
    )
    @test written == fill(50.0, 7)
end

@testset "the observed-state series of a mock replay system follow the raw observed state and bids" begin
    hive = mktempdir()
    create_mock_data(hive; complete_inputs = true)
    write_mock_interconnector_results(hive)
    db = aem_connect(HiveConfiguration(hive_location = hive))
    t = DateTime(2025, 1, 1, 0, 5)
    sys = nem_system(db, NEMDEConfiguration(); date_range = t:Minute(5):(t + Minute(20)))
    base = PowerSystems.get_base_power(sys)
    names = AustralianElectricityMarkets.NEM_STATE_INPUT_SERIES
    checked = 0
    fixed_checked = 0
    AustralianElectricityMarkets._foreach_nem_dispatch_device(sys) do device
        observed = AustralianElectricityMarkets.get_observed_state(device)
        observed.initial_mw isa _RS_IS.StaticTimeSeriesKey || return
        checked += 1
        stamps = PowerSystems.get_time_series_timestamps(PowerSystems.SingleTimeSeries, device, PowerSystems.get_name(observed.initial_mw))
        raw_initial = _rs_raw(device, observed.initial_mw, stamps)
        raw_mode = _rs_raw(device, observed.dispatch_mode, stamps)

        # Unobserved when the unit is not registered at the stamp, or is a pinned non-scheduled load.
        unit = AustralianElectricityMarkets._nem_unit_data(device)
        registration = unit.registration
        observed_at = [
            !AustralianElectricityMarkets.is_non_scheduled_load(device) &&
                (isnothing(registration) || AustralianElectricityMarkets._is_registered(registration, s))
                for s in stamps
        ]
        expected_initial = [observed_at[i] ? raw_initial[i] : 0.0 for i in eachindex(stamps)]
        @test PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, device, names.initial_mw; ignore_scaling_factors = true) ==
            expected_initial

        # The target nets the generation side and the load side, each applying when it is published, positive
        # and not in fast-start profile modes 1 or 2 (a NaN mode is not in them).
        if AustralianElectricityMarkets._has_fixed_load_bid(device)
            fixed_checked += 1
            cost = AustralianElectricityMarkets._nem_offer_cost(device)
            side_loading(side) = begin
                bid = AustralianElectricityMarkets._energy_bid(cost, side)
                isnothing(bid) || isnothing(bid.fixed_load) ? fill(NaN, length(stamps)) : _rs_raw(device, bid.fixed_load, stamps)
            end
            gen_fl = side_loading(AustralianElectricityMarkets.OfferSide.GEN)
            load_fl = side_loading(AustralianElectricityMarkets.OfferSide.LOAD)
            applies(fl) = [isfinite(fl[i]) && fl[i] > 0 && !(raw_mode[i] in (1.0, 2.0)) for i in eachindex(stamps)]
            gen_on, load_on = applies(gen_fl), applies(load_fl)
            storage = device isa PowerSystems.Storage
            target = [
                (gen_on[i] ? gen_fl[i] : 0.0) + (load_on[i] ? (storage ? -1.0 : 1.0) * load_fl[i] : 0.0)
                    for i in eachindex(stamps)
            ]
            @test PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, device, names.fixed_load; ignore_scaling_factors = true) ≈
                target ./ base
            @test PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, device, names.fixed_load_invoked; ignore_scaling_factors = true) ==
                Float64.(gen_on .| load_on)
        end
        return
    end
    @test checked > 0
    @test fixed_checked > 0
end
