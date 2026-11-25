begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using Chain
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;

# # [FCAS markets](@id template-fcas)
#
# This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
# interface. Only the preset-specific parts are new here.
#
# The preset is the interconnector-loss run with the FCAS market added. NEMDE models the FCAS
# requirements as generic constraints, so the preset keeps those (`constraints = :fcas_requirements`)
# and leaves out the other generic constraints. The preset has no tie-break. It corresponds to
# nempy's FCAS example.
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

template = template_fcas();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);

# ## Simulate

simulation = PSI.Simulation(;
    name = "fcas", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
build_status = PSI.build!(simulation; store_systems_in_results = false)

#-

execute_status = PSI.execute!(simulation)

# ## Compare with NEMDE
#
# The FCAS prices are the regional prices of each bid type, compared with the published
# regional original prices (ROP). The table shows the first interval; the summary covers all three.

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

@chain comparison.fcas_prices begin
    subset(:SETTLEMENTDATE => ByRow(==(first(steps))))
    select(:REGIONID, :BIDTYPE, :ROP_published, :ROP_solved)
end

#-

comparison_summary(comparison)

# Next: [Generic constraints](@ref template-constraints), which models every generic constraint.

@assert build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
