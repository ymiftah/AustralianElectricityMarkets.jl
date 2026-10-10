# Diagnoses one interval that does not solve: JuMP statuses, then the HiGHS conflict (or a penalty
# relaxation). Usage: julia --project=.../test diagnose_infeasible.jl 2026-06-13T04:15:00 [hive]

using AustralianElectricityMarketsData
using AustralianElectricityMarketsSimulations
using DataFrames: nrow
using Dates
using DuckDB
using HiGHS
using Printf
import PowerSimulations as PSI
using PowerSimulations.JuMP

const AEMS = AustralianElectricityMarketsSimulations
const MOI = JuMP.MOI

settlement_date = DateTime(isempty(ARGS) ? "2026-06-13T04:15:00" : ARGS[1])
hive = length(ARGS) >= 2 ? ARGS[2] : joinpath(homedir(), ".nemdb_cache")
db = aem_connect(HiveConfiguration(hive_location = hive))
# Bounded DuckDB resources; the temp dir follows TMPDIR.
DuckDB.execute(db.db, "SET memory_limit='3GB'")
DuckDB.execute(db.db, "SET threads=2")
DuckDB.execute(db.db, "SET temp_directory='$(get(ENV, "TMPDIR", "/tmp"))'")

# `JuMP.index(variable) => "container key[axis...]"` for every variable PSI created.
function _variable_labels(container)
    labels = Dict{MOI.VariableIndex, String}()
    for (key, array) in PSI.get_variables(container)
        try
            for k in keys(array)
                v = array[k]
                v isa JuMP.VariableRef && (labels[JuMP.index(v)] = "$(key) $(collect(k isa JuMP.Containers.DenseAxisArrayKey ? k.I : k))")
            end
        catch err
            @warn "could not label variables of $key" err
        end
    end
    return labels
end

# One-line description of a conflicting constraint: its name, else its function and set.
function _describe(con, var_labels)
    obj = JuMP.constraint_object(con)
    func = obj.func isa JuMP.VariableRef ? get(var_labels, JuMP.index(obj.func), string(obj.func)) : obj.func
    text = isempty(JuMP.name(con)) ? "$func in $(obj.set)" : JuMP.name(con)
    return length(text) > 400 ? first(text, 400) * "..." : text
end

# "Family" of a JuMP constraint: its name up to the first `[`, else its type.
function _family(con)
    name = JuMP.name(con)
    return isempty(name) ? "(unnamed)" : String(first(split(name, '[')))
end

println("Interval $settlement_date")
sys = AEMS.replication_system(db, settlement_date)
optimizer = JuMP.optimizer_with_attributes(HiGHS.Optimizer, "threads" => 2)
(; model, skipped_constraints, status) = AEMS._replication_model(sys, settlement_date; optimizer = optimizer)
build_status = status
println("skipped constraints: $(nrow(skipped_constraints))")
println("build status: $build_status")
build_status == PSI.ModelBuildStatus.BUILT || exit(1)
run_status = PSI.solve!(model)
container = PSI.get_optimization_container(model)
jm = PSI.get_jump_model(container)
var_labels = _variable_labels(container)
println("PSI run status: $run_status")
@printf(
    "JuMP termination_status = %s, primal_status = %s, dual_status = %s\n",
    JuMP.termination_status(jm), JuMP.primal_status(jm), JuMP.dual_status(jm)
)
println("raw_status = ", JuMP.raw_status(jm))
if JuMP.termination_status(jm) == MOI.OPTIMAL
    println("The model solved to optimality; nothing to diagnose.")
    exit(0)
end

# Variable bounds with lower > upper cannot be satisfied by any row.
crossed = [
    JuMP.name(v) for v in JuMP.all_variables(jm)
        if JuMP.has_lower_bound(v) && JuMP.has_upper_bound(v) && JuMP.lower_bound(v) > JuMP.upper_bound(v) + 1.0e-9
]
println("variables with lower bound > upper bound: $(length(crossed))", isempty(crossed) ? "" : "  e.g. $(first(crossed, 10))")

println("\n--- JuMP.compute_conflict! (HiGHS IIS) ---")
conflict_ok = false
try
    JuMP.compute_conflict!(jm)
    cstatus = MOI.get(jm, MOI.ConflictStatus())
    println("ConflictStatus = $cstatus")
    if cstatus == MOI.CONFLICT_FOUND
        counts = Dict{String, Int}()
        examples = Dict{String, Vector{String}}()
        for (F, S) in JuMP.list_of_constraint_types(jm), con in JuMP.all_constraints(jm, F, S)
            st = MOI.get(jm, MOI.ConstraintConflictStatus(), con)
            st == MOI.NOT_IN_CONFLICT && continue
            fam = "$(_family(con)) [$(S)]"
            counts[fam] = get(counts, fam, 0) + 1
            ex = get!(examples, fam, String[])
            length(ex) < 40 && push!(ex, _describe(con, var_labels))
        end
        global conflict_ok = !isempty(counts)
        for (fam, n) in sort(collect(counts); by = last, rev = true)
            @printf("  %5d  %s\n", n, fam)
            foreach(d -> println("         ", d), examples[fam])
        end
    end
catch err
    println("compute_conflict! failed: ", sprint(showerror, err))
end

if !conflict_ok
    println("\n--- relax_with_penalty! (L1, every constraint) ---")
    penalties = JuMP.relax_with_penalty!(jm)
    JuMP.optimize!(jm)
    println("relaxed termination_status = ", JuMP.termination_status(jm))
    violation = Dict{String, Float64}()
    for (con, expr) in penalties
        v = JuMP.value(expr)
        v > 1.0e-7 || continue
        fam = _family(con)
        violation[fam] = get(violation, fam, 0.0) + v
    end
    for (fam, v) in sort(collect(violation); by = last, rev = true)
        @printf("  %12.4f  %s\n", v, fam)
    end
end
