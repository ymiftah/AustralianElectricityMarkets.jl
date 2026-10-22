# Replays a range of historical NEM dispatch intervals from the local hive cache and prints the
# solved outcome against AEMO's published one. From the repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/scripts/replicate_range.jl \
#         [2026-06-04T00:00:00] [2026-06-04T00:00:00] [hive_location]
#
# The range defaults to the one interval 2026-06-04T00:00:00 and `hive_location` to
# `~/.nemdb_cache`. The cache must also hold the two five-minute intervals after the range.

using AustralianElectricityMarkets
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
using PowerSimulations: optimizer_with_attributes
using Printf

start = DateTime(isempty(ARGS) ? "2026-06-04T00:00:00" : ARGS[1])
stop = length(ARGS) >= 2 ? DateTime(ARGS[2]) : start
hive = length(ARGS) >= 3 ? ARGS[3] : joinpath(homedir(), ".nemdb_cache")
db = aem_connect(HiveConfiguration(hive_location = hive))

optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false, "mip_rel_gap" => 0.0)
comparison = replicate_range(db, start, stop; optimizer = optimizer).comparison

# Mean and max absolute gap over the rows with both a solved and a published value.
function report(title, df, solved, published)
    both = dropmissing(df[!, [solved, published]])
    if isempty(both)
        @printf("%-28s n = %4d   no rows with both values\n", title, nrow(both))
        return nothing
    end
    gap = abs.(both[!, solved] .- both[!, published])
    @printf(
        "%-28s n = %4d   mean |gap| = %9.3f   max |gap| = %9.3f\n",
        title, length(gap), sum(gap) / length(gap), maximum(gap),
    )
    return nothing
end

println("Intervals $start to $stop\n")
show(select(comparison.prices, :SETTLEMENTDATE, :REGIONID, :ROP_solved, :ROP_published, :RRP_published), allrows = true)
println("\n")
show(comparison.interconnectors, allrows = true)
println("\n")
report("Regional price ROP", comparison.prices, :ROP_solved, :ROP_published)
report("Dispatch TOTALCLEARED (MW)", comparison.dispatch, :TOTALCLEARED_solved, :TOTALCLEARED_published)
report("Interconnector MWFLOW", comparison.interconnectors, :MWFLOW_solved, :MWFLOW_published)
report("Interconnector MWLOSSES", comparison.interconnectors, :MWLOSSES_solved, :MWLOSSES_published)
report("FCAS ROP", comparison.fcas_prices, :ROP_solved, :ROP_published)
