const NDT_MPC = AustralianElectricityMarkets._financial_year_mpc(TOY_START)
const NDT_HOURS = interval_hours(DISPATCH_INTERVAL)
ndt_alta(; initial = 60.0, ramp_up = 100.0, bands = [(100.0, 20.0)], kwargs...) =
    TOY_CHEAP => toy_unit(100.0, bands; initial, ramp_up, kwargs...)
ndt_park(; initial = 60.0, ramp_up = 100.0, bands = [(100.0, 80.0)]) = TOY_EXPENSIVE => toy_unit(100.0, bands; initial, ramp_up)
ndt_battery(args...; kwargs...) = [TOY_BATTERY => toy_battery(args...; kwargs...)]
ndt_pump(price; kwargs...) = ["PUMP" => toy_load(30.0, price; kwargs...)]
ndt_capped(rhs_mw) = nem_toy_system(
    [ndt_alta(), ndt_park()], 120.0; mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, TOY_CHEAP, rhs_mw),
)

# Each case: a toy System, its demand and the MW, price and objective it clears at. `"<battery> out"` and
# `"<battery> in"` are a battery's directions; a scheduled load's name is its consumption.
const NDT_CASES = [
    (
        label = "merit order: the cheaper unit is filled first",
        sys = () -> nem_toy_system([ndt_alta(), ndt_park()], 120.0), demand = 120.0,
        mw = [TOY_CHEAP => 100.0, TOY_EXPENSIVE => 20.0], price = 80.0, objective = (100.0 * 20.0 + 20.0 * 80.0) * NDT_HOURS,
    ),
    (
        label = "multi-band stack: bands load in price order, the marginal one partially",
        sys = () -> nem_toy_system(
            [ndt_alta(; bands = [(20.0, 20.0), (30.0, 50.0), (50.0, 300.0)]), ndt_park(; bands = [(100.0, 1000.0)])], 40.0,
        ),
        demand = 40.0, mw = [TOY_CHEAP => 40.0, TOY_EXPENSIVE => 0.0], price = 50.0,
        objective = (20.0 * 20.0 + 20.0 * 50.0) * NDT_HOURS, bands = [20.0, 20.0, 0.0],
    ),
    (
        label = "a binding ramp holds the cheap unit at INITIALMW + rate x 5 min",
        sys = () -> nem_toy_system([ndt_alta(; initial = 50.0, ramp_up = 1.0), ndt_park(; initial = 50.0, ramp_up = 20.0)], 90.0),
        demand = 90.0, mw = [TOY_CHEAP => 55.0, TOY_EXPENSIVE => 35.0], price = 80.0,
    ),
    (
        label = "with the ramp relaxed, merit order is restored",
        sys = () -> nem_toy_system([ndt_alta(; initial = 50.0, ramp_up = 20.0), ndt_park(; initial = 50.0, ramp_up = 20.0)], 90.0),
        demand = 90.0, mw = [TOY_CHEAP => 90.0, TOY_EXPENSIVE => 0.0], price = 20.0,
    ),
    (
        # Its $1/MWh load band is never worth clearing, so it does not charge.
        label = "a battery discharges when the area price is above its generation offer",
        sys = () -> nem_toy_system([ndt_park()], 100.0; batteries = ndt_battery(60.0, 20.0, 10.0, 1.0; initial = 0.0, ramp_up = 100.0)),
        demand = 100.0, mw = ["$TOY_BATTERY out" => 60.0, "$TOY_BATTERY in" => 0.0, TOY_EXPENSIVE => 40.0], price = 80.0,
        objective = (60.0 * 20.0 + 40.0 * 80.0) * NDT_HOURS,
    ),
    (
        label = "a battery charges when its load bid is above the marginal generator's price",
        sys = () -> nem_toy_system([ndt_alta()], 40.0; batteries = ndt_battery(10.0, 1000.0, 30.0, 50.0; initial = 0.0, ramp_up = 100.0)),
        demand = 40.0, mw = ["$TOY_BATTERY in" => 30.0, "$TOY_BATTERY out" => 0.0, TOY_CHEAP => 70.0], price = 20.0,
        objective = (70.0 * 20.0 - 30.0 * 50.0) * NDT_HOURS,
    ),
    (
        # From -10 MW net a 1 MW/min up rate caps net at -5; zero generation availability pins In at 5.
        # The battery's band ties with Alta's at 20, so the price carries the tie-break penalty within tolerance.
        label = "a net ramp limit binding across zero",
        sys = () -> nem_toy_system(
            [ndt_alta()], 0.0;
            batteries = ndt_battery(10.0, 20.0, 10.0, 30.0; initial = -10.0, ramp_up = 1.0, ramp_down = 100.0, gen_avail = 0.0, load_avail = 5.0),
        ),
        demand = 0.0, mw = ["$TOY_BATTERY out" => 0.0, "$TOY_BATTERY in" => 5.0, TOY_CHEAP => 5.0], price = 20.0,
        objective = (5.0 * 20.0 - 5.0 * 30.0) * NDT_HOURS,
    ),
    (
        # Ramping holds net generation at 15 MW against 10 MW availability: 5 MW of priced availability violation.
        label = "a net ramp-down floor can violate generation availability at its price",
        sys = () -> nem_toy_system(
            [ndt_alta(; initial = 0.0, bands = [(100.0, 100.0)])], 15.0;
            batteries = ndt_battery(100.0, 5.0, 100.0, 1.0; initial = 20.0, ramp_up = 100.0, ramp_down = 1.0, gen_avail = 10.0),
        ),
        demand = 15.0, mw = ["$TOY_BATTERY out" => 15.0, "$TOY_BATTERY in" => 0.0, TOY_CHEAP => 0.0],
        objective = (15.0 * 5.0 + 5.0 * AustralianElectricityMarkets.ENERGY_MAX_AVAIL_CVP_FACTOR * NDT_MPC) * NDT_HOURS,
    ),
    (
        label = "a net ramp-up ceiling can violate load availability at its price",
        sys = () -> nem_toy_system(
            [ndt_alta()], 0.0;
            batteries = ndt_battery(100.0, 1.0, 100.0, 1000.0; initial = -20.0, ramp_up = 1.0, ramp_down = 100.0, gen_avail = 0.0, load_avail = 10.0),
        ),
        demand = 0.0, mw = ["$TOY_BATTERY in" => 15.0, "$TOY_BATTERY out" => 0.0, TOY_CHEAP => 15.0],
        objective = (15.0 * 20.0 - 15.0 * 1000.0 + 5.0 * AustralianElectricityMarkets.ENERGY_MAX_AVAIL_CVP_FACTOR * NDT_MPC) * NDT_HOURS,
    ),
    (
        label = "discharge is capped by the generation-side MAXAVAIL, not the cheaper price",
        sys = () -> nem_toy_system([ndt_alta()], 50.0; batteries = ndt_battery(10.0, 5.0, 10.0, 1.0; initial = 0.0, ramp_up = 100.0, load_avail = 0.0)),
        demand = 50.0, mw = ["$TOY_BATTERY out" => 10.0, "$TOY_BATTERY in" => 0.0, TOY_CHEAP => 40.0], price = 20.0,
        objective = (40.0 * 20.0 + 10.0 * 5.0) * NDT_HOURS,
    ),
    (
        label = "charge is capped by the load-side MAXAVAIL, not the attractive price",
        sys = () -> nem_toy_system(
            [ndt_alta()], 0.0; batteries = ndt_battery(10.0, 1.0, 20.0, 1000.0; initial = 0.0, ramp_up = 100.0, gen_avail = 0.0, load_avail = 8.0),
        ),
        demand = 0.0, mw = ["$TOY_BATTERY in" => 8.0, "$TOY_BATTERY out" => 0.0, TOY_CHEAP => 8.0], price = 20.0,
        objective = (8.0 * 20.0 - 8.0 * 1000.0) * NDT_HOURS,
    ),
    (
        # A binding `<=` carries a negative dual under minimisation.
        label = "a 70 MW generic constraint on the cheap unit binds, forcing the expensive unit up",
        sys = () -> ndt_capped(70.0), demand = 120.0, mw = [TOY_CHEAP => 70.0, TOY_EXPENSIVE => 50.0], price = 80.0,
        objective = (70.0 * 20.0 + 50.0 * 80.0) * NDT_HOURS, gc_price = -60.0,
    ),
    (
        label = "a slack 120 MW generic constraint leaves merit order unaffected",
        sys = () -> ndt_capped(120.0), demand = 120.0, mw = [TOY_CHEAP => 100.0, TOY_EXPENSIVE => 20.0], price = 80.0, gc_price = 0.0,
    ),
    (
        label = "a scheduled load clears when its bid is above the price",
        sys = () -> nem_toy_system(
            [ndt_alta(; initial = 40.0), ndt_park(; initial = 0.0)], 40.0; loads = ndt_pump(50.0; initial = 30.0, ramp_up = 100.0),
        ),
        demand = 40.0, mw = ["PUMP" => 30.0, TOY_CHEAP => 70.0, TOY_EXPENSIVE => 0.0], price = 20.0,
        objective = (70.0 * 20.0 - 30.0 * 50.0) * NDT_HOURS,
    ),
    (
        label = "a scheduled load does not clear when its bid is below the price",
        sys = () -> nem_toy_system([ndt_alta(; initial = 40.0)], 40.0; loads = ndt_pump(10.0; initial = 0.0, ramp_up = 100.0)),
        demand = 40.0, mw = ["PUMP" => 0.0, TOY_CHEAP => 40.0],
    ),
    (
        # The pump's $10/MWh bid would not clear at $20/MWh, but a 20 MW fixed loading holds it there.
        label = "a scheduled load's fixed loading holds its consumption against its bid",
        sys = () -> nem_toy_system(
            [ndt_alta(; initial = 40.0)], 40.0; loads = ndt_pump(10.0; initial = 0.0, ramp_up = 100.0),
            mutate! = function (sys, stamps)
                _toy_energy_bid!(
                    sys, PSY.get_component(InterruptiblePowerLoad, sys, "PUMP"), AustralianElectricityMarkets.BidDirection.LOAD, stamps,
                    fill(PSY.PiecewiseStepData([0.0, 30.0], [10.0]), length(stamps)), fill(30.0, length(stamps));
                    fixed_load = fill(20.0, length(stamps)),
                )
                return
            end,
        ),
        demand = 40.0, mw = ["PUMP" => 20.0, TOY_CHEAP => 60.0],
    ),
    (
        # 5 MW + 2 MW/min over 5 minutes caps the pump at 15 MW, below its 30 MW availability.
        label = "a scheduled load is limited by its ramp rate",
        sys = () -> nem_toy_system([ndt_alta(; initial = 40.0)], 40.0; loads = ndt_pump(50.0; initial = 5.0, ramp_up = 2.0, availability = 30.0)),
        demand = 40.0, mw = ["PUMP" => 15.0, TOY_CHEAP => 55.0],
    ),
    (
        label = "a scheduled load is limited by its availability",
        sys = () -> nem_toy_system([ndt_alta(; initial = 40.0)], 40.0; loads = ndt_pump(50.0; initial = 5.0, ramp_up = 100.0, availability = 10.0)),
        demand = 40.0, mw = ["PUMP" => 10.0, TOY_CHEAP => 50.0],
    ),
]

@testset "$(c.label)" for c in NDT_CASES
    out = solve_toy(c.sys())
    solved = merge(
        out.dispatch_mw, out.load_mw,
        Dict("$k out" => v for (k, v) in out.battery_out_mw), Dict("$k in" => v for (k, v) in out.battery_in_mw),
    )
    # Every case clears its demand from net generation, with no unit ramp row broken.
    @test sum(values(out.dispatch_mw)) - sum(values(out.load_mw); init = 0.0) ≈ c.demand atol = TOY_TOLERANCE
    @test all(≈(0.0; atol = TOY_TOLERANCE), (out.ramp_slack_mw..., out.storage_ramp_slack_mw...))
    @test [solved[k] for k in first.(c.mw)] ≈ last.(c.mw) atol = TOY_TOLERANCE
    haskey(c, :price) && @test out.price ≈ c.price atol = TOY_TOLERANCE
    haskey(c, :objective) && @test out.objective ≈ c.objective rtol = 1.0e-8 atol = TOY_TOLERANCE
    haskey(c, :bands) && @test [out.band_mw[(TOY_CHEAP, b)] for b in eachindex(c.bands)] ≈ c.bands atol = TOY_TOLERANCE
    haskey(c, :gc_price) && @test out.constraint_price["N_TOY_LIMIT"] ≈ c.gc_price atol = TOY_TOLERANCE
end

@testset "a ramp-up ceiling below zero is violated at 1155 x the Market Price Cap" begin
    # INITIALMW = -1 MW with a zero ramp rate gives x <= -1 against x >= 0, as for an offline
    # hydro unit with a slightly negative reading. The ramp row is elastic, the bound is not:
    # the unit stays at 0 MW and the 1 MW up slack is priced at 1155 x MPC for one interval.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = -1.0, ramp_up = 0.0)],
        0.0,
    )
    out = solve_toy(sys)
    mpc = AustralianElectricityMarkets._financial_year_mpc(TOY_START)

    @test out.dispatch_mw[TOY_CHEAP] ≈ 0.0 atol = TOY_TOLERANCE
    @test out.ramp_slack_mw.up ≈ 1.0 atol = TOY_TOLERANCE
    @test out.ramp_slack_mw.down ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ AustralianElectricityMarkets.UNIT_RAMP_CVP_FACTOR * mpc * interval_hours(DISPATCH_INTERVAL) rtol = 1.0e-8
    violations = read_constraint_violations(out.results, sys)
    @test violations.family == ["unit_ramp"]
    @test only(violations.MW) ≈ 1.0 atol = TOY_TOLERANCE
end

@testset "a battery's ramp floor can exceed its rating with priced availability" begin
    # INITIALMW = -50 (charging) with a zero up rate pins net <= -50, above the battery's 40 MW
    # input rating. NEMDE breaks MaxAvail and the rating before the ramp row, so the input
    # Availability absorbs the 10 MW conflict; static ratings do not impose another hard bound.
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
        0.0;
        batteries = [
            TOY_BATTERY => toy_battery(
                10.0, 1000.0, 50.0, 0.0; initial = -50.0, ramp_up = 0.0, gen_avail = 0.0, load_avail = 40.0,
            ),
        ],
        mutate! = function (s, _)
            battery = PSY.get_component(EnergyReservoirStorage, s, TOY_BATTERY)
            PSY.set_input_active_power_limits!(battery, (min = 0.0, max = 40.0))
            PSY.set_output_active_power_limits!(battery, (min = 0.0, max = 5.0))
            return
        end,
    )
    out = solve_toy(sys)
    mpc = AustralianElectricityMarkets._financial_year_mpc(TOY_START)

    @test out.battery_in_mw[TOY_BATTERY] ≈ 50.0 atol = TOY_TOLERANCE
    # Static ratings impose no bound on either direction's variable.
    @test !any(
        PSI.JuMP.has_upper_bound(PSI.get_variable(out.container, V(), EnergyReservoirStorage)[TOY_BATTERY, 1])
            for V in (PSI.ActivePowerOutVariable, PSI.ActivePowerInVariable)
    )
    @test out.storage_ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
    @test out.objective ≈ (50.0 * 20.0 + 10.0 * AustralianElectricityMarkets.ENERGY_MAX_AVAIL_CVP_FACTOR * mpc) * interval_hours(DISPATCH_INTERVAL) rtol = 1.0e-8

    @testset "the storage ramp slack is priced at 1155 x MPC" begin
        slack = PSI.get_variable(out.container, NEMUnitSlack(), EnergyReservoirStorage, "unit_ramp|up")[TOY_BATTERY, 1]
        coefficient = PSI.JuMP.objective_function(PSI.get_jump_model(out.container)).terms[slack]
        @test coefficient ≈
            PSY.get_base_power(sys) * interval_cost_coefficient(AustralianElectricityMarkets.UNIT_RAMP_CVP_FACTOR * mpc, TOY_RESOLUTION)
    end
end

@testset "constraint_violations directions follow the relaxed row's sense" begin
    direction = AEMS._violation_direction
    sys = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 40.0, ramp_up = 100.0)],
        40.0;
        loads = ["PUMP" => toy_load(30.0, 50.0; initial = 5.0, ramp_up = 100.0)],
    )
    for (name, bid_type) in (("S_RAISEREG", BidType.RAISEREG), ("S_LOWERREG", BidType.LOWERREG))
        service = FCASService(; name, region = "1", bid_type = bid_type)
        PSY.add_service!(sys, service, [PSY.get_component(PSY.StaticInjection, sys, n) for n in (TOY_CHEAP, "PUMP")])
    end
    # Capacity rows: the sense follows the `_lower` suffix whatever the device.
    @test direction(sys, FCASSlack, "joint_capacity|S_RAISEREG_upper", TOY_CHEAP, "up") == "up"
    @test direction(sys, FCASSlack, "joint_capacity|S_RAISEREG_lower", TOY_CHEAP, "up") == "down"
    @test direction(sys, FCASSlack, "joint_capacity|S_RAISEREG_gen_lower", "PUMP", "up") == "down"
    @test direction(sys, FCASSlack, "joint_capacity|S_RAISEREG_load_upper", "PUMP", "up") == "up"
    # Joint ramping: a generator's RAISEREG row is the `<=` form, a load's LOWERREG row is.
    @test direction(sys, FCASSlack, "joint_ramping|S_RAISEREG", TOY_CHEAP, "up") == "up"
    @test direction(sys, FCASSlack, "joint_ramping|S_LOWERREG", TOY_CHEAP, "up") == "down"
    @test direction(sys, FCASSlack, "joint_ramping|S_LOWERREG", "PUMP", "up") == "up"
    @test direction(sys, FCASSlack, "joint_ramping|S_RAISEREG", "PUMP", "up") == "down"
    @test direction(sys, NEMUnitSlack, "unit_ramp|down", TOY_CHEAP, "down") == "down"
end

@testset "penalty ordering: a lower CVP row breaks before a higher one" begin
    mpc = AustralianElectricityMarkets._financial_year_mpc(TOY_START)

    @testset "the area balance (150) breaks before the unit ramp (1155)" begin
        # A 100 MW load against a unit that can climb 5 MW from 0: the 95 MW shortfall is cheaper
        # to leave unserved at 150 x MPC than to buy with a ramp violation at 1155 x MPC.
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 1.0)],
            100.0,
        )
        out = solve_toy(sys)
        violations = read_constraint_violations(out.results, sys)

        @test out.dispatch_mw[TOY_CHEAP] ≈ 5.0 atol = TOY_TOLERANCE
        @test out.ramp_slack_mw.up ≈ 0.0 atol = TOY_TOLERANCE
        @test violations.family == ["area_balance"]
        # An equality row: the slack that adds supply (demand left unserved) is the "up" deficit.
        @test violations.direction == ["up"]
        @test only(violations.MW) ≈ 95.0 atol = TOY_TOLERANCE
        @test out.objective ≈
            (5.0 * 20.0 + 95.0 * AustralianElectricityMarkets.AREA_BALANCE_CVP_FACTOR * mpc) * interval_hours(DISPATCH_INTERVAL) rtol = 1.0e-8
    end

    @testset "an ordinary interval reports no violation" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 60.0, ramp_up = 100.0)],
            40.0,
        )
        out = solve_toy(sys)
        @test isempty(read_constraint_violations(out.results, sys))
    end
end

@testset "price-tied bands clear pro rata to band MW" begin
    third = "Solitude"
    function tied_toy(prices; ramp_up = (100.0, 100.0, 100.0), load = 168.0)
        return nem_toy_system(
            [
                TOY_CHEAP => toy_unit(168.0, [(168.0, prices[1])]; initial = 0.0, ramp_up = ramp_up[1]),
                TOY_EXPENSIVE => toy_unit(46.0, [(46.0, prices[2])]; initial = 0.0, ramp_up = ramp_up[2]),
                third => toy_unit(122.0, [(122.0, prices[3])]; initial = 0.0, ramp_up = ramp_up[3]),
            ],
            load,
        )
    end

    @testset "three tied units share the load in proportion to band MW" begin
        out = solve_toy(tied_toy((-984.5, -984.5, -984.5)))
        @test out.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-5
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 23.0 atol = 1.0e-5
        @test out.dispatch_mw[third] ≈ 61.0 atol = 1.0e-5
        @test out.price ≈ -984.5 atol = TOY_TOLERANCE
        @test out.objective ≈ -984.5 * 168.0 * interval_hours(DISPATCH_INTERVAL) atol = 1.0e-6
    end

    @testset "prices within the tolerance are tied, prices beyond it are not" begin
        near = solve_toy(tied_toy((10.0, 10.0 + 0.01 * TIE_BREAK_CVP_FACTOR, 10.0); load = 168.0))
        @test near.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-5
        @test near.dispatch_mw[third] ≈ 61.0 atol = 1.0e-5
        apart = solve_toy(tied_toy((10.0, 20.0, 10.0); load = 168.0))
        @test apart.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test apart.dispatch_mw[TOY_CHEAP] ≈ 168.0 * 168.0 / 290.0 atol = 1.0e-5
        @test apart.dispatch_mw[third] ≈ 168.0 * 122.0 / 290.0 atol = 1.0e-5
    end

    @testset "non-tied units keep merit order, price and objective" begin
        out = solve_toy(tied_toy((10.0, 30.0, 20.0); load = 200.0))
        @test out.dispatch_mw[TOY_CHEAP] ≈ 168.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[third] ≈ 32.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 0.0 atol = TOY_TOLERANCE
        @test out.price ≈ 20.0 atol = TOY_TOLERANCE
        @test out.objective ≈ (168.0 * 10.0 + 32.0 * 20.0) * interval_hours(DISPATCH_INTERVAL) atol = TOY_TOLERANCE
    end

    @testset "a ramp-bound tied unit relaxes the tie without moving the price or objective" begin
        # Cheap unit can reach only 5 * 8 = 40 MW; its fill fraction cannot match the others.
        out = solve_toy(tied_toy((10.0, 10.0, 10.0); ramp_up = (8.0, 100.0, 100.0)))
        @test out.dispatch_mw[TOY_CHEAP] ≤ 40.0 + TOY_TOLERANCE
        @test sum(values(out.dispatch_mw)) ≈ 168.0 atol = TOY_TOLERANCE
        @test out.price ≈ 10.0 atol = TOY_TOLERANCE
        @test out.objective ≈ 10.0 * 168.0 * interval_hours(DISPATCH_INTERVAL) atol = 1.0e-4
        # The two unconstrained units stay pro rata to each other.
        @test out.dispatch_mw[TOY_EXPENSIVE] / 46.0 ≈ out.dispatch_mw[third] / 122.0 atol = 1.0e-4
    end

    @testset "a held-back unit in the middle of the sort order does not skew the others" begin
        # Park City sorts between Alta and Solitude; its 2 MW/min ramp caps it at 10 MW.
        out = solve_toy(tied_toy((10.0, 10.0, 10.0); ramp_up = (100.0, 2.0, 100.0)))
        @test out.dispatch_mw[TOY_EXPENSIVE] ≤ 10.0 + TOY_TOLERANCE
        @test sum(values(out.dispatch_mw)) ≈ 168.0 atol = TOY_TOLERANCE
        @test out.dispatch_mw[TOY_CHEAP] / 168.0 ≈ out.dispatch_mw[third] / 122.0 atol = 1.0e-4
    end

    @testset "a group-limited tied set stays pro rata beside held-back tied bands, at production solver settings" begin
        # Alta, Park City and Solitude share a 168 MW group limit; Sundance and Brighton bid the
        # same price in three bands each and sit far below them (ramp), so every tied pair with
        # them is violated.
        group = (TOY_CHEAP, TOY_EXPENSIVE, third)
        mutate! = (sys, stamps) -> add_toy_generic_constraint!(sys, stamps, group, 168.0)
        sys = nem_toy_system(
            [
                TOY_CHEAP => toy_unit(168.0, [(168.0, -984.5)]; initial = 0.0, ramp_up = 100.0),
                TOY_EXPENSIVE => toy_unit(46.0, [(46.0, -984.5)]; initial = 0.0, ramp_up = 100.0),
                third => toy_unit(122.0, [(122.0, -984.5)]; initial = 0.0, ramp_up = 100.0),
                "Sundance" => toy_unit(300.0, fill((100.0, -984.5), 3); initial = 0.0, ramp_up = 4.0),
                "Brighton" => toy_unit(300.0, fill((100.0, -984.5), 3); initial = 0.0, ramp_up = 6.0),
            ],
            218.0;
            mutate!,
        )
        production = optimizer_with_attributes(
            HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0, "mip_abs_gap" => 1.0e-10,
        )
        out = solve_toy(sys; optimizer = production)
        @test out.dispatch_mw["Sundance"] ≈ 20.0 atol = 1.0e-4
        @test out.dispatch_mw["Brighton"] ≈ 30.0 atol = 1.0e-4
        @test out.dispatch_mw[TOY_CHEAP] ≈ 84.0 atol = 1.0e-3
        @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 23.0 atol = 1.0e-3
        @test out.dispatch_mw[third] ≈ 61.0 atol = 1.0e-3
    end

    @testset "a battery offer band ties with a thermal band across device types" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0)],
            100.0;
            batteries = [TOY_BATTERY => toy_battery(100.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
        )
        out = solve_toy(sys)
        @test out.dispatch_mw[TOY_CHEAP] ≈ 50.0 atol = 1.0e-5
        @test out.battery_out_mw[TOY_BATTERY] ≈ 50.0 atol = 1.0e-5
    end

    @testset "tied load bids of two batteries clear pro rata" begin
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(50.0, [(50.0, 5.0)]; initial = 0.0, ramp_up = 100.0)],
            0.0;
            batteries = [
                "batt1" => toy_battery(10.0, 1000.0, 60.0, 50.0; initial = 0.0, ramp_up = 100.0),
                "batt2" => toy_battery(10.0, 1000.0, 40.0, 50.0; initial = 0.0, ramp_up = 100.0),
            ],
        )
        out = solve_toy(sys)
        @test out.battery_in_mw["batt1"] ≈ 30.0 atol = 1.0e-5
        @test out.battery_in_mw["batt2"] ≈ 20.0 atol = 1.0e-5
    end
end

@testset "a tied contributor without its scale series fails the build" begin
    unscaled = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        100.0;
        tie_break_scales = false,
    )
    PSY.add_service!(
        unscaled, EnergyTieBreak(; name = TIE_BREAK_SERVICE_NAME),
        [PSY.get_component(ThermalStandard, unscaled, n) for n in (TOY_CHEAP, TOY_EXPENSIVE)],
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, unscaled)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(unscaled; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("tie-break: 2 unit(s) with price-tied bands carry no tie-break scale forecast: Alta, Park City.", log)
    @test occursin("Build the System with nem_system(db, NEMDEConfiguration(); date_range)", log)
end

@testset "a unit carrying tie-break scales must be modelled" begin
    tie_model() = PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME)
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        100.0,
    )
    # No ThermalStandard model: PowerSimulations finds no modelled contributor of the service.
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(template, TIE_BREAK_SERVICE_NAME, tie_model())
    @test_throws r"contributing devices for service energy_tie_break is empty" toy_model(sys; template)

    # The battery ties with the thermal unit but has no device model.
    mixed = nem_toy_system(
        [TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0)],
        100.0;
        batteries = [TOY_BATTERY => toy_battery(100.0, 10.0, 50.0, 1.0; initial = 0.0, ramp_up = 100.0)],
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    PSI.set_device_model!(template, ThermalStandard, NEMDispatch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(template, TIE_BREAK_SERVICE_NAME, tie_model())
    model = toy_model(mixed; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("tie-break: 1 unit(s) carry tie-break scales but have no energy offer band variables in the model: $TOY_BATTERY.", log)
end

@testset "an energy offer series without a recorded bid fails the build by name" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(100.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        100.0,
    )
    AustralianElectricityMarkets._nem_unit_data(PSY.get_component(ThermalStandard, sys, TOY_CHEAP)).offer = NEMOfferCost()
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    status, log = _toy_build_log(toy_model(sys; template))
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("$TOY_CHEAP has an energy offer series but no NEMEnergyBid on the", log)
end

@testset "empty bands priced alike do not form tie groups" begin
    # Both units hold a zero-width top band at the same price; only their first bands are tied.
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0), (0.0, 15_000.0)]; initial = 30.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0), (0.0, 15_000.0)]; initial = 30.0, ramp_up = 100.0),
        ],
        50.0,
    )
    series(name, band) = PSY.has_time_series(PSY.get_component(ThermalStandard, sys, name), PSY.SingleTimeSeries, "tie_break_scale_$band")
    for name in (TOY_CHEAP, TOY_EXPENSIVE)
        @test series(name, 1)
        @test !series(name, 2)
    end
    out = solve_toy(sys)
    # The tied first bands share the 50 MW pro rata to their 60 and 40 MW widths.
    @test out.dispatch_mw[TOY_CHEAP] ≈ 30.0 atol = TOY_TOLERANCE
    @test out.dispatch_mw[TOY_EXPENSIVE] ≈ 20.0 atol = TOY_TOLERANCE
end

@testset "tie-break scale rows skip devices excluded by the device model's filter_function" begin
    third = "Solitude"
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(168.0, [(168.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(46.0, [(46.0, 10.0), (10.0, 30.0)]; initial = 0.0, ramp_up = 100.0),
            third => toy_unit(122.0, [(122.0, 10.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        168.0,
    )
    # Park City ties with the other two units on band 1 but is filtered out of the model, so its row is left out.
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(
        template,
        PSI.DeviceModel(
            ThermalStandard, NEMDispatch;
            attributes = Dict{String, Any}("filter_function" => d -> PSY.get_name(d) != TOY_EXPENSIVE),
        ),
    )
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(sys; template)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    key = PSI.ParameterKey(TieBreakScaleParameter, ThermalStandard, AEMS._tie_break_meta(1, false))
    # Rows are keyed by the time-series UUID of each device's scale series.
    ts_uuid(n) = string(PSI.IS.get_time_series_uuid(PSY.SingleTimeSeries, PSY.get_component(ThermalStandard, sys, n), "tie_break_scale_1"))
    @test Set(axes(PSI.get_parameter_array(container, key), 1)) == Set(ts_uuid(n) for n in (TOY_CHEAP, third))
end

@testset "a template without the tie-break service model has no tie-break rows" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys; tie_breaks = false)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    @test isempty(PSI.get_service_models(template))
    model = toy_model(sys; template)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, TieBreakSlackUp, EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    @test !PSI.has_container_key(container, TieBreakConstraint, EnergyTieBreak, TIE_BREAK_SERVICE_NAME)
    jm = PSI.get_jump_model(container)
    @test !any(v -> occursin("TieBreakSlack", PSI.JuMP.name(v)), PSI.JuMP.all_variables(jm))
end

@testset "duals requested on the tie-break service model fail the build" begin
    sys = nem_toy_system(
        [
            TOY_CHEAP => toy_unit(100.0, [(60.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
            TOY_EXPENSIVE => toy_unit(100.0, [(40.0, 20.0)]; initial = 0.0, ramp_up = 100.0),
        ],
        50.0,
    )
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.AreaBalancePowerModel; use_slacks = true))
    set_nem_dispatch_models!(template, sys; tie_breaks = false)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_service_model!(
        template, TIE_BREAK_SERVICE_NAME,
        PSI.ServiceModel(EnergyTieBreak, TieBreakMarket, TIE_BREAK_SERVICE_NAME; duals = [TieBreakConstraint]),
    )
    model = toy_model(sys; template)
    status, log = _toy_build_log(model)
    @test status == PSI.ModelBuildStatus.FAILED
    @test occursin("requests duals TieBreakConstraint, which it does not register", log)
end

@testset "Market Price Cap penalties are priced at build on a non-area-balance network model" begin
    sys = nem_toy_system([TOY_CHEAP => toy_unit(100.0, [(100.0, 20.0)]; initial = 0.0, ramp_up = 100.0)], 50.0)
    template = PSI.ProblemTemplate(PSI.NetworkModel(PSI.CopperPlatePowerModel; use_slacks = false))
    set_nem_dispatch_models!(template, sys)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    model = toy_model(sys; template)
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    container = PSI.get_optimization_container(model)
    @test !PSI.has_container_key(container, PSI.SystemBalanceSlackUp, PSY.Area)
    # Each unit ramp slack's price: base power x interval coefficient of its CVP factor x the build-time cap.
    # The JuMP objective is read because building folds the invariant terms into the variant expression.
    expected = PSI.get_base_power(container) * AEMS.interval_cost_coefficient(
        AustralianElectricityMarkets.UNIT_RAMP_CVP_FACTOR * AEMS._container_market_price_cap(container, TOY_START),
        PSI.get_resolution(container),
    )
    objective = PSI.JuMP.objective_function(PSI.get_jump_model(container))
    slack = PSI.get_variable(container, AEMS.NEMUnitSlack(), ThermalStandard, "unit_ramp|up")
    @test [PSI.JuMP.coefficient(objective, slack[TOY_CHEAP, t]) for t in axes(slack)[2]] ≈ fill(expected, length(axes(slack)[2]))
end

@testset "typed storage fixed-loading rows preserve net injection and invocation" begin
    for (side, target, invoked) in ((OfferSide.GEN, 20.0, 1.0), (OfferSide.LOAD, -20.0, 1.0), (OfferSide.GEN, 20.0, 0.0))
        sys = nem_toy_system(
            [TOY_CHEAP => toy_unit(200.0, [(200.0, 20.0)]; initial = 80.0, ramp_up = 100.0)],
            80.0;
            batteries = [TOY_BATTERY => toy_battery(40.0, 50.0, 40.0, 1.0; initial = 0.0, ramp_up = 100.0)],
            mutate! = function (sys, stamps)
                storage = PSY.get_component(EnergyReservoirStorage, sys, TOY_BATTERY)
                n = length(stamps)
                _toy_energy_bid!(
                    sys, storage, AustralianElectricityMarkets.BidDirection.GEN, stamps,
                    fill(PSY.PiecewiseStepData([0.0, 40.0], [50.0]), n), fill(40.0, n);
                    fixed_load = side == OfferSide.GEN ? fill(20.0, n) : nothing,
                )
                _toy_energy_bid!(
                    sys, storage, AustralianElectricityMarkets.BidDirection.LOAD, stamps,
                    fill(PSY.PiecewiseStepData([0.0, 40.0], [1.0]), n), fill(40.0, n);
                    fixed_load = side == OfferSide.LOAD ? fill(20.0, n) : nothing,
                )
                # A fast-start profile (mode 1) leaves the loading uninvoked while the bid still carries it.
                set_toy_unit_field!(sys, storage, stamps, :dispatch_mode, fill(iszero(invoked) ? 1.0 : 0.0, n))
                return
            end,
        )
        out = solve_toy(sys)
        net = out.battery_out_mw[TOY_BATTERY] - out.battery_in_mw[TOY_BATTERY]
        @test net ≈ (iszero(invoked) ? 0.0 : target) atol = TOY_TOLERANCE
        container = out.container
        T = EnergyReservoirStorage
        U = PSI.get_variable(container, PSI.ActivePowerOutVariable(), T)[TOY_BATTERY, 1]
        D = PSI.get_variable(container, PSI.ActivePowerInVariable(), T)[TOY_BATTERY, 1]
        for meta in ("upper", "lower")
            row = PSI.get_constraint(container, AEMS.NEMUnitConstraint(), T, "fixed_load|$meta")[TOY_BATTERY, 1]
            @test abs(PSI.JuMP.normalized_coefficient(row, U)) == 1.0
            @test PSI.JuMP.normalized_coefficient(row, U) == -PSI.JuMP.normalized_coefficient(row, D)
        end
    end
end
