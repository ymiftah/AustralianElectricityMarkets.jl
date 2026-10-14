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
