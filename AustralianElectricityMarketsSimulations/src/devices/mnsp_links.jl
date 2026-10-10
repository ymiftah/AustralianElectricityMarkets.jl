# MNSP link offers on a `PSY.AreaInterchange` under `NEMInterconnectorLoss`: the interconnector's net
# flow is split into a forward and a reverse link flow, each bounded and priced by its own offer.

"""
    MNSPLinkFlowVariable

One MNSP link's flow at one timestep, non-negative and per-unit of the system base. Indexed
`(interconnector name, "forward" | "reverse", t)`; the forward link carries flow from the
interconnector's from area to its to area.
"""
struct MNSPLinkFlowVariable <: PSI.VariableType end

"""
    MNSPLinkFlowConstraint

`flow[ic,t] == forward link flow - reverse link flow`, per-unit.
"""
struct MNSPLinkFlowConstraint <: PSI.ConstraintType end

"""
    MNSPLinkDirectionVariable

Binary per interconnector and timestep, `1` when only the forward link may flow and `0` when only
the reverse link may, so the two links never flow at once.
"""
struct MNSPLinkDirectionVariable <: PSI.VariableType end

PSI.convert_result_to_natural_units(::Type{MNSPLinkFlowVariable}) = true

"DC losses supplied by one directional MNSP link's sending region, per-unit of base power."
struct MNSPLinkLossVariable <: PSI.VariableType end

PSI.convert_result_to_natural_units(::Type{MNSPLinkLossVariable}) = true

const _MNSP_DIRECTIONS = ("forward", "reverse")

"""
    _has_mnsp_offers(device) -> Bool

Whether `device` carries both links' offer and availability series from `set_mnsp_offers!`.
"""
function _has_mnsp_offers(device::PSY.AreaInterchange)
    return all(
        PSY.has_time_series(device, PSY.Deterministic, "mnsp_$(dir)_$(kind)")
            for dir in _MNSP_DIRECTIONS, kind in ("offer", "max_avail")
    )
end

"""
    _has_flow_limit_series(device) -> Bool

Whether `device` carries a time series other than the MNSP offer series, that is, per-interval flow limits.
"""
function _has_flow_limit_series(device::PSY.AreaInterchange)
    return any(k -> !startswith(PSY.get_name(k), "mnsp_"), PSY.get_time_series_keys(device))
end

"""
    _mnsp_link_tlfs(device, direction) -> NamedTuple

The `from` and `to` loss factors of `device`'s `direction` link, as recorded by `set_mnsp_offers!`.
Throws `ArgumentError` when either is missing or not positive.
"""
function _mnsp_link_tlfs(device::PSY.AreaInterchange, direction::AbstractString)
    info = get(PSY.get_ext(device), "mnsp_$direction", nothing)
    tlfs = isnothing(info) ? (nothing, nothing) : (get(info, "from_region_tlf", nothing), get(info, "to_region_tlf", nothing))
    all(t -> t isa Real && t > 0, tlfs) || throw(
        ArgumentError(
            "AreaInterchange \"$(PSY.get_name(device))\" has MNSP offers but no positive " *
                "from_region_tlf and to_region_tlf for its $direction link in ext[\"mnsp_$direction\"]",
        ),
    )
    return (from = Float64(tlfs[1]), to = Float64(tlfs[2]))
end

"""
    _add_mnsp_link_flows!(container, sys, devices)

For every device in `devices` carrying MNSP offers, adds one non-negative link flow per direction and
timestep, bounded by the link's `MAXAVAIL` and its offered bands, and ties it to the interconnector
flow as `flow = forward - reverse`. Each link's bands enter the objective at the offered price. A
link's receiving-end flow `q` and DC losses `loss` enter the regional balances as
`-from_tlf * (q + loss)` in its sending area and `+to_tlf * q` in its receiving area.
Devices without offers are untouched and keep their free-flow model. Quantities are per-unit of the
system base.

A registered binary per timestep allows only one direction to flow, so a zero net flow gives zero
link flows.
"""
function _add_mnsp_link_flows!(container::PSI.OptimizationContainer, sys::PSY.System, devices)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(mnsp)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    n_steps = length(time_steps)
    jm = PSI.get_jump_model(container)
    area_demand = _area_demand(container, sys)

    link_var = PSI.add_variable_container!(
        container, MNSPLinkFlowVariable(), PSY.AreaInterchange, names, collect(_MNSP_DIRECTIONS), time_steps,
    )
    direction_var = PSI.add_variable_container!(
        container, MNSPLinkDirectionVariable(), PSY.AreaInterchange, names, time_steps,
    )
    link_loss = PSI.add_variable_container!(
        container, MNSPLinkLossVariable(), PSY.AreaInterchange, names, collect(_MNSP_DIRECTIONS), time_steps,
    )
    link_con = PSI.add_constraints_container!(
        container, MNSPLinkFlowConstraint(), PSY.AreaInterchange, names, time_steps,
    )
    expr = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    loss_var = PSI.get_variable(container, InterconnectorLossVariable(), PSY.AreaInterchange)

    for d in mnsp
        name = PSY.get_name(d)
        loss_model = _loss_model(d)
        curves = Dict{String, Vector{PSY.PiecewiseStepData}}()
        avail = Dict{String, Vector{Float64}}()
        tlf = Dict(dir => _mnsp_link_tlfs(d, dir) for dir in _MNSP_DIRECTIONS)
        area = (forward = PSY.get_name(PSY.get_from_area(d)), reverse = PSY.get_name(PSY.get_to_area(d)))
        other = (forward = area.reverse, reverse = area.forward)
        for dir in _MNSP_DIRECTIONS
            curves[dir] = PSY.get_time_series_values(
                PSY.Deterministic, d, "mnsp_$(dir)_offer"; start_time = initial_time, len = n_steps,
            )
            avail[dir] = PSY.get_time_series_values(
                PSY.Deterministic, d, "mnsp_$(dir)_max_avail"; start_time = initial_time, len = n_steps,
            )
        end
        for t in time_steps
            upper = Dict{String, Float64}()
            for dir in _MNSP_DIRECTIONS
                x = PSY.get_x_coords(curves[dir][t])
                y = PSY.get_y_coords(curves[dir][t])
                widths = diff(x)
                upper[dir] = min(avail[dir][t], sum(widths)) / base_power
                q = JuMP.@variable(
                    jm, lower_bound = 0.0, upper_bound = upper[dir],
                    base_name = "MNSPLinkFlowVariable_{$name,$dir,$t}",
                )
                link_var[name, dir, t] = q
                bands = JuMP.@variable(
                    jm, [i = eachindex(widths)], lower_bound = 0.0,
                    upper_bound = widths[i] / base_power,
                    base_name = "MNSPLinkBandVariable_{$name,$dir,$t}",
                )
                JuMP.@constraint(jm, sum(bands) == q)
                cost = base_power * sum(
                    interval_cost_coefficient(y[i], resolution) * bands[i] for i in eachindex(widths)
                )
                PSI.add_to_objective_invariant_expression!(container, cost)
                sender, receiver = getproperty(area, Symbol(dir)), getproperty(other, Symbol(dir))
                JuMP.add_to_expression!(expr[sender, t], -(tlf[dir].from - 1.0), q)
                JuMP.add_to_expression!(expr[receiver, t], tlf[dir].to - 1.0, q)
            end
            link_con[name, t] = JuMP.@constraint(
                jm, flow_var[name, t] == link_var[name, "forward", t] - link_var[name, "reverse", t]
            )
            forward_on = JuMP.@variable(jm, binary = true, base_name = "MNSPLinkDirectionVariable_{$name,$t}")
            direction_var[name, t] = forward_on
            JuMP.@constraint(jm, link_var[name, "forward", t] <= upper["forward"] * forward_on)
            JuMP.@constraint(jm, link_var[name, "reverse", t] <= upper["reverse"] * (1 - forward_on))
            demand = _demand_at(area_demand, t)
            vertex_losses = _loss_curve_vertex_values(loss_model, demand)
            lower_loss, upper_loss = min(0.0, minimum(vertex_losses)), max(0.0, maximum(vertex_losses))
            for dir in _MNSP_DIRECTIONS
                on = dir == "forward" ? forward_on : 1 - forward_on
                loss = JuMP.@variable(
                    jm, lower_bound = lower_loss, upper_bound = upper_loss,
                    base_name = "MNSPLinkLossVariable_{$name,$dir,$t}",
                )
                link_loss[name, dir, t] = loss
                JuMP.@constraint(jm, loss >= lower_loss * on)
                JuMP.@constraint(jm, loss <= upper_loss * on)
                sender = getproperty(area, Symbol(dir))
                JuMP.add_to_expression!(expr[sender, t], -tlf[dir].from, loss)
            end
            JuMP.@constraint(jm, link_loss[name, "forward", t] + link_loss[name, "reverse", t] == loss_var[name, t])
        end
    end
    return
end
