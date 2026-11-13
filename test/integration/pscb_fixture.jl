using PowerSystemCaseBuilder

const PSB = PowerSystemCaseBuilder

# Replaces a stock generator with a freshly built stock device of the same type, keeping its name, bus,
# limits and parameters, and its stock operation cost.
function _replace_with_nem_device!(sys, stock::ThermalStandard)
    nem = ThermalStandard(;
        name = get_name(stock), available = get_available(stock), status = get_status(stock),
        bus = get_bus(stock), active_power = get_active_power(stock), reactive_power = get_reactive_power(stock),
        rating = get_rating(stock), active_power_limits = get_active_power_limits(stock),
        reactive_power_limits = get_reactive_power_limits(stock), ramp_limits = get_ramp_limits(stock),
        operation_cost = ThermalGenerationCost(nothing), base_power = get_base_power(stock), time_limits = get_time_limits(stock),
        must_run = get_must_run(stock), prime_mover_type = get_prime_mover_type(stock), fuel = get_fuel(stock),
        time_at_status = get_time_at_status(stock),
    )
    remove_component!(sys, stock)
    add_component!(sys, nem)
    return nem
end

function _replace_with_nem_device!(sys, stock::HydroDispatch)
    nem = HydroDispatch(;
        name = get_name(stock), available = get_available(stock), bus = get_bus(stock),
        active_power = get_active_power(stock), reactive_power = get_reactive_power(stock),
        rating = get_rating(stock), prime_mover_type = get_prime_mover_type(stock),
        active_power_limits = get_active_power_limits(stock), reactive_power_limits = get_reactive_power_limits(stock),
        ramp_limits = get_ramp_limits(stock), time_limits = get_time_limits(stock), base_power = get_base_power(stock),
        status = get_status(stock), time_at_status = get_time_at_status(stock), operation_cost = HydroGenerationCost(nothing),
    )
    remove_component!(sys, stock)
    add_component!(sys, nem)
    return nem
end

function _replace_with_nem_device!(sys, stock::HydroTurbine)
    nem = HydroDispatch(;
        name = get_name(stock), available = get_available(stock), bus = get_bus(stock),
        active_power = get_active_power(stock), reactive_power = get_reactive_power(stock),
        rating = get_rating(stock), prime_mover_type = get_prime_mover_type(stock),
        active_power_limits = get_active_power_limits(stock), reactive_power_limits = get_reactive_power_limits(stock),
        ramp_limits = get_ramp_limits(stock), time_limits = get_time_limits(stock), base_power = get_base_power(stock),
        operation_cost = HydroGenerationCost(nothing),
    )
    remove_component!(sys, stock)
    add_component!(sys, nem)
    return nem
end

function _replace_with_nem_device!(sys, stock::RenewableDispatch)
    nem = RenewableDispatch(;
        name = get_name(stock), available = get_available(stock), bus = get_bus(stock),
        active_power = get_active_power(stock), reactive_power = get_reactive_power(stock), rating = get_rating(stock),
        prime_mover_type = get_prime_mover_type(stock), reactive_power_limits = get_reactive_power_limits(stock),
        power_factor = get_power_factor(stock), operation_cost = RenewableGenerationCost(nothing), base_power = get_base_power(stock),
    )
    remove_component!(sys, stock)
    add_component!(sys, nem)
    return nem
end

"""
    augmented_pscb_system()

`5_bus_hydro_ed_sys` from PowerSystemCaseBuilder, augmented with the three components the NEM
FCAS and constraint types need before every code path can be reached.

The base case carries five `ThermalStandard`, one `HydroDispatch` and two `HydroTurbine` units
across two `Area`s (`"1"` and `"2"`), and is supply-adequate by construction. It has no
`AreaInterchange`, `RenewableDispatch` or `EnergyReservoirStorage`, so on its own
`_add_nem_constraints!` can never resolve an `INTERCONNECTOR` term, there is no
semi-scheduled unit to carry a `UIGF` ceiling, and the bids' decremental
(`LOAD`-direction) branch is never entered. One of each is added, the storage as an `EnergyReservoirStorage`, which the FCAS offer views read, named so NEMWEB fixture rows
can key to them by `DUID`.

Returned in `NATURAL_UNITS`, so component limits read as MW.

# Returns
A `PowerSystems.System`.
"""
function augmented_pscb_system()
    sys = PSB.build_system(PSISystems, "5_bus_hydro_ed_sys")
    set_units_base_system!(sys, "NATURAL_UNITS")

    area_1 = get_component(Area, sys, "1")
    area_2 = get_component(Area, sys, "2")
    bus_1 = first(get_components(b -> get_area(b) == area_1, ACBus, sys))
    bus_2 = first(get_components(b -> get_area(b) == area_2, ACBus, sys))

    add_component!(
        sys,
        AreaInterchange(;
            name = "IC1",
            available = true,
            active_power_flow = 0.0,
            from_area = area_1,
            to_area = area_2,
            flow_limits = (from_to = 100.0, to_from = 100.0),
        ),
    )

    add_component!(
        sys,
        RenewableDispatch(;
            name = "SOLAR1",
            available = true,
            bus = bus_2,
            active_power = 0.0,
            reactive_power = 0.0,
            rating = 50.0,
            prime_mover_type = PrimeMovers.PVe,
            reactive_power_limits = nothing,
            power_factor = 1.0,
            operation_cost = RenewableGenerationCost(; variable = CostCurve(LinearCurve(0.0))),
            base_power = 100.0,
        ),
    )

    add_component!(
        sys,
        EnergyReservoirStorage(;
            name = "BAT1",
            available = true,
            bus = bus_1,
            prime_mover_type = PrimeMovers.BA,
            storage_technology_type = StorageTech.LIB,
            storage_capacity = 100.0,
            storage_level_limits = (min = 0.0, max = 1.0),
            initial_storage_capacity_level = 0.5,
            rating = 25.0,
            active_power = 0.0,
            input_active_power_limits = (min = 0.0, max = 25.0),
            output_active_power_limits = (min = 0.0, max = 25.0),
            efficiency = (in = 0.9, out = 0.9),
            reactive_power = 0.0,
            reactive_power_limits = nothing,
            base_power = 100.0,
        ),
    )

    AustralianElectricityMarkets._set_replay_inputs!(sys)
    return sys
end


"""
    nem_pscb_system()

[`augmented_pscb_system`](@ref) with its thermal, hydro and renewable units rebuilt as replay units, each
carrying a `NEMUnitData` with an empty `NEMOfferCost` and a [`NEMRegistration`](@ref), so [`set_market_bids!`](@ref) can record their bids. The base
case's reserve service and hydro reservoirs, which reference the stock units, are removed.

# Returns
A `PowerSystems.System` in `NATURAL_UNITS`.
"""
function nem_pscb_system()
    sys = augmented_pscb_system()
    for service in collect(get_components(s -> !(s isa FCASService), Service, sys))
        remove_component!(sys, service)
    end
    for reservoir in collect(get_components(HydroReservoir, sys))
        remove_component!(sys, reservoir)
    end
    for T in (ThermalStandard, HydroDispatch, HydroTurbine, RenewableDispatch)
        for stock in collect(get_components(T, sys))
            _replace_with_nem_device!(sys, stock)
        end
    end
    # Every NEM device is scheduled, open over the fixture dates, with unit loss factors.
    for T in NEM_DISPATCH_DEVICE_TYPES, device in get_components(T, sys)
        attach_nem_unit_data!(sys, device)
        set_registration!(
            device,
            NEMRegistration(;
                schedule_type = ScheduleType.SCHEDULED, gen_loss_factor = 1.0, load_loss_factor = 1.0,
                registered_from = DateTime(2000, 1, 1), registered_until = DateTime(2999, 12, 31),
            ),
        )
        # A static observed state: the unit starts at its active power in dispatch mode 0.
        set_observed_state!(
            device, NEMObservedState(; initial_mw = Float64(get_active_power(device)), dispatch_mode = 0),
        )
    end
    AustralianElectricityMarkets._set_replay_inputs!(sys)
    return sys
end
