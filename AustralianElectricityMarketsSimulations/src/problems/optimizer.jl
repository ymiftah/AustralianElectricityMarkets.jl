"""
    NEMDE_HIGHS_OPTIONS

The HiGHS options of the NEMDE replication: relative MIP gap `1e-8`, absolute MIP gap `1e-10`, and the
root sub-MIP heuristics (RINS, RENS, root reduced cost and feasibility jump) turned off.
"""
const NEMDE_HIGHS_OPTIONS = (
    "mip_rel_gap" => 1.0e-8,
    "mip_abs_gap" => 1.0e-10,
    "mip_heuristic_run_rins" => false,
    "mip_heuristic_run_rens" => false,
    "mip_heuristic_run_root_reduced_cost" => false,
    "mip_heuristic_run_feasibility_jump" => false,
)

"""
    nemde_optimizer(; attributes...) -> MOI.OptimizerWithAttributes

The HiGHS optimizer with [`NEMDE_HIGHS_OPTIONS`](@ref), the MIP gaps at `1e-8` and `1e-10` and the root
sub-MIP heuristics (RINS, RENS, root reduced cost and feasibility jump) off. Keyword `attributes` are
HiGHS options that add to or override those of [`NEMDE_HIGHS_OPTIONS`](@ref), e.g. `threads = 1`.

# Arguments
- `attributes...`: HiGHS option names and values, as keyword arguments.

# Returns
A `MOI.OptimizerWithAttributes` for the `optimizer` keyword of `PSI.DecisionModel`.
"""
function nemde_optimizer(; attributes...)
    return PSI.optimizer_with_attributes(
        HiGHS.Optimizer, NEMDE_HIGHS_OPTIONS..., (string(k) => v for (k, v) in attributes)...,
    )
end
