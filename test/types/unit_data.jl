import AustralianElectricityMarkets as AEM
using Dates: DateTime, Minute
import TimeSeries
using TimeSeries: TimeArray

const _UD_IS = PowerSystems.IS

_ud_key(name::String) = _UD_IS.StaticTimeSeriesKey(;
    time_series_type = PowerSystems.SingleTimeSeries, name,
    initial_timestamp = DateTime(2025, 1, 1), resolution = Minute(5), length = 12,
    features = Dict{String, Any}(),
)

const _UD_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 1))
_ud_series(name) = SingleTimeSeries(; name, data = TimeArray(_UD_STAMPS, collect(1.0:length(_UD_STAMPS))))

_ud_bus() = ACBus(;
    number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
    magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
)

function _ud_thermal(name, bus; kwargs...)
    return AEM.NEMThermalGen(;
        name, available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0,
        rating = 120.0, active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = AEM.NEMOfferCost(), base_power = 100.0, kwargs...,
    )
end

_ud_registration() = AEM.NEMRegistration(;
    schedule_type = AEM.ScheduleType.SEMI_SCHEDULED, gen_loss_factor = 1, load_loss_factor = 0,
    registered_from = DateTime(2025, 1, 1), registered_until = DateTime(2030, 1, 1),
)

_ud_telemetry(; uigf = nothing) = AEM.NEMTelemetry(;
    agc_status = true, uigf, ramp_up_limit = 2, ramp_down_limit = 3,
    raise_reg_enablement = (0, 50), lower_reg_enablement = (1.5, 40),
    raise_reg_max_avail = 30, lower_reg_max_avail = 40,
)

@testset "NEMRegistration coerces numbers to Float64" begin
    reg = _ud_registration()
    @test reg.schedule_type == AEM.ScheduleType.SEMI_SCHEDULED
    @test reg.gen_loss_factor === 1.0
    @test reg.load_loss_factor === 0.0
    @test reg == _ud_registration()
    @test reg != AEM.NEMRegistration(;
        schedule_type = AEM.ScheduleType.SCHEDULED, gen_loss_factor = 1, load_loss_factor = 0,
        registered_from = DateTime(2025, 1, 1), registered_until = DateTime(2030, 1, 1),
    )
end

@testset "NEMTelemetry takes static and key-backed values" begin
    tel = _ud_telemetry()
    @test tel.agc_status === true
    @test isnothing(tel.uigf)
    @test tel.ramp_up_limit === 2.0
    @test tel.raise_reg_enablement === (0.0, 50.0)
    @test tel.lower_reg_enablement === (1.5, 40.0)
    @test tel == _ud_telemetry()

    keyed = AEM.NEMTelemetry(;
        agc_status = _ud_key("agc"), uigf = _ud_key("uigf"), ramp_up_limit = _ud_key("up"),
        ramp_down_limit = 3, raise_reg_enablement = _ud_key("raise_enab"), lower_reg_enablement = (1.5, 40),
        raise_reg_max_avail = _ud_key("raise_max"), lower_reg_max_avail = 40,
    )
    @test keyed.uigf isa _UD_IS.TimeSeriesKey
    @test keyed.agc_status isa _UD_IS.TimeSeriesKey
    @test keyed == AEM.NEMTelemetry(;
        agc_status = _ud_key("agc"), uigf = _ud_key("uigf"), ramp_up_limit = _ud_key("up"),
        ramp_down_limit = 3, raise_reg_enablement = _ud_key("raise_enab"), lower_reg_enablement = (1.5, 40),
        raise_reg_max_avail = _ud_key("raise_max"), lower_reg_max_avail = 40,
    )
    @test keyed != tel
end

@testset "NEMObservedState takes static and key-backed values" begin
    obs = AEM.NEMObservedState(; initial_mw = 12, dispatch_mode = 3)
    @test obs.initial_mw === 12.0
    @test obs.dispatch_mode === 3
    @test obs == AEM.NEMObservedState(; initial_mw = 12.0, dispatch_mode = 3)

    keyed = AEM.NEMObservedState(; initial_mw = _ud_key("initial"), dispatch_mode = _ud_key("mode"))
    @test keyed.initial_mw isa _UD_IS.TimeSeriesKey
    @test keyed.dispatch_mode isa _UD_IS.TimeSeriesKey
    @test keyed == AEM.NEMObservedState(; initial_mw = _ud_key("initial"), dispatch_mode = _ud_key("mode"))
    @test keyed != obs
end

@testset "NEM device accessors throw when the struct is missing" begin
    gen = _ud_thermal("bare", _ud_bus())
    @test isnothing(gen.registration) && isnothing(gen.telemetry) && isnothing(gen.observed_state)
    @test_throws ArgumentError AEM.get_registration(gen)
    @test_throws ArgumentError AEM.get_telemetry(gen)
    @test_throws ArgumentError AEM.get_observed_state(gen)

    err = try
        AEM.get_telemetry(gen)
    catch e
        e
    end
    @test err isa ArgumentError
    @test err.msg == "bare has no telemetry; build it with nem_system"
end

@testset "Stock devices throw an ArgumentError naming the device" begin
    stock = ThermalStandard(;
        name = "stock_unit", available = true, status = true, bus = _ud_bus(), active_power = 50.0,
        reactive_power = 0.0, rating = 120.0, active_power_limits = (min = 10.0, max = 100.0),
        reactive_power_limits = nothing, ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing),
        base_power = 100.0,
    )
    for (getter, what) in (
            (AEM.get_registration, "registration"),
            (AEM.get_telemetry, "telemetry"),
            (AEM.get_observed_state, "observed state"),
        )
        err = try
            getter(stock)
        catch e
            e
        end
        @test err isa ArgumentError
        @test err.msg == "stock_unit is not a NEM device, so it has no $what"
    end
end

@testset "NEM device setters replace the struct" begin
    gen = _ud_thermal("settable", _ud_bus())
    reg = _ud_registration()
    @test AEM.set_registration!(gen, reg) === reg
    @test AEM.get_registration(gen) == reg

    later = AEM.NEMRegistration(;
        schedule_type = AEM.ScheduleType.NON_SCHEDULED, gen_loss_factor = 0.5, load_loss_factor = 0.5,
        registered_from = DateTime(2026, 1, 1), registered_until = DateTime(2031, 1, 1),
    )
    AEM.set_registration!(gen, later)
    @test AEM.get_registration(gen) == later

    AEM.set_telemetry!(gen, _ud_telemetry())
    @test AEM.get_telemetry(gen) == _ud_telemetry()

    AEM.set_observed_state!(gen, AEM.NEMObservedState(; initial_mw = 5, dispatch_mode = 0))
    @test AEM.get_observed_state(gen) == AEM.NEMObservedState(; initial_mw = 5.0, dispatch_mode = 0)
end

@testset "NEM device structs round-trip through JSON" begin
    sys = System(100.0)
    bus = _ud_bus()
    add_component!(sys, bus)
    gen = _ud_thermal("unit", bus; registration = _ud_registration())
    add_component!(sys, gen)
    for name in ("initial_mw", "agc", "raise_enab")
        add_time_series!(sys, gen, _ud_series(name))
    end
    key(name) = only(k for k in _UD_IS.get_time_series_keys(gen) if k.name == name)
    AEM.set_telemetry!(
        gen,
        AEM.NEMTelemetry(;
            agc_status = key("agc"), uigf = nothing, ramp_up_limit = 2.0, ramp_down_limit = 3.0,
            raise_reg_enablement = key("raise_enab"), lower_reg_enablement = (1.5, 40.0),
            raise_reg_max_avail = 30.0, lower_reg_max_avail = 40.0,
        ),
    )
    AEM.set_observed_state!(gen, AEM.NEMObservedState(; initial_mw = key("initial_mw"), dispatch_mode = 2))

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        back = get_component(AEM.NEMThermalGen, restored, "unit")

        @test AEM.get_registration(back) == AEM.get_registration(gen)
        @test AEM.get_telemetry(back) == AEM.get_telemetry(gen)
        @test AEM.get_observed_state(back) == AEM.get_observed_state(gen)

        telemetry = AEM.get_telemetry(back)
        @test telemetry.agc_status isa _UD_IS.TimeSeriesKey
        @test telemetry.raise_reg_enablement isa _UD_IS.TimeSeriesKey
        @test telemetry.lower_reg_enablement === (1.5, 40.0)

        # Each key resolves through the reloaded unit to the series it was built from.
        observed = AEM.get_observed_state(back)
        @test observed.initial_mw isa _UD_IS.TimeSeriesKey
        for resolved in (observed.initial_mw, telemetry.agc_status, telemetry.raise_reg_enablement)
            @test _UD_IS.get_time_series(back, resolved) !== nothing
        end
        stored = get_time_series(SingleTimeSeries, back, observed.initial_mw.name).data
        @test TimeSeries.values(stored) == collect(1.0:length(_UD_STAMPS))
    end
end

_ud_stock(name, bus) = ThermalStandard(;
    name, available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0,
    rating = 120.0, active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = nothing,
    ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing), base_power = 100.0,
)

@testset "Stock devices carry NEM unit data as an attribute" begin
    sys = System(100.0)
    bus = _ud_bus()
    add_component!(sys, bus)
    stock = _ud_stock("attached", bus)
    add_component!(sys, stock)

    @test !AEM.has_nem_unit_data(stock)
    @test !AEM.has_nem_unit_data(bus)
    @test isnothing(AEM._nem_offer_cost(stock))
    @test isnothing(AEM._nem_offer_cost(bus))
    @test !AEM.has_registration(stock)
    @test_throws ArgumentError AEM.get_registration(stock)
    @test_throws ArgumentError AEM.get_telemetry(stock)
    @test_throws ArgumentError AEM.get_observed_state(stock)
    @test_throws ArgumentError AEM.set_registration!(stock, _ud_registration())
    @test_throws ArgumentError AEM.set_telemetry!(stock, _ud_telemetry())
    @test_throws ArgumentError AEM.set_observed_state!(stock, AEM.NEMObservedState(; initial_mw = 5, dispatch_mode = 0))

    err = try
        AEM.get_registration(stock)
    catch e
        e
    end
    @test err.msg == "attached is not a NEM device, so it has no registration"
    err = try
        AEM.set_telemetry!(stock, _ud_telemetry())
    catch e
        e
    end
    @test err.msg == "attached has no NEM unit data; attach it with attach_nem_unit_data!"

    unit = AEM.attach_nem_unit_data!(sys, stock)
    @test unit isa AEM.NEMUnitData
    @test AEM.has_nem_unit_data(stock)
    @test AEM._nem_offer_cost(stock) == unit.offer
    @test isnothing(unit.registration) && isnothing(unit.telemetry) && isnothing(unit.observed_state)
    @test_throws ArgumentError AEM.attach_nem_unit_data!(sys, stock)
    @test AEM.has_nem_unit_data(stock)

    # Unit data without a registration reports the registration missing, not a stock device.
    err = try
        AEM.get_registration(stock)
    catch e
        e
    end
    @test err.msg == "attached has no registration; build it with nem_system"

    reg = _ud_registration()
    @test AEM.set_registration!(stock, reg) === reg
    @test AEM.has_registration(stock)
    @test AEM.get_registration(stock) == reg
    @test unit.registration == reg

    later = AEM.NEMRegistration(;
        schedule_type = AEM.ScheduleType.NON_SCHEDULED, gen_loss_factor = 0.5, load_loss_factor = 0.5,
        registered_from = DateTime(2026, 1, 1), registered_until = DateTime(2031, 1, 1),
    )
    AEM.set_registration!(stock, later)
    @test AEM.get_registration(stock) == later

    AEM.set_telemetry!(stock, _ud_telemetry())
    @test AEM.get_telemetry(stock) == _ud_telemetry()

    AEM.set_observed_state!(stock, AEM.NEMObservedState(; initial_mw = 5, dispatch_mode = 0))
    @test AEM.get_observed_state(stock) == AEM.NEMObservedState(; initial_mw = 5.0, dispatch_mode = 0)
end

@testset "Stock device NEM unit data round-trips through JSON" begin
    sys = System(100.0)
    bus = _ud_bus()
    add_component!(sys, bus)
    stock = _ud_stock("stock_json", bus)
    add_component!(sys, stock)
    for name in ("max_avail", "initial_mw", "agc", "raise_enab")
        add_time_series!(sys, stock, _ud_series(name))
    end
    key(name) = only(k for k in _UD_IS.get_time_series_keys(stock) if k.name == name)

    offer = AEM.NEMOfferCost(;
        energy = [
            AEM.NEMEnergyBid(;
                direction = AEM.BidDirection.GEN, offer_curves = PowerSystems.PiecewiseStepData([0.0, 10.0], [25.0]),
                max_avail = key("max_avail"), roc_up = 1.0, roc_down = 2.0,
                fast_start_profile = (t1 = 1.0, t2 = 2.0, t3 = 3.0, t4 = 4.0), normal_status = true,
            ),
            AEM.NEMEnergyBid(;
                direction = AEM.BidDirection.LOAD, offer_curves = PowerSystems.PiecewiseStepData([0.0, 5.0], [10.0]),
                max_avail = 5.0, roc_up = 0.5, roc_down = 0.5,
            ),
        ],
        fcas = [
            AEM.NEMFCASBid(;
                service = AEM.BidType.RAISE6SEC, direction = AEM.BidDirection.GEN,
                offer_curves = PowerSystems.PiecewiseStepData([0.0, 10.0], [25.0]), max_avail = 10.0,
                trapezium = AEM.FCASTrapeziumPoints((0.0, 10.0, 90.0, 100.0)),
            ),
        ],
    )
    unit = AEM.attach_nem_unit_data!(sys, stock; offer)
    AEM.set_registration!(stock, _ud_registration())
    AEM.set_telemetry!(
        stock, AEM.NEMTelemetry(;
            agc_status = key("agc"), uigf = nothing, ramp_up_limit = 2.0, ramp_down_limit = 3.0,
            raise_reg_enablement = key("raise_enab"), lower_reg_enablement = (1.5, 40.0),
            raise_reg_max_avail = 30.0, lower_reg_max_avail = 40.0,
        )
    )
    AEM.set_observed_state!(stock, AEM.NEMObservedState(; initial_mw = key("initial_mw"), dispatch_mode = 2))

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        back = get_component(ThermalStandard, restored, "stock_json")

        @test AEM.has_nem_unit_data(back)
        @test AEM._nem_unit_data(back).offer == unit.offer
        @test AEM.get_registration(back) == AEM.get_registration(stock)
        @test AEM.get_telemetry(back) == AEM.get_telemetry(stock)
        @test AEM.get_observed_state(back) == AEM.get_observed_state(stock)
        @test AEM.get_telemetry(back).agc_status isa _UD_IS.TimeSeriesKey
        @test AEM.get_observed_state(back).initial_mw isa _UD_IS.TimeSeriesKey

        restored_offer = AEM._nem_offer_cost(back)
        @test restored_offer == offer
        @test only(AEM.get_fcas_bids(restored_offer)).max_avail == 10.0
        @test restored_offer.energy[1].max_avail isa _UD_IS.TimeSeriesKey
        @test only(b for b in restored_offer.energy if b.direction == AEM.BidDirection.LOAD).max_avail == 5.0
    end
end
