# MNSP link offers on a `PSY.AreaInterchange` under `NEMInterconnectorLoss`: the interconnector's net
# flow is split into a forward and a reverse link flow, each bounded and priced by its own offer.

"""
One MNSP link's flow at one timestep - MW, per-unit of base power, non-negative. Indexed
`(interconnector name, "forward" | "reverse", t)`; the forward link carries flow from the
interconnector's from area to its to area.
"""
struct MNSPLinkFlowVariable <: PSI.VariableType end

"`flow[ic,t] == forward link flow - reverse link flow`, per-unit."
struct MNSPLinkFlowConstraint <: PSI.ConstraintType end

PSI.convert_result_to_natural_units(::Type{MNSPLinkFlowVariable}) = true

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
    _mnsp_link_tlf(device, direction) -> Float64

The from-end loss factor of `device`'s `direction` link, as recorded by `set_mnsp_offers!`.
Throws `ArgumentError` when it is missing or not positive.
"""
function _mnsp_link_tlf(device::PSY.AreaInterchange, direction::AbstractString)
    info = get(PSY.get_ext(device), "mnsp_$direction", nothing)
    tlf = isnothing(info) ? nothing : get(info, "from_region_tlf", nothing)
    (tlf isa Real && tlf > 0) || throw(
        ArgumentError(
            "AreaInterchange \"$(PSY.get_name(device))\" has MNSP offers but no positive " *
                "from_region_tlf for its $direction link in ext[\"mnsp_$direction\"]",
        ),
    )
    return Float64(tlf)
end

"""
    _add_mnsp_link_flows!(container, devices)

For every device in `devices` carrying MNSP offers, adds one non-negative link flow per direction and
timestep, bounded by the link's `MAXAVAIL` and its offered bands, and ties it to the interconnector
flow as `flow = forward - reverse`. Each link's bands enter the objective at the offered price divided
by the link's from-end loss factor. Per-unit of the system base. Devices without offers are untouched
and keep their free-flow model.

Where the lowest offered prices of the two links sum below zero, circulating both links at once would
be profitable, so a binary per timestep allows only one direction to flow.
"""
function _add_mnsp_link_flows!(container::PSI.OptimizationContainer, devices)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(mnsp)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    n_steps = length(time_steps)
    jm = PSI.get_jump_model(container)

    link_var = PSI.add_variable_container!(
        container, MNSPLinkFlowVariable(), PSY.AreaInterchange, names, collect(_MNSP_DIRECTIONS), time_steps,
    )
    link_con = PSI.add_constraints_container!(
        container, MNSPLinkFlowConstraint(), PSY.AreaInterchange, names, time_steps,
    )
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)

    for d in mnsp
        name = PSY.get_name(d)
        curves = Dict{String, Vector{PSY.PiecewiseStepData}}()
        avail = Dict{String, Vector{Float64}}()
        tlf = Dict(dir => _mnsp_link_tlf(d, dir) for dir in _MNSP_DIRECTIONS)
        for dir in _MNSP_DIRECTIONS
            curves[dir] = PSY.get_time_series_values(
                PSY.Deterministic, d, "mnsp_$(dir)_offer"; start_time = initial_time, len = n_steps,
            )
            avail[dir] = PSY.get_time_series_values(
                PSY.Deterministic, d, "mnsp_$(dir)_max_avail"; start_time = initial_time, len = n_steps,
            )
            (length(curves[dir]) == n_steps && length(avail[dir]) == n_steps) || throw(
                ArgumentError(
                    "AreaInterchange \"$name\" MNSP $dir offer covers fewer than the model's $n_steps steps",
                ),
            )
        end
        for t in time_steps
            upper = Dict{String, Float64}()
            lowest_price = Dict{String, Float64}()
            for dir in _MNSP_DIRECTIONS
                x = PSY.get_x_coords(curves[dir][t])
                y = PSY.get_y_coords(curves[dir][t])
                widths = diff(x)
                upper[dir] = min(avail[dir][t], sum(widths)) / base_power
                first_band = findfirst(>(0), widths)
                lowest_price[dir] = isnothing(first_band) ? Inf : y[first_band] / tlf[dir]
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
                    interval_cost_coefficient(y[i] / tlf[dir], resolution) * bands[i] for i in eachindex(widths)
                )
                PSI.add_to_objective_invariant_expression!(container, cost)
            end
            link_con[name, t] = JuMP.@constraint(
                jm, flow_var[name, t] == link_var[name, "forward", t] - link_var[name, "reverse", t]
            )
            if lowest_price["forward"] + lowest_price["reverse"] < 0
                forward_on = JuMP.@variable(jm, binary = true, base_name = "MNSPLinkDirection_{$name,$t}")
                JuMP.@constraint(jm, link_var[name, "forward", t] <= upper["forward"] * forward_on)
                JuMP.@constraint(jm, link_var[name, "reverse", t] <= upper["reverse"] * (1 - forward_on))
            end
        end
    end
    return
end
