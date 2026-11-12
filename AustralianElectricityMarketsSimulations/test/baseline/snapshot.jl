# Replay snapshots: the realized PSI results, the optimizer statistics and the invoked input of the
# generic constraints of one replay, as name => table maps. The caller provides `PSI`, `PSY`,
# `AEMS` and `DataFrame`.

"""
    replay_snapshot(results, sys::PSY.System) -> Dict{String, DataFrame}

Reads every realized result table of `results`, the optimizer statistics and the invoked input of
each `GenericConstraint` of `sys` over the intervals of `results`. The keys are `"variable/<key>"`,
`"dual/<key>"`, `"aux/<key>"`, `"expression/<key>"` and `"parameter/<key>"`, with `<key>` the encoded
PSI key string, `"stats/optimizer"`, and `"input/constraint_invoked"`, which has one row per interval
and one column per constraint name.

# Arguments
- `results`: the decision-problem results of a replay.
- `sys`: the replay system the results were built from.

# Returns
A `Dict{String, DataFrame}`.
"""
function replay_snapshot(results, sys::PSY.System)
    snapshot = Dict{String, DataFrame}()
    readers = (
        "variable" => PSI.read_realized_variables,
        "dual" => PSI.read_realized_duals,
        "aux" => PSI.read_realized_aux_variables,
        "expression" => PSI.read_realized_expressions,
        "parameter" => PSI.read_realized_parameters,
    )
    for (kind, read) in readers, (key, table) in read(results)
        snapshot["$kind/$key"] = table
    end
    # The interval stamps are those of the realized variables, which the optimizer statistics follow row by row.
    variables = [snapshot[k] for k in keys(snapshot) if startswith(k, "variable/")]
    stamps = sort(unique(reduce(vcat, [t.DateTime for t in variables])))
    stats = PSI.read_optimizer_stats(results)
    nrow(stats) == length(stamps) || error("$(nrow(stats)) optimizer stat rows for $(length(stamps)) intervals.")
    snapshot["stats/optimizer"] = insertcols(stats, 1, :DateTime => stamps)
    snapshot["input/constraint_invoked"] = _invoked_input(sys, stamps)
    return snapshot
end

# The invoked series of every `GenericConstraint` of `sys` at `stamps`, one column per constraint name.
function _invoked_input(sys::PSY.System, stamps::AbstractVector{DateTime})
    input = DataFrame(DateTime = collect(stamps))
    for gc in PSY.get_components(AustralianElectricityMarkets.GenericConstraint, sys)
        key = AEMS._constraint_key(gc, :invoked, AEMS.NEM_CONSTRAINT_SERIES.invoked)
        input[!, PSY.get_name(gc)] = PSI.IS.get_time_series_values(
            gc, key; start_time = first(stamps), len = length(stamps), ignore_scaling_factors = true,
        )
    end
    return input
end

"""
    key_type_count(model) -> Int

Counts the distinct key types of the optimization container of `model`, over its variables,
parameters, constraints, expressions, auxiliary variables, duals and initial conditions. PSI compiles
one method per key type, so this is the cost driver of a build.

# Arguments
- `model`: a built `PSI.DecisionModel`.

# Returns
An `Int`.
"""
function key_type_count(model)
    container = PSI.get_optimization_container(model)
    tables = (
        PSI.get_variables(container), PSI.get_parameters(container), PSI.get_constraints(container),
        PSI.get_expressions(container), PSI.get_aux_variables(container), PSI.get_duals(container),
        PSI.get_initial_conditions(container),
    )
    return length(unique(typeof, Iterators.flatten(keys.(tables))))
end
