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
# (direction, region, time step). Segments PSI pads beyond a unit's offer curve are left out.
function _tie_break_bands(container::PSI.OptimizationContainer, sys::PSY.System)
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
                band <= length(prices) || continue
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


# Throws unless every price-tied band carries its scale series and every device carrying a scale
# series is modeled with market-bid block variables.
function _check_tie_break_series(container::PSI.OptimizationContainer, sys::PSY.System, groups)
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
    for device in PSY.get_available_components(PSY.StaticInjection, sys)
        (typeof(device), PSY.get_name(device)) in modeled && continue
        any(k -> startswith(IS.get_name(k), "tie_break_scale_"), IS.get_time_series_keys(device)) &&
            push!(unmodeled, PSY.get_name(device))
    end
    isempty(unmodeled) || throw(
        ArgumentError(
            "tie-break: $(length(unmodeled)) unit(s) carry tie-break scales but have no market-bid variables in the model: " *
                "$(join(sort!(unmodeled), ", ")). Their bands set the widest band of a tie group; model them or drop :tie_breaks.",
        ),
    )
    return
end


"""
    add_tie_break_constraints!(container, sys)

Dispatches price-tied energy bands in proportion to their size. Within each region, direction
(offer or load bid) and time step, bands whose prices at the reference node are within
[`TIE_BREAK_CVP_FACTOR`](@ref) of one another form a tie group. Every pair of bands of different
units in a group gets the row `s_b x_a - s_a x_b + up - down = 0`, where `x` is the cleared MW of a
band and `s = w / w_ref` its [`TieBreakScaleParameter`](@ref), `w` being its width and `w_ref` the
widest band of the group at that interval, so the slack is in system-base per-unit MW. The slacks are
priced at [`TIE_BREAK_CVP_FACTOR`](@ref) `\$/MWh`. A band held back by a ramp, availability or group
limit relaxes its rows instead of moving the dispatch of the other units: the penalty slope in each
band's MW depends only on the other band's width, so the split among the remaining bands is set by
their own rows and is proportional to band MW. A band of zero width has scale 0, which makes its rows
vacuous. FCAS bands are not tied. Groups are read from the offer prices at build, and the scales
are updated by simulation steps, so a recurrent build requires the same groups at every step
([`check_tie_break_pairs`](@ref)). Must run after every device model's objective; throws unless
[`set_tie_break_scales!`](@ref) covered exactly the modeled units.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` holding the built bid variables.
- `sys`: the `PowerSystems.System` the container was built from.

# Returns
The number of pairs added, as an `Int`.
"""
function add_tie_break_constraints!(container::PSI.OptimizationContainer, sys::PSY.System)
    jm = PSI.get_jump_model(container)
    coefficient = PSI.get_base_power(container) *
        interval_cost_coefficient(TIE_BREAK_CVP_FACTOR, PSI.get_resolution(container))
    groups = _tie_break_bands(container, sys)
    _check_tie_break_series(container, sys, groups)
    key(b, decremental) = PSI.ParameterKey(TieBreakScaleParameter, b.type, _tie_break_meta(b.band, decremental))
    links = 0
    for (decremental, region, t) in sort!(collect(keys(groups)))
        bands = groups[(decremental, region, t)]
        for group in _tie_groups(bands)
            foreach(i -> _add_tie_break_parameter!(container, bands[i].type, sys, decremental, bands[i].band), group)
            for i in 1:(length(group) - 1), j in (i + 1):length(group)
                a, b = bands[group[i]], bands[group[j]]
                a.name == b.name && continue
                up = JuMP.@variable(jm, base_name = "TieBreakSlackUp_{$region,$t,$links}", lower_bound = 0.0)
                down = JuMP.@variable(jm, base_name = "TieBreakSlackDown_{$region,$t,$links}", lower_bound = 0.0)
                # Unit placeholder coefficients; the scale parameters set both.
                row = JuMP.@constraint(jm, a.var + b.var + up - down == 0.0)
                PSI.add_coefficient_target!(container, key(b, decremental), b.name, t, row, a.var, 1.0)
                PSI.add_coefficient_target!(container, key(a, decremental), a.name, t, row, b.var, -1.0)
                PSI.add_to_objective_invariant_expression!(container, coefficient * (up + down))
                links += 1
            end
        end
    end
    return links
end
