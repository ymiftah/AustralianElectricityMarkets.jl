"""
    TIE_BREAK_CVP_FACTOR

Constraint violation penalty factor (1e-6) of AEMO's tie-break constraint (`TBSlack1` and
`TBSlack2`, item 53 of the *Schedule of Constraint Violation Penalty Factors* v8.0). It is also
the price tolerance, in `\$/MWh` after loss-factor adjustment, within which two energy bands are
price-tied.
"""
const TIE_BREAK_CVP_FACTOR = 1.0e-6


# Name of the series and meta of the parameter holding segment `band`'s tie-break scale.
function _tie_break_series_name(band::Int, decremental::Bool)
    return "tie_break_scale_$(band)" * (decremental ? "_decremental" : "")
end
function _tie_break_meta(band::Int, decremental::Bool)
    return string(band) * (decremental ? "_decremental" : "")
end


"""
    _tie_groups(bands) -> Vector{Vector{Int}}

Price-tied groups of `bands` (each with `price`, `name` and `band`): runs of the bands sorted by
price whose consecutive prices differ by at most [`TIE_BREAK_CVP_FACTOR`](@ref), kept when they
hold bands of two or more units. Each group lists indices into `bands` in sorted order. Throws an
`ArgumentError` for a run spanning more than [`TIE_BREAK_CVP_FACTOR`](@ref), which only
transitive ties produce.

# Returns
`Vector{Vector{Int}}`.
"""
function _tie_groups(bands)
    order = sort!(collect(eachindex(bands)); by = i -> (bands[i].price, bands[i].name, bands[i].band))
    groups = Vector{Int}[]
    start = 1
    for k in eachindex(order)
        (k == length(order) || bands[order[k + 1]].price - bands[order[k]].price > TIE_BREAK_CVP_FACTOR) || continue
        group = order[start:k]
        start = k + 1
        lo, hi = bands[first(group)], bands[last(group)]
        hi.price - lo.price > TIE_BREAK_CVP_FACTOR && throw(
            ArgumentError(
                "tie-break: the prices of $(lo.name) band $(lo.band) ($(lo.price)) and $(hi.name) band $(hi.band) " *
                    "($(hi.price)) are tied only through bands between them; transitive ties are not supported.",
            ),
        )
        length(unique(bands[i].name for i in group)) > 1 && push!(groups, group)
    end
    return groups
end


# A device's offer curves (`PiecewiseStepData`, natural units) over the container's time steps.
function _tie_break_curves(container::PSI.OptimizationContainer, device::PSY.Component, decremental::Bool)
    curves = PSI.get_offer_curves_maybe_decremental(Val(decremental), device)
    PSI.is_time_variant(curves) || return fill(PSY.get_function_data(PSY.get_value_curve(curves)), length(PSI.get_time_steps(container)))
    settings = PSI.get_settings(container)
    return PSI.get_time_series_initial_values!(
        container, PSI.get_default_time_series_type(container), device, IS.get_name(curves);
        interval = PSI.get_interval(settings), resolution = PSI.get_resolution(settings),
    )
end


# Bands of every PSI market-bid block variable in `container`, grouped by
# (direction, region, time step). Segments PSI pads beyond a unit's offer curve, and segments empty
# throughout the offer series, are left out. A unit absent from the offer series (a fixed curve in a
# direction where no unit has a time-varying one) keeps all its bands, so a tie it takes part in
# fails the build for want of scales.
function _tie_break_bands(container::PSI.OptimizationContainer, sys::PSY.System)
    active = _tie_break_active_bands(_tie_break_offers(sys))
    groups = Dict{Tuple{Bool, String, Int}, Vector{_TieBand}}()
    for (key, variables) in PSI.get_variables(container)
        entry = PSI.IS.Optimization.get_entry_type(key)
        decremental = entry === PSI.PiecewiseLinearBlockDecrementalOffer
        (decremental || entry === PSI.PiecewiseLinearBlockIncrementalOffer) || continue
        T = PSI.IS.Optimization.get_component_type(key)
        by_device = Dict{String, Vector{Tuple{Int, Int, JuMP.VariableRef}}}()
        for ((name, band, t), var) in pairs(variables.data)
            push!(get!(by_device, name, Tuple{Int, Int, JuMP.VariableRef}[]), (band, t, var))
        end
        for (name, cells) in by_device
            device = PSY.get_component(T, sys, name)
            region = PSY.get_name(PSY.get_area(PSY.get_bus(device)))
            curves = _tie_break_curves(container, device, decremental)
            for (band, t, var) in cells
                prices = PSY.get_y_coords(curves[t])
                band <= length(prices) && (!haskey(active, (decremental, name)) || band in active[(decremental, name)]) || continue
                push!(get!(groups, (decremental, region, t), _TieBand[]), (; price = prices[band], var, name, band, type = T))
            end
        end
    end
    return groups
end


"""
    _add_tie_break_parameter!(container, T, sys, decremental, band)

Adds the [`TieBreakScaleParameter`](@ref) of segment `band` keyed `(T, meta)`, unless it exists:
one row per available `T` carrying the segment's `"tie_break_scale_<band>[_decremental]"` forecast,
the set PowerSimulations' time-series parameter update visits. Multipliers are `1.0`.

# Returns
`nothing`.
"""
function _add_tie_break_parameter!(
        container::PSI.OptimizationContainer, ::Type{T}, sys::PSY.System, decremental::Bool, band::Int,
    ) where {T <: PSY.Component}
    meta = _tie_break_meta(band, decremental)
    PSI.has_container_key(container, TieBreakScaleParameter, T, meta) && return
    ts_name = _tie_break_series_name(band, decremental)
    ts_type = PSI.get_default_time_series_type(container)
    devices = [d for d in PSY.get_available_components(T, sys) if PSY.has_time_series(d, ts_type, ts_name)]
    settings = PSI.get_settings(container)
    interval, resolution = PSI.get_interval(settings), PSI.get_resolution(settings)
    names = PSY.get_name.(devices)
    uuids = [
        string(
            IS.get_time_series_uuid(
                ts_type, d, ts_name; resolution = PSI._to_is_resolution(resolution), interval = PSI._to_is_interval(interval),
            ),
        ) for d in devices
    ]
    time_steps = PSI.get_time_steps(container)
    param_container = PSI.add_param_container!(
        container, TieBreakScaleParameter(), T, ts_type, ts_name, uuids, names, (), time_steps; meta = meta,
    )
    attributes = PSI.get_attributes(param_container)
    jm = PSI.get_jump_model(container)
    values = PSI.get_parameter_array_data(param_container)
    multipliers = PSI.get_multiplier_array_data(param_container)
    for (i, d) in enumerate(devices)
        raw = PSI.get_time_series_initial_values!(container, ts_type, d, ts_name; interval = interval, resolution = resolution)
        for t in time_steps
            PSI._set_parameter_at!(values, jm, raw[t], i, t)
        end
        PSI._set_multiplier_at!(multipliers, 1.0, i)
        PSI.add_component_name!(attributes, names[i], uuids[i])
    end
    return
end


# Throws unless every price-tied band carries its scale series and every contributor of `service`
# carrying a scale series is modelled with market-bid block variables.
function _check_tie_break_series(container::PSI.OptimizationContainer, sys::PSY.System, groups, service::EnergyTieBreak)
    ts_type = PSI.get_default_time_series_type(container)
    missing_series = Set{String}()
    modeled = Set{Tuple{DataType, String}}()
    for ((decremental, _, _), bands) in groups
        foreach(b -> push!(modeled, (b.type, b.name)), bands)
        for group in _tie_groups(bands), i in group
            b = bands[i]
            PSY.has_time_series(PSY.get_component(b.type, sys, b.name), ts_type, _tie_break_series_name(b.band, decremental)) ||
                push!(missing_series, b.name)
        end
    end
    isempty(missing_series) || throw(
        ArgumentError(
            "tie-break: $(length(missing_series)) unit(s) with price-tied bands carry no tie-break scale forecast: " *
                "$(join(sort!(collect(missing_series)), ", ")). Call set_tie_break_scales!(sys) before transform_single_time_series!.",
        ),
    )
    unmodeled = String[]
    for device in PSY.get_contributing_devices(sys, service)
        PSY.get_available(device) || continue
        (typeof(device), PSY.get_name(device)) in modeled && continue
        any(k -> startswith(IS.get_name(k), "tie_break_scale_"), IS.get_time_series_keys(device)) &&
            push!(unmodeled, PSY.get_name(device))
    end
    isempty(unmodeled) || throw(
        ArgumentError(
            "tie-break: $(length(unmodeled)) unit(s) carry tie-break scales but have no market-bid variables in the model: " *
                "$(join(sort!(unmodeled), ", ")). Their bands set the widest band of a tie group; model them or leave " *
                "the EnergyTieBreak service model out of the template.",
        ),
    )
    return
end


# Row label of a region and direction in the tie-break containers.
function _tie_break_label(region::AbstractString, decremental::Bool)
    return region * (decremental ? "_bid" : "_offer")
end


PSI.get_default_time_series_names(::Type{EnergyTieBreak}, ::Type{TieBreakMarket}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}()


PSI.get_default_attributes(::Type{EnergyTieBreak}, ::Type{TieBreakMarket}) = Dict{String, Any}()


"""
    PSI.construct_service!(container, sys, ::PSI.ArgumentConstructStage, model::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket}, devices_template, incompatible_device_types, network_model)

Argument stage for [`TieBreakMarket`](@ref): adds nothing, as the rows read the market-bid block
variables that the device models create at their model stage.

# Returns
`nothing`.
"""
function PSI.construct_service!(
        ::PSI.OptimizationContainer,
        ::PSY.System,
        ::PSI.ArgumentConstructStage,
        ::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket},
        ::Dict{Symbol, PSI.DeviceModel},
        ::Set{<:DataType},
        ::PSI.NetworkModel,
    )
    return
end


"""
    PSI.construct_service!(container, sys, ::PSI.ModelConstructStage, model::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket}, devices_template, incompatible_device_types, network_model)

Model stage for [`TieBreakMarket`](@ref): dispatches price-tied energy bands in proportion to their
size. Within each region, direction (offer or load bid) and time step, the market-bid block bands
whose prices at the reference node are within [`TIE_BREAK_CVP_FACTOR`](@ref) of one another form a
tie group. Every pair of bands of different units in a group gets the [`TieBreakConstraint`](@ref)
row `s_b x_a - s_a x_b + up - down = 0`, where `x` is the cleared MW of a band and `s = w / w_ref`
its [`TieBreakScaleParameter`](@ref), `w` being its width and `w_ref` the widest band of the group at
that interval, so the [`TieBreakSlackUp`](@ref) and [`TieBreakSlackDown`](@ref) slacks are in
system-base per-unit MW. The slacks are priced at [`TIE_BREAK_CVP_FACTOR`](@ref) `\$/MWh`. A band
held back by a ramp, availability or group limit relaxes its rows instead of moving the dispatch of
the other units, and a band of zero width has scale 0, which makes its rows vacuous. FCAS bands are
not tied. Groups are read from the offer prices at build and the scales are updated by simulation
steps, so a recurrent build requires the same groups at every step ([`check_tie_break_pairs`](@ref)).
Containers are keyed by [`EnergyTieBreak`](@ref) with the service name as meta, and are not added
when no band is tied. Throws unless
[`set_tie_break_scales!`](@ref) covered every tied band and every contributor carrying a scale is
modelled.

# Returns
`nothing`.
"""
function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.ServiceModel{EnergyTieBreak, TieBreakMarket},
        ::Dict{Symbol, PSI.DeviceModel},
        ::Set{<:DataType},
        ::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    service = PSY.get_component(EnergyTieBreak, sys, name)
    PSY.get_available(service) || return
    groups = _tie_break_bands(container, sys)
    _check_tie_break_series(container, sys, groups, service)

    rows = Tuple{String, Int, Int, Bool, _TieBand, _TieBand}[]
    for (decremental, region, t) in sort!(collect(keys(groups)))
        bands = groups[(decremental, region, t)]
        label = _tie_break_label(region, decremental)
        pair = 0
        for group in _tie_groups(bands)
            foreach(i -> _add_tie_break_parameter!(container, bands[i].type, sys, decremental, bands[i].band), group)
            for i in 1:(length(group) - 1), j in (i + 1):length(group)
                a, b = bands[group[i]], bands[group[j]]
                a.name == b.name && continue
                pair += 1
                push!(rows, (label, pair, t, decremental, a, b))
            end
        end
    end

    # PSI's MILP dual pass cannot read an empty variable container, so a model with no ties has none.
    isempty(rows) && return
    time_steps = PSI.get_time_steps(container)
    labels = unique(first.(rows))
    pairs = 1:maximum(r[2] for r in rows)
    up = PSI.add_variable_container!(container, TieBreakSlackUp(), EnergyTieBreak; meta = name)
    down = PSI.add_variable_container!(container, TieBreakSlackDown(), EnergyTieBreak; meta = name)
    con = PSI.add_constraints_container!(
        container, TieBreakConstraint(), EnergyTieBreak, labels, pairs, time_steps; sparse = true, meta = name,
    )
    jm = PSI.get_jump_model(container)
    coefficient = PSI.get_base_power(container) *
        interval_cost_coefficient(TIE_BREAK_CVP_FACTOR, PSI.get_resolution(container))
    key(b, decremental) = PSI.ParameterKey(TieBreakScaleParameter, b.type, _tie_break_meta(b.band, decremental))
    for (label, pair, t, decremental, a, b) in rows
        up[label, pair, t] = JuMP.@variable(jm, base_name = "TieBreakSlackUp_{$label,$pair,$t}", lower_bound = 0.0)
        down[label, pair, t] = JuMP.@variable(jm, base_name = "TieBreakSlackDown_{$label,$pair,$t}", lower_bound = 0.0)
        # Unit placeholder coefficients; the scale parameters set both.
        row = JuMP.@constraint(jm, a.var + b.var + up[label, pair, t] - down[label, pair, t] == 0.0)
        con[label, pair, t] = row
        PSI.add_coefficient_target!(container, key(b, decremental), b.name, t, row, a.var, 1.0)
        PSI.add_coefficient_target!(container, key(a, decremental), a.name, t, row, b.var, -1.0)
        PSI.add_to_objective_invariant_expression!(container, coefficient * (up[label, pair, t] + down[label, pair, t]))
    end
    # Drops the cells of the label x pair x time product that hold no row.
    filter!(cell -> !isnothing(last(cell)), con.data)
    return
end
