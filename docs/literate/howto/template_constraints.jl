begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using Chain
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;

# # [Generic constraints](@id template-constraints)
#
# This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
# interface. Only the preset-specific parts are new here.
#
# The preset is the interconnector-loss run with every generic constraint added and no FCAS
# market. It has no counterpart among the nempy examples. Constraints with FCAS terms cannot clear
# without the FCAS market, so they are left out and reported as `:unmodeled_fcas_service`.
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

template = template_constraints();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);

# The constraints the run leaves out, and why, are reported without changing `sys`:

skipped = template_skipped_constraints(sys, template);
@chain skipped begin
    groupby(:reason)
    combine(nrow => :n_constraints)
end

# `:no_available_device` marks a constraint whose contributing devices are all unavailable.
# `n_missing` counts the terms of the constraint that the run cannot model.

# The first few:

first(skipped, 5)

# A constraint can also be left out on purpose. `exclude_constraints` maps the name of each
# constraint to the reason it is recorded with. The `System` is not changed:
#
# ```julia
# template_constraints(; exclude_constraints = Dict("<NAME>" => :my_reason))
# ```

# ## Simulate

simulation = PSI.Simulation(;
    name = "constraints", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
build_status = PSI.build!(simulation; store_systems_in_results = false)

#-

execute_status = PSI.execute!(simulation)

# ## Compare with NEMDE

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)

#-

comparison_summary(comparison)

# ## Constraint violations
#
# `read_constraint_violations` lists every slack above tolerance, with its family, the constraint
# or unit and the MW violated.

read_constraint_violations(results, sys)

# Next: [Running NEMDE dispatch](@ref run-nemde) runs the full model, with tie-break and FCAS.

@assert build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
