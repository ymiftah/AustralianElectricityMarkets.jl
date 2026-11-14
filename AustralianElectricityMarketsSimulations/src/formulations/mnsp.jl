function PSI.convert_result_to_natural_units(::Type{MNSPLinkFlowVariable})
    return true
end


# The values of the time series behind `key` on `device`, in order.
function _series_values(device, key::IS.TimeSeriesKey)
    ts::PSY.SingleTimeSeries = IS.get_time_series(device, key)
    return collect(values(PSY.get_time_series_array(device, ts)))
end


# Throws an `ArgumentError` naming `device` unless its derived fixed-loading series are attached and its bids'
# fixed-loading keys are named as the writer names them.
function _require_mnsp_fixed_loads(device::PSY.AreaInterchange)
    for dir in _MNSP_DIRECTIONS
        bid = _mnsp_bid(device, dir)
        (isnothing(bid) || isnothing(bid.fixed_load)) && continue
        bid.fixed_load isa IS.StaticTimeSeriesKey &&
            _require_key_name(device, bid.fixed_load, getproperty(NEM_MNSP_SERIES, Symbol(dir, "_fixed_load")))
    end
    for dir in _MNSP_DIRECTIONS, kind in (:value, :invoked)
        name = getproperty(NEM_MNSP_FIXED_LOAD_SERIES, Symbol(dir, "_", kind))
        PSY.has_time_series(device, PSY.SingleTimeSeries, name) || throw(
            ArgumentError(
                "AreaInterchange \"$(PSY.get_name(device))\" has no derived MNSP fixed loading \"$name\"; " *
                    "its replay inputs are written by nem_system, so build the system with it before the formulation",
            ),
        )
    end
    return
end


# The `NEMMNSPLink` of `device` for `direction`, or `nothing` when it has none.
function _mnsp_link(device::PSY.AreaInterchange, direction::AbstractString)
    dir = direction == "forward" ? MNSPDirection.FORWARD : MNSPDirection.REVERSE
    links = [l for l in (PSY.get_supplemental_attributes(NEMMNSPLink, device)::Vector{NEMMNSPLink}) if l.direction == dir]
    isempty(links) && return nothing
    length(links) == 1 || throw(
        ArgumentError("AreaInterchange \"$(PSY.get_name(device))\" carries $(length(links)) NEMMNSPLink for its $direction link; it requires one."),
    )
    return only(links)
end


# Whether `device`'s `direction` bid holds `field` as a key, which must be named `expected`.
function _mnsp_key_present(device::PSY.AreaInterchange, direction::AbstractString, field::Symbol, expected::AbstractString)
    bid = _mnsp_bid(device, direction)
    isnothing(bid) && return false
    key = getproperty(bid, field)
    key isa IS.StaticTimeSeriesKey || return false
    _require_key_name(device, key, expected)
    return true
end


# The `(field, suffix)` of each `NEMMNSPBid` key an MNSP link carries; the suffix names its series in `NEM_MNSP_SERIES`.
const _MNSP_BID_KEYS = ((:offer_curves, "offer"), (:max_avail, "max_avail"), (:ramp_up, "ramp_rate"))


# Whether each of `device`'s MNSP keys is attached, in `_MNSP_DIRECTIONS` order per `_MNSP_BID_KEYS`, then the initial flow.
function _mnsp_offer_series_present(device::PSY.AreaInterchange)
    bids = [
        _mnsp_key_present(device, dir, field, getproperty(NEM_MNSP_SERIES, Symbol(dir, "_", suffix)))
            for dir in _MNSP_DIRECTIONS, (field, suffix) in _MNSP_BID_KEYS
    ]
    observed = PSY.get_supplemental_attributes(NEMMNSPObservedState, device)::Vector{NEMMNSPObservedState}
    initial = !isempty(observed) && only(observed).initial_flow isa IS.StaticTimeSeriesKey
    initial && _require_key_name(device, only(observed).initial_flow, NEM_MNSP_SERIES.initial_flow)
    return vec(bids), initial
end


"""
    _has_mnsp_offers(device) -> Bool

Whether `device` carries both links' offer and availability series from `set_mnsp_offers!`.
`_check_mnsp_offers` rejects a partial set.
"""
function _has_mnsp_offers(device::PSY.AreaInterchange)
    bids, initial = _mnsp_offer_series_present(device)
    return all(bids) && initial
end


"""
    _has_flow_limit_series(device) -> Bool

Whether `device` carries a time-series flow limit in either direction, from its [`NEMInterconnectorLimits`](@ref).
"""
function _has_flow_limit_series(device::PSY.AreaInterchange)
    limits = _interconnector_limits(device)
    isnothing(limits) && return false
    return limits.from_to_limit isa IS.StaticTimeSeriesKey || limits.to_from_limit isa IS.StaticTimeSeriesKey
end


"""
    _mnsp_link_tlfs(device, direction) -> NamedTuple

The `from` and `to` loss factors of `device`'s `direction` link, as recorded by `set_mnsp_offers!` in its
[`NEMMNSPLink`](@ref). Throws `ArgumentError` when either is not positive.
"""
function _mnsp_link_tlfs(device::PSY.AreaInterchange, direction::AbstractString)
    link = _mnsp_link(device, direction)
    tlfs = isnothing(link) ? (nothing, nothing) : (link.from_region_tlf, link.to_region_tlf)
    all(t -> t isa Real && t > 0, tlfs) || throw(
        ArgumentError(
            "AreaInterchange \"$(PSY.get_name(device))\" has MNSP offers but no positive " *
                "from_region_tlf and to_region_tlf for its $direction link in its NEMMNSPLink",
        ),
    )
    return (from = Float64(tlfs[1]), to = Float64(tlfs[2]))
end


# The offer and availability series each link direction's parameters read; the direction is the key meta.
_mnsp_offer_series(dir::AbstractString) = getproperty(NEM_MNSP_SERIES, Symbol(dir, "_offer"))
_mnsp_max_avail_series(dir::AbstractString) = getproperty(NEM_MNSP_SERIES, Symbol(dir, "_max_avail"))


function PSI.get_multiplier_value(
        ::MNSPBandWidthParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss,
    )
    return 1.0
end


function PSI.get_multiplier_value(::MNSPMaxAvailParameter, ::PSY.AreaInterchange, ::NEMInterconnectorLoss)
    return 1.0
end


# A band-width parameter's band axis: `_mnsp_band_labels` of the links carrying the series.
function PSI.calc_additional_axes(
        ::PSI.OptimizationContainer, ::MNSPBandWidthParameter,
        devices::Union{Vector{PSY.AreaInterchange}, IS.FlattenIteratorWrapper{PSY.AreaInterchange}},
        ::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
    )
    return (_mnsp_band_labels(devices),)
end


"""
    _mnsp_band_labels(devices) -> Vector{String}

Band labels `"1"` to `"n"`, `n` the most bands any link of an MNSP in `devices` offers over the
whole of its offer curves.
"""
function _mnsp_band_labels(devices)
    n = 1
    for d in devices, dir in _MNSP_DIRECTIONS
        _has_mnsp_offers(d) || continue
        curves = _series_values(d, _mnsp_bid(d, dir).offer_curves)
        n = max(n, maximum(c -> length(PSY.get_y_coords(c)), curves))
    end
    return string.(1:n)
end


"""
    _mnsp_link_bound(device, direction) -> Float64

The non-negative flow extent of `device`'s loss-model domain in `direction`, in system-base per-unit.
Commercial availability and offered MW do not restrict this direction-selection bound.
"""
function _mnsp_link_bound(device::PSY.AreaInterchange, direction::AbstractString)
    model = _loss_model(device)
    extent = direction == "forward" ? last(model.breakpoints) : -first(model.breakpoints)
    return max(0.0, extent)
end


"""
    _add_mnsp_link_variables!(container, devices, device_model)

Adds, for each device in `devices` carrying MNSP offers, the MNSP parameters, a link flow, band
and loss variable per direction and timestep, and a direction binary per timestep. Link flows enter
the regional balances at the link's ends, and each directional loss at its sending area, bounded
by [`_loss_range`](@ref). Devices without offers keep their free-flow model.

# Arguments
- `container`: the optimization container of the model being built.
- `devices`: the `PSY.AreaInterchange` devices of the formulation.
- `device_model`: the `PSI.DeviceModel` supplying the MNSP parameter time-series names.

# Returns
`nothing`.
"""
function _add_mnsp_link_variables!(container::PSI.OptimizationContainer, devices, device_model)
    foreach(_check_mnsp_offers, devices)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    foreach(_require_mnsp_fixed_loads, mnsp)
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(mnsp)
    base_power = PSI.get_base_power(container)
    jm = PSI.get_jump_model(container)
    labels = _mnsp_band_labels(mnsp)
    directions = collect(_MNSP_DIRECTIONS)

    for dir in _MNSP_DIRECTIONS
        PSI.add_parameters!(
            container, MNSPBandWidthParameter, devices, device_model;
            meta = dir, time_series_name = _mnsp_offer_series(dir),
        )
        PSI.add_parameters!(
            container, MNSPMaxAvailParameter, devices, device_model;
            meta = dir, time_series_name = _mnsp_max_avail_series(dir),
        )
    end
    for (meta, series) in _MNSP_OPERATING_SERIES
        PSI.add_parameters!(container, MNSPOperatingParameter, mnsp, device_model; meta, time_series_name = series)
    end
    _add_mnsp_limit_variables!(container, mnsp)
    link_var = PSI.add_variable_container!(
        container, MNSPLinkFlowVariable(), PSY.AreaInterchange, names, directions, time_steps,
    )
    direction_var = PSI.add_variable_container!(
        container, MNSPLinkDirectionVariable(), PSY.AreaInterchange, names, time_steps,
    )
    link_loss = PSI.add_variable_container!(
        container, MNSPLinkLossVariable(), PSY.AreaInterchange, names, directions, time_steps,
    )
    band_var = Dict(
        dir => PSI.add_variable_container!(
            container, MNSPLinkBandVariable(), PSY.AreaInterchange, names, labels, time_steps; meta = dir,
        ) for dir in _MNSP_DIRECTIONS
    )
    expr = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)

    for d in mnsp
        name = PSY.get_name(d)
        lower_loss, upper_loss = _loss_range(d, _loss_model(d))
        tlf = Dict(dir => _mnsp_link_tlfs(d, dir) for dir in _MNSP_DIRECTIONS)
        bound = Dict(dir => _mnsp_link_bound(d, dir) for dir in _MNSP_DIRECTIONS)
        area = (forward = PSY.get_name(PSY.get_from_area(d)), reverse = PSY.get_name(PSY.get_to_area(d)))
        other = (forward = area.reverse, reverse = area.forward)
        for t in time_steps
            direction_var[name, t] = JuMP.@variable(jm, binary = true, base_name = "MNSPLinkDirectionVariable_{$name,$t}")
            for dir in _MNSP_DIRECTIONS
                for label in labels
                    band_var[dir][name, label, t] = JuMP.@variable(
                        jm, lower_bound = 0.0, base_name = "MNSPLinkBandVariable_{$name,$dir,$label,$t}",
                    )
                end
                q = link_var[name, dir, t] = JuMP.@variable(
                    jm, lower_bound = 0.0, upper_bound = bound[dir],
                    base_name = "MNSPLinkFlowVariable_{$name,$dir,$t}",
                )
                loss = link_loss[name, dir, t] = JuMP.@variable(
                    jm, lower_bound = lower_loss, upper_bound = upper_loss,
                    base_name = "MNSPLinkLossVariable_{$name,$dir,$t}",
                )
                sender, receiver = getproperty(area, Symbol(dir)), getproperty(other, Symbol(dir))
                JuMP.add_to_expression!(expr[sender, t], -(tlf[dir].from - 1.0), q)
                JuMP.add_to_expression!(expr[receiver, t], tlf[dir].to - 1.0, q)
                JuMP.add_to_expression!(expr[sender, t], -tlf[dir].from, loss)
            end
        end
    end
    return
end


"""
    _add_mnsp_link_constraints!(container, devices)

Adds, for each device in `devices` carrying MNSP offers, the rows over the variables of
[`_add_mnsp_link_variables!`](@ref): each band within its offered width, the bands plus an offer surplus summing to the
link flow (meta `"band"`), an elastic `MAXAVAIL` limit (`"max_avail"`), `flow = forward - reverse` (`"flow"`),
one direction at a time (`"direction"`), each directional loss zero on the inactive link (`"loss|lb"` and
`"loss|ub"`), and the two losses summing to the interconnector loss (`"loss_split"`), all rows of
[`MNSPLinkConstraint`](@ref).

# Returns
`nothing`.
"""
function _add_mnsp_link_constraints!(container::PSI.OptimizationContainer, devices)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    time_steps = PSI.get_time_steps(container)
    names = PSY.get_name.(mnsp)
    base_power = PSI.get_base_power(container)
    jm = PSI.get_jump_model(container)
    labels = _mnsp_band_labels(mnsp)
    directions = collect(_MNSP_DIRECTIONS)

    link_var = PSI.get_variable(container, MNSPLinkFlowVariable(), PSY.AreaInterchange)
    direction_var = PSI.get_variable(container, MNSPLinkDirectionVariable(), PSY.AreaInterchange)
    link_loss = PSI.get_variable(container, MNSPLinkLossVariable(), PSY.AreaInterchange)
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    loss_var = PSI.get_variable(container, InterconnectorLossVariable(), PSY.AreaInterchange)
    band_var = Dict(dir => PSI.get_variable(container, MNSPLinkBandVariable(), PSY.AreaInterchange, dir) for dir in _MNSP_DIRECTIONS)
    width = Dict(
        dir => PSI.get_parameter(container, MNSPBandWidthParameter(), PSY.AreaInterchange, dir)
            for dir in _MNSP_DIRECTIONS
    )
    max_avail = Dict(
        dir => PSI.get_parameter(container, MNSPMaxAvailParameter(), PSY.AreaInterchange, dir)
            for dir in _MNSP_DIRECTIONS
    )
    container_for(meta) = PSI.add_constraints_container!(
        container, MNSPLinkConstraint(), PSY.AreaInterchange, names, directions, time_steps; meta,
    )
    band_con = container_for("band")
    avail_con = container_for("max_avail")
    direction_con = container_for("direction")
    loss_lb_con = container_for("loss|lb")
    loss_ub_con = container_for("loss|ub")
    link_con = PSI.add_constraints_container!(
        container, MNSPLinkConstraint(), PSY.AreaInterchange, names, time_steps; meta = "flow",
    )
    split_con = PSI.add_constraints_container!(
        container, MNSPLinkConstraint(), PSY.AreaInterchange, names, time_steps; meta = "loss_split",
    )

    for d in mnsp
        name = PSY.get_name(d)
        lower_loss, upper_loss = _loss_range(d, _loss_model(d))
        bound = Dict(dir => _mnsp_link_bound(d, dir) for dir in _MNSP_DIRECTIONS)
        widths = Dict(dir => PSI.get_parameter_column_refs(width[dir], name) for dir in _MNSP_DIRECTIONS)
        width_mult = Dict(dir => PSI.get_multiplier_array(width[dir]) for dir in _MNSP_DIRECTIONS)
        avails = Dict(dir => PSI.get_parameter_column_refs(max_avail[dir], name) for dir in _MNSP_DIRECTIONS)
        avail_mult = Dict(dir => PSI.get_multiplier_array(max_avail[dir]) for dir in _MNSP_DIRECTIONS)
        for t in time_steps
            forward_on = direction_var[name, t]
            for dir in _MNSP_DIRECTIONS
                q = link_var[name, dir, t]
                bands = band_var[dir]
                for label in labels
                    JuMP.@constraint(jm, bands[name, label, t] <= width_mult[dir][name, label, t] * widths[dir][label, t] / base_power)
                end
                link = _mnsp_direction_link(dir)
                offer_slack = PSI.get_variable(container, MNSPSlack(), PSY.AreaInterchange, _mnsp_slack_meta(MNSPOfferVariant(), link))[name, t]
                avail_slack = PSI.get_variable(container, MNSPSlack(), PSY.AreaInterchange, _mnsp_slack_meta(MNSPMaxAvailVariant(), link))[name, t]
                band_con[name, dir, t] = JuMP.@constraint(jm, sum(bands[name, label, t] for label in labels) + offer_slack == q)
                avail_con[name, dir, t] = JuMP.@constraint(jm, q - avail_slack <= avail_mult[dir][name, t] * avails[dir][t] / base_power)
                on = dir == "forward" ? forward_on : 1 - forward_on
                direction_con[name, dir, t] = JuMP.@constraint(jm, q <= bound[dir] * on)
                loss = link_loss[name, dir, t]
                loss_lb_con[name, dir, t] = JuMP.@constraint(jm, loss >= lower_loss * on)
                loss_ub_con[name, dir, t] = JuMP.@constraint(jm, loss <= upper_loss * on)
            end
            link_con[name, t] = JuMP.@constraint(
                jm, flow_var[name, t] == link_var[name, "forward", t] - link_var[name, "reverse", t]
            )
            split_con[name, t] = JuMP.@constraint(
                jm, link_loss[name, "forward", t] + link_loss[name, "reverse", t] == loss_var[name, t]
            )
        end
    end
    return
end


"""
    _add_mnsp_band_costs!(container, devices, device_model)

Prices each [`MNSPLinkBandVariable`](@ref) of the devices in `devices` carrying MNSP offers in the invariant
objective expression: the `band_prices` entry (`\$/MWh`, the day price of the link's bid) times the system base
power and the interval hours.

# Arguments
- `container`: the optimization container of the model being built.
- `devices`: the `PSY.AreaInterchange` devices of the formulation.
- `device_model`: the `PSI.DeviceModel` of the formulation.

# Returns
`nothing`.
"""
function _add_mnsp_band_costs!(container::PSI.OptimizationContainer, devices, device_model)
    mnsp = filter(_has_mnsp_offers, collect(devices))
    isempty(mnsp) && return
    labels = _mnsp_band_labels(mnsp)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    scale = base_power * interval_hours(resolution)
    time_steps = PSI.get_time_steps(container)
    for dir in _MNSP_DIRECTIONS
        bands = PSI.get_variable(container, MNSPLinkBandVariable(), PSY.AreaInterchange, dir)
        for device in mnsp
            name = PSY.get_name(device)
            prices = _mnsp_bid(device, dir).band_prices
            isnothing(prices) && throw(ArgumentError("$name has no MNSP $dir band prices; run the replay input stage."))
            for t in time_steps, (b, label) in enumerate(labels)
                PSI.add_to_objective_invariant_expression!(container, (scale * prices[b]) * bands[name, label, t])
            end
        end
    end
    _add_mnsp_limit_costs!(container, mnsp)
    return
end
