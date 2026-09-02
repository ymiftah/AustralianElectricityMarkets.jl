# NEMDE's interconnector losses (`InterconnectorLossModel`, root `src/losses.jl`) on
# `PSY.AreaInterchange`, linearised into the from/to area balance as monotonically-increasing
# chord slopes - no SOS2/binary needed, cost minimisation fills the cheapest (lowest-slope)
# segment first on its own (see `NEMInterconnectorLoss`'s docstring). The lossless
# `FlowActivePowerVariable` contribution (`-flow` from-area, `+flow` to-area) is inherited from
# PSI's own `add_to_expression!` method for `W <: AbstractBranchFormulation`
# (`devices/common/add_to_expression.jl`) - this file only adds the loss terms on top. Reuses
# `fcas_market.jl`'s `_resolve_fcas_series`/`_fcas_series_row`/`_container_timestamps` for
# absolute-timestamp series lookups, so must be included after it.

"""
Device formulation for `PSY.AreaInterchange` that adds NEMDE's interconnector losses into the
from/to area power balance, on top of the ordinary lossless flow.

The loss curve ([`InterconnectorLossModel`](@ref), root package) is supplied per interconnector
name via the `DeviceModel`'s `"loss_models"` attribute, not read from a database inside this
formulation:

```julia
PSI.set_device_model!(
    template,
    PSI.DeviceModel(
        PSY.AreaInterchange, NEMInterconnectorLoss;
        attributes = Dict{String,Any}("loss_models" => models),
    ),
)
```

where `models::Dict{String,InterconnectorLossModel}` is keyed by `INTERCONNECTORID` (e.g. from
`interconnector_loss_models(db, as_of)`). An `AreaInterchange` present in the template but absent
from `models` throws an `ArgumentError` naming it - never silently modeled as lossless.

Regional demand for the loss curve's linear coefficient ([`loss_factor`](@ref)) is resolved
per timestep from the `System` itself: total `PSY.PowerLoad` active power per `PSY.Area`, so
`Area` names must match the loss model's own region names for its `demand_coefficients` to
apply (they contribute nothing, not an error, otherwise - see [`loss_factor`](@ref)).

Only `PSI.AreaBalancePowerModel`/`PSI.AreaPTDFPowerModel` are supported (losses are an area-level
concept in this package's NEM model), and only two decision variables are needed per loss
segment - no SOS2/binary: the loss curve is convex (chord slopes strictly increase across
segments, `loss_segments`), and losses only ever subtract from the area balance, so minimising
generation cost always fills the lowest-slope segment first. A `loss_flow_coefficient <= 0`
breaks that convexity and is rejected with an `ArgumentError` at construction (see
[`_validate_convex_segments`](@ref)) rather than silently understating losses.

**The loss model's breakpoint range is an implicit flow limit.** `InterconnectorFlowSegmentConstraint`
pins `flow == breakpoints[1] + sum(segment flows)`, and the segment widths sum to
`breakpoints[end] - breakpoints[1]`, so flow is confined to `[breakpoints[1], breakpoints[end]]` -
on top of, and potentially tighter than, `PSI.FlowLimitConstraint`'s own bound from the
interconnector's `flow_limits`. For real AEMO data `LOSSMODEL`'s breakpoints do span the
interconnector's operating range, so this is faithful to NEMDE; but a caller-supplied loss model
narrower than the interconnector's actual flow limits silently tightens dispatch with no
indication beyond one summary `@warn` at construction naming every such interconnector (see
[`_narrow_breakpoint_interconnectors`](@ref)).
"""
struct NEMInterconnectorLoss <: PSI.AbstractBranchFormulation end

"An interconnector's total loss at one timestep - MW, per-unit of base power."
struct InterconnectorLossVariable <: PSI.VariableType end

"""
One loss-curve segment's flow allocation for one interconnector at one timestep - MW, per-unit.
Indexed `(interconnector name, segment label, t)`; the segment axis is sized to the largest
interconnector's segment count, with a smaller interconnector's unused cells fixed to `0.0`
(bounds `[0, 0]`) rather than left `#undef`, which would break read-back.
"""
struct InterconnectorLossSegmentVariable <: PSI.VariableType end

"`flow[ic,t] == first_breakpoint + sum(segment flows)`, both per-unit."
struct InterconnectorFlowSegmentConstraint <: PSI.ConstraintType end

"`loss[ic,t] == losses at the first breakpoint + sum(segment slope * segment flow)`, per-unit."
struct InterconnectorLossDefinitionConstraint <: PSI.ConstraintType end

PSI.convert_result_to_natural_units(::Type{InterconnectorLossVariable}) = true
PSI.convert_result_to_natural_units(::Type{InterconnectorLossSegmentVariable}) = true

# `get_default_time_series_names`/`get_default_attributes`/`get_initial_conditions_device_model`
# for `PSY.AreaInterchange` are already defined generically over `V <: AbstractBranchFormulation`
# in installed PSI's `devices/area_interchange.jl`, so `NEMInterconnectorLoss` inherits them -
# no override needed here.

# --- "loss_models" attribute + per-interconnector validation ---

"""
    _missing_loss_model_error(name) -> ArgumentError

Names `name` (an `AreaInterchange`) and the reader that produces a `"loss_models"` `Dict` -
[`NEMInterconnectorLoss`](@ref) never silently treats a missing interconnector as lossless.
"""
_missing_loss_model_error(name::AbstractString) = ArgumentError(
    "AreaInterchange \"$name\" has no InterconnectorLossModel in the DeviceModel's " *
        "\"loss_models\" attribute. Build one with `interconnector_loss_models(db, as_of)` " *
        "(root package), or give \"$name\" a lossless formulation such as `PSI.StaticBranch`.",
)

"""
    _validate_loss_models(devices, loss_models)

Throws [`_missing_loss_model_error`](@ref) for the first of `devices` absent from `loss_models`.
"""
function _validate_loss_models(devices, loss_models::Dict{String, InterconnectorLossModel})
    for d in devices
        name = PSY.get_name(d)
        haskey(loss_models, name) || throw(_missing_loss_model_error(name))
    end
    return nothing
end

"""
    _validate_convex_segments(name, model)

Throws `ArgumentError` naming `name` if `model`'s [`loss_segments`](@ref) are not ascending -
the convexity [`NEMInterconnectorLoss`](@ref)'s no-SOS2/no-binary segment encoding relies on
(see its docstring). Checked once per interconnector at construction, not per timestep: from
`loss_segments`, segment `i`'s chord slope is

```
linear(demand) + 0.5 * loss_flow_coefficient * (breakpoints[i] + breakpoints[i + 1])
```

`linear(demand)` (`loss_constant - 1 + Σ demand_coefficients[r] * demand[r]`) is the same additive
constant on every segment regardless of `demand`, so it can never change their relative order;
`breakpoints[i] + breakpoints[i + 1]` is strictly increasing in `i` since `breakpoints` themselves
are strictly ascending. Only `loss_flow_coefficient`'s sign decides ascending-vs-descending, and
that's fixed at construction - hence one check per interconnector, evaluated against an empty
demand dict (any demand gives the same order), rather than one per (interconnector, timestep).
"""
function _validate_convex_segments(name::AbstractString, model::InterconnectorLossModel)
    segments = loss_segments(model, Dict{String, Float64}())
    issorted(s.slope for s in segments) || throw(
        ArgumentError(
            "AreaInterchange \"$name\"'s InterconnectorLossModel has non-ascending loss " *
                "segment slopes (loss_flow_coefficient = $(model.loss_flow_coefficient) makes " *
                "the loss curve concave, not convex) - NEMInterconnectorLoss's segment " *
                "encoding requires a convex curve to fill segments cheapest-first without " *
                "SOS2/binary variables.",
        ),
    )
    return nothing
end

"""
    _narrow_breakpoint_interconnectors(devices, loss_models, base_power) -> Vector{String}

Names of `devices` whose `InterconnectorLossModel` breakpoint range
`[breakpoints[1], breakpoints[end]]` (natural MW) is strictly narrower than the interconnector's
own static `PSY.get_flow_limits` - see [`NEMInterconnectorLoss`](@ref)'s docstring for why this
silently tightens dispatch. Skips any device carrying `from_to_flow_limit`/`to_from_flow_limit`
time series: their applied limit varies per timestep, so no single static comparison is
meaningful. Only ever called from `construct_device!`, where `sys` is in `UnitSystem.SYSTEM_BASE`
(`PSI.init_optimization_container!` sets it before any device is constructed) - `PSY.get_flow_limits`
itself reads back per-unit of `base_power` there, so it's scaled back to natural MW before
comparing against `breakpoints`, the same conversion [`_area_demand`](@ref) applies.
"""
function _narrow_breakpoint_interconnectors(
        devices, loss_models::Dict{String, InterconnectorLossModel}, base_power::Float64,
    )
    narrow = String[]
    for d in devices
        PSY.has_time_series(d) && continue
        name = PSY.get_name(d)
        bps = loss_models[name].breakpoints
        limits = PSY.get_flow_limits(d)
        from_to_mw = limits.from_to * base_power
        to_from_mw = limits.to_from * base_power
        if bps[1] > -from_to_mw || bps[end] < to_from_mw
            push!(narrow, name)
        end
    end
    return narrow
end

"""
    _warn_narrow_breakpoints(narrow)

One summary `@warn` naming every interconnector in `narrow` (from
[`_narrow_breakpoint_interconnectors`](@ref)) - split out from that pure function so it, and the
warning it emits, can each be tested directly without going through `PSI.build!`'s own logger
setup (which filters `@warn` below its `console_level` default of `Logging.Error`, so it never
reaches a `@test_logs` wrapped around a full build).
"""
function _warn_narrow_breakpoints(narrow::Vector{String})
    isempty(narrow) ||
        @warn "NEMInterconnectorLoss: $(length(narrow)) interconnector(s) have a loss-model breakpoint range narrower than their own flow limits - dispatch is silently tightened to the breakpoint range" narrow
    return nothing
end

"""
    _loss_models(device_model) -> Dict{String, InterconnectorLossModel}

The `Dict{String,InterconnectorLossModel}` passed through the `DeviceModel`'s `"loss_models"`
attribute (see [`NEMInterconnectorLoss`](@ref)). Throws `ArgumentError` if the attribute was
never set at all - a configuration error distinct from [`_validate_loss_models`](@ref)'s
per-interconnector one.
"""
function _loss_models(device_model::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss})
    models = PSI.get_attribute(device_model, "loss_models")
    isnothing(models) && throw(
        ArgumentError(
            "NEMInterconnectorLoss requires a \"loss_models\" attribute " *
                "(Dict{String,InterconnectorLossModel}) on its DeviceModel - pass " *
                "`attributes = Dict{String,Any}(\"loss_models\" => models)` (models from " *
                "`interconnector_loss_models(db, as_of)`).",
        ),
    )
    return models::Dict{String, InterconnectorLossModel}
end

# --- regional demand, per `_container_timestamps` (`fcas_market.jl`) ---

"""
    _area_demand(container, sys) -> Dict{String, Vector{Float64}}

Total `PSY.PowerLoad` active power (natural MW) per `PSY.Area` name, at every `container`
dispatch timestep - resolved the same absolute-timestamp way `fcas_market.jl`'s
`_resolve_fcas_series`/`_fcas_series_row` resolve a device's own series. An `Area` with no
`PowerLoad` never appears as a key; [`loss_factor`](@ref) already treats a demand region absent
from its dict as contributing zero.

A `"max_active_power"` `Deterministic` row is a normalized `[0,1]` multiplier of
`PSY.get_max_active_power(load)`, not an absolute MW value - PSI's own convention
(`get_multiplier_value(::TimeSeriesParameter, ::PSY.ElectricLoad, ::PSI.StaticPowerLoad)`) and how
this package's own `parser.jl` attaches NEM demand. `construct_device!` always runs with `sys` in
`UnitSystem.SYSTEM_BASE` (`PSI.init_optimization_container!` sets it before any device is
constructed), so `get_max_active_power` itself reads back per-unit of `base_power` there -
multiplying by `base_power` recovers its natural-MW peak.
"""
function _area_demand(container::PSI.OptimizationContainer, sys::PSY.System)
    time_steps = PSI.get_time_steps(container)
    timestamps = _container_timestamps(container)
    base_power = PSI.get_base_power(container)
    demand = Dict{String, Vector{Float64}}()
    for load in PSY.get_components(PSY.PowerLoad, sys)
        area_name = PSY.get_name(PSY.get_area(PSY.get_bus(load)))
        series = get!(() -> zeros(Float64, length(time_steps)), demand, area_name)
        resolved = _resolve_fcas_series(load, "max_active_power")
        peak_mw = PSY.get_max_active_power(load) * base_power
        for t in time_steps
            series[t] += _fcas_series_row(resolved, timestamps[t]) * peak_mw
        end
    end
    return demand
end

"`demand`'s per-timestep slice at `t` - `REGIONID => MW`, [`loss_factor`](@ref)'s own input shape."
_demand_at(demand::Dict{String, Vector{Float64}}, t::Int) =
    Dict(area => series[t] for (area, series) in demand)

# --- loss variables/constraints + area balance terms ---

"""
    _add_loss_variables_and_constraints!(container, sys, devices, loss_models)

Adds [`InterconnectorLossSegmentVariable`](@ref)/[`InterconnectorLossVariable`](@ref) and their
defining constraints ([`InterconnectorFlowSegmentConstraint`](@ref)/
[`InterconnectorLossDefinitionConstraint`](@ref)) for every one of `devices`, plus the loss terms
into the area balance expression - the whole point of [`NEMInterconnectorLoss`](@ref). Every
device's [`loss_segments`](@ref) is recomputed per timestep since NEMDE's loss curve shifts with
regional demand ([`_area_demand`](@ref)). The segment variable container is sized to the largest
interconnector's segment count (as a `Vector{String}` axis - PSI's result store only knows how to
write a 3-axis variable shaped `(String, String, Int)`); a smaller interconnector's unused cells
are fixed to `0.0` rather than left `#undef`.

Per-unit conversion: `PSI.FlowActivePowerVariable`/segment/loss variables are per-unit of
`PSI.get_base_power(container)`; [`InterconnectorLossModel`](@ref) is natural MW. Breakpoints and
the constant loss-at-first-breakpoint offset are divided by `base_power`; segment slopes are
dimensionless (MW loss per MW flow) and are never scaled.
"""
function _add_loss_variables_and_constraints!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        devices,
        loss_models::Dict{String, InterconnectorLossModel},
    )
    time_steps = PSI.get_time_steps(container)
    base_power = PSI.get_base_power(container)
    device_names = PSY.get_name.(devices)
    n_segments = Dict(
        name => length(loss_models[name].breakpoints) - 1 for name in device_names
    )
    max_segments = maximum(values(n_segments))
    segment_labels = string.(1:max_segments)
    area_demand = _area_demand(container, sys)

    seg_var = PSI.add_variable_container!(
        container, InterconnectorLossSegmentVariable(), PSY.AreaInterchange,
        device_names, segment_labels, time_steps,
    )
    loss_var = PSI.add_variable_container!(
        container, InterconnectorLossVariable(), PSY.AreaInterchange, device_names, time_steps,
    )
    flow_seg_con = PSI.add_constraints_container!(
        container, InterconnectorFlowSegmentConstraint(), PSY.AreaInterchange,
        device_names, time_steps,
    )
    loss_def_con = PSI.add_constraints_container!(
        container, InterconnectorLossDefinitionConstraint(), PSY.AreaInterchange,
        device_names, time_steps,
    )
    flow_var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    expr = PSI.get_expression(container, PSI.ActivePowerBalance(), PSY.Area)
    jm = PSI.get_jump_model(container)

    for d in devices
        name = PSY.get_name(d)
        model = loss_models[name]
        n = n_segments[name]
        bp1_pu = model.breakpoints[1] / base_power
        from_area = PSY.get_name(PSY.get_from_area(d))
        to_area = PSY.get_name(PSY.get_to_area(d))
        share = model.from_region_loss_share

        for t in time_steps
            demand_t = _demand_at(area_demand, t)
            segments = loss_segments(model, demand_t)
            for s in 1:max_segments
                width_pu = s <= n ? (segments[s].to_mw - segments[s].from_mw) / base_power : 0.0
                seg_var[name, segment_labels[s], t] = JuMP.@variable(
                    jm, lower_bound = 0.0, upper_bound = width_pu,
                    base_name = "InterconnectorLossSegmentVariable_{$name,$s,$t}",
                )
            end
            loss_var[name, t] = JuMP.@variable(
                jm, base_name = "InterconnectorLossVariable_{$name,$t}",
            )
            flow_seg_con[name, t] = JuMP.@constraint(
                jm,
                flow_var[name, t] ==
                    bp1_pu + sum(seg_var[name, segment_labels[s], t] for s in 1:max_segments)
            )
            base_loss_pu =
                interconnector_losses(model, model.breakpoints[1], demand_t) / base_power
            loss_def_con[name, t] = JuMP.@constraint(
                jm,
                loss_var[name, t] == base_loss_pu +
                    sum(segments[s].slope * seg_var[name, segment_labels[s], t] for s in 1:n)
            )
            JuMP.add_to_expression!(expr[from_area, t], -share, loss_var[name, t])
            JuMP.add_to_expression!(expr[to_area, t], -(1.0 - share), loss_var[name, t])
        end
    end
    return
end

# --- FlowLimitConstraint, duplicated from installed PSI's `PSY.AreaInterchange`/`StaticBranch`
# builder (`branch_constructor.jl`/`area_interchange.jl`) rather than reused: that method is
# dispatched on the concrete `DeviceModel{PSY.AreaInterchange, StaticBranch}` type, not on
# `AbstractBranchFormulation`, so it never fires for `NEMInterconnectorLoss`. ---

"""
    _add_flow_limit_constraint!(container, devices, device_model, network_model)

`PSI.FlowActivePowerVariable` bounds by the interconnector's own static `flow_limits`, or - when
every device carries `from_to_flow_limit`/`to_from_flow_limit` time series - by
`PSI.FromToFlowLimitParameter`/`PSI.ToFromFlowLimitParameter` instead. See this file's module
comment for why this duplicates rather than calls PSI's own `PSI.StaticBranch` builder.
"""
function _add_flow_limit_constraint!(
        container::PSI.OptimizationContainer,
        devices,
        device_model::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
        ::PSI.NetworkModel{U},
    ) where {U <: Union{PSI.AreaBalancePowerModel, PSI.AreaPTDFPowerModel}}
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

    if !all(PSY.has_time_series.(devices))
        for device in devices
            name = PSY.get_name(device)
            to_from_limit = PSY.get_flow_limits(device).to_from
            from_to_limit = PSY.get_flow_limits(device).from_to
            for t in time_steps
                con_lb[name, t] = JuMP.@constraint(jm, var_array[name, t] >= -1.0 * from_to_limit)
                con_ub[name, t] = JuMP.@constraint(jm, var_array[name, t] <= to_from_limit)
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
                    jm, var_array[name, t] >= mult_from_to[name, t] * refs_from_to[t]
                )
                con_ub[name, t] = JuMP.@constraint(
                    jm, var_array[name, t] <= mult_to_from[name, t] * refs_to_from[t]
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
    ) where {U <: Union{PSI.AreaBalancePowerModel, PSI.AreaPTDFPowerModel}}
    devices = PSI.get_available_components(device_model, sys)
    loss_models = _loss_models(device_model)
    _validate_loss_models(devices, loss_models)
    for d in devices
        _validate_convex_segments(PSY.get_name(d), loss_models[PSY.get_name(d)])
    end
    narrow = _narrow_breakpoint_interconnectors(devices, loss_models, PSI.get_base_power(container))
    _warn_narrow_breakpoints(narrow)

    has_ts = PSY.has_time_series.(devices)
    if any(has_ts) && !all(has_ts)
        error(
            "Not all AreaInterchange devices have time series. Check data to complete (or remove) time series.",
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
            num_ts = length(unique(PSY.get_name.(PSY.get_time_series_keys(device))))
            if num_ts < 2
                error(
                    "AreaInterchange $name has less than two time series. It is required to add both from_to and to_from time series.",
                )
            end
        end
        PSI.add_parameters!(container, PSI.FromToFlowLimitParameter, devices, device_model)
        PSI.add_parameters!(container, PSI.ToFromFlowLimitParameter, devices, device_model)
    end
    PSI.add_feedforward_arguments!(container, device_model, devices)

    _add_loss_variables_and_constraints!(container, sys, devices, loss_models)
    return
end

function PSI.construct_device!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        device_model::PSI.DeviceModel{PSY.AreaInterchange, NEMInterconnectorLoss},
        network_model::PSI.NetworkModel{U},
    ) where {U <: Union{PSI.AreaBalancePowerModel, PSI.AreaPTDFPowerModel}}
    devices = PSI.get_available_components(device_model, sys)
    _add_flow_limit_constraint!(container, devices, device_model, network_model)
    PSI.add_feedforward_constraints!(container, device_model, devices)
    return
end
