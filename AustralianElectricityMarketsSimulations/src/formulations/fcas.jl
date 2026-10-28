function PSI.get_default_time_series_names(::Type{FCASService}, ::Type{FCASMarket})
    return Dict{Type{<:PSI.TimeSeriesParameter}, String}()
end


function PSI.get_default_attributes(::Type{FCASService}, ::Type{FCASMarket})
    return Dict{String, Any}()
end


"""
    _fcas_direction_problem(device, bid_type, direction) -> Union{Nothing, String}

Why [`FCASMarket`](@ref) cannot model `device`'s `bid_type` bid in `direction` (as returned by
`fcas_bid_direction`), or `nothing` when it can. Modeled directions
are an incremental bid on any device but a `PSY.ControllableLoad`, a decremental bid on a
`PSY.Storage` device or a `PSY.ControllableLoad`, and both directions on a `PSY.Storage` device's
regulation bid.

# Returns
`Union{Nothing, String}`, the reason phrased to follow the device name.
"""
function _fcas_direction_problem(device::PSY.Device, bid_type::BidType, direction::FCASBidDirection)
    bid = string(bid_type)
    direction === FCASBidDirection.NONE && return "carries neither an incremental nor a decremental $bid bid; call set_fcas_bids! first"
    direction === FCASBidDirection.BOTH && !(device isa PSY.Storage && bid_type in FCAS_REGULATION_MARKETS) &&
        return "carries both an incremental and a decremental $bid bid; bidirectional FCAS capacity is modeled " *
        "only for a `PSY.Storage` device's regulation markets"
    direction === FCASBidDirection.DECREMENTAL && !(device isa PSY.Storage || device isa PSY.ControllableLoad) &&
        return "($(typeof(device))) has only a decremental $bid bid; that direction is modeled only for a " *
        "`PSY.Storage` device or a `PSY.ControllableLoad`"
    direction === FCASBidDirection.INCREMENTAL && device isa PSY.ControllableLoad &&
        return "is a load with an incremental $bid bid; a load offers FCAS on its decremental " *
        "(`LOAD`-direction) series only"
    return nothing
end


"""
    _fcas_direction(device, bid_type) -> FCASBidDirection

Which of `bid_type`'s `"fcas_trapezium_<bid_type>[_decremental]"` series `device` carries. Throws
an `ArgumentError` when [`FCASMarket`](@ref) does not model that direction
([`_fcas_direction_problem`](@ref)).

# Returns
`FCASBidDirection.INCREMENTAL`, `DECREMENTAL` or `BOTH`.
"""
function _fcas_direction(device::PSY.Device, bid_type::BidType)
    direction = fcas_bid_direction(device, bid_type)
    problem = _fcas_direction_problem(device, bid_type, direction)
    isnothing(problem) || throw(ArgumentError("FCASMarket: \"$(PSY.get_name(device))\" $problem."))
    return direction
end


"""
    _fcas_energy_terms(device, is_regulation, decremental)

The `(PSI.VariableType, multiplier)` pairs making up `device`'s FCAS "Energy Dispatch Target": its
net energy ([`_energy_variables`](@ref)), except a `PSY.Storage` device's regulation bid, which
reads its bid side's own energy (`ActivePowerOutVariable` for a generation-side bid,
`-ActivePowerInVariable` for a load-side one). A `PSY.ControllableLoad`'s energy is its consumed MW.

# Returns
A tuple of `(VariableType, multiplier)` pairs.
"""
_fcas_energy_terms(device::PSY.Device, ::Bool, ::Bool) = _energy_variables(device)
function _fcas_energy_terms(device::PSY.Storage, is_regulation::Bool, decremental::Bool)
    is_regulation || return _energy_variables(device)
    return decremental ? ((PSI.ActivePowerInVariable, -1.0),) : ((PSI.ActivePowerOutVariable, 1.0),)
end


"""
    _add_fcas_energy_terms!(container, expr, device, is_regulation, decremental, dname, t)

Adds `device`'s FCAS energy terms ([`_fcas_energy_terms`](@ref)) into `expr` at `(dname, t)`.
Throws `ArgumentError` if `device`'s formulation defines no such energy variable.
"""
function _add_fcas_energy_terms!(
        container, expr, device::PSY.Device, is_regulation::Bool, decremental::Bool, dname::AbstractString, t::Int,
    )
    _add_fcas_variable_terms!(container, expr, device, _fcas_energy_terms(device, is_regulation, decremental), dname, t)
    return
end


"""
    _add_fcas_variable_terms!(container, expr, device, terms, dname, t)

Adds each `(VariableType, multiplier)` of `terms` for `device` into `expr` at `(dname, t)`.
Throws `ArgumentError` if `device`'s formulation defines no such variable.
"""
function _add_fcas_variable_terms!(container, expr, device::PSY.Device, terms, dname::AbstractString, t::Int)
    for (var_type, multiplier) in terms
        PSI.has_container_key(container, var_type, typeof(device)) || throw(
            ArgumentError(
                "FCASMarket: \"$dname\" ($(typeof(device))) contributes to an FCASService, but its " *
                    "device formulation defines no $(nameof(var_type)) for the FCAS energy term.",
            ),
        )
        var = PSI.get_variable(container, var_type(), typeof(device))
        JuMP.add_to_expression!(expr, multiplier, var[dname, t])
    end
    return
end


"The meta of an FCAS offer's parameters: `\"<BIDTYPE>\"`, or `\"<BIDTYPE>_decremental\"` for a decremental offer."
function _fcas_offer_meta(bid_type::BidType, decremental::Bool)
    return string(bid_type) * side_suffix(offer_side(decremental))
end


# Field axes of the FCAS time-series parameters and the slices of a series element each reads.
const _FCAS_LIMIT_FIELDS = ["max_avail", "enablement_min", "enablement_max"]
const _FCAS_RAMPING_FIELDS = ["joint_ramping", "bdu_ramping"]
const _FCAS_BAND_LABELS = string.(1:FCAS_BAND_COUNT)
const _FCAS_OFFER_PARAMETERS = (FCASOfferLimitParameter, FCASBandWidthParameter, FCASUpperSlopeParameter, FCASLowerSlopeParameter)

function _fcas_parameter_axes(::FCASOfferLimitParameter)
    return (_FCAS_LIMIT_FIELDS,)
end
function _fcas_parameter_axes(::FCASBandWidthParameter)
    return (_FCAS_BAND_LABELS,)
end
function _fcas_parameter_axes(::FCASRampingLimitParameter)
    return (_FCAS_RAMPING_FIELDS,)
end
function _fcas_parameter_axes(::Union{FCASUpperSlopeParameter, FCASLowerSlopeParameter})
    return ()
end

"`devices_template`'s `PSI.DeviceModel` for component type `D`."
function _fcas_device_model(devices_template, ::Type{D}) where {D <: PSY.Device}
    for model in values(devices_template)
        PSI.get_component_type(model) == D && return model
    end
    throw(ArgumentError("FCASMarket: the template has no device model for $D."))
end


"""
    _add_fcas_parameter!(container, param, model, sys, ts_name, meta)

Adds `param`, keyed by `model`'s component type and `meta`, unless it exists: one row per available
component of `model` carrying a `ts_name` forecast, the set PowerSimulations' time-series parameter
update visits ([`_add_series_parameter!`](@ref)), on the axes of [`_fcas_parameter_axes`](@ref).

# Returns
`nothing`.
"""
function _add_fcas_parameter!(
        container::PSI.OptimizationContainer, param::T, model::PSI.DeviceModel{D}, sys::PSY.System,
        ts_name::String, meta::String,
    ) where {T <: PSI.TimeSeriesParameter, D <: PSY.Device}
    PSI.has_container_key(container, T, D, meta) && return
    ts_type = PSI.get_default_time_series_type(container)
    devices = [d for d in PSI.get_available_components(model, sys) if PSY.has_time_series(d, ts_type, ts_name)]
    isempty(devices) && return
    param_container = _add_series_parameter!(container, param, D, devices, ts_name, meta; axes = _fcas_parameter_axes(param))
    PSI.set_subsystem!(PSI.get_attributes(param_container), PSI.get_subsystem(model))
    return
end


"""
    _check_fcas_effective_series(container, devices, bid_type, directions)

Throws `ArgumentError` naming every device in `devices` without a forecast of its
[`set_fcas_effective_offers!`](@ref) series for `bid_type`.

# Returns
`nothing`.
"""
function _check_fcas_effective_series(container::PSI.OptimizationContainer, devices, bid_type::BidType, directions)
    ts_type = PSI.get_default_time_series_type(container)
    uncovered = String[]
    for d in devices
        dname = PSY.get_name(d)
        names = [fcas_effective_series_name(bid_type, dec) for dec in fcas_offer_sides(directions[dname])]
        bid_type in FCAS_REGULATION_MARKETS && push!(names, fcas_ramping_series_name(bid_type))
        all(n -> PSY.has_time_series(d, ts_type, n), names) || push!(uncovered, dname)
    end
    isempty(uncovered) || throw(
        ArgumentError(
            "FCASMarket: $(length(uncovered)) device(s) carry no effective $(string(bid_type)) offer forecast: " *
                "$(join(uncovered, ", ")). Call set_fcas_effective_offers!(sys) before transform_single_time_series!.",
        ),
    )
    return
end


"""
    _add_fcas_offer_parameters!(container, sys, devices_template, devices, bid_type, directions)

Adds the [`FCASOfferLimitParameter`](@ref), [`FCASBandWidthParameter`](@ref),
[`FCASUpperSlopeParameter`](@ref) and [`FCASLowerSlopeParameter`](@ref) of every offer of `devices`
in `bid_type`, and the [`FCASRampingLimitParameter`](@ref) of a regulation market, each keyed by
device type and shared by every service of that market.

# Returns
`nothing`.
"""
function _add_fcas_offer_parameters!(
        container::PSI.OptimizationContainer, sys::PSY.System, devices_template, devices, bid_type::BidType, directions,
    )
    regulation = bid_type in FCAS_REGULATION_MARKETS
    for device in devices
        model = _fcas_device_model(devices_template, typeof(device))
        for decremental in fcas_offer_sides(directions[PSY.get_name(device)])
            name, meta = fcas_effective_series_name(bid_type, decremental), _fcas_offer_meta(bid_type, decremental)
            for P in _FCAS_OFFER_PARAMETERS
                _add_fcas_parameter!(container, P(), model, sys, name, meta)
            end
        end
        regulation && _add_fcas_parameter!(
            container, FCASRampingLimitParameter(), model, sys, fcas_ramping_series_name(bid_type), string(bid_type),
        )
    end
    return
end


"`device`'s column of the `P` parameter keyed `(typeof(device), meta)`, and that parameter's multiplier array."
function _fcas_parameter_refs(container::PSI.OptimizationContainer, ::Type{P}, device::PSY.Device, meta::String) where {P}
    param_container = PSI.get_parameter(container, P(), typeof(device), meta)
    return PSI.get_parameter_column_refs(param_container, PSY.get_name(device)), PSI.get_multiplier_array(param_container)
end


"""
    _fcas_capacity_bound(device, bid_type, decremental) -> Float64

The largest effective `MaxAvail` of `device`'s `bid_type` offer on one side, per-unit: over its whole
`"fcas_effective_..."` series.

# Returns
`Float64`.
"""
function _fcas_capacity_bound(device::PSY.Device, bid_type::BidType, decremental::Bool)
    series = PSY.get_time_series_values(PSY.SingleTimeSeries, device, fcas_effective_series_name(bid_type, decremental))
    return maximum(first, series)
end


# A capacity variable's static upper bound: the largest effective MaxAvail without slacks, where the
# MaxAvail row is hard; with slacks only a zero bound, for an offer never enabled.
function _set_fcas_capacity_bound!(model::PSI.ServiceModel, variable, bound::Float64)
    PSI.get_use_slacks(model) && !iszero(bound) && return
    JuMP.set_upper_bound(variable, bound)
    return
end


"""
    _add_fcas_slack!(container, model, var_type, meta, names, time_steps, cvp_factor)

When `PSI.get_use_slacks(model)`, builds an [`_add_cvp_slack!`](@ref) slack of `var_type` per
`(name, t)` keyed by `FCASService` and `meta`, at the model's Market Price Cap override.

# Returns
The slack variable container, or `nothing` when `use_slacks` is `false`.
"""
function _add_fcas_slack!(
        container::PSI.OptimizationContainer, model::PSI.ServiceModel, var_type, meta::AbstractString,
        names, time_steps, cvp_factor::Real,
    )
    PSI.get_use_slacks(model) || return nothing
    return _add_cvp_slack!(
        container, var_type, FCASService, names, time_steps, cvp_factor;
        meta = meta, label = "$(nameof(var_type))_$meta", rate = PSI.get_attribute(model, "market_price_cap"),
    )
end


"""
    _add_fcas_max_avail_row!(jm, variable, slack, con, dname, t, max_avail)

Stores `variable - slack <= max_avail` in `con[dname, t]`, the MaxAvail limit of a capacity
variable: elastic when `slack` is a slack container, hard when it is `nothing`.

# Arguments
- `jm`: the JuMP model.
- `variable`, `slack`: the capacity variable and the slack container of [`FCASMaxAvailSlack`](@ref), or `nothing`.
- `con`: the [`FCASMaxAvailConstraint`](@ref) container the row is stored in, at `[dname, t]`.
- `max_avail`: the effective MaxAvail in per-unit, a number or a parameter.

# Returns
`nothing`.
"""
function _add_fcas_max_avail_row!(jm, variable, slack, con, dname, t, max_avail)
    con[dname, t] = JuMP.@constraint(jm, variable - _fcas_slack_term(slack, dname, t) <= max_avail)
    return
end


"""
    _fcas_slack_term(slack, name, t)

The slack variable of `slack` at `(name, t)`, or `0.0` when `slack` is `nothing` (`use_slacks = false`).
"""
function _fcas_slack_term(slack, name, t)
    return isnothing(slack) ? 0.0 : slack[name, t]
end


"""
    _add_fcas_capacity_rows!(container, device, meta, capacity, upper_lhs, lower_lhs, slacks, cons, dname, t)

Builds `device`'s MaxAvail row and its two AEMO *FCAS Model in NEMDE* §6.2/§6.3 joint capacity
rows at `t` for the offer `meta` ([`_fcas_offer_meta`](@ref)) with capacity variable `capacity`:
`capacity - slack <= MaxAvail`, `upper_lhs + UpperSlopeCoeff × capacity - slack <= EnablementMax` and
`lower_lhs - LowerSlopeCoeff × capacity + slack >= EnablementMin`. The limits come from
[`FCASOfferLimitParameter`](@ref) and the slope coefficients from [`FCASUpperSlopeParameter`](@ref)
and [`FCASLowerSlopeParameter`](@ref).

# Arguments
- `slacks`: `(max, upper, lower)` slack containers, each `nothing` without slacks.
- `cons`: `(max, upper, lower)` constraint containers.

# Returns
`nothing`.
"""
function _add_fcas_capacity_rows!(
        container::PSI.OptimizationContainer, device::PSY.Device, meta::String, capacity, upper_lhs, lower_lhs,
        slacks, cons, dname::String, t::Int,
    )
    jm = PSI.get_jump_model(container)
    limits, multiplier = _fcas_parameter_refs(container, FCASOfferLimitParameter, device, meta)
    limit(field) = multiplier[dname, field, t] * limits[field, t]
    _add_fcas_max_avail_row!(jm, capacity, slacks.max, cons.max, dname, t, limit("max_avail"))
    cons.upper[dname, t] = JuMP.@constraint(
        jm, upper_lhs + capacity - _fcas_slack_term(slacks.upper, dname, t) <= limit("enablement_max"),
    )
    PSI.add_coefficient_target!(
        container, PSI.ParameterKey(FCASUpperSlopeParameter, typeof(device), meta), dname, t, cons.upper[dname, t], capacity, 1.0,
    )
    cons.lower[dname, t] = JuMP.@constraint(
        jm, lower_lhs - capacity + _fcas_slack_term(slacks.lower, dname, t) >= limit("enablement_min"),
    )
    PSI.add_coefficient_target!(
        container, PSI.ParameterKey(FCASLowerSlopeParameter, typeof(device), meta), dname, t, cons.lower[dname, t], capacity, -1.0,
    )
    return
end


"""
    _add_fcas_capacity_constraints!(container, model, devices, label, capacity, metas)

Builds the MaxAvail and joint capacity rows ([`_add_fcas_capacity_rows!`](@ref)) of each of
`devices` at every time step, on its `capacity` variable and the [`FCASJointCapacityLHS`](@ref)
expressions of meta `"<label>_upper"` and `"<label>_lower"`. The [`FCASMaxAvailConstraint`](@ref)
and [`FCASJointCapacityConstraint`](@ref) containers and their slacks take the metas
`"<label>_maxavail"`, `"<label>_upper"` and `"<label>_lower"`.

# Arguments
- `devices`: the devices sharing the capacity variable container `capacity`.
- `label`: the service name, suffixed with the side for a `PSY.Storage` device bidding both sides.
- `metas`: each device's offer meta ([`_fcas_offer_meta`](@ref)), in the order of `devices`.

# Returns
`nothing`.
"""
function _add_fcas_capacity_constraints!(
        container::PSI.OptimizationContainer, model::PSI.ServiceModel, devices, label::String, capacity,
        metas::Vector{String},
    )
    names = PSY.get_name.(devices)
    time_steps = PSI.get_time_steps(container)
    upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(label)_upper")
    lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(label)_lower")
    slacks = (
        max = _add_fcas_slack!(
            container, model, FCASMaxAvailSlack, "$(label)_maxavail", names, time_steps, FCAS_MAXAVAIL_CVP_FACTOR,
        ),
        upper = _add_fcas_slack!(
            container, model, FCASJointCapacitySlack, "$(label)_upper", names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
        ),
        lower = _add_fcas_slack!(
            container, model, FCASJointCapacitySlack, "$(label)_lower", names, time_steps, FCAS_CAPACITY_CVP_FACTOR,
        ),
    )
    cons = (
        max = PSI.add_constraints_container!(
            container, FCASMaxAvailConstraint(), FCASService, names, time_steps; meta = "$(label)_maxavail",
        ),
        upper = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, names, time_steps; meta = "$(label)_upper",
        ),
        lower = PSI.add_constraints_container!(
            container, FCASJointCapacityConstraint(), FCASService, names, time_steps; meta = "$(label)_lower",
        ),
    )
    for (device, dname, meta) in zip(devices, names, metas), t in time_steps
        _add_fcas_capacity_rows!(
            container, device, meta, capacity[dname, t], upper_lhs[dname, t], lower_lhs[dname, t], slacks, cons, dname, t,
        )
    end
    return
end


"""
    _add_fcas_joint_ramping_constraints!(container, model, jm, devices, bid_type, name, time_steps)

Builds AEMO *FCAS Model in NEMDE* §6.1's [`FCASJointRampingConstraint`](@ref) for every
contributing `device` of a regulation `FCASService` named `name`: the unit's net energy
([`_energy_variables`](@ref)) combined with its [`FCASUnitRegulationTarget`](@ref) against
the `"joint_ramping"` field of its [`FCASRampingLimitParameter`](@ref), in the upper or lower form
depending on `bid_type` ([`fcas_upper_regulation_service`](@ref)). Where §6.1 does not apply, the
parameter holds [`FCAS_INACTIVE_LIMIT_MW`](@ref) and the row never binds.

# Returns
`nothing`.
"""
function _add_fcas_joint_ramping_constraints!(
        container::PSI.OptimizationContainer, model::PSI.ServiceModel, jm, devices, bid_type::BidType,
        name::AbstractString, time_steps,
    )
    names = PSY.get_name.(devices)
    con = PSI.add_constraints_container!(
        container, FCASJointRampingConstraint(), FCASService, names, time_steps; meta = name,
    )
    target = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
    slack = _add_fcas_slack!(
        container, model, FCASJointRampingSlack, name, names, time_steps, FCAS_RAMPING_CVP_FACTOR,
    )
    for device in devices
        dname = PSY.get_name(device)
        ramping, multiplier = _fcas_parameter_refs(container, FCASRampingLimitParameter, device, string(bid_type))
        upper = bid_type == fcas_upper_regulation_service(device)
        for t in time_steps
            lhs = JuMP.AffExpr(0.0)
            _add_fcas_variable_terms!(container, lhs, device, _energy_variables(device), dname, t)
            limit = multiplier[dname, "joint_ramping", t] * ramping["joint_ramping", t]
            deficit = _fcas_slack_term(slack, dname, t)
            con[dname, t] = if upper
                JuMP.@constraint(jm, lhs + target[dname, t] - deficit <= limit)
            else
                JuMP.@constraint(jm, lhs - target[dname, t] + deficit >= limit)
            end
        end
    end
    return
end


"""
    _device_regulation_target(container, device, reg_bid_type, t) -> Union{Nothing, JuMP.AbstractJuMPScalar}

`device`'s [`FCASUnitRegulationTarget`](@ref) at `t` for the `reg_bid_type` regulation market it
belongs to, found via `PSY.get_services(device)`. `nothing` when `device` carries no such
service, or that service wasn't built under [`FCASMarket`](@ref) this run. Throws
`ArgumentError` if `device` belongs to more than one such service.

# Returns
`Union{Nothing, JuMP.AbstractJuMPScalar}`.
"""
function _device_regulation_target(container::PSI.OptimizationContainer, device::PSY.Device, reg_bid_type::BidType, t::Int)
    dname = PSY.get_name(device)
    targets = JuMP.AffExpr[]
    for svc in PSY.get_services(device)
        svc isa FCASService || continue
        get_bid_type(svc) == reg_bid_type || continue
        name = PSY.get_name(svc)
        PSI.has_container_key(container, FCASUnitRegulationTarget, FCASService, name) || continue
        expr = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
        dname in axes(expr, 1) || continue
        push!(targets, expr[dname, t])
    end
    length(targets) > 1 && throw(
        ArgumentError(
            "FCASMarket: \"$dname\" contributes to $(length(targets)) $(string(reg_bid_type)) " *
                "FCASServices; a device can offer each FCAS market through only one.",
        ),
    )
    return isempty(targets) ? nothing : only(targets)
end


function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.ServiceModel{FCASService, FCASMarket},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    unsupported = filter(!in((FCASJointCapacityConstraint, FCASJointRampingConstraint)), PSI.get_duals(model))
    isempty(unsupported) || throw(
        ArgumentError(
            "FCASMarket records duals for FCASJointCapacityConstraint and " *
                "FCASJointRampingConstraint only; got $(unsupported).",
        ),
    )
    name = PSI.get_service_name(model)
    svc = PSY.get_component(FCASService, sys, name)
    PSY.get_available(svc) || return
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    bid_type = get_bid_type(svc)
    is_regulation = bid_type in FCAS_REGULATION_MARKETS
    time_steps = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)

    directions = Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices)
    _check_fcas_effective_series(container, devices, bid_type, directions)
    _add_fcas_offer_parameters!(container, sys, devices_template, devices, bid_type, directions)
    target = is_regulation ? PSI.add_expression_container!(
            container, FCASUnitRegulationTarget(), FCASService, PSY.get_name.(devices), time_steps; meta = name,
        ) : nothing

    for group in _fcas_offer_groups(name, devices, directions)
        names = [PSY.get_name(d) for (d, _) in group.offers]
        var = PSI.add_variable_container!(container, group.variable, FCASService, names, time_steps; meta = group.meta)
        lhs = [
            PSI.lazy_container_addition!(
                container, FCASJointCapacityLHS(), FCASService, names, time_steps; meta = "$(group.meta)_$side",
            ) for side in ("upper", "lower")
        ]
        label = "$(nameof(typeof(group.variable)))_FCASService_$(group.meta)"
        for (device, decremental) in group.offers
            dname = PSY.get_name(device)
            bound = _fcas_capacity_bound(device, bid_type, decremental)
            for t in time_steps
                var[dname, t] = JuMP.@variable(jm, base_name = "$(label)_{$dname, $t}", lower_bound = 0.0)
                _set_fcas_capacity_bound!(model, var[dname, t], bound)
                for expr in lhs
                    _add_fcas_energy_terms!(container, expr[dname, t], device, is_regulation, decremental, dname, t)
                end
                isnothing(target) || JuMP.add_to_expression!(target[dname, t], var[dname, t])
            end
        end
        _add_fcas_band_variables!(container, group, bid_type)
    end
    return
end


"""
    _fcas_offer_groups(name, devices, bid_type) -> Vector{NamedTuple}
    _fcas_offer_groups(name, devices, directions) -> Vector{NamedTuple}

The offers of an `FCASService` named `name`, grouped by the capacity variable container they sum
to: `(meta, variable, offers)` with `offers` a vector of `(device, decremental)`. Single-sided
devices form the group `meta = name` on [`FCASCapacityVariable`](@ref); a `PSY.Storage` device
bidding both sides of a regulation market has one offer in each of `"<name>_gen"` and
`"<name>_load"` on [`FCASSideCapacityVariable`](@ref). `directions` maps each device name to its
[`_fcas_direction`](@ref), computed from `bid_type` when not given.

# Returns
`Vector{NamedTuple{(:meta, :variable, :offers)}}`.
"""
# The capacity-variable meta of one side of a `PSY.Storage` device's two-sided regulation offer.
_fcas_side_meta(name::AbstractString, decremental::Bool) = decremental ? "$(name)_load" : "$(name)_gen"


function _fcas_offer_groups(name::AbstractString, devices, bid_type::BidType)
    return _fcas_offer_groups(name, devices, Dict(PSY.get_name(d) => _fcas_direction(d, bid_type) for d in devices))
end
function _fcas_offer_groups(name::AbstractString, devices, directions::AbstractDict)
    both = [d for d in devices if directions[PSY.get_name(d)] == FCASBidDirection.BOTH]
    single = [(d, directions[PSY.get_name(d)] == FCASBidDirection.DECREMENTAL) for d in devices if directions[PSY.get_name(d)] != FCASBidDirection.BOTH]
    groups = NamedTuple[]
    isempty(single) || push!(groups, (meta = String(name), variable = FCASCapacityVariable(), offers = single))
    if !isempty(both)
        for decremental in (false, true)
            push!(groups, (meta = _fcas_side_meta(name, decremental), variable = FCASSideCapacityVariable(), offers = [(d, decremental) for d in both]))
        end
    end
    return groups
end


"""
    _fcas_band_labels(offers, bid_type) -> Vector{String}

Band labels `"1"` to `"n"`, `n` the most bands any offer in `offers` has over the whole of its
`"fcas_curve_..."` series, at least 1.

# Returns
`Vector{String}`.
"""
function _fcas_band_labels(offers, bid_type::BidType)
    n = 1
    for (device, decremental) in offers
        name = fcas_series_name("fcas_curve", bid_type, decremental)
        curves = PSY.get_time_series_values(PSY.SingleTimeSeries, device, name)
        n = max(n, maximum(c -> length(PSY.get_y_coords(c)), curves))
    end
    return string.(1:n)
end


"""
    _set_fcas_band_prices!(container, prices, multiplier, meta, offers, bid_type, start_time; source = container)

Writes the band prices of each of `offers` (`(device, decremental)`) for `bid_type` from
`start_time` through `source`, into the [`FCASBandPriceParameter`](@ref) array `prices` (`0.0` beyond the offered
bands) and adds each band's cost, price times `multiplier` times its [`FCASOfferBandVariable`](@ref)
of meta `meta`, to the variant objective.

# Arguments
- `container`, `prices`, `multiplier`: the optimization container and price/multiplier arrays.
- `meta`, `offers`, `bid_type`: the offer-group key, device/direction pairs and FCAS market.
- `start_time`: the first requested timestamp.
- `source`: the model for cached recurrent reads, or the container for construction reads.

# Returns
`nothing`.
"""
function _set_fcas_band_prices!(
        container::PSI.OptimizationContainer, prices, multiplier, meta::String, offers, bid_type::BidType, start_time::DateTime; source = container,
    )
    bands = PSI.get_variable(container, FCASOfferBandVariable(), FCASService, meta)
    labels = axes(prices)[2]
    for (device, decremental) in offers
        dname = PSY.get_name(device)
        curves = _forecast_window_values(source, device, fcas_series_name("fcas_curve", bid_type, decremental), start_time)
        for (t, curve) in enumerate(curves)
            y = PSY.get_y_coords(curve)
            for (b, label) in enumerate(labels)
                prices[dname, label, t] = b <= length(y) ? y[b] : 0.0
                PSI.add_to_objective_variant_expression!(
                    container, prices[dname, label, t] * multiplier[dname, label, t] * bands[dname, label, t],
                )
            end
        end
    end
    return
end


"""
    _add_fcas_band_variables!(container, group, bid_type)

For an [`_fcas_offer_groups`](@ref) `group`, adds one [`FCASOfferBandVariable`](@ref) per offer,
band and time step, of meta `group.meta`.

# Returns
`nothing`.
"""
function _add_fcas_band_variables!(container::PSI.OptimizationContainer, group, bid_type::BidType)
    names = [PSY.get_name(d) for (d, _) in group.offers]
    labels = _fcas_band_labels(group.offers, bid_type)
    jm = PSI.get_jump_model(container)
    bands = PSI.add_variable_container!(
        container, FCASOfferBandVariable(), FCASService, names, labels, PSI.get_time_steps(container); meta = group.meta,
    )
    for name in names, label in labels, t in PSI.get_time_steps(container)
        bands[name, label, t] = JuMP.@variable(
            jm, lower_bound = 0.0, base_name = "FCASOfferBandVariable_$(group.meta)_{$name,$label,$t}",
        )
    end
    return
end


"""
    _add_fcas_band_constraints!(container, group, bid_type)

For an [`_fcas_offer_groups`](@ref) `group`, bounds each [`FCASOfferBandVariable`](@ref) by its
[`FCASBandWidthParameter`](@ref) width and ties the bands' sum to the group's capacity variable
([`FCASOfferBandConstraint`](@ref), meta `group.meta`). Widths are per-unit of the system base.

# Returns
`nothing`.
"""
function _add_fcas_band_constraints!(container::PSI.OptimizationContainer, group, bid_type::BidType)
    names = [PSY.get_name(d) for (d, _) in group.offers]
    time_steps = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)
    capacity = PSI.get_variable(container, group.variable, FCASService, group.meta)
    bands = PSI.get_variable(container, FCASOfferBandVariable(), FCASService, group.meta)
    labels = axes(bands)[2]
    con = PSI.add_constraints_container!(
        container, FCASOfferBandConstraint(), FCASService, names, time_steps; meta = group.meta,
    )
    for (device, decremental) in group.offers
        dname = PSY.get_name(device)
        widths, multiplier = _fcas_parameter_refs(container, FCASBandWidthParameter, device, _fcas_offer_meta(bid_type, decremental))
        for t in time_steps
            for label in labels
                JuMP.@constraint(jm, bands[dname, label, t] <= multiplier[dname, label, t] * widths[label, t])
            end
            con[dname, t] = JuMP.@constraint(jm, sum(bands[dname, label, t] for label in labels) == capacity[dname, t])
        end
    end
    return
end


"""
    _add_fcas_band_costs!(container, group, bid_type)

Prices the [`FCASOfferBandVariable`](@ref)s of an [`_fcas_offer_groups`](@ref) `group` through an
[`FCASBandPriceParameter`](@ref) of meta `group.meta`. Prices are `\$/MW` per hour, so the price
multiplier is the system base power times the interval length in hours.

# Returns
`nothing`.
"""
function _add_fcas_band_costs!(container::PSI.OptimizationContainer, group, bid_type::BidType)
    names = [PSY.get_name(d) for (d, _) in group.offers]
    labels = axes(PSI.get_variable(container, FCASOfferBandVariable(), FCASService, group.meta))[2]
    price = PSI.add_param_container!(
        container, FCASBandPriceParameter(), FCASService, (FCASOfferBandVariable,),
        PSI.SOSStatusVariable.NO_VARIABLE, false, Float64, names, labels, PSI.get_time_steps(container); meta = group.meta,
    )
    prices, multiplier = PSI.get_parameter_array(price), PSI.get_multiplier_array(price)
    fill!(multiplier, PSI.get_base_power(container) * interval_hours(PSI.get_resolution(container)))
    _set_fcas_band_prices!(container, prices, multiplier, group.meta, group.offers, bid_type, PSI.get_initial_time(container))
    return
end


"""
    PSI.objective_function!(container, svc, model::PSI.ServiceModel{FCASService, FCASMarket})

Prices every contributing device's FCAS offer bands ([`_add_fcas_band_costs!`](@ref)): one offer
per single-sided device, and one per side for a `PSY.Storage` device bidding both sides.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        svc::FCASService,
        model::PSI.ServiceModel{FCASService, FCASMarket},
    )
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    for group in _fcas_offer_groups(PSY.get_name(svc), devices, get_bid_type(svc))
        _add_fcas_band_costs!(container, group, get_bid_type(svc))
    end
    return
end


# The `FCASService` and side (`nothing` for single-sided offers, else `decremental`) whose
# `_fcas_offer_groups` meta is `meta`.
function _fcas_price_meta_service(sys::PSY.System, meta::String)
    for svc in PSY.get_components(FCASService, sys)
        name = PSY.get_name(svc)
        meta == name && return svc, nothing
        for decremental in (false, true)
            meta == _fcas_side_meta(name, decremental) && return svc, decremental
        end
    end
    throw(ArgumentError("No FCASService for the FCASBandPriceParameter meta \"$meta\"."))
end


"""
    PSI.update_container_parameter_values!(container, model, key::PSI.ParameterKey{FCASBandPriceParameter, FCASService}, input)

Simulation-step update of an [`FCASBandPriceParameter`](@ref): reads each offer's band prices for the
window at the model's current time and re-adds the band costs to the variant objective.

# Returns
`nothing`.
"""
function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{FCASBandPriceParameter, FCASService}, ::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    PSI.is_synchronized(container) && error(
        "Cannot update FCASBandPriceParameter on a synchronized container; the band costs would be added twice.",
    )
    sys = PSI.get_system(model)
    svc, side = _fcas_price_meta_service(sys, key.meta)
    bid_type = get_bid_type(svc)
    prices = PSI.get_parameter_array(container, key)
    multiplier = PSI.get_parameter_multiplier_array(container, key)
    service_model = PSI.get_model(PSI.get_template(model), FCASService, PSY.get_name(svc))
    contributors = Dict(PSY.get_name(d) => d for d in PSI.get_contributing_devices(service_model))
    offers = map(axes(prices)[1]) do dname
        device = contributors[dname]
        (device, isnothing(side) ? _fcas_direction(device, bid_type) == FCASBidDirection.DECREMENTAL : side)
    end
    _set_fcas_band_prices!(container, prices, multiplier, key.meta, offers, bid_type, PSI.get_current_time(model); source = model)
    return
end


function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.ServiceModel{FCASService, FCASMarket},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    svc = PSY.get_component(FCASService, sys, name)
    PSY.get_available(svc) || return
    devices = PSI.get_contributing_devices(model)
    isempty(devices) && return
    bid_type = get_bid_type(svc)
    is_regulation = bid_type in FCAS_REGULATION_MARKETS
    time_steps = PSI.get_time_steps(container)
    jm = PSI.get_jump_model(container)

    groups = _fcas_offer_groups(name, devices, bid_type)

    # Contingency services carry the regulation targets: `RaiseReg` upper, `LowerReg` lower, swapped for a load.
    if !is_regulation
        upper_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_upper")
        lower_lhs = PSI.get_expression(container, FCASJointCapacityLHS(), FCASService, "$(name)_lower")
        for group in groups, (device, _) in group.offers
            dname = PSY.get_name(device)
            upper_service = fcas_upper_regulation_service(device)
            lower_service = _other_regulation(upper_service)
            for t in time_steps
                upper_reg = _device_regulation_target(container, device, upper_service, t)
                isnothing(upper_reg) || JuMP.add_to_expression!(upper_lhs[dname, t], 1.0, upper_reg)
                lower_reg = _device_regulation_target(container, device, lower_service, t)
                isnothing(lower_reg) || JuMP.add_to_expression!(lower_lhs[dname, t], -1.0, lower_reg)
            end
        end
    end

    for group in groups
        capacity = PSI.get_variable(container, group.variable, FCASService, group.meta)
        metas = [_fcas_offer_meta(bid_type, decremental) for (_, decremental) in group.offers]
        _add_fcas_capacity_constraints!(container, model, first.(group.offers), group.meta, capacity, metas)
        _add_fcas_band_constraints!(container, group, bid_type)
    end

    both_devices = [d for group in groups if group.meta == _fcas_side_meta(name, false) for (d, _) in group.offers]
    if !isempty(both_devices)
        both_names = PSY.get_name.(both_devices)
        target = PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, name)
        con_ramp = PSI.add_constraints_container!(
            container, FCASBDURampingConstraint(), FCASService, both_names, time_steps; meta = name,
        )
        slack_ramp = _add_fcas_slack!(
            container, model, FCASBDURampingSlack, name, both_names, time_steps, FCAS_BDU_RAMPING_CVP_FACTOR,
        )
        for device in both_devices
            dname = PSY.get_name(device)
            ramping, multiplier = _fcas_parameter_refs(container, FCASRampingLimitParameter, device, string(bid_type))
            for t in time_steps
                con_ramp[dname, t] = JuMP.@constraint(
                    jm, target[dname, t] - _fcas_slack_term(slack_ramp, dname, t) <=
                        multiplier[dname, "bdu_ramping", t] * ramping["bdu_ramping", t],
                )
            end
        end
    end

    if is_regulation
        _add_fcas_joint_ramping_constraints!(container, model, jm, devices, bid_type, name, time_steps)
    end

    if FCASJointCapacityConstraint in PSI.get_duals(model)
        for group in groups, side in ("upper", "lower")
            PSI.add_dual_container!(
                container, FCASJointCapacityConstraint, FCASService, [PSY.get_name(d) for (d, _) in group.offers],
                time_steps; meta = "$(group.meta)_$side",
            )
        end
    end

    if is_regulation && FCASJointRampingConstraint in PSI.get_duals(model)
        names = PSY.get_name.(devices)
        PSI.add_dual_container!(container, FCASJointRampingConstraint, FCASService, names, time_steps; meta = name)
    end

    PSI.objective_function!(container, svc, model)
    return
end
