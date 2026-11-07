using TimeSeries: TimeArray

const _ST_IS = PowerSystems.IS
const _ST_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 0, 30))
_st_series(name, values) = SingleTimeSeries(; name, data = TimeArray(_ST_STAMPS, values))
_st_key(component, name::String) = only(k for k in _ST_IS.get_time_series_keys(component) if k.name == name)

_st_bus() = ACBus(;
    number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
    magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
)

function _st_thermal(name, bus)
    return AustralianElectricityMarkets.NEMThermalGen(;
        name, available = true, status = true, bus, active_power = 50.0, reactive_power = 0.0,
        rating = 120.0, active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = nothing,
        ramp_limits = nothing, operation_cost = AustralianElectricityMarkets.NEMOfferCost(), base_power = 100.0,
    )
end

@testset "unit_state reads a key-backed observed state at each stamp" begin
    sys = System(100.0)
    bus = _st_bus()
    add_component!(sys, bus)
    gen = _st_thermal("keyed", bus)
    add_component!(sys, gen)
    mw = [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0]
    modes = [0.0, 1.0, 2.0, 3.0, 4.0, 0.0, 1.0]
    add_time_series!(sys, gen, _st_series("initial_mw", mw))
    add_time_series!(sys, gen, _st_series("dispatch_mode", modes))
    AustralianElectricityMarkets.set_observed_state!(
        gen,
        AustralianElectricityMarkets.NEMObservedState(;
            initial_mw = _st_key(gen, "initial_mw"), dispatch_mode = _st_key(gen, "dispatch_mode"),
        ),
    )

    first_state = AustralianElectricityMarketsSimulations.unit_state(
        AustralianElectricityMarketsSimulations.ObservedState(), gen, _ST_STAMPS[1],
    )
    @test first_state isa AustralianElectricityMarketsSimulations.NEMUnitState
    @test first_state.initial_mw === 10.0
    @test first_state.dispatch_mode === 0

    third_state = AustralianElectricityMarketsSimulations.unit_state(
        AustralianElectricityMarketsSimulations.ObservedState(), gen, _ST_STAMPS[3],
    )
    @test third_state.initial_mw === 30.0
    @test third_state.dispatch_mode === 2
end

@testset "unit_state reads a static observed state" begin
    sys = System(100.0)
    bus = _st_bus()
    add_component!(sys, bus)
    gen = _st_thermal("static", bus)
    add_component!(sys, gen)
    AustralianElectricityMarkets.set_observed_state!(
        gen, AustralianElectricityMarkets.NEMObservedState(; initial_mw = 55, dispatch_mode = 1),
    )
    state = AustralianElectricityMarketsSimulations.unit_state(
        AustralianElectricityMarketsSimulations.ObservedState(), gen, _ST_STAMPS[2],
    )
    @test state == AustralianElectricityMarketsSimulations.NEMUnitState(55.0, 1)
end

@testset "unit_state rejects devices without NEM observed state and the unimplemented source" begin
    sys = System(100.0)
    bus = _st_bus()
    add_component!(sys, bus)
    stock = ThermalStandard(;
        name = "stock_unit", available = true, status = true, bus = bus, active_power = 50.0,
        reactive_power = 0.0, rating = 120.0, active_power_limits = (min = 10.0, max = 100.0),
        reactive_power_limits = nothing, ramp_limits = nothing, operation_cost = ThermalGenerationCost(nothing),
        base_power = 100.0,
    )
    add_component!(sys, stock)
    observed = AustralianElectricityMarketsSimulations.ObservedState()
    @test_throws ArgumentError AustralianElectricityMarketsSimulations.unit_state(observed, stock, _ST_STAMPS[1])

    bare = _st_thermal("bare", bus)
    add_component!(sys, bare)
    @test_throws ArgumentError AustralianElectricityMarketsSimulations.unit_state(observed, bare, _ST_STAMPS[1])

    @test_throws ArgumentError AustralianElectricityMarketsSimulations.unit_state(
        AustralianElectricityMarketsSimulations.SimulatedState(), bare, _ST_STAMPS[1],
    )
end

@testset "NEMDispatchInputs and NEMFCASInputs survive a System JSON round-trip" begin
    AEMS = AustralianElectricityMarketsSimulations
    sys = System(100.0)
    bus = _st_bus()
    add_component!(sys, bus)
    gen = _st_thermal("unit", bus)
    add_component!(sys, gen)
    # Distinct values per series, so a key that resolves to the wrong series fails the value check.
    expected = Dict{String, Vector{Float64}}()
    for (i, name) in enumerate(("energy", "energy_dec", "avail", "uigf", "up", "down", "fcas_offer", "fcas_trap", "agc"))
        values = collect(1.0:length(_ST_STAMPS)) .+ 100.0 * i
        expected[name] = values
        add_time_series!(sys, gen, _st_series(name, values))
    end
    inputs = AEMS.NEMDispatchInputs(;
        energy_offer = _st_key(gen, "energy"), energy_offer_decremental = _st_key(gen, "energy_dec"),
        energy_availability = _st_key(gen, "avail"), energy_availability_decremental = nothing,
        uigf = _st_key(gen, "uigf"), ramp_up = _st_key(gen, "up"), ramp_down = _st_key(gen, "down"),
        fcas = [
            AEMS.NEMFCASInputs(;
                service = AustralianElectricityMarkets.BidType.RAISE6SEC,
                side = AustralianElectricityMarkets.OfferSide.GEN,
                offer = _st_key(gen, "fcas_offer"), trapezium = _st_key(gen, "fcas_trap"), agc_ramp = _st_key(gen, "agc"),
            ),
        ],
    )
    add_supplemental_attribute!(sys, gen, inputs)

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        back_gen = get_component(AustralianElectricityMarkets.NEMThermalGen, restored, "unit")
        back = only(get_supplemental_attributes(AEMS.NEMDispatchInputs, back_gen))

        @test back.energy_offer isa _ST_IS.TimeSeriesKey
        @test isnothing(back.energy_availability_decremental)
        @test AustralianElectricityMarkets._keys_equal(back.energy_offer, inputs.energy_offer)
        @test AustralianElectricityMarkets._keys_equal(back.uigf, inputs.uigf)
        @test length(back.fcas) == 1
        fcas = only(back.fcas)
        @test fcas isa AEMS.NEMFCASInputs
        @test fcas.service == AustralianElectricityMarkets.BidType.RAISE6SEC
        @test fcas.side == AustralianElectricityMarkets.OfferSide.GEN
        @test AustralianElectricityMarkets._keys_equal(fcas.agc_ramp, inputs.fcas[1].agc_ramp)

        # Every present key reads back the values of the series it was built from.
        read_back(key) = _ST_IS.get_time_series_values(
            back_gen, key; start_time = first(_ST_STAMPS), len = length(_ST_STAMPS),
        )
        resolved = Set{String}()
        check(key, built) = if isnothing(key)
            @test isnothing(built)
        else
            @test key isa _ST_IS.TimeSeriesKey
            @test key.name == built.name
            @test read_back(key) == expected[built.name]
            push!(resolved, built.name)
        end
        for field in (
                :energy_offer, :energy_offer_decremental, :energy_availability,
                :energy_availability_decremental, :uigf, :ramp_up, :ramp_down,
            )
            check(getfield(back, field), getfield(inputs, field))
        end
        for (built_fcas, back_fcas) in zip(inputs.fcas, back.fcas)
            for field in (:offer, :trapezium, :agc_ramp)
                check(getfield(back_fcas, field), getfield(built_fcas, field))
            end
        end
        @test resolved == Set(keys(expected))
    end

    @testset "NEMFCASInputs rejects a service that is not an FCAS bid type" begin
        AEMS = AustralianElectricityMarketsSimulations
        @test_throws ArgumentError AEMS.NEMFCASInputs(;
            service = AustralianElectricityMarkets.BidType.ENERGY,
            side = AustralianElectricityMarkets.OfferSide.GEN,
        )
    end
end
