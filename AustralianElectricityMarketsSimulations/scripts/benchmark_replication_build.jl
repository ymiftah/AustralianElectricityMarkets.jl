# Compare warmed preparation/build timings and model signatures using the same interval/cache on both revisions.
# Arguments: [interval] [hive_location] [label] [samples]; use the Simulations test project.

using AustralianElectricityMarkets, AustralianElectricityMarketsSimulations, Dates, Statistics, SHA
import PowerSimulations as PSI
import PowerSystems as PSY
const JuMP = PSI.JuMP
const AEMS = AustralianElectricityMarketsSimulations
at = DateTime(isempty(ARGS) ? "2026-06-06T11:15:00" : ARGS[1])
hive = length(ARGS) >= 2 ? ARGS[2] : joinpath(homedir(), ".nemdb_cache")
label = length(ARGS) >= 3 ? ARGS[3] : "current"
sample_count = length(ARGS) >= 4 ? parse(Int, ARGS[4]) : 3
sample_count > 0 || throw(ArgumentError("sample count must be positive"))
db = aem_connect(HiveConfiguration(hive_location = hive))
function _affine_signature(f)
    f isa JuMP.VariableRef && return "variable:" * string(JuMP.index(f).value)
    f isa JuMP.GenericAffExpr || return repr(f)
    terms = sort([(JuMP.index(v).value, c) for (c, v) in JuMP.linear_terms(f)])
    return repr((JuMP.constant(f), terms))
end
function _model_signature(jm)
    rows = String[]
    for c in JuMP.all_constraints(jm; include_variable_in_set_constraints = true)
        obj = JuMP.constraint_object(c)
        push!(rows, _affine_signature(obj.func) * " in " * repr(obj.set))
    end
    sort!(rows)
    return bytes2hex(sha256(join(rows, "\n") * "\nOBJECTIVE " * _affine_signature(JuMP.objective_function(jm))))
end
function _sample_build(db, at)
    system = @timed AEMS.replication_system(db, at)
    build = @timed AEMS._replication_model(system.value, at)
    build.value.status == PSI.ModelBuildStatus.BUILT || error("Build failed")
    jm = PSI.get_jump_model(build.value.model)
    result = (;
        system_seconds = system.time, build_seconds = build.time,
        total_seconds = system.time + build.time, system_bytes = system.bytes,
        build_bytes = build.bytes, variables = JuMP.num_variables(jm),
        constraints = JuMP.num_constraints(jm; count_variable_in_set_constraints = true),
        signature = _model_signature(jm),
    )
    rm(build.value.output_dir; recursive = true)
    return result
end
println("WARMUP ", label); flush(stdout)
warm = _sample_build(db, at)
println("WARMUP_RESULT ", warm); flush(stdout)
samples = NamedTuple[]
for i in 1:sample_count
    GC.gc()
    result = _sample_build(db, at)
    result.signature == warm.signature || error("Structure changed between samples")
    push!(samples, result)
    println("SAMPLE ", label, " ", i, " ", result); flush(stdout)
end
println(
    "SUMMARY ", label, " ", (;
        system_seconds = median(getproperty.(samples, :system_seconds)),
        build_seconds = median(getproperty.(samples, :build_seconds)), total_seconds = median(getproperty.(samples, :total_seconds)),
        system_bytes = median(getproperty.(samples, :system_bytes)), build_bytes = median(getproperty.(samples, :build_bytes)),
        signature = warm.signature, variables = warm.variables, constraints = warm.constraints,
    )
)
