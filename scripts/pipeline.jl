using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsSimulations
using Dates
import PowerSystems as PSY
import PowerSimulations as PSI
import HiGHS

include(joinpath(@__DIR__, "template.jl"))
include(joinpath(@__DIR__, "seeding.jl"))

"""
    run_interval(db, settlement_date::DateTime; intervention = 0, optimizer = HiGHS.Optimizer,
        resolution = Minute(5), lookback = Hour(1)) -> (model, results)

Reconstructs one real historical NEM dispatch interval end-to-end and solves it against
[`dispatch_replication_template`](@ref), then reads results at `settlement_date` - the model's
*last* timestep, not its first.

`date_range` spans `[settlement_date - lookback, settlement_date]` - exactly the same shape
`docs/literate/interchanges.jl`'s known-working example uses (`start_date:interval:(start_date +
horizon)`), just anchored at the *end* rather than the start, so the horizon has somewhere to
ramp from and `settlement_date` is the interval actually reported. `date_range`'s span must equal
`lookback` exactly (not merely contain it): `PowerSystems.transform_single_time_series!(sys,
lookback, resolution)` produces one windowed forecast per raw point the range can support a full
`lookback`-long window from, and passing a range even one step longer or shorter than `lookback`
produces either zero windows (`date_range` too short) or more than one candidate window
(`date_range` longer than `lookback`, ambiguous which one `PSI.DecisionModel` should pick without
an explicit `initial_time`) - anchoring both to `settlement_date` from opposite ends guarantees
exactly one, matching `add_nem_constraints!`/`set_fcas_bids!`'s own single-window series (both
attached inside `nem_system(db, ConstrainedNetworkConfiguration(); date_range)`) without an
interval mismatch (confirmed empirically: a shorter, near-single-point range hits
`InfrastructureSystems.ConflictingInputsError`s this shape does not).

`lookback` exists only to give ramp-rate/`ThermalBasicUnitCommitment` state somewhere to
transition from - it is not itself validated against real dispatch, only `settlement_date` is.
Longer than necessary makes each interval more expensive to build/solve for no accuracy gain;
`Hour(1)` (12 five-minute steps) is enough headroom for this package's own ramp/trapezium
coupling to bind meaningfully without approaching a full day's `docs/literate/interchanges.jl`-
scale unit-commitment problem per interval, since the harness (`scripts/harness.jl`) solves many.

Errors loudly (not silently) if the build fails - a real historical interval this package cannot
reconstruct is a finding to investigate, not a case to swallow.
"""
function run_interval(
        db, settlement_date::DateTime;
        intervention::Integer = 0, optimizer = HiGHS.Optimizer,
        resolution::Period = Minute(5), lookback::Period = Hour(1),
    )
    date_range = (settlement_date - lookback):resolution:settlement_date
    sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
    PSY.set_units_base_system!(sys, "NATURAL_UNITS")
    set_demand!(sys, db, date_range; resolution = resolution)
    set_renewable_pv!(sys, db, date_range; resolution = resolution)
    set_renewable_wind!(sys, db, date_range; resolution = resolution)
    set_hydro_limits!(sys, db, date_range; resolution = resolution)
    set_market_bids!(sys, db, date_range; resolution = resolution)

    inputs = read_interval_inputs(db, settlement_date; intervention = intervention)
    seed_initial_conditions!(sys, inputs)

    PSY.transform_single_time_series!(sys, lookback, resolution)
    template = dispatch_replication_template()
    model = PSI.DecisionModel(template, sys; optimizer = optimizer, horizon = lookback)
    build_status = PSI.build!(model; output_dir = mktempdir())
    build_status == PSI.ModelBuildStatus.BUILT ||
        error("Interval $settlement_date failed to build: $build_status")
    PSI.solve!(model)
    return model, PSI.OptimizationProblemResults(model)
end
