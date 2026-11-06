import AustralianElectricityMarkets as AEM
using Dates: DateTime, Minute
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
    @test keyed == keyed
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
    gen = _ud_thermal("unit", bus; registration = _ud_registration(), telemetry = _ud_telemetry())
    add_component!(sys, gen)
    add_time_series!(sys, gen, _ud_series("initial_mw"))
    key = only(k for k in _UD_IS.get_time_series_keys(gen) if k.name == "initial_mw")
    AEM.set_observed_state!(gen, AEM.NEMObservedState(; initial_mw = key, dispatch_mode = 2))

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        back = get_component(AEM.NEMThermalGen, restored, "unit")

        @test AEM.get_registration(back) == AEM.get_registration(gen)
        @test AEM.get_telemetry(back) == AEM.get_telemetry(gen)
        @test AEM.get_observed_state(back) == AEM.get_observed_state(gen)
        restored_key = AEM.get_observed_state(back).initial_mw
        @test restored_key isa _UD_IS.TimeSeriesKey
        @test has_time_series(back, SingleTimeSeries, restored_key.name)
    end
end
