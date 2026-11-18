begin
    using AustralianElectricityMarkets
    using AustralianElectricityMarketsData: populate
    using AustralianElectricityMarketsSimulations
    using DataFrames
    using Dates
    import PowerSimulations as PSI
end;

# # [Lossless interconnectors](@id template-interconnected)
#
# This page runs the intervals of [Running NEMDE dispatch](@ref run-nemde) with the same run
# interface. Only the preset-specific parts are new here.
#
# The preset adds the interchanges to the energy-only run, lossless. Each interchange keeps its
# flow limits: the flow stays within IMPORTLIMIT and EXPORTLIMIT, and a violation is penalised
# under AEMO's Constraint Violation Penalty item 5, "Interconnector Capacity Limit". No loss is
# taken, so the loss columns are `missing`.
#
# A lossless run is a study setting. NEMDE always applies the loss model. Without losses, regional
# prices separate only where a flow limit binds. NEMDE's prices also carry marginal losses and the
# generic constraints, which this preset leaves out, so prices and flows differ from the published
# ones. An MNSP, such as Basslink, is a
# regulated flow within its limits here, with no MNSP offers. It is the lossless counterpart of
# the nempy interchange example, whose constant 5 percent loss is not modelled.
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

template = template_interconnected();
(; models, sequence) = nem_dispatch_sequence(
    NEMDispatchProblem, template, sys;
    fast_start = false, optimizer = nemde_optimizer(; output_flag = false), initial_time = first(steps),
);

# ## Simulate

simulation = PSI.Simulation(;
    name = "interconnected", steps = length(steps), models, sequence,
    simulation_folder = mktempdir(), initial_time = first(steps),
);
build_status = PSI.build!(simulation; store_systems_in_results = false)

#-

execute_status = PSI.execute!(simulation)

# ## Compare with NEMDE
#
# Interchange flows are compared with the published flows. The losses are `missing` on the solved
# side, because the lossless model has no loss variable.

results = PSI.get_decision_problem_results(PSI.SimulationResults(simulation), "dispatch");
solved = read_solved_interval(results, sys);
comparison = compare_intervals(read_published_interval(db, steps), solved);

select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_published, :ROP_solved)

#-

select(
    comparison.interconnectors, :SETTLEMENTDATE, :INTERCONNECTORID,
    :MWFLOW_published, :MWFLOW_solved, :MWLOSSES_published, :MWLOSSES_solved,
)

#-

comparison_summary(comparison)

# Next: [Interconnector losses](@ref template-losses), which takes the loss model.

@assert build_status == PSI.SimulationBuildStatus.BUILT #hide
@assert execute_status == PSI.RunStatus.SUCCESSFULLY_FINALIZED #hide
