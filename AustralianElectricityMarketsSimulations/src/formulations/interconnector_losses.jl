function PSI.convert_result_to_natural_units(::Type{InterconnectorLossVariable})
    return true
end

function PSI.convert_result_to_natural_units(::Type{InterconnectorLossSegmentVariable})
    return true
end


# PSI's flow-limit series names for `AreaInterchange`, plus the loss-factor demand coefficient.
function PSI.get_default_time_series_names(::Type{PSY.AreaInterchange}, ::Type{NEMInterconnectorLoss})
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}(
        PSI.FromToFlowLimitParameter => NEM_SERIES.from_to_flow_limit,
        PSI.ToFromFlowLimitParameter => NEM_SERIES.to_from_flow_limit,
        LossDemandCoefficientParameter => NEM_SERIES.loss_demand_coefficient,
        MNSPForwardBandWidthParameter => mnsp_series_name("forward", "offer"),
        MNSPReverseBandWidthParameter => mnsp_series_name("reverse", "offer"),
        MNSPForwardMaxAvailParameter => mnsp_series_name("forward", "max_avail"),
        MNSPReverseMaxAvailParameter => mnsp_series_name("reverse", "max_avail"),
        _MNSP_OPERATING_SERIES...,
    )
end


function PSI.get_multiplier_value(::LossDemandCoefficientParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss)
    return 1.0
end

# --- attached `InterconnectorLossModel` + per-interconnector validation ---

"""
    _missing_loss_model_error(name, n) -> ArgumentError

The `ArgumentError` naming `name`, an `AreaInterchange` that carries `n` rather than exactly one
`InterconnectorLossModel`.
"""
function _missing_loss_model_error(name::AbstractString, n::Int)
    return ArgumentError(
        "AreaInterchange \"$name\" carries $n InterconnectorLossModel supplemental attribute(s); " *
            "NEMInterconnectorLoss requires exactly one. Attach it with " *
            "`attach_interconnector_losses!(sys, db, as_of)` (root package), or give \"$name\" a " *
            "lossless formulation such as `PSI.StaticBranch`.",
    )
end


"""
    _loss_model(device) -> InterconnectorLossModel

The single [`InterconnectorLossModel`](@ref) attached to `device` (an `AreaInterchange`) via
`attach_interconnector_losses!`. Throws [`_missing_loss_model_error`](@ref) if `device` carries
zero or more than one.
"""
function _loss_model(device::PSY.AreaInterchange)
    models = PSY.get_supplemental_attributes(InterconnectorLossModel, device)
    length(models) == 1 || throw(_missing_loss_model_error(PSY.get_name(device), length(models)))
    return only(models)
end


"""
    _validate_convex_segments(name, model)

Throws `ArgumentError` naming `name` when `model`'s [`loss_segments`](@ref) chord slopes are not
ascending. Evaluated once per interconnector against an empty demand, since demand shifts every
slope by the same constant.
"""
function _validate_convex_segments(name::AbstractString, model::InterconnectorLossModel)
    segments = loss_segments(model, Dict{String, Float64}())
    issorted(s.slope for s in segments) || throw(
        ArgumentError(
            "AreaInterchange \"$name\"'s InterconnectorLossModel has non-ascending loss " *
                "segment slopes (loss_flow_coefficient = $(model.loss_flow_coefficient) makes " *
                "the loss curve concave, not convex); NEMInterconnectorLoss's contiguous " *
                "segment fill requires a convex curve.",
        ),
    )
    return nothing
end


"""
    _narrow_breakpoint_interconnectors(devices, loss_models) -> Vector{String}

Names of `devices` (without flow-limit time series) whose loss-model breakpoint range is strictly
narrower than their static `PSY.get_flow_limits`. Both are per-unit of the system base.
"""
function _narrow_breakpoint_interconnectors(devices, loss_models::Dict{String, InterconnectorLossModel})
    narrow = String[]
    for d in devices
        _has_flow_limit_series(d) && continue
        name = PSY.get_name(d)
        bps = loss_models[name].breakpoints
        limits = PSY.get_flow_limits(d)
        if bps[1] > -limits.from_to || bps[end] < limits.to_from
            push!(narrow, name)
        end
    end
    return narrow
end


"""
    _warn_narrow_breakpoints(narrow)

Emits one `@warn` naming every interconnector in `narrow`; silent when `narrow` is empty.
"""
function _warn_narrow_breakpoints(narrow::Vector{String})
    isempty(narrow) ||
        @warn "NEMInterconnectorLoss: $(length(narrow)) interconnector(s) have a loss-model breakpoint range narrower than their own flow limits; dispatch is tightened to the breakpoint range" narrow
    return nothing
end


# --- loss-factor demand coefficient ---

"""
    _check_loss_demand_coefficients(container, devices, device_model)

Throws `ArgumentError` naming every interconnector in `devices` without a forecast of the model's
[`LossDemandCoefficientParameter`](@ref) series.

# Arguments
- `container`: the optimization container of the model being built.
- `devices`: the `PSY.AreaInterchange` devices of the formulation.
- `device_model`: the `PSI.DeviceModel` supplying the series name.

# Returns
`nothing`.
"""
function _check_loss_demand_coefficients(container::PSI.OptimizationContainer, devices, device_model)
    name = PSI.get_time_series_names(device_model)[LossDemandCoefficientParameter]
    ts_type = PSI.get_default_time_series_type(container)
    uncovered = [PSY.get_name(d) for d in devices if !PSY.has_time_series(d, ts_type, name)]
    isempty(uncovered) || throw(
        ArgumentError(
            "NEMInterconnectorLoss: $(length(uncovered)) interconnector(s) carry no \"$name\" forecast: " *
                "$(join(uncovered, ", ")). Call set_loss_demand_coefficients!(sys) before transform_single_time_series!.",
        ),
    )
    return
end


"""
    _loss_range(device, model) -> Tuple{Float64, Float64}

The smallest and largest zero-referenced vertex loss of `model` over every value of `device`'s
`"loss_demand_coefficient"` series, widened to include `0.0`, per-unit of the system base.
"""
function _loss_range(device::PSY.AreaInterchange, model::InterconnectorLossModel)
    coefficients = PSY.get_time_series_values(PSY.SingleTimeSeries, device, NEM_SERIES.loss_demand_coefficient)
    at_zero = loss_curve_vertex_values(model, Dict{String, Float64}())
    vertex = [v + k * bp for k in coefficients for (v, bp) in zip(at_zero, model.breakpoints)]
    return min(0.0, minimum(vertex)), max(0.0, maximum(vertex))
end


# --- loss variables/constraints + area balance terms ---

# Segment counts per device and the shared segment and order axes, sized to the largest interconnector.
function _loss_segment_axes(devices, loss_models::Dict{String, InterconnectorLossModel})
    n_segments = Dict(PSY.get_name(d) => length(loss_models[PSY.get_name(d)].breakpoints) - 1 for d in devices)
    segment_labels = string.(1:maximum(values(n_segments)))
    return n_segments, segment_labels, segment_labels[1:(end - 1)]
end


"""
    _add_loss_variables!(container, devices, loss_models)

Adds the segment, fill-indicator and loss variables, and the `-share * loss` and
`-(1 - share) * loss` terms in the from and to area balances. Segment widths are those at zero
demand. Devices carrying directional MNSP offers omit the balance terms: their losses are supplied
at the sending area. The segment axis is sized to the largest interconnector; unused cells are
fixed to zero. All quantities are per-unit of the system base.
"""
function _add_loss_variables!(
        container::PSI.OptimizationContainer,
        devices,
        loss_models::Dict{String, InterconnectorLossModel},
    )
    time_steps = PSI.get_time_steps(container)
    device_names = PSY.get_name.(devices)
    n_segments, segment_labels, order_labels = _loss_segment_axes(devices, loss_models)
    seg_var = PSI.add_variable_container!(
        container, InterconnectorLossSegmentVariable(), PSY.AreaInterchange,
        device_names, segment_labels, time_steps,
    )
    loss_var = PSI.add_variable_container!(
        container, InterconnectorLossVariable(), PSY.AreaInterchange, device_names, time_steps,
    )
    # PSI cannot read back an empty container, so a model with only straight-line curves has none.
    ordered = !isempty(order_labels)
    if ordered
        full_var = PSI.add_variable_container!(
            container, InterconnectorLossSegmentFullVariable(), PSY.AreaInterchange,
            device_names, order_labels, time_steps,
        )
    end
    expr = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)
    jm = PSI.get_jump_model(container)

    for d in devices
        name = PSY.get_name(d)
        model = loss_models[name]
        n = n_segments[name]
        from_area = PSY.get_name(PSY.get_from_area(d))
        to_area = PSY.get_name(PSY.get_to_area(d))
        share = model.from_region_loss_share
        _check_mnsp_offers(d)
        offered = _has_mnsp_offers(d)
        segments = loss_segments(model, Dict{String, Float64}())
        for t in time_steps
            for (s, label) in enumerate(segment_labels)
                width = s <= n ? (segments[s].to_mw - segments[s].from_mw) : 0.0
                seg_var[name, label, t] = JuMP.@variable(
                    jm, lower_bound = 0.0, upper_bound = width,
                    base_name = "InterconnectorLossSegmentVariable_{$name,$s,$t}",
                )
            end
            if ordered
                for (s, label) in enumerate(order_labels)
                    full_var[name, label, t] = JuMP.@variable(
                        jm, binary = true,
                        base_name = "InterconnectorLossSegmentFullVariable_{$name,$s,$t}",
                    )
                end
            end
            loss_var[name, t] = JuMP.@variable(
                jm, base_name = "InterconnectorLossVariable_{$name,$t}",
            )
            if !offered
                JuMP.add_to_expression!(expr[from_area, t], -share, loss_var[name, t])
                JuMP.add_to_expression!(expr[to_area, t], -(1.0 - share), loss_var[name, t])
            end
        end
    end
    return
end


"""
    _add_loss_constraints!(container, devices, loss_models)

Adds the segment-order, flow-segment and loss-definition constraints over the variables of
[`_add_loss_variables!`](@ref). Segment widths, slopes and the first-breakpoint loss are those at
zero demand; the demand term enters as the flow's coefficient in the loss definition, driven by
[`LossDemandCoefficientParameter`](@ref).
"""
function _add_loss_constraints!(
        container::PSI.OptimizationContainer,
        devices,
        loss_models::Dict{String, InterconnectorLossModel},
    )
    time_steps = PSI.get_time_steps(container)
    device_names = PSY.get_name.(devices)
    n_segments, segment_labels, order_labels = _loss_segment_axes(devices, loss_models)
    seg_var = PSI.get_variable(container, InterconnectorLossSegmentVariable(), PSY.AreaInterchange)
    loss_var = PSI.get_variable(container, InterconnectorLossVariable(), PSY.AreaInterchange)
    ordered = !isempty(order_labels)
    if ordered
        full_var = PSI.get_variable(container, InterconnectorLossSegmentFullVariable(), PSY.AreaInterchange)
        order_ub = PSI.add_constraints_container!(
            container, InterconnectorLossSegmentOrderConstraint(), PSY.AreaInterchange,
            device_names, order_labels, time_steps; meta = "ub",
        )
        order_lb = PSI.add_constraints_container!(
            container, InterconnectorLossSegmentOrderConstraint(), PSY.AreaInterchange,
            device_names, order_labels, time_steps; meta = "lb",
        )
    end
    flow_seg_con = PSI.add_constraints_container!(
        container, InterconnectorFlowSegmentConstraint(), PSY.AreaInterchange,
        device_names, time_steps,
    )
    loss_def_con = PSI.add_constraints_container!(
        container, InterconnectorLossDefinitionConstraint(), PSY.AreaInterchange,
        device_names, time_steps,
    )
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    jm = PSI.get_jump_model(container)
    coefficient_key = PSI.ParameterKey(LossDemandCoefficientParameter, PSY.AreaInterchange)

    for d in devices
        name = PSY.get_name(d)
        model = loss_models[name]
        n = n_segments[name]
        bp1 = model.breakpoints[1]
        segments = loss_segments(model, Dict{String, Float64}())
        base_loss = first(loss_curve_vertex_values(model, Dict{String, Float64}()))
        for t in time_steps
            if ordered
                for s in 1:(n - 1)
                    lbl, next = order_labels[s], segment_labels[s + 1]
                    order_ub[name, lbl, t] = JuMP.@constraint(
                        jm,
                        seg_var[name, next, t] <=
                            (segments[s + 1].to_mw - segments[s + 1].from_mw) * full_var[name, lbl, t]
                    )
                    order_lb[name, lbl, t] = JuMP.@constraint(
                        jm,
                        seg_var[name, lbl, t] >=
                            (segments[s].to_mw - segments[s].from_mw) * full_var[name, lbl, t]
                    )
                end
            end
            flow_seg_con[name, t] = JuMP.@constraint(
                jm,
                flow_var[name, t] ==
                    bp1 + sum(seg_var[name, label, t] for label in segment_labels)
            )
            # The flow term's coefficient is the demand coefficient, set by the target below.
            loss_def_con[name, t] = JuMP.@constraint(
                jm,
                loss_var[name, t] == base_loss +
                    sum(segments[s].slope * seg_var[name, segment_labels[s], t] for s in 1:n) +
                    flow_var[name, t]
            )
            PSI.add_coefficient_target!(container, coefficient_key, name, t, loss_def_con[name, t], flow_var[name, t], -1.0)
        end
    end
    return
end


# PSI builds `FlowLimitConstraint` only for the concrete `StaticBranch` model, so it is repeated here.

"""
    _add_flow_limit_constraint!(container, devices, device_model, network_model)

Bounds `PSI.FlowActivePowerVariable` by the static `flow_limits`, or by the from-to and to-from
flow-limit parameters when every device carries those time series. Each row carries an
[`InterconnectorFlowSurplusSlack`](@ref) (upper) or [`InterconnectorFlowDeficitSlack`](@ref)
(lower) priced at [`INTERCONNECTOR_FLOW_CVP_FACTOR`](@ref) times the Market Price Cap, always,
whatever the device model's `use_slacks`, as NEMDE's limit is always soft, so
limits that conflict with each other or with the loss breakpoint range are violated at that price
instead of making the model infeasible. The breakpoint range itself stays a hard bound. Because
the slacks are priced from the Market Price Cap, building requires a cap for every interval,
whether the cap comes from `MARKET_PRICE_CAP_BY_FINANCIAL_YEAR` (from FY2024-25) or from the
`"market_price_cap"` entry of the model's settings, even when `use_slacks` is `false`.
"""
function _add_flow_limit_constraint!(
        container::PSI.OptimizationContainer,
        devices,
        device_model::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
        ::PSI.NetworkModel{U},
    ) where {U <: PSI.AreaBalancePowerModel}
    time_steps = PSI.get_time_steps(container)
    device_names = PSY.get_name.(devices)

    con_ub = PSI.add_constraints_container!(
        container, PSI.FlowLimitConstraint(), PSY.AreaInterchange, device_names, time_steps;
        meta = "ub",
    )
    con_lb = PSI.add_constraints_container!(
        container, PSI.FlowLimitConstraint(), PSY.AreaInterchange, device_names, time_steps;
        meta = "lb",
    )
    var_array = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    jm = PSI.get_jump_model(container)
    surplus = _add_cvp_slack!(
        container, InterconnectorFlowSurplusSlack, PSY.AreaInterchange, device_names, time_steps,
        INTERCONNECTOR_FLOW_CVP_FACTOR,
    )
    deficit = _add_cvp_slack!(
        container, InterconnectorFlowDeficitSlack, PSY.AreaInterchange, device_names, time_steps,
        INTERCONNECTOR_FLOW_CVP_FACTOR,
    )

    if !all(_has_flow_limit_series.(devices))
        for device in devices
            name = PSY.get_name(device)
            to_from_limit = PSY.get_flow_limits(device).to_from
            from_to_limit = PSY.get_flow_limits(device).from_to
            for t in time_steps
                con_lb[name, t] = JuMP.@constraint(jm, var_array[name, t] + deficit[name, t] >= -1.0 * from_to_limit)
                con_ub[name, t] = JuMP.@constraint(jm, var_array[name, t] - surplus[name, t] <= to_from_limit)
            end
        end
    else
        param_from_to = PSI.get_parameter(
            container, PSI.FromToFlowLimitParameter(), PSY.AreaInterchange,
        )
        mult_from_to = PSI.get_parameter_multiplier_array(
            container, PSI.FromToFlowLimitParameter(), PSY.AreaInterchange,
        )
        param_to_from = PSI.get_parameter(
            container, PSI.ToFromFlowLimitParameter(), PSY.AreaInterchange,
        )
        mult_to_from = PSI.get_parameter_multiplier_array(
            container, PSI.ToFromFlowLimitParameter(), PSY.AreaInterchange,
        )
        for device in devices
            name = PSY.get_name(device)
            refs_from_to = PSI.get_parameter_column_refs(param_from_to, name)
            refs_to_from = PSI.get_parameter_column_refs(param_to_from, name)
            for t in time_steps
                con_lb[name, t] = JuMP.@constraint(
                    jm, var_array[name, t] + deficit[name, t] >= mult_from_to[name, t] * refs_from_to[t]
                )
                con_ub[name, t] = JuMP.@constraint(
                    jm, var_array[name, t] - surplus[name, t] <= mult_to_from[name, t] * refs_to_from[t]
                )
            end
        end
    end
    return
end


# --- construct_device! stage pair ---

function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        device_model::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
        network_model::PSI.NetworkModel{U},
    ) where {U <: PSI.AreaBalancePowerModel}
    devices = PSI.get_available_components(device_model, sys)
    isempty(devices) && return
    loss_models = Dict(PSY.get_name(d) => _loss_model(d) for d in devices)
    for d in devices
        _validate_convex_segments(PSY.get_name(d), loss_models[PSY.get_name(d)])
    end
    narrow = _narrow_breakpoint_interconnectors(devices, loss_models)
    _warn_narrow_breakpoints(narrow)

    has_ts = _has_flow_limit_series.(devices)
    if any(has_ts) && !all(has_ts)
        throw(
            ArgumentError(
                "Not all AreaInterchange devices have time series. Check data to complete (or remove) time series.",
            ),
        )
    end
    PSI.add_variables!(
        container, PSI.FlowActivePowerVariable, network_model, devices, NEMInterconnectorLoss(),
    )
    PSI.add_to_expression!(
        container, PSI.ActivePowerBalance, PSI.FlowActivePowerVariable, devices, device_model,
        network_model,
    )
    if all(has_ts)
        for device in devices
            name = PSY.get_name(device)
            if !all(series -> PSY.has_time_series(device, PSY.SingleTimeSeries, series), _FLOW_LIMIT_SERIES)
                throw(
                    ArgumentError(
                        "AreaInterchange $name has less than two time series. It is required to add both from_to and to_from time series.",
                    ),
                )
            end
        end
        PSI.add_parameters!(container, PSI.FromToFlowLimitParameter, devices, device_model)
        PSI.add_parameters!(container, PSI.ToFromFlowLimitParameter, devices, device_model)
    end
    PSI.add_feedforward_arguments!(container, device_model, devices)

    _check_loss_demand_coefficients(container, devices, device_model)
    PSI.add_parameters!(container, LossDemandCoefficientParameter, devices, device_model)
    _add_loss_variables!(container, devices, loss_models)
    _add_mnsp_link_variables!(container, devices, device_model)
    return
end


function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        device_model::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
        network_model::PSI.NetworkModel{U},
    ) where {U <: PSI.AreaBalancePowerModel}
    devices = PSI.get_available_components(device_model, sys)
    isempty(devices) && return
    loss_models = Dict(PSY.get_name(d) => _loss_model(d) for d in devices)
    _add_loss_constraints!(container, devices, loss_models)
    _add_mnsp_link_constraints!(container, devices)
    _add_mnsp_operating_constraints!(container, devices)
    _add_mnsp_band_costs!(container, devices)
    _add_flow_limit_constraint!(container, devices, device_model, network_model)
    PSI.add_feedforward_constraints!(container, device_model, devices)
    return
end


function PSI.construct_device!(
        ::PSI.OptimizationContainer,
        ::PSY.System,
        ::Union{PSI.ArgumentConstructStage, PSI.ModelConstructStage},
        ::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
        ::PSI.NetworkModel{U},
    ) where {U <: PM.AbstractPowerModel}
    throw(ArgumentError("NEMInterconnectorLoss supports PSI.AreaBalancePowerModel only, got $U"))
end
