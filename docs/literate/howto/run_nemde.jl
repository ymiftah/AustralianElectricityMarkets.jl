begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;

# # [Running NEMDE dispatch](@id run-nemde)
#
# This page runs a few real dispatch intervals with `AustralianElectricityMarketsSimulations`
# and compares the solved prices, dispatch and flows with what NEMDE published. It follows the
# run interface end to end:
#
# ```text
# nem_system -> template_nemde -> nem_dispatch_sequence -> PSI.Simulation -> build! -> execute!
# ```
#
# The formulation it solves is described in the [NEMDE formulation](@ref nemde-model) chapters,
# and [Building it with AEM and AEMSim](@ref nemde-aem) assembles the same pieces by hand on a
# toy market.
#
# ## The data
#
# The run reads the local cache and downloads nothing. The tables it needs are those of
# `table_requirements(NEMDEConfiguration())`; uncomment the loop below to cache January 2025.

db = aem_connect();
## for table in table_requirements(NEMDEConfiguration())
##     populate(db, table, Date(2025, 1, 1), Date(2025, 1, 3))
## end

# We run three intervals of the morning of 2 January 2025. Timestamps are interval-ending
# `SETTLEMENTDATE`s in market time (AEST).

steps = DateTime(2025, 1, 2, 8, 5):DISPATCH_INTERVAL:DateTime(2025, 1, 2, 8, 15)

# ## Step 1: the run `System`
#
# `nem_system` with `NEMDEConfiguration` builds every NEMDE input: energy and FCAS offers,
# unit conditions, generic constraints, interconnector losses and MNSP offers. Its date range
# runs past the last run interval, because each five-minute forecast window holds the
# next interval as well. The build ends with the run checks: a missing input fails here,
# before any model is built.

horizon = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
sys = nem_system(db, NEMDEConfiguration(); date_range = horizon)
dispatch_intervals(sys)

# ## Step 2: the template and the decision models
#
# `template_nemde()` is the data-free problem template. `nem_dispatch_sequence` turns it into
# the PowerSimulations decision models of the run and the sequence that runs them.
# `nemde_optimizer()` is HiGHS with tight MIP gaps.

template = template_nemde()
(; models, sequence, dispatch, commitment) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
)
PSI.get_name.(PSI.get_decision_models(models))

# When the `System` holds a fast-start unit, as here, each interval runs NEMDE's two runs at
# the same timestamp, as [Fast-start dispatch](@ref nemde-fast-start) describes: the commitment
# run without inflexibility profiles, then the dispatch run, which holds every fast-start unit
# to the profile of the mode it ends the interval in. Results and prices are the dispatch
# run's, named `"dispatch"`. Pass `fast_start = false` to build the single model instead.
#
# `NEMDispatchProblem` is the **open-loop** run: every interval starts from AEMO's metered
# output and observed state, so each interval is an independent solve that can be compared
# with NEMDE's. `NEMClosedLoopDispatchProblem` is the **closed-loop** run: each interval
# after the first starts from the previous solve instead. It answers what dispatch would have
# done had the market followed the run, and its gap to NEMDE grows with the gap between the
# solved and metered trajectories.
#
# The constraints the run leaves out, for example those whose every device is unavailable,
# are reported without changing `sys`:

template_skipped_constraints(sys, template)

# ## Step 3: simulate
#
# A `PSI.Simulation` steps the models through the intervals, updating the time-series
# parameters in place instead of rebuilding the model.

simulation = PSI.Simulation(;
    name = "run", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
)
build_status = PSI.build!(simulation; store_systems_in_results = false)

#-

execute_status = PSI.execute!(simulation)

# ## Step 4: compare with NEMDE
#
# `read_solved_interval` reads the solved outcome in the keys and columns of
# `read_published_interval`, so `compare_intervals` joins the two:

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch")
solved = read_solved_interval(results, sys)
comparison = compare_intervals(read_published_interval(db, steps), solved);

# Energy prices are compared with the regional original price (ROP), the price straight from
# the optimisation, not the settlement price (RRP):

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)

# `comparison_summary` gives one row per compared quantity: energy prices, unit dispatch,
# interconnector flows and losses and FCAS prices.

comparison_summary(comparison)

# The interconnector flows:

select(comparison.interconnectors, :SETTLEMENTDATE, :INTERCONNECTORID, :MWFLOW_published, :MWFLOW_solved)

# ## Constraint violations
#
# Almost every constraint is elastic, at a penalty set by AEMO's constraint violation
# penalty factors. `read_constraint_violations` lists every slack above tolerance, with its
# family, the constraint or unit and the MW violated. A violated constraint in the run is
# the first thing to look at when a solved price departs from the published one.

read_constraint_violations(results, sys)

# ## Simpler templates
#
# `template_nemde()` is the full model. Its keyword builder takes parts out one at a time, and
# five presets are one-line calls to it. The presets follow the nempy examples, which add the
# parts of NEMDE one at a time:
#
# | Preset | Interchanges | FCAS | Generic constraints | nempy example |
# | --- | --- | --- | --- | --- |
# | `template_energy_only()` | none | no | no | 1 and 2: bid stack, ramps |
# | `template_interconnected()` | lossless | no | no | 3, its lossless counterpart (nempy's constant 5 percent loss is not modelled) |
# | `template_losses()` | dynamic losses | no | no | 4: dynamic losses |
# | `template_fcas()` | dynamic losses | yes | FCAS requirements only | 5: FCAS markets |
# | `template_constraints()` | dynamic losses | no | all | none |
#
# None of the presets has tie-break, which only the full `template_nemde()` models. Ramp
# limits are always kept.
#
# ```julia
# template_energy_only()
# template_interconnected()
# template_losses(; loss_breakpoints = 4)
# template_fcas(; loss_breakpoints = 4)
# template_constraints(; loss_breakpoints = 4)
# ```
#
# `loss_breakpoints = N` keeps at most `N` breakpoints of each interchange's loss model, always
# the first and the last, with the interior thinned evenly by index. The `System` is not changed,
# and `read_interconnector_loss_gaps` still reads the full curve, so its `gap_mw` column shows the
# error the thinning adds.
#
# Fast start is an option of the sequence, not of the template. The nempy examples have no
# fast-start unit, so run a preset with `fast_start = false` to build the single model:
#
# ```julia
# nem_dispatch_sequence(NEMDispatchProblem, template_losses(), sys; fast_start = false)
# ```
#
# ## Going further
#
# - Run a whole trading day with `trading_day_steps(day)`, split by `dispatch_chunks` into
#   ranges one `PSI.Simulation` can hold.
# - The batch runner in `scripts/batch_run.jl` runs whole days, selected intervals or a
#   random sample and writes the comparisons as CSV files; see
#   [Batch runs and benchmark](@ref run-batch).

@assert build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
