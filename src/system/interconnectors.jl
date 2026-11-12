# AEMO's `FROMREGIONLOSSSHARE` for Basslink is not well defined; nempy sets it to 1 to best match NEMDE.
const _LOSS_SHARE_OVERRIDES = Dict("T-V-MNSP1" => 1.0)

# Demand coefficients AEMO publishes but MMSDM LOSSFACTORMODEL omits, as
# (interconnector, region) => (value, valid_from, valid_until). Used only where the table has no
# value for that pair. V-SA NSW1 for FY2025-26: AEMO, 2025-26 Marginal Loss Factors report,
# section 3 p. 56 and Table 25 p. 59.
const _DEMAND_COEFFICIENT_PATCHES = Dict(
    ("V-SA", "NSW1") => (value = 1.6981e-6, valid_from = Date(2025, 7, 1), valid_until = Date(2026, 7, 1)),
)

function _apply_demand_coefficient_patches!(demand_coefficients, as_of)
    for ((id, region), p) in _DEMAND_COEFFICIENT_PATCHES
        p.valid_from <= Date(as_of) < p.valid_until || continue
        haskey(demand_coefficients, id) || continue
        get!(demand_coefficients[id], region, p.value)
    end
    return demand_coefficients
end


"""
    interconnector_loss_models(db, as_of) -> Dict{String, InterconnectorLossModel}

Every interconnector's [`InterconnectorLossModel`](@ref), assembled from
[`read_interconnector_loss_parameters`](@ref),
[`read_interconnector_demand_coefficients`](@ref) and
[`read_interconnector_loss_breakpoints`](@ref) as of `as_of`.

An interconnector with loss parameters but no `LOSSMODEL` breakpoints is skipped, reported in
one summary `@warn`.

The loss share of `T-V-MNSP1` (Basslink) is fixed at `1.0`, as in nempy, because AEMO's published
value is not well defined.

Demand coefficients missing from `LOSSFACTORMODEL` but published by AEMO (V-SA `NSW1` for
FY2025-26) are filled in; a value present in the table is never overridden.

Throws `ArgumentError` when no interconnector survives.
"""
function interconnector_loss_models(db, as_of::Union{Date, DateTime})
    params = read_interconnector_loss_parameters(db; as_of = as_of)
    coefficients = read_interconnector_demand_coefficients(db; as_of = as_of)
    breakpoints = read_interconnector_loss_breakpoints(db; as_of = as_of)

    # TODO isn't this a groupby combine as array ?
    by_interconnector = Dict{String, Vector{Float64}}()
    for row in eachrow(breakpoints)
        push!(get!(by_interconnector, row.INTERCONNECTORID, Float64[]), row.MWBREAKPOINT)
    end
    demand_coefficients = Dict{String, Dict{String, Float64}}()
    # TODO isn't this a groupby combine as array ?
    for row in eachrow(coefficients)
        d = get!(demand_coefficients, row.INTERCONNECTORID, Dict{String, Float64}())
        d[row.REGIONID] = row.DEMANDCOEFFICIENT
    end
    _apply_demand_coefficient_patches!(demand_coefficients, as_of)

    models = Dict{String, InterconnectorLossModel}()
    skipped = String[]
    for row in eachrow(params)
        id = row.INTERCONNECTORID
        bps = sort(get(by_interconnector, id, Float64[]))
        if length(bps) < 2
            push!(skipped, id)
            continue
        end
        models[id] = InterconnectorLossModel(;
            interconnector = id,
            from_region = row.REGIONFROM,
            to_region = row.REGIONTO,
            from_region_loss_share = get(_LOSS_SHARE_OVERRIDES, id, coalesce(row.FROMREGIONLOSSSHARE, 0.5)),
            loss_constant = coalesce(row.LOSSCONSTANT, 1.0),
            loss_flow_coefficient = coalesce(row.LOSSFLOWCOEFFICIENT, 0.0),
            demand_coefficients = get(demand_coefficients, id, Dict{String, Float64}()),
            breakpoints = bps,
        )
    end
    isempty(skipped) ||
        @warn "interconnector_loss_models: $(length(skipped)) interconnector(s) have no LOSSMODEL breakpoints as of $as_of; skipped" skipped
    isempty(models) && throw(
        ArgumentError(
            "no interconnector has a complete loss model as of $as_of. Check that " *
                "LOSSMODEL/LOSSFACTORMODEL/INTERCONNECTORCONSTRAINT are cached and that their " *
                "EFFECTIVEDATEs precede $as_of.",
        ),
    )
    return models
end


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
`PSY.AreaInterchange` in `sys` as a [`NEMInterconnectorLimits`](@ref) whose keys are the
`SingleTimeSeries` named by [`NEM_INTERCONNECTOR_SERIES`](@ref), in MW: the flow is bounded below by
`IMPORTLIMIT` and above by `EXPORTLIMIT`. The lower bound is the smaller of the two limits and the upper
bound the larger, each clamped into the static envelope `[-MAXMWIN, MAXMWOUT]`. An interval with no
published row or a `missing` limit keeps the static limit, and one `@warn` counts them.

The published limits are computed after NEMDE's solve (each binding constraint's right-hand side
projected with the other terms held at the solved values), so bounding flow by them pins it to
NEMDE's answer. Use them as a diagnostic, not when validating flows.

A repeat call replaces the earlier limits.

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

    # A static limit of zero or less is kept as published, as a fraction of it would be.
    limit_or_static(limit, static) = static > 0 ? limit : static
    fallbacks = String[]
    series = Dict{String, NTuple{2, Vector{Float64}}}()
    for d in get_components(AreaInterchange, sys)
        name = get_name(d)
        limits = with_units_base(() -> get_flow_limits(d), sys, "NATURAL_UNITS")
        from_to = fill(Float64(limits.from_to), length(full_grid))
        to_from = fill(Float64(limits.to_from), length(full_grid))
        for (k, t) in enumerate(full_grid)
            row = get(get(by_ic, name, Dict{DateTime, Any}()), t, nothing)
            if isnothing(row) || ismissing(row.EXPORTLIMIT) || ismissing(row.IMPORTLIMIT)
                push!(fallbacks, "$name@$t")
                continue
            end
            # Signed bounds, ordered and clamped into the static envelope [-MAXMWIN, MAXMWOUT].
            lower = clamp(min(row.IMPORTLIMIT, row.EXPORTLIMIT), -limits.from_to, limits.to_from)
            upper = clamp(max(row.IMPORTLIMIT, row.EXPORTLIMIT), -limits.from_to, limits.to_from)
            from_to[k] = limit_or_static(-lower, limits.from_to)
            to_from[k] = limit_or_static(upper, limits.to_from)
        end
        series[name] = (from_to, to_from)
    end
    isempty(fallbacks) ||
        @warn "set_interconnector_flow_limits!: $(length(fallbacks)) interconnector interval(s) kept the static flow limit (no usable published limits)" first_fallbacks = first(fallbacks, 5)

    for d in get_components(AreaInterchange, sys)
        from_to, to_from = series[get_name(d)]
        for old in (get_supplemental_attributes(NEMInterconnectorLimits, d)::Vector{NEMInterconnectorLimits})
            remove_supplemental_attribute!(sys, d, old)
        end
        replace_single_series!(sys, d, single_series(NEM_INTERCONNECTOR_SERIES.from_to_limit, full_grid, from_to))
        replace_single_series!(sys, d, single_series(NEM_INTERCONNECTOR_SERIES.to_from_limit, full_grid, to_from))
        add_supplemental_attribute!(
            sys, d,
            NEMInterconnectorLimits(;
                from_to_limit = _series_key(d, NEM_INTERCONNECTOR_SERIES.from_to_limit),
                to_from_limit = _series_key(d, NEM_INTERCONNECTOR_SERIES.to_from_limit),
            ),
        )
    end
    return
end
