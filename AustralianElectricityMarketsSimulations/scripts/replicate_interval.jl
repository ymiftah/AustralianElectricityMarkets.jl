# Replicates one historical NEM dispatch interval from the local hive cache and prints the
# solved outcome against AEMO's published one. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/scripts/replicate_interval.jl \
#         [2026-06-04T00:00:00] [hive_location]
#
# The interval defaults to 2026-06-04T00:00:00 and `hive_location` to `~/.nemdb_cache`.

using AustralianElectricityMarketsData
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
using PowerSimulations: optimizer_with_attributes
using Printf

settlement_date = DateTime(isempty(ARGS) ? "2026-06-04T00:00:00" : ARGS[1])
hive = length(ARGS) >= 2 ? ARGS[2] : joinpath(homedir(), ".nemdb_cache")
db = aem_connect(HiveConfiguration(hive_location = hive))

optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
comparison = replicate_interval(db, settlement_date; optimizer = optimizer).comparison

function report(title, df, solved, published)
    gap = abs.(df[!, solved] .- df[!, published])
    @printf(
        "%-28s n = %4d   mean |gap| = %9.3f   max |gap| = %9.3f\n",
        title, nrow(df), sum(gap) / length(gap), maximum(gap),
    )
    return nothing
end

println("Interval $settlement_date\n")
show(select(comparison.prices, :REGIONID, :RRP_solved, :RRP_published), allrows = true)
println("\n")
show(comparison.interconnectors, allrows = true)
println("\n")
report("Regional price RRP", comparison.prices, :RRP_solved, :RRP_published)
report("Dispatch TOTALCLEARED (MW)", comparison.dispatch, :TOTALCLEARED_solved, :TOTALCLEARED_published)
report("Interconnector MWFLOW", comparison.interconnectors, :MWFLOW_solved, :MWFLOW_published)
report("Interconnector MWLOSSES", comparison.interconnectors, :MWLOSSES_solved, :MWLOSSES_published)
report("FCAS ROP", comparison.fcas_prices, :ROP_solved, :ROP_published)
