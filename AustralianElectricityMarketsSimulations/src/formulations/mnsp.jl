PSI.convert_result_to_natural_units(::Type{MNSPLinkFlowVariable}) = true


const _MNSP_DIRECTIONS = ("forward", "reverse")


"Names of an interchange's per-interval flow-limit series, from `set_interconnector_flow_limits!`."
const _FLOW_LIMIT_SERIES = ("from_to_flow_limit", "to_from_flow_limit")


"""
    _has_mnsp_offers(device) -> Bool

Whether `device` carries both links' offer and availability series from `set_mnsp_offers!`. Throws
`ArgumentError` when `device` is an MNSP (`ext["ic_type"] == "MNSP"`), or carries only some of the four
series, since a partial set cannot be modelled.
"""
function _has_mnsp_offers(device::PSY.AreaInterchange)
    present = [
        PSY.has_time_series(device, PSY.SingleTimeSeries, "mnsp_$(dir)_$(kind)")
            for dir in _MNSP_DIRECTIONS, kind in ("offer", "max_avail")
    ]
    required = get(PSY.get_ext(device), "ic_type", nothing) == "MNSP"
    if (required || any(present)) && !all(present)
        throw(ArgumentError("AreaInterchange $(PSY.get_name(device)) is an MNSP with incomplete directional offer inputs; call set_mnsp_offers! with complete data before dispatch"))
    end
    return all(present)
end


"""
    _has_flow_limit_series(device) -> Bool

Whether `device` carries a `"from_to_flow_limit"` or `"to_from_flow_limit"` series, that is,
per-interval flow limits.
"""
function _has_flow_limit_series(device::PSY.AreaInterchange)
    return any(name -> PSY.has_time_series(device, PSY.SingleTimeSeries, name), _FLOW_LIMIT_SERIES)
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


# The time-series parameters of each MNSP link direction.
const _MNSP_PARAMETERS = (
    forward = (width = MNSPForwardBandWidthParameter, max_avail = MNSPForwardMaxAvailParameter),
    reverse = (width = MNSPReverseBandWidthParameter, max_avail = MNSPReverseMaxAvailParameter),
)


PSI.get_multiplier_value(::MNSPBandWidthParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss) = 1.0


PSI.get_multiplier_value(::MNSPMaxAvailParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss) = 1.0


# A band-width parameter's band axis: `_mnsp_band_labels` of the links carrying the series.
function PSI.calc_additional_axes(
        ::PSI.OptimizationContainer, ::MNSPBandWidthParameter,
        devices::Union{Vector{PSY.AreaInterchange}, IS.FlattenIteratorWrapper{PSY.AreaInterchange}},
        ::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
    )
    return (_mnsp_band_labels(devices),)
end


# An offer curve's band widths in MW, padded with zero-width bands to the band axis.
function PSI._unwrap_for_param(::MNSPBandWidthParameter, curve::IS.PiecewiseStepData, expected_axs)
    widths = diff(PSY.get_x_coords(curve))
    n = length(only(expected_axs))
    length(widths) <= n || error("MNSP offer has $(length(widths)) bands, more than the band axis' $n.")
    return vcat(widths, zeros(n - length(widths)))
end


"""
    _mnsp_band_labels(devices) -> Vector{String}

Band labels `"1"` to `"n"`, `n` the most bands any link of an MNSP in `devices` offers over the
whole of its `"mnsp_<direction>_offer"` series.
"""
function _mnsp_band_labels(devices)
    n = 1
    for d in devices, dir in _MNSP_DIRECTIONS
        _has_mnsp_offers(d) || continue
        curves = PSY.get_time_series_values(PSY.SingleTimeSeries, d, "mnsp_$(dir)_offer")
        n = max(n, maximum(c -> length(PSY.get_y_coords(c)), curves))
    end
    return string.(1:n)
end


"""
    _mnsp_link_bound(device, direction) -> Float64

The largest `min(MAXAVAIL, offered MW)` of `device`'s `direction` link over the whole of its
series, in MW.
"""
function _mnsp_link_bound(device::PSY.AreaInterchange, direction::AbstractString)
    curves = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "mnsp_$(direction)_offer")
    avail = PSY.get_time_series_values(PSY.SingleTimeSeries, device, "mnsp_$(direction)_max_avail")
    return maximum(min(a, sum(diff(PSY.get_x_coords(c)))) for (a, c) in zip(avail, curves))
end


"""
    _mnsp_offer_window(container, device, direction, start_time) -> Vector{PSY.PiecewiseStepData}

`device`'s `direction` offer curves over the container's time steps from `start_time`, read from the
container's default forecast type.
"""
function _mnsp_offer_window(container::PSI.OptimizationContainer, device::PSY.AreaInterchange, direction::AbstractString, start_time::DateTime)
    ts_type = PSI.get_default_time_series_type(container)
    forecast = IS.get_time_series(ts_type, device, "mnsp_$(direction)_offer"; start_time = start_time, count = 1)
    return IS.get_time_series_values(
        device, forecast; start_time = start_time, len = length(PSI.get_time_steps(container)),
        ignore_scaling_factors = true,
    )
end


"""
    _set_mnsp_band_prices!(container, prices, multiplier, device, direction, start_time)

Writes the band prices of `device`'s `direction` offers from `start_time` into the
[`MNSPBandPriceParameter`](@ref) array `prices` (`0.0` beyond the offered bands) and adds each
band's cost, price times `multiplier`, to the variant objective.

# Returns
`nothing`.
"""
function _set_mnsp_band_prices!(container::PSI.OptimizationContainer, prices, multiplier, device::PSY.AreaInterchange, direction::AbstractString, start_time::DateTime)
    name = PSY.get_name(device)
    bands = PSI.get_variable(container, MNSPLinkBandVariable(), PSY.AreaInterchange, direction)
    labels = axes(prices)[2]
    for (t, curve) in enumerate(_mnsp_offer_window(container, device, direction, start_time))
        y = PSY.get_y_coords(curve)
        for (b, label) in enumerate(labels)
            prices[name, label, t] = b <= length(y) ? y[b] : 0.0
            PSI.add_to_objective_variant_expression!(
                container, prices[name, label, t] * multiplier[name, label, t] * bands[name, label, t],
            )
        end
    end
    return
end


"""
    PSI.update_container_parameter_values!(container, model, key::PSI.ParameterKey{MNSPBandPriceParameter, PSY.AreaInterchange}, input)

Simulation-step update of the [`MNSPBandPriceParameter`](@ref) of the link `key.meta`: reads each
MNSP's band prices for the window at the model's current time and re-adds the band costs to the
variant objective.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{MNSPBandPriceParameter, PSY.AreaInterchange}, ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    PSI.is_synchronized(container) && error(
        "Cannot update MNSPBandPriceParameter on a synchronized container; the band costs would be added twice.",
    )
    prices = PSI.get_parameter_array(container, key)
    multiplier = PSI.get_parameter_multiplier_array(container, key)
    sys = PSI.get_system(model)
    for name in axes(prices)[1]
        device = PSY.get_component(PSY.AreaInterchange, sys, name)
        _set_mnsp_band_prices!(container, prices, multiplier, device, key.meta, PSI.get_current_time(model))
    end
    return
end


"""
    _add_mnsp_link_flows!(container, devices, device_model)

Adds, for each device in `devices` carrying MNSP offers, a link flow per direction and timestep, the
sum of its offer bands, tied to the interconnector flow as `flow = forward - reverse`. Link flows
enter the regional balances at the link's ends, and the two directional losses are bounded by
[`_loss_range`](@ref). Devices without offers keep their free-flow model.

# Arguments
- `container`: the optimization container of the model being built.
- `devices`: the `PSY.AreaInterchange` devices of the formulation.
- `device_model`: the `PSI.DeviceModel` supplying the MNSP parameter time-series names.

# Returns
`nothing`.
"""
function _add_mnsp_link_flows!(container::PSI.OptimizationContainer, devices, device_model)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(mnsp)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    initial_time = PSI.get_initial_time(container)
    jm = PSI.get_jump_model(container)
    labels = _mnsp_band_labels(mnsp)

    for dir in _MNSP_DIRECTIONS, param in _MNSP_PARAMETERS[Symbol(dir)]
        PSI.add_parameters!(container, param, devices, device_model)
    end
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
    band_var = Dict{String, Any}()
    width = Dict{String, Any}()
    max_avail = Dict{String, Any}()
    for dir in _MNSP_DIRECTIONS
        band_var[dir] = PSI.add_variable_container!(
            container, MNSPLinkBandVariable(), PSY.AreaInterchange, names, labels, time_steps; meta = dir,
        )
        for name in names, label in labels, t in time_steps
            band_var[dir][name, label, t] = JuMP.@variable(
                jm, lower_bound = 0.0, base_name = "MNSPLinkBandVariable_{$name,$dir,$label,$t}",
            )
        end
        params = _MNSP_PARAMETERS[Symbol(dir)]
        width[dir] = PSI.get_parameter(container, params.width(), PSY.AreaInterchange)
        max_avail[dir] = PSI.get_parameter(container, params.max_avail(), PSY.AreaInterchange)
    end

    for d in mnsp
        name = PSY.get_name(d)
        lower_loss, upper_loss = _loss_range(d, _loss_model(d))
        tlf = Dict(dir => _mnsp_link_tlfs(d, dir) for dir in _MNSP_DIRECTIONS)
        bound = Dict(dir => _mnsp_link_bound(d, dir) / base_power for dir in _MNSP_DIRECTIONS)
        area = (forward = PSY.get_name(PSY.get_from_area(d)), reverse = PSY.get_name(PSY.get_to_area(d)))
        other = (forward = area.reverse, reverse = area.forward)
        widths = Dict(dir => PSI.get_parameter_column_refs(width[dir], name) for dir in _MNSP_DIRECTIONS)
        width_mult = Dict(dir => PSI.get_multiplier_array(width[dir]) for dir in _MNSP_DIRECTIONS)
        avails = Dict(dir => PSI.get_parameter_column_refs(max_avail[dir], name) for dir in _MNSP_DIRECTIONS)
        avail_mult = Dict(dir => PSI.get_multiplier_array(max_avail[dir]) for dir in _MNSP_DIRECTIONS)
        for t in time_steps
            for dir in _MNSP_DIRECTIONS
                q = JuMP.@variable(
                    jm, lower_bound = 0.0, upper_bound = bound[dir],
                    base_name = "MNSPLinkFlowVariable_{$name,$dir,$t}",
                )
                link_var[name, dir, t] = q
                bands = band_var[dir]
                for label in labels
                    JuMP.@constraint(jm, bands[name, label, t] <= width_mult[dir][name, label, t] * widths[dir][label, t] / base_power)
                end
                JuMP.@constraint(jm, sum(bands[name, label, t] for label in labels) == q)
                JuMP.@constraint(jm, q <= avail_mult[dir][name, t] * avails[dir][t] / base_power)
                sender, receiver = getproperty(area, Symbol(dir)), getproperty(other, Symbol(dir))
                JuMP.add_to_expression!(expr[sender, t], -(tlf[dir].from - 1.0), q)
                JuMP.add_to_expression!(expr[receiver, t], tlf[dir].to - 1.0, q)
            end
            link_con[name, t] = JuMP.@constraint(
                jm, flow_var[name, t] == link_var[name, "forward", t] - link_var[name, "reverse", t]
            )
            forward_on = JuMP.@variable(jm, binary = true, base_name = "MNSPLinkDirectionVariable_{$name,$t}")
            direction_var[name, t] = forward_on
            JuMP.@constraint(jm, link_var[name, "forward", t] <= bound["forward"] * forward_on)
            JuMP.@constraint(jm, link_var[name, "reverse", t] <= bound["reverse"] * (1 - forward_on))
            for dir in _MNSP_DIRECTIONS
                on = dir == "forward" ? forward_on : 1 - forward_on
                loss = JuMP.@variable(
                    jm, lower_bound = lower_loss, upper_bound = upper_loss,
                    base_name = "MNSPLinkLossVariable_{$name,$dir,$t}",
                )
                link_loss[name, dir, t] = loss
                JuMP.@constraint(jm, loss >= lower_loss * on)
                JuMP.@constraint(jm, loss <= upper_loss * on)
                JuMP.add_to_expression!(expr[getproperty(area, Symbol(dir)), t], -tlf[dir].from, loss)
            end
            JuMP.@constraint(jm, link_loss[name, "forward", t] + link_loss[name, "reverse", t] == loss_var[name, t])
        end
    end

    for dir in _MNSP_DIRECTIONS
        price = PSI.add_param_container!(
            container, MNSPBandPriceParameter(), PSY.AreaInterchange, (MNSPLinkBandVariable,),
            PSI.SOSStatusVariable.NO_VARIABLE, false, Float64, names, labels, time_steps; meta = dir,
        )
        prices, multiplier = PSI.get_parameter_array(price), PSI.get_multiplier_array(price)
        fill!(multiplier, base_power * interval_hours(resolution))
        for d in mnsp
            _set_mnsp_band_prices!(container, prices, multiplier, d, dir, initial_time)
        end
    end
    return
end
