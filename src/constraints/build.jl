"""
    _pad_to_grid(values_by_time, grid, initial_fill) -> (series, invoked_mask)

Reindexes a `SETTLEMENTDATE -> Float64` mapping onto `grid` (sorted, one entry per dispatch
interval NEMDE actually solved somewhere in the requested range — see [`add_nem_constraints!`](@ref)).
A gap — an interval this `GENCONID` wasn't invoked at, e.g. its constraint set applied only
partway through the range — carries the last known value forward rather than an invented
sentinel; `invoked_mask` (`1.0`/`0.0`) is the authoritative per-interval signal for whether the
value at that position was actually enforced, since the carried-forward value itself is not.
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

Infers the sampling resolution of a sorted, deduplicated grid of timestamps as the spacing
between consecutive points, canonicalized to `Minute`/`Second` where it divides evenly
(see [`_canonical_period`](@ref)). Fewer than 2 points carries no spacing information and
falls back to `Minute(5)`. Unequal spacings mean the grid has gaps a single fixed resolution
cannot represent exactly; this warns naming the distinct spacings found and proceeds using
the smallest one, rather than throwing.
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

Every `Generator`/`Storage` unit in `sys` whose bus's area is named `region` — the
[`GenericConstraint`](@ref) `Service` machinery's contributing-device set for a `RegionTerm`
(see the "GenericConstraint as a service" design; a `PowerSimulations.jl` extension further
restricts this to a term's `bid_type` at LHS-assembly time).
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

Adds one [`GenericConstraint`](@ref) per constraint invoked in `date_range`
(`DISPATCHCONSTRAINT` membership) whose LHS terms all resolve against components already in
`sys` — a constraint with any unresolvable term is skipped entirely, never added with a
partial LHS. `GenericConstraint` is a `PSY.Service`, so each added constraint is attached via
`add_service!` with its contributing devices: a `UnitTerm`/`InterconnectorTerm`'s single named
device, or (Ruling R8) a `RegionTerm`'s every `Generator`/`Storage` unit in that region (see
[`_region_devices`](@ref)) — a region with no matching unit skips the whole constraint
(`:no_region_devices`), the same as an unresolvable `UnitTerm`/`InterconnectorTerm`. Each added
constraint also gets an `"rhs"` `Deterministic` time series spanning every interval in
`date_range` itself (not merely the intervals this or any other `GENCONID` happened to be
invoked at), replaying `DISPATCHCONSTRAINT.RHS` where this `GENCONID` was actually invoked and
carrying the last known value forward elsewhere (a constraint's own coverage can be shorter than
`date_range` — it stopped or started applying partway through the range, or simply wasn't bound
at every interval — and a series shorter than `date_range` would fail `PowerSystems.jl`'s
cross-component time-series horizon check the moment it's combined with another time series -
`set_demand!`'s, say - that does span the full range). A companion `"invoked"` `Deterministic`
series (`1.0`/`0.0`) is the authoritative record of which intervals were real: **do not** treat a
carried-forward `"rhs"` value as enforced without checking it. `include_solution = true`
additionally attaches `"lhs"` (same carry-forward) and `"marginal_value"` (`0.0`, not
carried forward, at any interval `"invoked"` is `0.0` — a constraint not in force has no
shadow price, by definition) — both validation-only, since feeding a solved `MARGINALVALUE`
back into a dispatch simulation is the same category error as using `RRP` as an LP input.

`resolution` sets the declared `resolution`/`interval` of every attached `Deterministic`. When
`nothing` (the default) it is inferred from `date_range` via [`_infer_resolution`](@ref): the
spacing between consecutive points. Passing `resolution` explicitly skips inference — the caller
is asserting it themselves.

Returns `(added, skipped)`: `added::Vector{String}` of `GENCONID`s successfully added, and
`skipped::Dict{String, Symbol}` mapping a skipped `GENCONID` to one reason — `:no_definition`
(no matching `GENCONDATA` version), `:no_terms` (no `SPD*` rows for its version),
`:unknown_duid`/`:unknown_region`/`:unknown_interconnector` (a term referenced a component
`sys` doesn't have), or `:no_region_devices` (a `RegionTerm`'s region has no matching
`Generator`/`Storage` unit in `sys`). Skips are reported as one summary `@warn`, not one per
constraint.

Throws an `ArgumentError` when `DISPATCHCONSTRAINT` isn't cached at all. If it *is* cached but
genuinely has no rows in `date_range`, that is a real answer, not a missing-data problem — this
warns and returns `(String[], Dict{String, Symbol}())` rather than throwing.
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

    # The caller's own requested range, not `unique(invoked.SETTLEMENTDATE)`: a GENCONID's rows
    # only cover the intervals it was actually invoked at, so deriving the grid from whichever
    # intervals *any* constraint happened to be invoked at silently shrinks it the moment real
    # data has a gap NEMDE genuinely dispatched through with nothing bound — every constraint's
    # series must span exactly what the caller asked for so it matches every other time series
    # attached to the same `System` (e.g. `set_demand!`'s), or `PowerSystems.jl`'s cross-
    # component horizon check rejects the mismatch outright (confirmed empirically: a real
    # historical hour with a sparser subset of intervals actually invoked produced a shorter
    # `GenericConstraint` series than `set_demand!`'s, and `transform_single_time_series!` then
    # raised `ConflictingInputsError` complaining the two didn't agree). Drop the last point:
    # `date_range`'s N+1 grid points label N interval *starts*, matching `read_fcas_bids`/
    # `set_demand!`'s own half-open (`start <= x < stop`) convention — keeping all N+1 points
    # produces a series one row longer than theirs and the same conflicting-horizon error from
    # the opposite direction (confirmed empirically against `test/fcas.jl`'s own fixture).
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
                "dynamic_rhs" => def.DYNAMICRHS,
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
