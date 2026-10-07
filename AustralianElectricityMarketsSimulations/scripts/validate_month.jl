# Validates a month of NEM dispatch replication against AEMO's published outcomes: a stratified
# sample of intervals is replicated and compared, and the complementary-slackness check runs on
# AEMO's own solution for every interval of the month. Local only; reads the hive cache. From the
# repository root:
#
#     julia --project=AustralianElectricityMarketsSimulations/test \
#         AustralianElectricityMarketsSimulations/scripts/validate_month.jl \
#         [2026-06] [n = 20] [hive_location] [sample_file]
#
# The month defaults to 2026-06 and `hive_location` to `~/.nemdb_cache`. When `sample_file` (a
# CSV written by an earlier run, e.g. `validation_sample_2026-06.csv`) exists, its intervals are
# replicated unchanged so runs stay comparable; otherwise a sample of `n` is drawn and written
# there. Output: `validation_<month>.csv` (the tidy table) in VALIDATION_OUT_DIR (default: next to
# the sample file) and a summary on stdout. VALIDATION_SKIP_SOLVE=1 runs only the complementary-slackness
# check, VALIDATION_CS_DAYS=all extends it from the sample's days to the whole month, and
# VALIDATION_TMP_DIR sets DuckDB's spill directory.

using AustralianElectricityMarkets
using AustralianElectricityMarketsData
using AustralianElectricityMarketsSimulations
using DataFrames
using Dates
using HiGHS
using PowerSimulations: optimizer_with_attributes

month = Date(isempty(ARGS) ? "2026-06" : ARGS[1] * "-01")
n = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 20
hive = length(ARGS) >= 3 ? ARGS[3] : joinpath(homedir(), ".nemdb_cache")
sample_file = length(ARGS) >= 4 ? ARGS[4] : joinpath(@__DIR__, "validation_sample_$(Dates.format(month, "yyyy-mm")).csv")
out_dir = get(ENV, "VALIDATION_OUT_DIR", dirname(sample_file))
table_file = joinpath(out_dir, "validation_$(Dates.format(month, "yyyy-mm")).csv")
db = aem_connect(HiveConfiguration(hive_location = hive))

# Cap DuckDB memory and put any spill on a scratch disk (VALIDATION_TMP_DIR).
tmp_dir = get(ENV, "VALIDATION_TMP_DIR", joinpath(out_dir, "duckdb_tmp"))
mkpath(tmp_dir)
for setting in ("memory_limit='3GB'", "threads=2", "temp_directory='$tmp_dir'")
    AustralianElectricityMarkets._query(db, "SET $setting")
end

csv_field(x) = ismissing(x) ? "" : occursin(r"[,\"\n]", string(x)) ? "\"" * replace(string(x), "\"" => "\"\"") * "\"" : string(x)
function write_csv(path, df)
    open(path, "w") do io
        println(io, join(names(df), ","))
        for r in eachrow(df)
            println(io, join(csv_field.(collect(r)), ","))
        end
    end
    return path
end

if isfile(sample_file)
    lines = readlines(sample_file)[2:end]
    sample = DataFrame(;
        interval = [DateTime(split(l, ',')[1]) for l in lines],
        stratum = [split(l, ',')[2] for l in lines],
        intervention = [parse(Int, split(l, ',')[3]) for l in lines],
    )
    println("Read $(nrow(sample)) intervals from $sample_file")
else
    sample = validation_sample(db, month; n = n)
    write_csv(sample_file, sample)
    println("Drew $(nrow(sample)) intervals into $sample_file")
end

# Complementary slackness runs one day at a time: DISPATCHLOAD x bids for a whole month does not fit
# in memory. By default only the days of the sample; VALIDATION_CS_DAYS=all covers the month.
days = if get(ENV, "VALIDATION_CS_DAYS", "sample") == "all"
    collect(month:Day(1):(month + Month(1) - Day(1)))
else
    sort!(unique(Date.(sample.interval .- Minute(5))))
end
cs_tables = DataFrame[]
for day in days
    started = time()
    range = (DateTime(day) + Minute(5)):Minute(5):DateTime(day + Day(1))
    push!(cs_tables, complementary_slackness_table(db, range))
    println("complementary slackness $day: $(round(time() - started; digits = 1)) s")
    flush(stdout)
end
cs = reduce(vcat, cs_tables)

table = cs
if get(ENV, "VALIDATION_SKIP_SOLVE", "0") != "1"
    optimizer = optimizer_with_attributes(HiGHS.Optimizer, "output_flag" => false)
    solved = run_validation(db, sample; optimizer = optimizer, log = stdout)
    table = vcat(solved, cs)
end
write_csv(table_file, table)
println("Wrote $(nrow(table)) rows to $table_file\n")

options = (; allrows = true, allcols = true)
show(stdout, validation_summary(table); options...)
println()
