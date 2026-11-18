begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;

# # [Interconnector losses](@id template-losses)
#
# This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
# interface. Only the preset-specific parts are new here.
#
# The preset is the energy-only run with each interchange under its dynamic loss model. A flow
# gives up the loss the loss curve takes at that flow, as NEMDE does. It has no FCAS, generic
# constraints or tie-break. It corresponds to nempy's loss example.
#
# ## The data
#
# The run reads the local cache and downloads nothing. Uncomment the loop below to cache January 2025.

db = aem_connect();
## for table in table_requirements(NEMDEConfiguration())
##     populate(db, table, Date(2025, 1, 1), Date(2025, 1, 3))
## end

steps = DateTime(2025, 1, 2, 8, 5):DISPATCH_INTERVAL:DateTime(2025, 1, 2, 8, 15)

# ## The run `System`

horizon = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
sys = nem_system(db, NEMDEConfiguration(); date_range = horizon);

# ## The template and the decision model
#
# The presets are run with `fast_start = false`, because fast start is an option of the sequence.

template = template_losses();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);

# ## Simulate

simulation = PSI.Simulation(;
    name = "losses", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
build_status = PSI.build!(simulation; store_systems_in_results = false)

#-

execute_status = PSI.execute!(simulation)

# ## Compare with NEMDE
#
# The interchange flows and losses are compared with the published values.

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(
    comparison.interconnectors, :SETTLEMENTDATE, :INTERCONNECTORID,
    :MWFLOW_published, :MWFLOW_solved, :MWLOSSES_published, :MWLOSSES_solved,
)

#-

comparison_summary(comparison)

# Without generic constraints, flows run to their limits, far from NEMDE's, so the solved losses on
# the loss curve are far larger than the published ones. The near-zero `gap_mw` below shows that
# each loss lies on its curve.

# ## Loss gaps
#
# `read_interconnector_loss_gaps` reads each interchange's solved loss against the loss curve
# at its solved flow. The gap is the difference, so it is about zero when the solver takes the
# loss the curve gives.

loss_gaps = read_interconnector_loss_gaps(results, sys)

# ## Thinning the loss curve
#
# `loss_breakpoints` keeps at most `N` breakpoints of each interchange's loss model, always the first
# and the last, with the interior thinned evenly by index. The `System` is not changed, and
# `read_interconnector_loss_gaps` still reads the full curve, so its `gap_mw` column shows the
# error the thinning adds.
#
# This second run uses four breakpoints, in its own simulation folder.

thinned_template = template_losses(; loss_breakpoints = 4);
thinned = nem_dispatch_sequence(
    NEMDispatchProblem, thinned_template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);
thinned_simulation = PSI.Simulation(;
    name = "losses_thinned", steps = length(steps), models = thinned.models, sequence = thinned.sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
thinned_build_status = PSI.build!(thinned_simulation; store_systems_in_results = false)

#-

thinned_execute_status = PSI.execute!(thinned_simulation)

thinned_results = PSI.get_decision_problem_results(PSI.SimulationResults(thinned_simulation), "dispatch");
thinned_loss_gaps = read_interconnector_loss_gaps(thinned_results, sys)

# Next: [FCAS markets](@ref template-fcas), which adds the FCAS market.

@assert build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
@assert thinned_build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert thinned_execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
