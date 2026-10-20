"""
    attach_interconnector_losses!(sys, db, as_of) -> (added, skipped)

Attaches each `PSY.AreaInterchange` already in `sys` its [`InterconnectorLossModel`](@ref) from
[`interconnector_loss_models`](@ref), as of `as_of`, per-unitized to `sys`'s base power.

# Arguments
- `sys`: the `System` to attach to.
- `db`: the database connection.
- `as_of`: `Date` or `DateTime` passed through to [`interconnector_loss_models`](@ref).

# Returns
`(added, skipped)`: `added::Vector{String}` of interconnector names attached, `skipped::Dict{
String, Symbol}` mapping a skipped name to `:no_loss_model`.
"""
function attach_interconnector_losses!(sys, db, as_of::Union{Date, DateTime})
    models = interconnector_loss_models(db, as_of)
    base_power = PSY.get_base_power(sys)

    added = String[]
    skipped = Dict{String, Symbol}()
    for area_interchange in get_components(PSY.AreaInterchange, sys)
        name = PSY.get_name(area_interchange)
        model = get(models, name, nothing)
        if isnothing(model)
            skipped[name] = :no_loss_model
            continue
        end
        # SupplementalAttribute is never stamped with units_info, so unlike GenericConstraint
        # this per-unitizes once here rather than converting on every read.
        PSY.add_supplemental_attribute!(sys, area_interchange, _to_pu(model, base_power))
        push!(added, name)
    end

    if !isempty(skipped)
        @warn "attach_interconnector_losses!: skipped $(length(skipped)) of $(length(added) + length(skipped)) interconnector(s) with no resolvable loss model" skipped
    end

    return added, skipped
end


"""
    set_interconnector_flow_limits!(sys, db, date_range; kwargs...)

Attaches the per-interval flow limits of [`read_interconnector_limits`](@ref) to every
`PSY.AreaInterchange` in `sys` as the `"from_to_flow_limit"` and `"to_from_flow_limit"`
`SingleTimeSeries` that `NEMInterconnectorLoss` reads: the flow is bounded below by `IMPORTLIMIT`
and above by `EXPORTLIMIT`. Each series is the limit as a fraction of the interchange's static
flow limit. The lower bound is the smaller of the two limits and the upper bound the larger,
each clamped into the static envelope `[-MAXMWIN, MAXMWOUT]`. An interval with no published row
or a `missing` limit keeps the static limit, and one `@warn` counts them.

The published limits are computed after NEMDE's solve (each binding constraint's right-hand side
projected with the other terms held at the solved values), so bounding flow by them pins it to
NEMDE's answer. Use them as a diagnostic, not when validating flows.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `kwargs`: passed to [`read_interconnector_limits`](@ref) (e.g. `intervention`).

# Returns
`nothing`.
"""
function set_interconnector_flow_limits!(sys, db, date_range; kwargs...)
    full_grid = collect(date_range)[1:(end - 1)]
    rows = read_interconnector_limits(db, date_range; kwargs...)
    by_ic = Dict(
        key.INTERCONNECTORID => Dict(r.SETTLEMENTDATE => r for r in eachrow(g)) for
            (key, g) in pairs(groupby(rows, :INTERCONNECTORID))
    )

    # Fraction of the static limit `static`; 1.0 keeps the static limit.
    ratio(limit, static) = static > 0 ? limit / static : 1.0
    fallbacks = String[]
    series = Dict{String, NTuple{2, Vector{Float64}}}()
    for d in get_components(AreaInterchange, sys)
        name = get_name(d)
        limits = with_units_base(() -> get_flow_limits(d), sys, "NATURAL_UNITS")
        from_to = ones(length(full_grid))
        to_from = ones(length(full_grid))
        for (k, t) in enumerate(full_grid)
            row = get(get(by_ic, name, Dict{DateTime, Any}()), t, nothing)
            if isnothing(row) || ismissing(row.EXPORTLIMIT) || ismissing(row.IMPORTLIMIT)
                push!(fallbacks, "$name@$t")
                continue
            end
            # Signed bounds, ordered and clamped into the static envelope [-MAXMWIN, MAXMWOUT].
            lower = clamp(min(row.IMPORTLIMIT, row.EXPORTLIMIT), -limits.from_to, limits.to_from)
            upper = clamp(max(row.IMPORTLIMIT, row.EXPORTLIMIT), -limits.from_to, limits.to_from)
            from_to[k] = ratio(-lower, limits.from_to)
            to_from[k] = ratio(upper, limits.to_from)
        end
        series[name] = (from_to, to_from)
    end
    isempty(fallbacks) ||
        @warn "set_interconnector_flow_limits!: $(length(fallbacks)) interconnector interval(s) kept the static flow limit (no usable published limits)" first_fallbacks = first(fallbacks, 5)

    for d in get_components(AreaInterchange, sys)
        from_to, to_from = series[get_name(d)]
        add_time_series!(sys, d, SingleTimeSeries(; name = "from_to_flow_limit", data = TimeArray(full_grid, from_to)))
        add_time_series!(sys, d, SingleTimeSeries(; name = "to_from_flow_limit", data = TimeArray(full_grid, to_from)))
    end
    return
end


"Name of the series [`set_loss_demand_coefficients!`](@ref) attaches."
const _LOSS_DEMAND_COEFFICIENT = "loss_demand_coefficient"


"""
    set_loss_demand_coefficients!(sys)

Attaches to each `PSY.AreaInterchange` carrying exactly one [`InterconnectorLossModel`](@ref) a
`SingleTimeSeries` `"loss_demand_coefficient"`: at each interval, the demand term of its
[`loss_factor`](@ref), `Σ_r demand_coefficients[r] × demand[r]`. `demand[r]` is the summed demand of
the available `PowerLoad`s in area `r`, per-unit of the system base, from each load's
`"loss_demand"` series set by [`set_demand!`](@ref). The series sits on the timestamps of those
series and replaces an existing one. Call it after `set_demand!` and after any change to the loads or loss models, before
`transform_single_time_series!`.

# Arguments
- `sys`: the `System` to add to.

# Returns
`nothing`. Throws `ArgumentError` when the system has no available load, when an available load is
on a bus with no area or has no `"loss_demand"` series, or when two loads' series have different
timestamps.
"""
function set_loss_demand_coefficients!(sys)
    stamps, resolution, demand = _area_loss_demand(sys)
    for ic in get_components(AreaInterchange, sys)
        models = PSY.get_supplemental_attributes(InterconnectorLossModel, ic)
        length(models) == 1 || continue
        model = only(models)
        values = [_demand_offset(model, Dict(area => series[t] for (area, series) in demand)) for t in eachindex(stamps)]
        has_time_series(ic, SingleTimeSeries, _LOSS_DEMAND_COEFFICIENT) &&
            remove_time_series!(sys, SingleTimeSeries, ic, _LOSS_DEMAND_COEFFICIENT)
        add_time_series!(sys, ic, _single_series(_LOSS_DEMAND_COEFFICIENT, first(stamps), values, resolution))
    end
    return
end


"""
    _area_loss_demand(sys) -> (stamps, resolution, demand)

Summed demand of `sys`'s available `PowerLoad`s per area name, per-unit of the system base, on the
timestamps of their demand series, as [`set_loss_demand_coefficients!`](@ref) reads it.
"""
function _area_loss_demand(sys)
    loads = collect(get_components(get_available, PowerLoad, sys))
    for load in loads
        isnothing(get_area(get_bus(load))) && throw(
            ArgumentError(
                "PowerLoad $(get_name(load)) is on a bus with no area; the interconnector loss " *
                    "demand needs every available load assigned to an area",
            ),
        )
    end
    isempty(loads) && throw(ArgumentError("set_loss_demand_coefficients!: the system has no available PowerLoad."))
    for load in loads
        has_time_series(load, SingleTimeSeries, "loss_demand") || throw(
            ArgumentError(
                "set_loss_demand_coefficients!: PowerLoad $(get_name(load)) has no \"loss_demand\" series; " *
                    "call set_demand! after the loads are added and before set_loss_demand_coefficients!",
            ),
        )
    end
    reference = first(loads)
    stamps = PSY.get_time_series_timestamps(SingleTimeSeries, reference, "loss_demand")
    resolution = IS.get_resolution(PSY.get_time_series(SingleTimeSeries, reference, "loss_demand"))
    demand = Dict{String, Vector{Float64}}()
    with_units_base(sys, "SYSTEM_BASE") do
        for load in loads
            PSY.get_time_series_timestamps(SingleTimeSeries, load, "loss_demand") == stamps || throw(
                ArgumentError(
                    "set_loss_demand_coefficients!: PowerLoad $(get_name(load))'s \"loss_demand\" series is not on " *
                        "the timestamps of $(get_name(reference))'s.",
                ),
            )
            total = get!(() -> zeros(Float64, length(stamps)), demand, get_name(get_area(get_bus(load))))
            total .+= get_time_series_values(SingleTimeSeries, load, "loss_demand")
        end
    end
    return stamps, resolution, demand
end
