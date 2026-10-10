using PowerSystemCaseBuilder

const PSB = PowerSystemCaseBuilder

"""
    augmented_pscb_system()

`5_bus_hydro_ed_sys` from PowerSystemCaseBuilder, augmented with the three components the NEM
FCAS and constraint types need before every code path can be reached.

The base case carries five `ThermalStandard`, one `HydroDispatch` and two `HydroTurbine` units
across two `Area`s (`"1"` and `"2"`), and is supply-adequate by construction. It has no
`AreaInterchange`, `RenewableDispatch` or `EnergyReservoirStorage`, so on its own
[`add_nem_constraints!`](@ref) can never resolve an `INTERCONNECTOR` term, there is no
semi-scheduled unit to carry a `UIGF` ceiling, and [`set_fcas_bids!`](@ref)'s decremental
(`LOAD`-direction) branch is never entered. One of each is added, named so NEMWEB fixture rows
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
            operation_cost = StorageCost(),
        ),
    )

    return sys
end
