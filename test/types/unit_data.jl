import AustralianElectricityMarkets as AEM
using Dates: DateTime, Minute
import TimeSeries
using TimeSeries: TimeArray

const _UD_IS = PowerSystems.IS

const _UD_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 1))
_ud_series(name) = SingleTimeSeries(; name, data = TimeArray(_UD_STAMPS, collect(1.0:length(_UD_STAMPS))))

_ud_bus() = ACBus(;
    number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
    magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
)

function _ud_thermal(name, bus)
    return ThermalStandard(;
        name, available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0,
        rating = 120.0, active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing), base_power = 100.0,
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

@testset "Stock devices carry NEM unit data as an attribute" begin
    sys = System(100.0)
    bus = _ud_bus()
    add_component!(sys, bus)
    stock = _ud_thermal("attached", bus)
    add_component!(sys, stock)

    @test !AEM.has_nem_unit_data(stock)
    @test isnothing(AEM._nem_offer_cost(stock))
    @test !AEM.has_registration(stock)
    @test_throws ArgumentError AEM.get_telemetry(stock)
    @test_throws ArgumentError AEM.get_observed_state(stock)
    @test_throws ArgumentError AEM.set_registration!(stock, _ud_registration())
    @test_throws ArgumentError AEM.set_observed_state!(stock, AEM.NEMObservedState(; initial_mw = 5, dispatch_mode = 0))

    @test_throws ArgumentError("attached is not a NEM device, so it has no registration") AEM.get_registration(stock)
    @test_throws ArgumentError("attached has no NEM unit data; attach it with attach_nem_unit_data!") AEM.set_telemetry!(stock, _ud_telemetry())

    unit = AEM.attach_nem_unit_data!(sys, stock)
    @test AEM.has_nem_unit_data(stock)
    @test AEM._nem_offer_cost(stock) == unit.offer
    @test isnothing(unit.registration) && isnothing(unit.telemetry) && isnothing(unit.observed_state)
    @test_throws ArgumentError AEM.attach_nem_unit_data!(sys, stock)
    @test AEM.has_nem_unit_data(stock)

    # Unit data without a registration reports the registration missing, not a stock device.
    @test_throws ArgumentError("attached has no registration; build it with nem_system") AEM.get_registration(stock)

    reg = _ud_registration()
    @test AEM.set_registration!(stock, reg) === reg
    @test AEM.has_registration(stock)
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
    stock = _ud_thermal("stock_json", bus)
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
    AEM.attach_nem_unit_data!(sys, stock; offer)
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

        @test AEM._nem_offer_cost(back) == offer
        @test AEM.get_registration(back) == AEM.get_registration(stock)
        @test AEM.get_telemetry(back) == AEM.get_telemetry(stock)
        @test AEM.get_observed_state(back) == AEM.get_observed_state(stock)

        # Each key resolves through the reloaded unit to the series it was built from.
        initial_mw = AEM.get_observed_state(back).initial_mw
        stored = get_time_series(SingleTimeSeries, back, initial_mw.name).data
        @test TimeSeries.values(stored) == collect(1.0:length(_UD_STAMPS))
        @test _UD_IS.get_time_series(back, AEM.get_telemetry(back).agc_status) !== nothing
    end
end
