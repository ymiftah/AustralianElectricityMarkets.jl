import AustralianElectricityMarkets as AEM
using Dates: DateTime, Minute
using TimeSeries: TimeArray

const _ND_IS = PowerSystems.IS

function _nd_bus()
    return ACBus(;
        number = 1, name = "bus", available = true, bustype = ACBusTypes.REF, angle = 0.0,
        magnitude = 1.0, voltage_limits = (min = 0.9, max = 1.1), base_voltage = 230.0,
    )
end

const _ND_STAMPS = collect(DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 1, 1))
_nd_series(name) = SingleTimeSeries(; name, data = TimeArray(_ND_STAMPS, collect(1.0:length(_ND_STAMPS))))

# (counterpart, NEM type, abstract parent, fields shared by both, counterpart's empty cost)
function _nd_cases(bus)
    return [
        (
            ThermalStandard, NEMThermalGen, ThermalGen,
            (;
                available = true, status = true, bus, active_power = 50.0, reactive_power = 5.0, rating = 120.0,
                active_power_limits = (min = 10.0, max = 100.0), reactive_power_limits = (min = -5.0, max = 5.0),
                ramp_limits = (up = 2.0, down = 3.0), base_power = 150.0, time_limits = (up = 1.0, down = 2.0),
                must_run = true, prime_mover_type = PrimeMovers.ST, fuel = ThermalFuels.COAL, time_at_status = 4.0,
            ),
            ThermalGenerationCost(nothing),
        ),
        (
            HydroDispatch, NEMHydroGen, HydroGen,
            (;
                available = true, bus, active_power = 20.0, reactive_power = 1.0, rating = 60.0,
                prime_mover_type = PrimeMovers.HY, active_power_limits = (min = 0.0, max = 55.0),
                reactive_power_limits = (min = -1.0, max = 1.0), ramp_limits = (up = 1.0, down = 1.5),
                time_limits = (up = 1.0, down = 1.0), base_power = 80.0, status = true, time_at_status = 2.0,
            ),
            HydroGenerationCost(nothing),
        ),
        (
            RenewableDispatch, NEMRenewableGen, RenewableGen,
            (;
                available = true, bus, active_power = 30.0, reactive_power = 2.0, rating = 90.0,
                prime_mover_type = PrimeMovers.WT, reactive_power_limits = (min = -2.0, max = 2.0),
                power_factor = 0.9, base_power = 90.0,
            ),
            RenewableGenerationCost(nothing),
        ),
        (
            EnergyReservoirStorage, NEMStorage, Storage,
            (;
                available = true, bus, prime_mover_type = PrimeMovers.BA, storage_technology_type = StorageTech.OTHER_CHEM,
                storage_capacity = 200.0, storage_level_limits = (min = 0.1, max = 0.9),
                initial_storage_capacity_level = 0.5, rating = 50.0, active_power = 10.0,
                input_active_power_limits = (min = 0.0, max = 45.0), output_active_power_limits = (min = 0.0, max = 40.0),
                efficiency = (in = 0.9, out = 0.95), reactive_power = 0.0, reactive_power_limits = (min = -1.0, max = 1.0),
                base_power = 60.0, conversion_factor = 1.0, storage_target = 0.2, cycle_limits = 5000,
            ),
            StorageCost(nothing),
        ),
        (
            InterruptiblePowerLoad, NEMLoad, ControllableLoad,
            (;
                available = true, bus, active_power = 15.0, reactive_power = 1.0, max_active_power = 40.0,
                max_reactive_power = 4.0, base_power = 70.0, conformity = LoadConformity.CONFORMING,
            ),
            LoadCost(nothing),
        ),
    ]
end

# Fields to compare: components compare by name, since they are separate objects after a round trip.
function _nd_same(a, b)
    a isa PowerSystems.Component && return b isa PowerSystems.Component && get_name(a) == get_name(b)
    a isa AbstractVector && return length(a) == length(b) && all(_nd_same.(a, b))
    return a == b
end

function _nd_check_fields(stock, nem; skip = (:internal, :operation_cost))
    for f in fieldnames(typeof(stock))
        f in skip && continue
        @test hasfield(typeof(nem), f)
        @test _nd_same(getfield(stock, f), getfield(nem, f))
    end
    return
end

function _nd_check_getters(stock, nem, sys)
    for units in (UnitSystem.SYSTEM_BASE, UnitSystem.DEVICE_BASE, UnitSystem.NATURAL_UNITS)
        set_units_base_system!(sys, units)
        for f in fieldnames(typeof(stock))
            f in (:internal, :operation_cost, :name) && continue
            getter = getfield(PowerSystems, Symbol(:get_, f))
            @test _nd_same(getter(stock), getter(nem))
        end
    end
    set_units_base_system!(sys, UnitSystem.SYSTEM_BASE)
    return
end

function _nd_conforms(case, offer_bid)
    (Stock, Nem, Parent, fields, stock_cost) = case
    sys = System(100.0)
    add_component!(sys, fields.bus)
    stock = Stock(; name = "stock", fields..., operation_cost = stock_cost)
    nem = Nem(; name = "nem", fields..., operation_cost = NEMOfferCost())
    add_component!(sys, stock)
    add_component!(sys, nem)

    _nd_check_fields(stock, nem; skip = (:internal, :operation_cost, :name))
    _nd_check_getters(stock, nem, sys)
    @test get_operation_cost(nem) == NEMOfferCost()
    @test nem isa Parent
    @test Set(get_name.(get_components(Parent, sys))) == Set(["stock", "nem"])

    reserve = VariableReserve{ReserveUp}(; name = "reserve", available = true, time_frame = 600.0, requirement = 10.0)
    fcas = FCASService(; name = "fcas", region = "NSW1", bid_type = BidType.RAISE6SEC)
    for service in (reserve, fcas)
        add_service!(sys, service, [stock, nem])
        @test length(get_services(nem)) == length(get_services(stock))
    end

    for dev in (stock, nem)
        add_time_series!(sys, dev, _nd_series("energy_offer"))
        add_time_series!(sys, dev, _nd_series("max_avail"))
    end
    keys_by_name = Dict(k.name => k for k in _ND_IS.get_time_series_keys(nem))
    set_operation_cost!(
        nem,
        NEMOfferCost(;
            energy = [
                NEMEnergyBid(;
                    direction = BidDirection.GEN, offer_curves = keys_by_name["energy_offer"],
                    max_avail = keys_by_name["max_avail"], roc_up = 0.0, roc_down = 0.0,
                ),
            ],
        ),
    )

    mktempdir() do dir
        path = joinpath(dir, "sys.json")
        to_json(sys, path; force = true)
        restored = System(path)
        back = get_component(Nem, restored, "nem")
        @test back isa Nem
        _nd_check_fields(nem, back)
        @test get_operation_cost(back) == get_operation_cost(nem)
        @test !isempty(get_energy_bids(get_operation_cost(back)))
        @test has_time_series(back, SingleTimeSeries, "energy_offer")
    end
    return
end

for i in 1:5
    case = _nd_cases(_nd_bus())[i]
    @testset "$(nameof(case[2])) conforms to $(nameof(case[1]))" begin
        _nd_conforms(_nd_cases(_nd_bus())[i], OfferSide.GEN)
    end
end
