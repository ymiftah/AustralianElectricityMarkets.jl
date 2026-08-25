"""
Abstract supertype for a model fidelity tier. T0/T1 are real `PowerSimulations.jl` problems —
see [`build_template`](@ref); T2 adds `GenericConstraint` enforcement on top of T1's template
(see the `generic_constraints.jl` extension) rather than being a different problem.
"""
abstract type FidelityTier end

"Copper plate, energy only. Mirrors `docs/literate/economic_dispatch.jl` exactly."
struct T0CopperPlate <: FidelityTier end
tier_name(::T0CopperPlate) = "T0"

"Per-region balances with interconnector limits. Mirrors `docs/literate/interchanges.jl` exactly."
struct T1Interconnected <: FidelityTier end
tier_name(::T1Interconnected) = "T1"

"""
One tier's solved outcome for one interval.

# Fields
- `settlement_date`: interval end.
- `tier`: the tier's short name.
- `status`: `:optimal`, `:infeasible`, or `:error`.
- `dispatch`: `DUID -> MW`, the last time step's (i.e. `settlement_date`'s) `ActivePowerVariable`
  value.
- `prices`: `\$/MWh`, keyed by `REGIONID` for T1's per-area prices, or by a single reference-bus
  key for T0's one system-wide price; from Task 3 onward, additionally `"<REGION>|<SERVICE>"`
  for FCAS prices.
- `binding`: `GENCONID -> shadow price`. Empty below T2.
"""
struct IntervalResult
    settlement_date::DateTime
    tier::String
    status::Symbol
    dispatch::Dict{String, Float64}
    prices::Dict{String, Float64}
    binding::Dict{String, Float64}
end

_empty_result(tier, settlement_date, status) = IntervalResult(
    settlement_date, tier_name(tier), status,
    Dict{String, Float64}(), Dict{String, Float64}(), Dict{String, Float64}(),
)

"""
    build_template(::T0CopperPlate)

The exact `ProblemTemplate` from `docs/literate/economic_dispatch.jl`.
"""
function build_template(::T0CopperPlate)
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.Line, PSI.StaticBranch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicDispatch)
    PSI.set_device_model!(template, PSY.HydroDispatch, HydroPowerSimulations.HydroDispatchRunOfRiver)
    # `duals` must be requested explicitly for PSI to store them; neither doc page reads prices,
    # so this is the one addition beyond `economic_dispatch.jl`'s template.
    PSI.set_network_model!(
        template,
        PSI.NetworkModel(PSI.CopperPlatePowerModel; duals = [PSI.CopperPlateBalanceConstraint]),
    )
    return template
end

"""
    build_template(::T1Interconnected)

The exact `ProblemTemplate` from `docs/literate/interchanges.jl`.
"""
function build_template(::T1Interconnected)
    template = PSI.ProblemTemplate()
    PSI.set_device_model!(template, PSY.Line, PSI.StaticBranch)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)
    PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.RenewableFullDispatch)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalBasicUnitCommitment)
    PSI.set_device_model!(template, PSY.HydroDispatch, HydroPowerSimulations.HydroDispatchRunOfRiver)
    # `duals` must be requested explicitly for PSI to store them; neither doc page reads prices,
    # so this is the one addition beyond `interchanges.jl`'s template.
    PSI.set_network_model!(
        template,
        PSI.NetworkModel(
            PSI.AreaBalancePowerModel; use_slacks = true, duals = [PSI.CopperPlateBalanceConstraint],
        ),
    )
    PSI.set_device_model!(template, PSY.AreaInterchange, PSI.StaticBranch)
    return template
end

"""
    _seed_interval_time_series!(tier, sys, db, settlement_date)

Attaches a two-step (5-minute resolution) `Deterministic` time series window covering
`settlement_date` for demand, renewables and hydro — the same setters
`docs/literate/economic_dispatch.jl`/`interchanges.jl` call for a whole `date_range`, called
here for exactly one interval so each [`solve_interval`](@ref) call is self-contained and
independently parallelisable (design spec §3: no PSI `Simulation` state carryover between
intervals). `set_market_bids!` is only called for [`T1Interconnected`](@ref), mirroring
`interchanges.jl` exactly — `economic_dispatch.jl`'s `ThermalBasicDispatch` has no `OnVariable`
for `MarketBidCost`'s piecewise constraint to reference and instead relies on `ThermalStandard`'s
default `ThermalGenerationCost` set at `nem_system` parse time.

Requires `sys`'s `PowerLoad` components to be named `"<REGIONID> Load"` (as `nem_system`
builds them) — `set_demand!` matches time series columns to component names on that
convention. It is therefore only usable against a `nem_system`-built `System`, not against
`AustralianElectricityMarketsSimulations/test/pscb_fixture.jl`'s `augmented_pscb_system()`,
whose `PowerLoad`s keep PowerSystemCaseBuilder's own bus-based names.
"""
function _seed_interval_time_series!(tier::FidelityTier, sys, db, settlement_date::DateTime)
    # Two raw points are needed: `SingleTimeSeries` infers its resolution from consecutive
    # timestamps, and the setters' internal filter is half-open (`start <= x < stop`), so the
    # range must extend one step past `settlement_date` to keep it.
    date_range = (settlement_date - Minute(5)):Minute(5):(settlement_date + Minute(5))
    set_demand!(sys, db, date_range; resolution = Minute(5))
    set_renewable_pv!(sys, db, date_range; resolution = Minute(5))
    set_renewable_wind!(sys, db, date_range; resolution = Minute(5))
    set_hydro_limits!(sys, db, date_range; resolution = Minute(5))
    if tier isa T1Interconnected
        set_market_bids!(sys, db, date_range; resolution = Minute(5))
    end
    # `set_market_bids!` (T1 only) registers exactly one Deterministic window spanning the whole
    # seeded range (`horizon = length(bids) * resolution = 10 min` for 2 raw points); PSY
    # requires every Forecast in a System to share (count, initial_timestamp, horizon), so the
    # transform below produces that same single 10-minute window rather than one per raw point.
    transform_single_time_series!(sys, Minute(10), Minute(5))
    return
end

"""
    _read_dispatch(res)

`DUID -> MW` at the last time step (`settlement_date`), across every dispatchable device type
PSI's templates register variables for.
"""
function _read_dispatch(res)
    dispatch = Dict{String, Float64}()
    for var_name in (
            "ActivePowerVariable__ThermalStandard",
            "ActivePowerVariable__RenewableDispatch",
            "ActivePowerVariable__HydroDispatch",
        )
        df = try
            PSI.read_variable(res, var_name)
        catch
            continue
        end
        DataFrames.isempty(df) && continue
        last_t = maximum(df.DateTime)
        for row in eachrow(subset(df, :DateTime => ByRow(==(last_t))))
            dispatch[row.name] = row.value
        end
    end
    return dispatch
end

"""
    solve_interval(tier, sys, db, inputs; optimizer)

Seeds `sys` with one interval's time series, builds and solves a `PowerSimulations.jl`
`DecisionModel` from [`build_template`](@ref)`(tier)`, and reads dispatch and prices back out.

Requires a `nem_system`-built `sys` — see [`_seed_interval_time_series!`](@ref)'s naming-
convention note.

# Arguments
- `tier`: [`T0CopperPlate`](@ref) or [`T1Interconnected`](@ref).
- `sys`: a `PowerSystems.System`, e.g. from `nem_system`.
- `db`: an `AEMDB` connection, used to seed the interval's time series.
- `inputs`: the interval's [`IntervalInputs`](@ref), for `settlement_date`.
- `optimizer`: a JuMP-compatible optimizer factory, e.g. `HiGHS.Optimizer`.

# Returns
An [`IntervalResult`](@ref).
"""
function solve_interval(tier::Union{T0CopperPlate, T1Interconnected}, sys, db, inputs::IntervalInputs; optimizer)
    set_units_base_system!(sys, "NATURAL_UNITS")
    _seed_interval_time_series!(tier, sys, db, inputs.settlement_date)

    template = build_template(tier)
    # `horizon` must match `_seed_interval_time_series!`'s transform horizon (10 min = 2 steps:
    # interval start and `settlement_date`) so it lines up with the single window PSY requires
    # every Forecast in the System to share; `_read_dispatch`/the price loop below then keep
    # only the last (settlement_date) time step.
    problem = PSI.DecisionModel(template, sys; optimizer = optimizer, horizon = Minute(10))
    output_dir = mktempdir()
    PSI.build!(problem; output_dir = output_dir)
    PSI.solve!(problem)

    if PSI.get_run_status(problem) != PSI.RunStatus.SUCCESSFULLY_FINALIZED
        return _empty_result(tier, inputs.settlement_date, :infeasible)
    end

    res = PSI.OptimizationProblemResults(problem)
    dispatch = _read_dispatch(res)

    dual_key = tier isa T0CopperPlate ? "CopperPlateBalanceConstraint__System" : "CopperPlateBalanceConstraint__Area"
    duals = PSI.read_dual(res, dual_key)
    prices = Dict{String, Float64}()
    for row in eachrow(subset(duals, :DateTime => ByRow(==(maximum(duals.DateTime)))))
        # `name` is the reference bus number (e.g. "1") for T0's single system-wide price,
        # an area/region name (e.g. "NSW1") for T1 — confirmed via `names(duals) ==
        # ["DateTime", "name", "value"]` against the mock fixture, not assumed.
        prices[row.name] = row.value
    end

    return IntervalResult(
        inputs.settlement_date, tier_name(tier), :optimal, dispatch, prices, Dict{String, Float64}(),
    )
end
