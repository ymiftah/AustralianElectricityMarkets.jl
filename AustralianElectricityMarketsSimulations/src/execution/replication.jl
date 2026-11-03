# A copy of `template` whose network model prices its balance slacks at `cost`; `template` itself is unchanged.
function _with_balance_slack_cost(template::PSI.ProblemTemplate, cost::Real)
    network = deepcopy(PSI.get_network_model(template))
    network.slack_cost = Float64(cost)
    priced = PSI.ProblemTemplate(network)
    priced.devices = deepcopy(PSI.get_device_models(template))
    priced.branches = deepcopy(PSI.get_branch_models(template))
    priced.services = deepcopy(PSI.get_service_models(template))
    return priced
end


"""
    replication_decision_model(template, sys, initial_time; optimizer, name = "replication", market_price_cap = nothing) -> PSI.DecisionModel

Constructs the one-interval `PSI.DecisionModel` of `template` on `sys` from `initial_time`. The Market Price
Cap is resolved once: the balance slacks of the model and every penalty of its container are priced at it.
The caller's `template` is not changed.

# Arguments
- `template`: a [`template_nemde`](@ref) whose components were prepared by [`exclude_unmodeled_services!`](@ref).
- `sys`: the system the template was checked against.
- `initial_time`: the first interval of the model, which dates the Market Price Cap.
- `optimizer`: the JuMP optimizer for the model.
- `name`: the decision problem name used to retrieve its results.
- `market_price_cap`: a Market Price Cap that replaces the one dated by `initial_time`, or `nothing`.

# Returns
The `PSI.DecisionModel`.
"""
function replication_decision_model(
        template::PSI.ProblemTemplate, sys::PSY.System, initial_time::DateTime;
        optimizer, name = "replication", market_price_cap = nothing,
    )
    cap = _resolved_market_price_cap(initial_time, market_price_cap)
    priced = _with_balance_slack_cost(template, _area_balance_slack_cost(sys, cap))
    model = PSI.DecisionModel(
        priced, sys;
        optimizer = optimizer, horizon = DISPATCH_INTERVAL, resolution = DISPATCH_INTERVAL,
        interval = DISPATCH_INTERVAL, initial_time = initial_time, name = name,
    )
    # Construct methods read the cap from the settings ext; the container has no other route to it.
    PSI.get_ext(PSI.get_settings(model))["market_price_cap"] = cap
    return model
end
