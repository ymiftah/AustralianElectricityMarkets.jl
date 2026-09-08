"""
    _pad_to_grid(values_by_time, grid, initial_fill) -> (series, invoked_mask)

Reindexes a `SETTLEMENTDATE -> Float64` mapping onto `grid`, carrying the last known value
forward across gaps.

# Arguments
- `values_by_time`: known values, keyed by timestamp.
- `grid`: sorted timestamps to reindex onto.
- `initial_fill`: value used before the first known one.

# Returns
`(series, invoked_mask)`, both `Vector{Float64}` of `length(grid)`. `invoked_mask` is `1.0`
where `grid`'s timestamp was present in `values_by_time` and `0.0` where the value was carried
forward.
"""
function _pad_to_grid(values_by_time::Dict, grid::Vector{DateTime}, initial_fill::Float64)
    series = Vector{Float64}(undef, length(grid))
    mask = Vector{Float64}(undef, length(grid))
    last_value = initial_fill
    for (i, t) in enumerate(grid)
        if haskey(values_by_time, t)
            last_value = values_by_time[t]
            mask[i] = 1.0
        else
            mask[i] = 0.0
        end
        series[i] = last_value
    end
    return series, mask
end

"""
    _infer_resolution(grid) -> Dates.Period

The spacing between consecutive points of a sorted grid, canonicalized by
[`_canonical_period`](@ref).

# Arguments
- `grid`: sorted, deduplicated timestamps.

# Returns
A `Dates.Period`. Falls back to `Minute(5)` for fewer than 2 points; warns and uses the
smallest spacing if spacings are unequal.
"""
function _infer_resolution(grid::Vector{DateTime})
    length(grid) < 2 && return Minute(5)
    distinct = sort(unique(diff(grid)))
    if length(distinct) > 1
        @warn "add_nem_constraints!: grid spacing is not uniform (found $(join(distinct, ", "))); the stored series' fixed resolution will not match every SETTLEMENTDATE. Proceeding with the smallest spacing, $(first(distinct))."
    end
    return _canonical_period(first(distinct))
end

"""
    _canonical_period(ms::Millisecond) -> Dates.Period

Converts a `Millisecond` period to `Minute` or `Second` where it divides evenly, so a stored
time series' resolution reads naturally (e.g. `Minute(5)`) rather than as raw milliseconds.
"""
function _canonical_period(ms::Millisecond)
    if ms.value % 60_000 == 0
        return Minute(ms.value ÷ 60_000)
    elseif ms.value % 1000 == 0
        return Second(ms.value ÷ 1000)
    else
        return ms
    end
end

"""
    _region_devices(sys, region) -> Vector{Device}

A [`RegionTerm`](@ref)'s contributing devices.

# Arguments
- `sys`: the `System` to search.
- `region`: an `Area` name.

# Returns
`Vector{Device}` of every `Generator`/`Storage` in `sys` whose bus's area is named `region`.
"""
function _region_devices(sys, region::AbstractString)
    devices = Device[]
    for d in Iterators.flatten((get_components(Generator, sys), get_components(Storage, sys)))
        get_name(get_area(get_bus(d))) == region && push!(devices, d)
    end
    return devices
end

"""
    add_nem_constraints!(sys, db, date_range; intervention = 0, include_solution = false, resolution = nothing)

Adds one [`GenericConstraint`](@ref) per constraint invoked in `date_range`, attaching each via
`add_service!` to its contributing devices. A constraint with any unresolvable term is skipped
whole, never added with a partial LHS.

Each added constraint carries an `"rhs"` `Deterministic` series replaying
`DISPATCHCONSTRAINT.RHS` over `date_range`, carried forward where the constraint was not
invoked, and an `"invoked"` series (`1.0`/`0.0`) recording which intervals were real. Do not
treat a carried-forward `"rhs"` value as enforced without checking `"invoked"`.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `intervention`: `DISPATCHCONSTRAINT.INTERVENTION` to read (default `0`, the normal run).
- `include_solution`: also attach `"lhs"` and `"marginal_value"`. Validation only — a solved
  `MARGINALVALUE` is not a dispatch input.
- `resolution`: declared resolution of every attached series. Inferred from `date_range` when
  `nothing`.

# Returns
`(added, skipped)`. `added::Vector{String}` names the constraints added.
`skipped::Dict{String, Symbol}` maps a skipped `GENCONID` to one reason: `:no_definition`,
`:no_terms`, `:unknown_duid`, `:unknown_region`, `:unknown_interconnector`, or
`:no_region_devices`. Skips are reported as one summary `@warn`.

Throws `ArgumentError` when `DISPATCHCONSTRAINT` is not cached. A cached table with no rows in
`date_range` warns and returns empties.
"""
function add_nem_constraints!(
        sys, db, date_range; intervention::Integer = 0, include_solution::Bool = false,
        resolution::Union{Nothing, Dates.Period} = nothing,
    )
    start_date = first(date_range)

    _table_is_cached(db, :DISPATCHCONSTRAINT) || throw(
        ArgumentError(
            "DISPATCHCONSTRAINT is not cached for $date_range — run " *
                "`populate(db, :DISPATCHCONSTRAINT, <from>, <to>)` first.",
        ),
    )

    invoked = read_invoked_constraints(db, date_range; intervention = intervention)
    if DataFrames.isempty(invoked)
        @warn "No constraints invoked over $date_range; nothing added."
        return String[], Dict{String, Symbol}()
    end
    invoked_by_id = groupby(invoked, :GENCONID)

    # Drop the last point: `date_range`'s N+1 timestamps label N interval starts, matching
    # `read_fcas_bids`/`set_demand!`'s half-open convention.
    full_grid = collect(date_range)[1:(end - 1)]
    resolution = isnothing(resolution) ? _infer_resolution(full_grid) : resolution

    gencon_versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    definitions = read_constraint_definitions(db, gencon_versions)
    def_by_id = Dict(row.GENCONID => row for row in eachrow(definitions))

    terms_long = read_constraint_terms(db, gencon_versions, date_range)
    terms_by_id = groupby(terms_long, :GENCONID)

    reqs_long = read_constraint_fcas_requirements(db, date_range; intervention = intervention)
    req_by_id = groupby(reqs_long, :GENCONID)

    added = String[]
    skipped = Dict{String, Symbol}()

    for gencon_id in unique(invoked.GENCONID)
        if !haskey(def_by_id, gencon_id)
            skipped[gencon_id] = :no_definition
            continue
        end
        if !haskey(terms_by_id, (gencon_id,))
            skipped[gencon_id] = :no_terms
            continue
        end
        def = def_by_id[gencon_id]
        term_rows = terms_by_id[(gencon_id,)]

        resolved_terms = ConstraintTerm[]
        contributing_devices = Device[]
        skip_reason = nothing
        for row in eachrow(term_rows)
            if row.TERM_KIND == "UNIT"
                device = get_component(Device, sys, row.KEY)
                if isnothing(device)
                    skip_reason = :unknown_duid
                    break
                end
                push!(resolved_terms, UnitTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR))
                push!(contributing_devices, device)
            elseif row.TERM_KIND == "REGION"
                if isnothing(get_component(Area, sys, row.KEY))
                    skip_reason = :unknown_region
                    break
                end
                region_devices = _region_devices(sys, row.KEY)
                if isempty(region_devices)
                    skip_reason = :no_region_devices
                    break
                end
                push!(resolved_terms, RegionTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR))
                append!(contributing_devices, region_devices)
            else
                device = get_component(AreaInterchange, sys, row.KEY)
                if isnothing(device)
                    skip_reason = :unknown_interconnector
                    break
                end
                push!(resolved_terms, InterconnectorTerm(row.KEY, row.FACTOR))
                push!(contributing_devices, device)
            end
        end
        if !isnothing(skip_reason)
            skipped[gencon_id] = skip_reason
            continue
        end

        sense = def.CONSTRAINTTYPE == "<=" ? ConstraintSense.LE :
            def.CONSTRAINTTYPE == ">=" ? ConstraintSense.GE : ConstraintSense.EQ

        reqs = haskey(req_by_id, (gencon_id,)) ?
            [FCASRequirement(r.REGIONID, r.BIDTYPE) for r in eachrow(req_by_id[(gencon_id,)])] :
            FCASRequirement[]

        constraint_rows = sort(invoked_by_id[(gencon_id,)], :SETTLEMENTDATE)
        rhs_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.RHS))
        rhs_series, invoked_series = _pad_to_grid(
            rhs_by_time, full_grid, coalesce(def.CONSTRAINTVALUE, first(constraint_rows.RHS)),
        )

        gc = GenericConstraint(;
            name = gencon_id,
            sense = sense,
            rhs = coalesce(def.CONSTRAINTVALUE, first(rhs_series)),
            constraint_weight = coalesce(def.GENERICCONSTRAINTWEIGHT, 1.0),
            terms = resolved_terms,
            fcas_requirements = reqs,
            ext = Dict{String, Any}(
                "description" => def.DESCRIPTION,
                "limit_type" => def.LIMITTYPE,
                "source" => def.SOURCE,
                "effective_date" => string(def.EFFECTIVEDATE),
                "version_no" => def.VERSIONNO,
            ),
        )
        add_service!(sys, gc, unique(contributing_devices))

        add_time_series!(
            sys, gc,
            Deterministic(; name = "rhs", data = Dict(start_date => rhs_series), resolution = resolution, interval = resolution),
        )
        add_time_series!(
            sys, gc,
            Deterministic(; name = "invoked", data = Dict(start_date => invoked_series), resolution = resolution, interval = resolution),
        )
        if include_solution
            lhs_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.LHS))
            lhs_series, _ = _pad_to_grid(lhs_by_time, full_grid, first(constraint_rows.LHS))
            mv_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.MARGINALVALUE))
            # Not carried forward like rhs/lhs: an interval this constraint wasn't invoked at
            # genuinely has zero shadow price, so 0.0 is a fact here, not a filler value.
            marginal_value_series = [get(mv_by_time, t, 0.0) for t in full_grid]

            add_time_series!(
                sys, gc,
                Deterministic(; name = "lhs", data = Dict(start_date => lhs_series), resolution = resolution, interval = resolution),
            )
            add_time_series!(
                sys, gc,
                Deterministic(; name = "marginal_value", data = Dict(start_date => marginal_value_series), resolution = resolution, interval = resolution),
            )
        end

        push!(added, gencon_id)
    end

    if !isempty(skipped)
        reason_counts = Dict{Symbol, Int}()
        for reason in values(skipped)
            reason_counts[reason] = get(reason_counts, reason, 0) + 1
        end
        @warn "add_nem_constraints!: skipped $(length(skipped)) of $(length(unique(invoked.GENCONID))) invoked constraints" reason_counts
    end

    return added, skipped
end
