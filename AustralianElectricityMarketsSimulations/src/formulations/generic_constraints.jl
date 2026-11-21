# `LinearFactorLimit`, the `GenericConstraint` service formulation over energy and FCAS terms.

PSI.get_default_time_series_names(::Type{GenericConstraint}, ::Type{LinearFactorLimit}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}(
    NEMConstraintRHSParameter => NEM_CONSTRAINT_SERIES.rhs,
    GenericConstraintInvocationParameter => NEM_CONSTRAINT_SERIES.invoked,
)


# The series key `field` of `gc`, which must be keyed and named `expected`.
function _constraint_key(gc::GenericConstraint, field::Symbol, expected::AbstractString)
    key = getproperty(gc, field)
    key isa IS.StaticTimeSeriesKey || throw(
        ArgumentError("GenericConstraint \"$(PSY.get_name(gc))\" has a static $field; the NEM constraint formulation reads it from a series."),
    )
    _require_key_name(gc, key, expected)
    return key
end


PSI.get_default_attributes(::Type{GenericConstraint}, ::Type{LinearFactorLimit}) =
    Dict{String, Any}()


PSI.get_multiplier_value(::NEMConstraintRHSParameter, ::GenericConstraint, ::LinearFactorLimit) =
    1.0


PSI.get_multiplier_value(::GenericConstraintInvocationParameter, ::GenericConstraint, ::LinearFactorLimit) =
    1.0


# The System is unchanged during one build, so one lookup serves every constraint's terms and
# diagnostics. `devices` maps each device name to its device, so an abstract `PSY.Device` lookup
# does not scan every concrete type; a name shared by several device types is in `ambiguous` and
# resolves through `PSY.get_component`, which throws.
struct _ConstraintComponentLookup
    system::PSY.System
    components::Dict{Tuple{DataType, String}, Union{Nothing, PSY.Component}}
    devices::Dict{String, PSY.Device}
    ambiguous::Set{String}
end

function _ConstraintComponentLookup(sys::PSY.System)
    devices = Dict{String, PSY.Device}()
    ambiguous = Set{String}()
    for device in PSY.get_components(PSY.Device, sys)
        name = PSY.get_name(device)
        haskey(devices, name) ? push!(ambiguous, name) : (devices[name] = device)
    end
    return _ConstraintComponentLookup(
        sys, Dict{Tuple{DataType, String}, Union{Nothing, PSY.Component}}(), devices, ambiguous,
    )
end

# The build's lookup, kept in the build scratch so every constraint of the build shares it.
function _constraint_lookup(container::PSI.OptimizationContainer, sys::PSY.System)
    scratch = _build_scratch(container)
    lookup = get(scratch, :component_lookup, nothing)
    lookup isa _ConstraintComponentLookup && lookup.system === sys && return lookup
    lookup = _ConstraintComponentLookup(sys)
    scratch[:component_lookup] = lookup
    return lookup
end

function _constraint_component(::Type{T}, sys::PSY.System, name::String) where {T <: PSY.Component}
    return PSY.get_component(T, sys, name)
end

function _constraint_component(::Type{PSY.Device}, lookup::_ConstraintComponentLookup, name::String)
    name in lookup.ambiguous && return PSY.get_component(PSY.Device, lookup.system, name)
    return get(lookup.devices, name, nothing)
end

function _constraint_component(::Type{T}, lookup::_ConstraintComponentLookup, name::String) where {T <: PSY.Component}
    component = get!(lookup.components, (T, name)) do
        return PSY.get_component(T, lookup.system, name)
    end
    return component::Union{Nothing, T}
end

function _constraint_system(sys::PSY.System)
    return sys
end

function _constraint_system(lookup::_ConstraintComponentLookup)
    return lookup.system
end


# --- Term validation: fail loudly, never a partial LHS ---

"A device's ENERGY variables and each one's multiplier in its net injection. `PSY.Storage` has no
`ActivePowerVariable`: storage formulations split it into charge/discharge, which PSI's own
nodal balance nets with variable multipliers of -1.0 and +1.0."
_energy_variables(::PSY.Storage) =
    ((PSI.ActivePowerOutVariable, 1.0), (PSI.ActivePowerInVariable, -1.0))

_energy_variables(::PSY.Device) = ((PSI.ActivePowerVariable, 1.0),)


_energy_modeled(container::PSI.OptimizationContainer, device::PSY.Device) = all(
    v -> PSI.has_container_key(container, first(v), typeof(device)),
    _energy_variables(device),
)


"""
    _checked_device(container, sys, gc, term::UnitTerm) -> PSY.Device

Resolves `term`'s device and confirms the template models its energy variables. Throws
`ArgumentError` naming `gc`, `term` and the reason when its device is absent from `sys`, or an
available device's energy variables aren't in `container`.

# Returns
The resolved `PSY.Device`.
"""
function _checked_device(
        container::PSI.OptimizationContainer, sys::Union{PSY.System, _ConstraintComponentLookup}, gc::GenericConstraint, term::UnitTerm,
    )
    name = PSY.get_name(gc)
    device = _constraint_component(PSY.Device, sys, get_duid(term))
    isnothing(device) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": UnitTerm's DUID \"$(get_duid(term))\" has no matching " *
                "component in `sys`.",
        ),
    )
    PSY.get_available(device) && !_energy_modeled(container, device) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": UnitTerm's device \"$(get_duid(term))\" " *
                "($(typeof(device))) has no energy variables in this template; the template " *
                "must model $(typeof(device)).",
        ),
    )
    return device
end


"""
    _checked_devices(container, sys, gc, term::RegionTerm) -> Vector{PSY.Device}

Resolves `term`'s already-attributed devices ([`get_devices`](@ref)) and confirms the template
models each one's energy variables. Throws `ArgumentError` naming `gc`, `term` and the reason
when a device is absent from `sys`, or an available device's energy variables aren't in `container`.

# Returns
A `Vector{PSY.Device}`.
"""
function _checked_devices(
        container::PSI.OptimizationContainer, sys::Union{PSY.System, _ConstraintComponentLookup}, gc::GenericConstraint, term::RegionTerm,
    )
    name = PSY.get_name(gc)
    devices = PSY.Device[]
    for dname in get_devices(term)
        device = _constraint_component(PSY.Device, sys, dname)
        isnothing(device) && throw(
            ArgumentError(
                "GenericConstraint \"$name\": RegionTerm on region \"$(get_region(term))\" " *
                    "names device \"$dname\", which has no matching component in `sys`.",
            ),
        )
        PSY.get_available(device) && !_energy_modeled(container, device) && throw(
            ArgumentError(
                "GenericConstraint \"$name\": RegionTerm on region \"$(get_region(term))\" " *
                    "device \"$dname\" ($(typeof(device))) has no energy variables in this " *
                    "template; the template must model $(typeof(device)).",
            ),
        )
        push!(devices, device)
    end
    return devices
end


"""
    _checked_interconnector(container, sys, gc, term::InterconnectorTerm) -> PSY.AreaInterchange

Resolves `term`'s `PSY.AreaInterchange` and confirms the template models
`PSI.FlowActivePowerVariable` for it. Throws `ArgumentError` naming `gc`, `term` and the reason
otherwise.

# Returns
The resolved `PSY.AreaInterchange`.
"""
function _checked_interconnector(
        container::PSI.OptimizationContainer, sys::Union{PSY.System, _ConstraintComponentLookup}, gc::GenericConstraint,
        term::InterconnectorTerm,
    )
    name = PSY.get_name(gc)
    device = _constraint_component(PSY.AreaInterchange, sys, get_interconnector(term))
    isnothing(device) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": InterconnectorTerm's interconnector " *
                "\"$(get_interconnector(term))\" has no matching component in `sys`.",
        ),
    )
    PSY.get_available(device) && !PSI.has_container_key(container, PSI.FlowActivePowerVariable, PSY.AreaInterchange) && throw(
        ArgumentError(
            "GenericConstraint \"$name\": InterconnectorTerm's interconnector " *
                "\"$(get_interconnector(term))\" has no FlowActivePowerVariable in this " *
                "template; the template must model PSY.AreaInterchange.",
        ),
    )
    return device
end


# --- add_to_expression! per term type ---

"Adds `factor * device's net injection` into `expr`, over every variable `_energy_variables` names."
function _add_device_energy_terms!(container, expr, name, device, factor)
    PSY.get_available(device) || return  # unavailable devices have no variables: they contribute zero
    dname = PSY.get_name(device)
    for (var_type, multiplier) in _energy_variables(device)
        var = PSI.get_variable(container, var_type(), typeof(device))
        for t in PSI.get_time_steps(container)
            JuMP.add_to_expression!(expr[name, t], multiplier * factor, var[dname, t])
        end
    end
    return
end


"""
    _add_device_fcas_terms!(container, expr, sys, gc, device, bid_type, factor)

Adds `factor` times `device`'s enablement of its [`fcas_service_name`](@ref) service into `expr`:
its [`FCASCapacityVariable`](@ref) for a contingency service, or its
[`FCASUnitRegulationTarget`](@ref) for a regulation service (the net gen + load target, AEMO
*FCAS Model in NEMDE* §2.4). Adds nothing when the service is absent, unavailable or has no
available devices, or `device` has no variable in it. Throws `ArgumentError` when the service has
devices but the template sets no [`FCASMarket`](@ref) model for it.
"""
function _add_device_fcas_terms!(container, expr, sys, gc, device, bid_type::BidType, factor)
    svc_name = fcas_service_name(device, bid_type)
    svc = _constraint_component(FCASService, sys, svc_name)
    (isnothing(svc) || !PSY.get_available(svc)) && return
    dname = PSY.get_name(device)
    regulation = bid_type in FCAS_REGULATION_MARKETS
    key_type = regulation ? FCASUnitRegulationTarget : FCASCapacityVariable
    if !PSI.has_container_key(container, key_type, FCASService, svc_name)
        any(PSY.get_available, PSY.get_contributing_devices(_constraint_system(sys), svc)) || return
        throw(
            ArgumentError(
                "GenericConstraint \"$(PSY.get_name(gc))\": term on \"$dname\" references FCASService " *
                    "\"$svc_name\", which has no $(nameof(key_type)) in this template; the template " *
                    "must set an FCASMarket model for it.",
            ),
        )
    end
    fcas = regulation ?
        PSI.get_expression(container, FCASUnitRegulationTarget(), FCASService, svc_name) :
        PSI.get_variable(container, FCASCapacityVariable(), FCASService, svc_name)
    dname in axes(fcas, 1) || return
    for t in PSI.get_time_steps(container)
        JuMP.add_to_expression!(expr[PSY.get_name(gc), t], factor, fcas[dname, t])
    end
    return
end


"""
    _warn_absent_fcas_services(container, lookup, sys)

Warns once per build, naming the sorted union of FCAS services that the terms of the build's generic
constraints reference but `sys` lacks (those terms contribute zero), and how many constraints reference them.
Later calls in the same build are silent.
"""
function _warn_absent_fcas_services(container::PSI.OptimizationContainer, lookup::_ConstraintComponentLookup, sys::PSY.System)
    scratch = _build_scratch(container)
    get(scratch, :absent_fcas_warned, false) && return
    scratch[:absent_fcas_warned] = true
    union_names = Set{String}()
    affected = 0
    for row in _build_scratch(container)[:constraint_parameters]
        gc = PSY.get_component(GenericConstraint, sys, row.name)
        absent = _absent_fcas_services(lookup, gc)
        isempty(absent) && continue
        affected += 1
        union!(union_names, absent)
    end
    isempty(union_names) || @warn(
        "FCAS terms reference services absent from the System and contribute zero: " *
            "$(join(sort!(collect(union_names)), ", ")); $affected generic constraint(s) reference them."
    )
    return
end

# The FCAS service names the non-energy unit and region terms of `gc` reference that `lookup` lacks.
function _absent_fcas_services(lookup::_ConstraintComponentLookup, gc::GenericConstraint)
    absent = Set{String}()
    for term in get_terms(gc)
        term isa Union{UnitTerm, RegionTerm} || continue
        get_bid_type(term) == BidType.ENERGY && continue
        names = term isa UnitTerm ? [get_duid(term)] : get_devices(term)
        for dname in names
            device = _constraint_component(PSY.Device, lookup, dname)
            isnothing(device) && continue
            svc_name = fcas_service_name(device, get_bid_type(term))
            isnothing(_constraint_component(FCASService, lookup, svc_name)) && push!(absent, svc_name)
        end
    end
    return absent
end


"Adds `device`'s `bid_type` term to `expr`: its energy injection for `ENERGY`, else its FCAS enablement."
function _add_device_terms!(container, expr, sys, gc, device, bid_type::BidType, factor)
    if bid_type == BidType.ENERGY
        _add_device_energy_terms!(container, expr, PSY.get_name(gc), device, factor)
    else
        _add_device_fcas_terms!(container, expr, sys, gc, device, bid_type, factor)
    end
    return
end


function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLHS},
        ::Type{UnitTerm},
        gc::GenericConstraint,
        term::UnitTerm,
        sys::Union{PSY.System, _ConstraintComponentLookup},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint)
    device = _checked_device(container, sys, gc, term)
    _add_device_terms!(container, expr, sys, gc, device, get_bid_type(term), get_factor(term))
    return
end


function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLHS},
        ::Type{RegionTerm},
        gc::GenericConstraint,
        term::RegionTerm,
        sys::Union{PSY.System, _ConstraintComponentLookup},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint)
    for device in _checked_devices(container, sys, gc, term)
        _add_device_terms!(container, expr, sys, gc, device, get_bid_type(term), get_factor(term))
    end
    return
end


function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLHS},
        ::Type{InterconnectorTerm},
        gc::GenericConstraint,
        term::InterconnectorTerm,
        sys::Union{PSY.System, _ConstraintComponentLookup},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint)
    device = _checked_interconnector(container, sys, gc, term)
    PSY.get_available(device) || return  # no flow variable: contributes zero
    var = PSI.get_variable(container, PSI.FlowActivePowerVariable(), PSY.AreaInterchange)
    dname = PSY.get_name(device)
    for t in PSI.get_time_steps(container)
        JuMP.add_to_expression!(expr[name, t], get_factor(term), var[dname, t])
    end
    return
end


"""
    _add_gc_slack_variables!(container, gc, model)

Fills [`GenericConstraintSlackUp`](@ref)/[`GenericConstraintSlackDown`](@ref) for `gc` in the shared slack
containers when `PSI.get_use_slacks(model)`, one side per `get_sense(gc)` (`LE`: up only, `GE`: down only,
`EQ`: both), and merges each into [`NEMConstraintLHS`](@ref): `-slack_up` on the `LE` side and
`+slack_down` on the `GE` side. A no-op when `use_slacks` is `false`.
"""
function _add_gc_slack_variables!(
        container::PSI.OptimizationContainer, gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    PSI.get_use_slacks(model) || return
    name = PSY.get_name(gc)
    time_steps = PSI.get_time_steps(container)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint)
    sense = get_sense(gc)
    jm = PSI.get_jump_model(container)
    for (var_type, side, coefficient) in (
            (GenericConstraintSlackUp, ConstraintSense.LE, -1.0),
            (GenericConstraintSlackDown, ConstraintSense.GE, 1.0),
        )
        sense in (side, ConstraintSense.EQ) || continue
        slack = PSI.get_variable(container, var_type(), GenericConstraint)
        for t in time_steps
            slack[name, t] = JuMP.@variable(jm, base_name = "$(nameof(var_type))_{$name,$t}", lower_bound = 0.0)
            JuMP.add_to_expression!(expr[name, t], coefficient, slack[name, t])
        end
    end
    return
end


# --- add_constraints!: sense dispatch, honouring the invoked series ---

function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        ::Type{NEMConstraintLimit},
        gc::GenericConstraint,
        ::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    name = PSY.get_name(gc)
    expr = PSI.get_expression(container, NEMConstraintLHS(), GenericConstraint)
    time_steps = PSI.get_time_steps(container)
    con = PSI.get_constraint(container, NEMConstraintLimit(), GenericConstraint)
    rhs_param = PSI.get_parameter(container, NEMConstraintRHSParameter(), GenericConstraint)
    rhs_refs = PSI.get_parameter_column_refs(rhs_param, name)
    rhs_mult = PSI.get_multiplier_array(rhs_param)
    _constraint_key(gc, :rhs, NEM_CONSTRAINT_SERIES.rhs)
    _constraint_key(gc, :invoked, NEM_CONSTRAINT_SERIES.invoked)
    base_power = PSI.get_base_power(container)
    jm = PSI.get_jump_model(container)
    sense = get_sense(gc)
    # Every row is an Interval row; the invocation parameter frees the row of a non-invoked interval.
    bounds = if sense == ConstraintSense.LE
        JuMP.MOI.Interval(-Inf, 0.0)
    elseif sense == ConstraintSense.GE
        JuMP.MOI.Interval(0.0, Inf)
    else
        JuMP.MOI.Interval(0.0, 0.0)
    end
    invoked_key = PSI.ParameterKey(GenericConstraintInvocationParameter, GenericConstraint)
    for t in time_steps
        rhs = rhs_refs[t] * rhs_mult[name, t] / base_power
        con[name, t] = JuMP.@constraint(jm, expr[name, t] - rhs in bounds)
        active = JuMP.MOI.get(jm, JuMP.MOI.ConstraintSet(), con[name, t])
        _add_bound_target!(container, invoked_key, name, t, con[name, t], (active.lower, active.upper))
    end
    return
end


# --- Shared containers: one per role for every generic constraint of the model ---

# One constraint's parameter inputs, held from the argument stage until the shared containers exist: per
# parameter type the series UUID and the (1 x time) row of values (`Float64`, or the `JuMP` parameter variables,
# which are created here so they keep the position a per-constraint container gave them).
const _ConstraintParameterRow = @NamedTuple{name::String, series::Dict{DataType, @NamedTuple{uuid::String, row::Matrix}}}

const _CONSTRAINT_PARAMETER_TYPES = (NEMConstraintRHSParameter, GenericConstraintInvocationParameter)

function _stash_constraint_parameters!(
        container::PSI.OptimizationContainer, gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    ts_type = PSI.get_default_time_series_type(container)
    ts_type <: Union{PSY.AbstractDeterministic, PSY.StaticTimeSeries} || throw(
        ArgumentError("generic constraint parameters are not compatible with the time series type $ts_type."),
    )
    interval = PSI.get_interval(PSI.get_settings(container))
    jm = PSI.get_jump_model(container)
    time_steps = PSI.get_time_steps(container)
    series = Dict{DataType, @NamedTuple{uuid::String, row::Matrix}}()
    for T in _CONSTRAINT_PARAMETER_TYPES
        ts_name = PSI._get_time_series_name(T(), gc, model)
        uuid = string(IS.get_time_series_uuid(ts_type, gc, ts_name; interval = PSI._to_is_interval(interval)))
        values = PSI.get_time_series_initial_values!(container, ts_type, gc, ts_name; interval = interval)
        row = Matrix{_parameter_eltype(container, T)}(undef, 1, length(time_steps))
        for t in time_steps
            PSI._set_parameter_at!(row, jm, values[t], 1, t)
        end
        series[T] = (; uuid, row)
    end
    scratch = _build_scratch(container)
    if pop!(scratch, :constraints_built, false)
        delete!(scratch, :constraint_parameters)
    end
    push!(get!(Vector{_ConstraintParameterRow}, scratch, :constraint_parameters), (; name = PSY.get_name(gc), series))
    return
end


# Adds the single parameter container of `T` over every stashed constraint: the series UUIDs on the first
# axis, the constraint names on the multiplier's, and the time steps on the second.
function _add_constraint_parameters!(
        container::PSI.OptimizationContainer, ::Type{T}, stash::Vector{_ConstraintParameterRow}, gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    ) where {T <: PSI.TimeSeriesParameter}
    ts_type = PSI.get_default_time_series_type(container)
    ts_name = PSI._get_time_series_name(T(), gc, model)
    names = String[r.name for r in stash]
    uuids = unique(String[r.series[T].uuid for r in stash])
    param_container = PSI.add_param_container!(
        container, T(), GenericConstraint, ts_type, ts_name, uuids, names, (), PSI.get_time_steps(container),
    )
    PSI.set_subsystem!(PSI.get_attributes(param_container), PSI.get_subsystem(model))
    parent_param = PSI.get_parameter_array_data(param_container)
    parent_mult = PSI.get_multiplier_array_data(param_container)
    row_of = Dict(uuid => i for (i, uuid) in enumerate(uuids))
    multiplier = Float64(PSI.get_multiplier_value(T(), gc, PSI.get_formulation(model)()))
    for (i, r) in enumerate(stash)
        series = r.series[T]
        parent_param[row_of[series.uuid], :] = series.row[1, :]
        PSI._set_multiplier_at!(parent_mult, multiplier, i)
        PSI.add_component_name!(PSI.get_attributes(param_container), r.name, series.uuid)
    end
    return
end


# The names of the constraints in `gcs` that have a slack on `side`.
function _slack_names(gcs::Vector{GenericConstraint}, side)
    return String[PSY.get_name(gc) for gc in gcs if get_sense(gc) in (side, ConstraintSense.EQ)]
end


# Adds the containers shared by every generic constraint of the model, over the constraints the argument
# stage stashed; the model stage of each constraint then fills its own rows.
function _add_generic_constraint_containers!(
        container::PSI.OptimizationContainer, sys::PSY.System, stash::Vector{_ConstraintParameterRow},
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    names = String[r.name for r in stash]
    gcs = GenericConstraint[PSY.get_component(GenericConstraint, sys, name) for name in names]
    time_steps = PSI.get_time_steps(container)
    for T in _CONSTRAINT_PARAMETER_TYPES
        _add_constraint_parameters!(container, T, stash, first(gcs), model)
    end
    PSI.lazy_container_addition!(container, NEMConstraintLHS(), GenericConstraint, names, time_steps)
    PSI.add_constraints_container!(container, NEMConstraintLimit(), GenericConstraint, names, time_steps)
    if PSI.get_use_slacks(model)
        for (var_type, side) in (
                (GenericConstraintSlackUp, ConstraintSense.LE), (GenericConstraintSlackDown, ConstraintSense.GE),
            )
            slack_names = _slack_names(gcs, side)
            isempty(slack_names) || PSI.add_variable_container!(container, var_type(), GenericConstraint, slack_names, time_steps)
        end
    end
    # Not `PSI.add_constraint_dual!(container, sys, model)`: `add_dual_container!` directly is
    # exactly what that method's scalar-`D<:PSY.Service` branch does internally.
    for constraint_type in PSI.get_duals(model)
        PSI.add_dual_container!(container, constraint_type, GenericConstraint, names, time_steps)
    end
    return
end


# --- construct_service!: argument + model stages ---

# The argument stage creates the constraint's parameter values; the first model stage adds the shared
# containers, and each model stage then fills the rows of its own constraint, so variables and rows keep the
# order PSI visits the service models in.
function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    _add_area_balance_slacks!(container, sys, network_model)
    gc = PSY.get_component(GenericConstraint, sys, PSI.get_service_name(model))
    _stash_constraint_parameters!(container, gc, model)
    return
end


function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    scratch = _build_scratch(container)
    if !get(scratch, :constraints_built, false)
        scratch[:constraints_built] = true
        _add_generic_constraint_containers!(container, sys, scratch[:constraint_parameters], model)
    end
    gc = PSY.get_component(GenericConstraint, sys, PSI.get_service_name(model))
    lookup = _constraint_lookup(container, sys)
    for term in get_terms(gc)
        PSI.add_to_expression!(container, NEMConstraintLHS, typeof(term), gc, term, lookup)
    end
    _warn_absent_fcas_services(container, lookup, sys)
    # Before add_constraints! reads NEMConstraintLHS: a slack must already be merged in for the
    # constraint it relaxes to be built with it, not around it.
    _add_gc_slack_variables!(container, gc, model)
    PSI.add_constraints!(container, NEMConstraintLimit, gc, model)
    PSI.objective_function!(container, gc, model)
    return
end


# --- Per-step updates of the shared parameter containers ---

# PSI's service update reads one service named by the key's meta; these containers hold every constraint,
# so each constraint's series is read in turn, and the invocation rows are reset once all are read.
function _update_constraint_parameters!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{T, GenericConstraint}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    ) where {T}
    param_container = PSI.get_parameter(container, key)
    array = PSI.get_parameter_array(param_container)
    attributes = PSI.get_attributes(param_container)
    sys = PSI.get_system(model)
    for name in keys(attributes.component_name_to_ts_uuid)
        gc = PSY.get_component(GenericConstraint, sys, name)
        isnothing(gc) && error("GenericConstraint \"$name\" is no longer in the system; cannot update parameter $key")
        PSI._update_parameter_values!(array, T(), attributes, gc, model, input)
    end
    _apply_targets!(container, key)
    return
end

function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{NEMConstraintRHSParameter, GenericConstraint}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _update_constraint_parameters!(container, model, key, input)
    return
end

function PSI.update_container_parameter_values!(
        container::PSI.OptimizationContainer, model::PSI.OperationModel,
        key::PSI.ParameterKey{GenericConstraintInvocationParameter, GenericConstraint}, input::PSI.DatasetContainer{PSI.InMemoryDataset},
    )
    _update_constraint_parameters!(container, model, key, input)
    return
end


"""
    PSI.objective_function!(container, gc, model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit})

Prices `gc`'s elastic slacks (filled by [`_add_gc_slack_variables!`](@ref), a no-op unless
`PSI.get_use_slacks(model)`) at the system base power times [`constraint_cvp_factor`](@ref) per interval
times the Market Price Cap of the service model at the build's initial time, as constants of the
invariant objective.
`GenericConstraint`s built without slacks carry no cost of their own.

# Returns
`nothing`.
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer, gc::GenericConstraint,
        model::PSI.ServiceModel{GenericConstraint, LinearFactorLimit},
    )
    PSI.get_use_slacks(model) || return
    name = PSY.get_name(gc)
    time_steps = PSI.get_time_steps(container)
    resolution = PSI.get_resolution(container)
    base_power = PSI.get_base_power(container)
    weight = constraint_cvp_factor(gc)
    mpc = _container_market_price_cap(container, PSI.get_initial_time(container))
    scale = base_power * interval_cost_coefficient(weight, resolution) * mpc
    invariant = _invariant_objective(container)
    for (var_type, side) in (
            (GenericConstraintSlackUp, ConstraintSense.LE), (GenericConstraintSlackDown, ConstraintSense.GE),
        )
        get_sense(gc) in (side, ConstraintSense.EQ) || continue
        slack = PSI.get_variable(container, var_type(), GenericConstraint)
        for t in time_steps
            JuMP.add_to_expression!(invariant, scale, slack[name, t])
        end
    end
    return
end
