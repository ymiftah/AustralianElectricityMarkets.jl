# The long-format (`DateTime`, `name`, `value`) frame of each of `keys`: solved values of a model,
# realized values of a simulation's decision problem.
function _read_variable_frames(results::PSI.OptimizationProblemResults, keys)
    return Dict(key => PSI.read_variable(results, key) for key in keys)
end
function _read_variable_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.VariableKey, DataFrame}()
    names = Dict(key => PSI.IS.Optimization.encode_key_as_string(key) for key in keys)
    vals = PSI.read_realized_variables(results, collect(values(names)))
    return Dict(key => vals[name] for (key, name) in names)
end


# Each dispatch variable's sign in net MW: generation (or discharge) minus charge.
const _DISPATCH_SIGNS = Dict(
    PSI.ActivePowerVariable => 1.0, PSI.ActivePowerOutVariable => 1.0, PSI.ActivePowerInVariable => -1.0,
)


function _read_balance_duals(results::PSI.OptimizationProblemResults)
    return PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area)
end
function _read_balance_duals(results::PSI.SimulationProblemResults)
    return only(values(PSI.read_realized_duals(results, [PSI.ConstraintKey(PSI.CopperPlateBalanceConstraint, PSY.Area)])))
end


# Each key's long-format frame (`DateTime`, `value`): solved values, or realized ones of a simulation.
_read_dual_frames(results::PSI.OptimizationProblemResults, keys) = Dict(key => PSI.read_dual(results, key) for key in keys)
# Opens the simulation store once for all `keys`, over the window `read_realized_duals` reads.
function _read_dual_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.OptimizationContainerKey, DataFrame}()
    vals = PSI.read_realized_duals(results, collect(keys))
    return Dict(key => vals[PSI.IS.Optimization.encode_key_as_string(key)] for key in keys)
end
