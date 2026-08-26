# Task 5: FCAS-typed `GenericConstraint` terms resolving to `NEMFCASMarket`'s `FCASCapacityVariable`,
# and `compute_fcas_prices`'s dual-to-regional-price attribution. Needs both `TermConstraint` and
# `NEMFCASMarket` registered together, so builds its own combined fixture rather than reusing
# `nem_constraints.jl`'s or `fcas_market.jl`'s single-service ones. Self-contained like both of
# those files - not dependent on run order elsewhere in `runtests.jl`.

using HiGHS
using TimeSeries: TimeArray
import PowerSimulations as PSI
const AEMS = AustralianElectricityMarketsSimulations
const ISOPT = PSI.IS.Optimization

include(joinpath(@__DIR__, "..", "..", "test", "pscb_fixture.jl"))
include(joinpath(@__DIR__, "..", "..", "test", "pscb_nemweb_data.jl"))
include(joinpath(@__DIR__, "template_helpers.jl"))

const FCAS_PRICING_HIVE_DIR = mktempdir()
create_pscb_nemweb_data(FCAS_PRICING_HIVE_DIR)
const FCAS_PRICING_DB = aem_connect(
    HiveConfiguration(; hive_location = FCAS_PRICING_HIVE_DIR, filesystem = "file"),
)
const FCAS_PRICING_START = DateTime(2025, 1, 1, 0, 0)
const FCAS_PRICING_DATE_RANGE =
    FCAS_PRICING_START:Minute(5):(FCAS_PRICING_START + Hour(2) + Minute(5))

function _fix_thermal_floor!(sys)
    for gen in get_components(ThermalStandard, sys)
        limits = get_active_power_limits(gen)
        set_active_power_limits!(gen, (min = 0.0, max = limits.max))
    end
    return
end

function _native_forecast_params(sys)
    load = first(get_components(PowerLoad, sys))
    dts = get_time_series(DeterministicSingleTimeSeries, load, "max_active_power")
    return (
        initial_timestamp = dts.initial_timestamp, interval = dts.interval,
        count = dts.count, horizon = dts.horizon,
    )
end

"""
    _retime_gc_series!(sys, params) -> Dict{String, Float64}

Retimes every added `GenericConstraint`'s `"rhs"`/`"invoked"` series to `params`'s epoch as a
flat constant (the fixture's own first raw point, per `GENCONID`) - mirrors `test/nem_constraints.jl`'s
`_retime_gc_series!` (no override support needed here). Returns the constant RHS used per
`GENCONID`, since it's no longer cheaply re-derivable from `sys` once `transform_single_time_series!`
has windowed it.
"""
function _retime_gc_series!(sys, params)
    n_steps = Int(params.horizon / params.interval)
    n_raw = params.count + n_steps - 1
    times = collect(
        params.initial_timestamp:params.interval:(params.initial_timestamp + params.interval * (n_raw - 1)),
    )
    rhs_values = Dict{String, Float64}()
    for gc in get_components(GenericConstraint, sys)
        name = get_name(gc)
        rhs_value = first(values(get_data(get_time_series(Deterministic, gc, "rhs"))))[1]
        rhs_values[name] = rhs_value
        remove_time_series!(sys, Deterministic, gc, "rhs")
        remove_time_series!(sys, Deterministic, gc, "invoked")
        add_time_series!(sys, gc, SingleTimeSeries(; name = "rhs", data = TimeArray(times, fill(rhs_value, n_raw))))
        add_time_series!(sys, gc, SingleTimeSeries(; name = "invoked", data = TimeArray(times, fill(1.0, n_raw))))
    end
    transform_single_time_series!(sys, params.horizon, params.interval)
    return rhs_values
end

"Retimes every `\"fcas_trapezium_<SERVICE>\"`/`\"fcas_curve_<SERVICE>\"` series to `new_start` and widens the trapezium's enablement bounds - mirrors `test/fcas_market.jl`'s `_retime_fcas_series!` exactly (same reasons: shared time origin with the fixture's 2020-dated demand, and the fixture's flat `ENABLEMENTMIN`/`MAX` otherwise makes several PSCB units infeasible)."
function _retime_fcas_series!(sys, new_start::DateTime)
    to_retime = Tuple{Device, String, Dates.Period, Any}[]
    for bid_type in AustralianElectricityMarkets.FCAS_BID_TYPES
        service = string(bid_type)
        for series_name in (
                "fcas_trapezium_$(service)", "fcas_curve_$(service)",
                "fcas_trapezium_$(service)_decremental", "fcas_curve_$(service)_decremental",
            )
            for comp in get_components(Device, sys)
                has_time_series(comp, Deterministic, series_name) || continue
                ts_data = get_time_series(Deterministic, comp, series_name)
                resolution = PowerSystems.get_resolution(ts_data)
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
            Deterministic(; name = series_name, data = Dict(new_start => rows), resolution = resolution, interval = resolution),
        )
    end
    return
end

"""
    _prepared_combined_system()

An `augmented_pscb_system()` with both [`add_nem_constraints!`](@ref) and
[`set_fcas_bids!`](@ref)/[`add_fcas_services!`](@ref) applied and retimed to the same native
forecast epoch, so `TermConstraint` and `NEMFCASMarket` can be registered together in one
`DecisionModel`.
"""
function _prepared_combined_system()
    sys = augmented_pscb_system()
    _fix_thermal_floor!(sys)
    add_nem_constraints!(sys, FCAS_PRICING_DB, FCAS_PRICING_DATE_RANGE)
    set_fcas_bids!(sys, FCAS_PRICING_DB, FCAS_PRICING_DATE_RANGE)
    params = _native_forecast_params(sys)
    rhs_values = _retime_gc_series!(sys, params)
    _retime_fcas_series!(sys, params.initial_timestamp)
    AEMS.add_fcas_services!(sys)
    return sys, rhs_values
end

function _combined_template()
    template = _t1_template()
    PSI.set_service_model!(template, PSI.ServiceModel(AEMS.NEMFCASService, AEMS.NEMFCASMarket))
    PSI.set_service_model!(
        template,
        PSI.ServiceModel(GenericConstraint, AEMS.TermConstraint; duals = [AEMS.NEMConstraintLimit]),
    )
    return template
end

@testset "Step 1: an FCAS-typed term resolves to FCASCapacityVariable and binds" begin
    sys, rhs_values = _prepared_combined_system()
    template = _combined_template()
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer,
        horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT

    container = PSI.get_optimization_container(model)
    # F_R1_RAISE6SEC (region "1") is skipped whole: HydroDispatch1-3 sit in region 1, carry
    # RAISE6SEC bid data, but this test's own T1 template never models HydroDispatch with an
    # ActivePowerVariable, so they never get an FCASCapacityVariable slot either - same reason
    # N_HYDRO_LIMIT is skipped in `test/nem_constraints.jl`. F_R2_LOWERREG (region "2" = Solitude
    # + SOLAR1, both modeled) is the only FCAS-typed constraint that survives.
    skipped = AEMS._skip_reasons!(container, sys)
    @test get(skipped, "F_R1_RAISE6SEC", nothing) === :unmodeled_fcas_service
    @test !haskey(skipped, "F_R2_LOWERREG")

    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    res = PSI.OptimizationProblemResults(model)
    lower_var = PSI.read_variable(res, "FCASCapacityVariable__NEMFCASService__LOWERREG")
    base_power = PSI.get_model_base_power(res)

    # F_R2_LOWERREG's LHS: Solitude's LOWERREG capacity counted twice (once via its own UnitTerm
    # on CP_C, once via the region-"2" RegionTerm) plus SOLAR1's (region term only) - must meet
    # its (now-constant, see `_retime_gc_series!`) RHS exactly, not just approximately clear it,
    # since nothing bounds capacity from above except cost.
    rhs = rhs_values["F_R2_LOWERREG"]
    for t in PSI.get_time_steps(container)
        dt = AEMS._container_timestamps(container)[t]
        solitude_mw = only(subset(lower_var, :DateTime => ByRow(==(dt)), :name => ByRow(==("Solitude")))).value * base_power
        solar_mw = only(subset(lower_var, :DateTime => ByRow(==(dt)), :name => ByRow(==("SOLAR1")))).value * base_power
        lhs = 2 * solitude_mw + solar_mw
        @test isapprox(lhs, rhs; atol = 1.0e-3)
    end
end

@testset "Step 3: compute_fcas_prices sums TermConstraint duals per (region, service), skipping unbuilt constraints" begin
    sys, _ = _prepared_combined_system()
    template = _combined_template()
    model = PSI.DecisionModel(
        template, sys; optimizer = HiGHS.Optimizer,
        horizon = Hour(2), resolution = Hour(1), interval = Hour(1),
    )
    @test PSI.build!(model; output_dir = mktempdir()) == PSI.ModelBuildStatus.BUILT
    PSI.solve!(model)
    @test PSI.get_run_status(model) == PSI.RunStatus.SUCCESSFULLY_FINALIZED

    res = PSI.OptimizationProblemResults(model)
    base_power = PSI.get_model_base_power(res)
    prices = AEMS.compute_fcas_prices(res, sys)

    # F_R2_LOWERREG is the PSCB fixture's only FCAS-typed constraint with exactly one governing
    # constraint per (region, service) pair - it can't exercise the "sum of several constraints"
    # branch directly, but that branch is the same per-row accumulation loop this does exercise.
    container = PSI.get_optimization_container(model)
    nem_keys = [
        k for k in PSI.get_constraint_keys(container)
            if ISOPT.get_entry_type(k) === AEMS.NEMConstraintLimit
    ]
    dual_key = only(k for k in nem_keys if k.meta == "F_R2_LOWERREG")
    raw_dual = PSI.read_dual(res, dual_key)

    lowerreg_prices = subset(prices, :REGIONID => ByRow(==("2")), :BIDTYPE => ByRow(==(BidType.LOWERREG)))
    @test nrow(lowerreg_prices) == nrow(raw_dual)
    for row in eachrow(raw_dual)
        price_row = only(subset(lowerreg_prices, :SETTLEMENTDATE => ByRow(==(row.DateTime))))
        @test isapprox(price_row.RRP, row.value / base_power; atol = 1.0e-9)
    end

    # F_R1_RAISE6SEC was skipped whole (previous testset) - never registered a dual, so region
    # "1" contributes nothing to the returned prices at all, not a zero/missing row.
    @test isempty(subset(prices, :REGIONID => ByRow(==("1"))))
end
