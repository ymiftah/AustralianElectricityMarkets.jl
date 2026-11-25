# AEMO's `FROMREGIONLOSSSHARE` for Basslink is not well defined; nempy sets it to 1 to best match NEMDE.
const _LOSS_SHARE_OVERRIDES = Dict("T-V-MNSP1" => 1.0)

# Demand coefficients AEMO publishes but MMSDM LOSSFACTORMODEL omits. Used only where the table has
# no value for that pair. V-SA NSW1 for FY2025-26: AEMO, 2025-26 Marginal Loss Factors report,
# section 3 p. 56 and Table 25 p. 59.
const _DEMAND_COEFFICIENT_PATCHES = [
    (
        INTERCONNECTORID = "V-SA", REGIONID = "NSW1", DEMANDCOEFFICIENT = 1.6981e-6,
        valid_from = Date(2025, 7, 1), valid_until = Date(2026, 7, 1),
    ),
]


"""
    interconnector_loss_models(db, as_of) -> Dict{String, InterconnectorLossModel}

Every interconnector's [`InterconnectorLossModel`](@ref), assembled from
[`read_interconnector_loss_parameters`](@ref),
[`read_interconnector_demand_coefficients`](@ref) and
[`read_interconnector_loss_breakpoints`](@ref) as of `as_of`.

An interconnector with no `LOSSMODEL` breakpoints is skipped with one summary `@warn`. The loss share
of `T-V-MNSP1` (Basslink) is fixed at `1.0`. Demand coefficients absent from `LOSSFACTORMODEL` but
published by AEMO (V-SA `NSW1` for FY2025-26) are filled in, never overriding a cached value. Throws
`ArgumentError` when no interconnector remains.
"""
function interconnector_loss_models(db, as_of::Union{Date, DateTime})
    params = read_interconnector_loss_parameters(db; as_of = as_of)
    coefficients = read_interconnector_demand_coefficients(db; as_of = as_of)
    breakpoints = read_interconnector_loss_breakpoints(db; as_of = as_of)

    patches = @chain DataFrame(_DEMAND_COEFFICIENT_PATCHES) begin
        subset(:valid_from => ByRow(<=(Date(as_of))), :valid_until => ByRow(>(Date(as_of))))
        select(:INTERCONNECTORID, :REGIONID, :DEMANDCOEFFICIENT)
        semijoin(coefficients; on = :INTERCONNECTORID)
        antijoin(coefficients; on = [:INTERCONNECTORID, :REGIONID])
    end
    demand_coefficients = @chain vcat(coefficients[:, [:INTERCONNECTORID, :REGIONID, :DEMANDCOEFFICIENT]], patches) begin
        groupby(:INTERCONNECTORID)
        combine([:REGIONID, :DEMANDCOEFFICIENT] => ((r, c) -> Dict{String, Float64}(zip(r, c))) => :demand_coefficients)
    end
    sorted_breakpoints = @chain breakpoints begin
        groupby(:INTERCONNECTORID)
        combine(:MWBREAKPOINT => (b -> Ref(sort(collect(Float64, b)))) => :breakpoints)
    end
    candidates = @chain params begin
        leftjoin(sorted_breakpoints; on = :INTERCONNECTORID)
        leftjoin(demand_coefficients; on = :INTERCONNECTORID)
        transform(
            :breakpoints => ByRow(b -> coalesce(b, Float64[])) => :breakpoints,
            :demand_coefficients => ByRow(d -> coalesce(d, Dict{String, Float64}())) => :demand_coefficients,
        )
    end
    skipped = subset(candidates, :breakpoints => ByRow(b -> length(b) < 2)).INTERCONNECTORID
    models = Dict{String, InterconnectorLossModel}()
    for row in eachrow(subset(candidates, :breakpoints => ByRow(b -> length(b) >= 2)))
        id = row.INTERCONNECTORID
        models[id] = InterconnectorLossModel(;
            interconnector = id,
            from_region = row.REGIONFROM,
            to_region = row.REGIONTO,
            from_region_loss_share = get(_LOSS_SHARE_OVERRIDES, id, coalesce(row.FROMREGIONLOSSSHARE, 0.5)),
            loss_constant = coalesce(row.LOSSCONSTANT, 1.0),
            loss_flow_coefficient = coalesce(row.LOSSFLOWCOEFFICIENT, 0.0),
            demand_coefficients = row.demand_coefficients,
            breakpoints = row.breakpoints,
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

The published limits are computed from NEMDE's solution, so they are a diagnostic and must not be
used to validate simulated flows. A repeat call replaces the earlier limits.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to run.
- `kwargs`: passed to [`read_interconnector_limits`](@ref) (e.g. `intervention`).

# Returns
`nothing`.
"""
function set_interconnector_flow_limits!(sys, db, date_range; kwargs...)
    grid = DataFrame(SETTLEMENTDATE = collect(date_range)[1:(end - 1)])
    published = read_interconnector_limits(db, date_range; kwargs...)
    isempty(get_components(AreaInterchange, sys)) && return
    devices = DataFrame(
        [
            (
                INTERCONNECTORID = get_name(d), device = d,
                static = with_units_base(() -> get_flow_limits(d), sys, "NATURAL_UNITS"),
            ) for d in get_components(AreaInterchange, sys)
        ]
    )
    # A static limit of zero or less is kept as published, as a fraction of it would be.
    limit_or_static(limit, static) = static > 0 ? limit : static
    # Signed bounds, ordered and clamped into the static envelope [-MAXMWIN, MAXMWOUT].
    function bounds(static, import_limit, export_limit)
        (ismissing(import_limit) || ismissing(export_limit)) && return (static.from_to, static.to_from, true)
        lower = clamp(min(import_limit, export_limit), -static.from_to, static.to_from)
        upper = clamp(max(import_limit, export_limit), -static.from_to, static.to_from)
        return (limit_or_static(-lower, static.from_to), limit_or_static(upper, static.to_from), false)
    end
    limits = @chain crossjoin(devices, grid) begin
        leftjoin(published; on = [:INTERCONNECTORID, :SETTLEMENTDATE])
        transform([:static, :IMPORTLIMIT, :EXPORTLIMIT] => ByRow(bounds) => [:from_to, :to_from, :fallback])
        sort([:INTERCONNECTORID, :SETTLEMENTDATE])
    end
    fallbacks = @. string(limits.INTERCONNECTORID[limits.fallback], "@", limits.SETTLEMENTDATE[limits.fallback])
    isempty(fallbacks) ||
        @warn "set_interconnector_flow_limits!: $(length(fallbacks)) interconnector interval(s) kept the static flow limit (no usable published limits)" first_fallbacks = first(fallbacks, 5)

    for g in groupby(limits, :INTERCONNECTORID)
        d = first(g.device)
        for old in (get_supplemental_attributes(NEMInterconnectorLimits, d)::Vector{NEMInterconnectorLimits})
            remove_supplemental_attribute!(sys, d, old)
        end
        from_to_key = replace_single_series!(
            sys, d, single_series(NEM_INTERCONNECTOR_SERIES.from_to_limit, grid.SETTLEMENTDATE, Float64.(g.from_to)),
        )
        to_from_key = replace_single_series!(
            sys, d, single_series(NEM_INTERCONNECTOR_SERIES.to_from_limit, grid.SETTLEMENTDATE, Float64.(g.to_from)),
        )
        add_supplemental_attribute!(sys, d, NEMInterconnectorLimits(; from_to_limit = from_to_key, to_from_limit = to_from_key))
    end
    return
end
