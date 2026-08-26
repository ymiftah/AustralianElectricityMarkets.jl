# NEM FCAS market participation as a `PSI.Service` (`NEMFCASService`). Built against the PSCB
# fixture (`test/pscb_fixture.jl`/`test/pscb_nemweb_data.jl`), self-contained like
# `nem_constraints.jl` - not dependent on run order elsewhere in `runtests.jl`.

using HiGHS
import JuMP
import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations

include(joinpath(@__DIR__, "..", "..", "test", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "pscb_nemweb_data.jl"))
include(joinpath(@__DIR__, "template_helpers.jl"))

const FCAS_MARKET_HIVE_DIR = mktempdir()
create_pscb_nemweb_data(FCAS_MARKET_HIVE_DIR)
const FCAS_MARKET_DB = aem_connect(
    HiveConfiguration(; hive_location = FCAS_MARKET_HIVE_DIR, filesystem = "file"),
)
const FCAS_MARKET_START = DateTime(2025, 1, 1, 0, 0)
const FCAS_MARKET_DATE_RANGE = FCAS_MARKET_START:Minute(5):(FCAS_MARKET_START + Hour(2) + Minute(5))

# Sundance's 100 MW floor exceeds fixture demand under no-commitment dispatch; same fix
# `tiers.jl`/`nem_constraints.jl` apply before building any `augmented_pscb_system()` template.
function _fix_thermal_floor!(sys)
    for gen in get_components(ThermalStandard, sys)
        limits = get_active_power_limits(gen)
        set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    return
end

"""
    _native_forecast_start(sys)

`augmented_pscb_system()`'s own baked-in `Deterministic` forecast start (2020-dated hourly) -
the epoch every FCAS series must be retimed to so it shares a common time origin with the
fixture's own `PowerLoad` demand data inside one `DecisionModel`.
"""
function _native_forecast_start(sys)
    load = first(get_components(PowerLoad, sys))
    dts = get_time_series(DeterministicSingleTimeSeries, load, "max_active_power")
    return dts.initial_timestamp
end

"""
    _retime_fcas_series!(sys, new_start)

Moves every `"fcas_trapezium_<SERVICE>"`/`"fcas_curve_<SERVICE>"` series (incremental and
decremental alike) attached by `set_fcas_bids!` to start at `new_start` instead of the real
NEMWEB calendar date used to select them, keeping every row and the original resolution
unchanged - the same epoch-relocation `_retime_gc_series!` (`test/nem_constraints.jl`) applies
to `GenericConstraint` series, needed for the same reason: `augmented_pscb_system()`'s own
demand forecast is 2020-dated, NEMWEB data is real-calendar-dated, and one `DecisionModel` needs
both to share a time origin. Decremental series are retimed too even though nothing in this
package's production code ever reads them (Step 6) - `InfrastructureSystems` requires every
`Deterministic` sharing a (resolution, interval) key to also share `initial_timestamp`, so a
leftover 2025-dated decremental series would block every other series in the same group from
moving to 2020.

Also widens every `fcas_trapezium_<SERVICE>` row's `enablement_min`/`enablement_max` (indices 1
and 4 of the packed `NTuple{7,Float64}`) to `0.0`/`250.0` - `test/pscb_nemweb_data.jl`'s flat
`ENABLEMENTMIN=20.0`/`ENABLEMENTMAX=100.0` (fine for parsing/round-trip tests, which never build
a real constraint from it) exceeds several PSCB units' own `active_power_limits` outright (Alta
tops out at 2.6 MW, `HydroDispatch1` at 5.0 MW), so `FCASLowerSlopeConstraint` alone -
independent of any `FCASCapacityVariable` value - makes the model infeasible before Step 4 can
even test the slope relationship. Breakpoints/`max_avail`/ramp rates are untouched.
"""
function _retime_fcas_series!(sys, new_start::DateTime)
    # Two passes, not remove-then-add per series: removing and re-adding one series at a time
    # leaves other not-yet-retimed series in the same (resolution, interval) group still
    # registered at the old epoch, so the very first retimed add conflicts with them. Collect
    # everything, remove it all, then re-add every series at `new_start`.
    to_retime = Tuple{Device, String, Dates.Period, Any}[]
    for bid_type in AustralianElectricityMarkets.FCAS_BID_TYPES
        service = string(bid_type)
        series_names = (
            "fcas_trapezium_$(service)", "fcas_curve_$(service)",
            "fcas_trapezium_$(service)_decremental", "fcas_curve_$(service)_decremental",
        )
        for series_name in series_names
            for comp in get_components(Device, sys)
                has_time_series(comp, Deterministic, series_name) || continue
                ts_data = get_time_series(Deterministic, comp, series_name)
                resolution = get_resolution(ts_data)
                rows = first(values(get_data(ts_data)))
                if startswith(series_name, "fcas_trapezium_")
                    rows = [(0.0, r[2], r[3], 250.0, r[5], r[6], r[7]) for r in rows]
                end
                push!(to_retime, (comp, series_name, resolution, rows))
            end
        end
    end
    for (comp, series_name, _, _) in to_retime
        remove_time_series!(sys, Deterministic, comp, series_name)
    end
    for (comp, series_name, resolution, rows) in to_retime
        add_time_series!(
            sys, comp,
            Deterministic(;
                name = series_name, data = Dict(new_start => rows),
                resolution = resolution, interval = resolution,
            ),
        )
    end
    return
end

"""
    _prepared_fcas_system(; retime_offset = Minute(0))

An `augmented_pscb_system()` with the thermal floor fixed and every unit's FCAS bid data
(`set_fcas_bids!`) attached over [`FCAS_MARKET_DATE_RANGE`](@ref), retimed to the fixture's own
native forecast epoch plus `retime_offset` ([`_retime_fcas_series!`](@ref)), with
[`add_fcas_services!`](@ref) registering one `NEMFCASService` per bid market.
"""
function _prepared_fcas_system(; retime_offset::Period = Minute(0))
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    set_fcas_bids!(sys, FCAS_MARKET_DB, FCAS_MARKET_DATE_RANGE)
    new_start = _native_forecast_start(sys) + retime_offset
    _retime_fcas_series!(sys, new_start)
    AEMS.add_fcas_services!(sys)
    return sys
end

function _fcas_template()
    template = _t1_template()
    PSI.set_service_model!(template, PSI.ServiceModel(AEMS.NEMFCASService, AEMS.NEMFCASMarket))
    return template
end

@testset "add_fcas_services! registers one NEMFCASService per market with GEN-direction bidders" begin
    sys = _prepared_fcas_system()
    services = collect(get_components(AEMS.NEMFCASService, sys))
    @test Set(get_name.(services)) == Set(string.(AustralianElectricityMarkets.FCAS_BID_TYPES))

    raise6sec = get_component(AEMS.NEMFCASService, sys, "RAISE6SEC")
    contributing = Set(get_name.(get_contributing_devices(sys, raise6sec)))
    @test "Park City" in contributing
    @test "BAT1" in contributing  # BAT1 gets GEN-direction (incremental) bids too

    # get_service round-trips the market's own BidType for every registered service.
    for service in services
        @test string(get_service(service)) == get_name(service)
    end
end

@testset "is_raise_market/is_regulation_market classify all 8 FCAS_BID_TYPES correctly" begin
    expected = Dict(
        BidType.RAISE6SEC => (raise = true, regulation = false),
        BidType.LOWER6SEC => (raise = false, regulation = false),
        BidType.RAISE60SEC => (raise = true, regulation = false),
        BidType.LOWER60SEC => (raise = false, regulation = false),
        BidType.RAISE5MIN => (raise = true, regulation = false),
        BidType.LOWER5MIN => (raise = false, regulation = false),
        BidType.RAISEREG => (raise = true, regulation = true),
        BidType.LOWERREG => (raise = false, regulation = true),
    )
    @test Set(keys(expected)) == Set(AustralianElectricityMarkets.FCAS_BID_TYPES)
    for (bid_type, want) in expected
        @test AustralianElectricityMarkets.is_raise_market(bid_type) == want.raise
        @test AustralianElectricityMarkets.is_regulation_market(bid_type) == want.regulation
    end
end

@testset "Step 6: decremental bidding is out of scope" begin
    sys = _prepared_fcas_system()
    bat1 = get_component(EnergyReservoirStorage, sys, "BAT1")
    @test has_time_series(bat1, Deterministic, "fcas_trapezium_RAISE6SEC_decremental")  # data exists...
    @test isnothing(get_component(AEMS.NEMFCASService, sys, "RAISE6SEC_decremental"))  # ...but no service is ever built from it
end

@testset "Step 1: raising FCAS enablement reduces energy headroom" begin
    sys = _prepared_fcas_system()
    template = _fcas_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(model)
    t = first(PSI.get_time_steps(container))

    raise_var = PSI.get_variable(container, AEMS.FCASCapacityVariable(), AEMS.NEMFCASService, "RAISE6SEC")
    ub_expr = PSI.get_expression(container, PSI.ActivePowerRangeExpressionUB(), ThermalStandard)
    @test JuMP.coefficient(ub_expr["Park City", t], raise_var["Park City", t]) == 1.0

    lower_var = PSI.get_variable(container, AEMS.FCASCapacityVariable(), AEMS.NEMFCASService, "LOWER6SEC")
    lb_expr = PSI.get_expression(container, PSI.ActivePowerRangeExpressionLB(), ThermalStandard)
    @test JuMP.coefficient(lb_expr["Park City", t], lower_var["Park City", t]) == -1.0
end

@testset "Step 2: FCASCapacityVariable bounds come from the trapezium at the matching absolute timestamp" begin
    sys = _prepared_fcas_system()
    template = _fcas_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(model)
    base_power = PSI.get_base_power(container)
    t1, t2 = PSI.get_time_steps(container)
    raise_var = PSI.get_variable(container, AEMS.FCASCapacityVariable(), AEMS.NEMFCASService, "RAISE6SEC")

    # PSCB NEMWEB fixture: MAXAVAIL = 20.0 + i for FCAS bid types, i the 5-min interval index
    # from FCAS_MARKET_START. Model dispatch is hourly: t1 -> i=0 -> 20.0; t2 (1h later = 12
    # five-minute steps on) -> i=12 -> 32.0.
    @test isapprox(JuMP.upper_bound(raise_var["Park City", t1]), 20.0 / base_power; atol = 1.0e-9)
    @test isapprox(JuMP.upper_bound(raise_var["Park City", t2]), 32.0 / base_power; atol = 1.0e-9)
end

@testset "Step 2: a model timestep off the trapezium series' grid fails the build, not silently" begin
    sys = _prepared_fcas_system(; retime_offset = Minute(2))  # off the 5-minute grid
    template = _fcas_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.FAILED
end

@testset "Step 4: trapezium slope constraints bind ActivePowerVariable to FCASCapacityVariable" begin
    sys = _prepared_fcas_system()
    template = _fcas_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(model)
    base_power = PSI.get_base_power(container)
    timestamps = AEMS._container_timestamps(container)
    t1 = first(PSI.get_time_steps(container))
    raise_var = PSI.get_variable(container, AEMS.FCASCapacityVariable(), AEMS.NEMFCASService, "RAISE6SEC")

    # Nothing in Task 4's formulation gives FCASCapacityVariable an economic reason to be
    # nonzero yet (connecting it to a real requirement is Task 5's job) - fix it directly here
    # to exercise the slope coupling itself, independent of that.
    fixed_raise_mw = 4.0
    JuMP.fix(raise_var["Park City", t1], fixed_raise_mw / base_power; force = true)

    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    # Not JuMP.value on the live variable: PSI's dual computation for this MILP (BAT1's binary
    # charge/discharge indicator) fixes/unfixes integer variables around a resolve to get duals
    # for this test's own T1 template's CopperPlateBalanceConstraint (always requested,
    # unconditionally, by `_t1_template`), which leaves the live JuMP model in a
    # JuMP.OptimizeNotCalled() state after
    # PSI.solve! returns even though the run status is SUCCESSFULLY_FINALIZED - the primal values
    # PSI captured *before* that dance are only reachable via its own results API.
    res = PSI.OptimizationProblemResults(model)
    energy_df = PSI.read_variable(res, "ActivePowerVariable__ThermalStandard")
    park_city_mw = only(subset(energy_df, :DateTime => ByRow(==(timestamps[t1])), :name => ByRow(==("Park City")))).value

    resolved = AEMS._resolve_fcas_series(get_component(ThermalStandard, sys, "Park City"), "fcas_trapezium_RAISE6SEC")
    row = AEMS._fcas_series_row(resolved, timestamps[t1])
    trap = AEMS._fcas_trapezium(row)
    eff = scale_trapezium(trap; uigf = nothing, agc_ramp_mw = nothing, is_regulation = false)
    lsc = lower_slope_coeff(eff)
    usc = upper_slope_coeff(eff)
    lower_bound_mw = eff.enablement_min + lsc * fixed_raise_mw

    @test lower_bound_mw > 0.0  # otherwise this test isn't exercising anything
    @test park_city_mw >= lower_bound_mw - 1.0e-6
    @test park_city_mw <= eff.enablement_max - usc * fixed_raise_mw + 1.0e-6
end

@testset "Step 4: the ROCUP/ROCDOWN MW-per-minute to MW-per-hour conversion is not off by 60x" begin
    sys = _prepared_fcas_system()
    resolution = Hour(1)  # this test's own T1 template's hourly dispatch resolution on this fixture
    # PSCB fixture: ROCUP = ROCDOWN = 1.0 MW/min for regulation services (RAISEREG/LOWERREG).
    agc_ramp_mw = AEMS._agc_ramp_mw(1.0, resolution)
    # Deliverable within 1 model hour at 1.0 MW/min: 60.0 MW, not 1.0 MW (no conversion) or
    # 3600.0 MW (converting minutes to seconds instead of hours to minutes).
    @test agc_ramp_mw == 60.0
    @test isnothing(AEMS._agc_ramp_mw(nothing, resolution))
end

@testset "Step 5: FCAS offer bands are costed from fcas_curve_<SERVICE>, cheapest band first" begin
    sys = _prepared_fcas_system()
    template = _fcas_template()
    model = PSI.DecisionModel(template, sys; optimizer = HiGHS.Optimizer, horizon = Hour(2), resolution = Hour(1), interval = Hour(1))
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(model)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    dt = Dates.value(Dates.Millisecond(resolution)) / 3.6e6
    timestamps = AEMS._container_timestamps(container)
    t1 = first(PSI.get_time_steps(container))

    cap_var = PSI.get_variable(container, AEMS.FCASCapacityVariable(), AEMS.NEMFCASService, "RAISE6SEC")

    # No requirement pulls FCASCapacityVariable off zero yet (Task 5's job) - fix it directly so
    # there is a nonzero amount of offer-band cost for this test to actually check.
    cap_mw = 4.0
    JuMP.fix(cap_var["Park City", t1], cap_mw / base_power; force = true)

    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    resolved = AEMS._resolve_fcas_series(get_component(ThermalStandard, sys, "Park City"), "fcas_curve_RAISE6SEC")
    row = AEMS._fcas_series_row(resolved, timestamps[t1])
    x = get_x_coords(row)
    y = get_y_coords(row)
    expected_cost = 0.0
    remaining = cap_mw
    for i in eachindex(y)
        band_width = x[i + 1] - x[i]
        used = min(remaining, band_width)
        expected_cost += used * y[i] * dt
        remaining -= used
        remaining <= 0.0 && break
    end
    @test expected_cost > 0.0  # otherwise this test isn't exercising anything

    # Not JuMP.value on the live variable - see Step 4's test for why (this test's own T1
    # template's CopperPlateBalanceConstraint duals + BAT1's binary make this a MILP whose dual computation
    # leaves the live model in a JuMP.OptimizeNotCalled() state after PSI.solve! returns).
    # FCASOfferCostVariable is dollars, not per-unit of base_power (see its docstring), so no
    # base_power scaling is needed on the value read back here.
    res = PSI.OptimizationProblemResults(model)
    cost_df = PSI.read_variable(res, "FCASOfferCostVariable__NEMFCASService__RAISE6SEC")
    cost_value = only(subset(cost_df, :DateTime => ByRow(==(timestamps[t1])), :name => ByRow(==("Park City")))).value
    @test isapprox(cost_value, expected_cost; atol = 1.0e-6)
end
