begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;

# # [Energy-only template](@id template-energy-only)
#
# This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
# interface. Only the preset-specific parts are new here.
#
# The energy-only preset keeps the dispatch participants, their bid stacks and their ramp limits,
# with the demand of each region. It has no interchanges, FCAS, generic constraints or tie-break,
# so each region clears its own bid stack against its own demand. Ramp limits are always kept.
# Tie-break is modelled only by the full `template_nemde()`.
#
# ## The data
#
# The run reads the local cache and downloads nothing. Uncomment the loop below to cache January 2025.

db = aem_connect();
## for table in table_requirements(NEMDEConfiguration())
##     populate(db, table, Date(2025, 1, 1), Date(2025, 1, 3))
## end

# We run three intervals of the morning of 2 January 2025, the same as the full run.

steps = DateTime(2025, 1, 2, 8, 5):DISPATCH_INTERVAL:DateTime(2025, 1, 2, 8, 15)

# ## The run `System`
#
# The `System` is the NEMDE build of the full run. The preset uses only its bids and demand.

horizon = first(steps):DISPATCH_INTERVAL:(last(steps) + 2DISPATCH_INTERVAL)
sys = nem_system(db, NEMDEConfiguration(); date_range = horizon);

# ## The template and the decision model
#
# `template_energy_only()` is one call to the keyword builder of `template_nemde`. The presets are
# run with `fast_start = false`, because fast start is an option of the sequence, not of the template.

template = template_energy_only();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);

# ## Simulate
#
# As in the full run, the `PSI.Simulation` steps the model through the intervals.

simulation = PSI.Simulation(;
    name = "energy_only", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
build_status = PSI.build!(simulation; store_systems_in_results = false)

#-

execute_status = PSI.execute!(simulation)

# ## Compare with NEMDE
#
# Regional prices are compared with the regional original price (ROP). Regions are not coupled
# in this preset, so each regional price is set by its own bid stack. NEMDE couples the regions
# through the interchanges, and a regional price diverges from the published one wherever that
# coupling sets it.

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)

# Tasmania imports over Basslink in NEMDE. On its own it runs short, its balance is met by the
# deficit slack, and its price is the energy deficit penalty, 150 times the Market Price Cap. NSW
# exports in NEMDE. Here it keeps that generation, and its marginal bid falls to the Market Floor
# Price of -1000 \$/MWh. The other regions clear on their own bid stacks. `read_constraint_violations`
# shows the deficit:

read_constraint_violations(results, sys)

# `comparison_summary` gives one row per compared quantity. A deficit price dominates the
# energy price error. The interchange and FCAS rows have no paired values, because the preset models neither.

comparison_summary(comparison)

# Next: [Lossless interconnectors](@ref template-interconnected), which adds the interchanges.

@assert build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
