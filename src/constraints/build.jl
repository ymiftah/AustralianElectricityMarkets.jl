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
constraint also gets an `"rhs"` `Deterministic` time series spanning every
dispatch interval any constraint was invoked at in `date_range`, replaying
`DISPATCHCONSTRAINT.RHS` where this `GENCONID` was actually invoked and carrying the last
known value forward elsewhere (a constraint's own coverage can be shorter than another's — it
stopped or started applying partway through the range — and a short series would fail PSY's
cross-component time-series horizon check). A companion `"invoked"` `Deterministic` series
(`1.0`/`0.0`) is the authoritative record of which intervals were real: **do not** treat a
carried-forward `"rhs"` value as enforced without checking it. `include_solution = true`
additionally attaches `"lhs"` (same carry-forward) and `"marginal_value"` (`0.0`, not
carried forward, at any interval `"invoked"` is `0.0` — a constraint not in force has no
shadow price, by definition) — both validation-only, since feeding a solved `MARGINALVALUE`
back into a dispatch simulation is the same category error as using `RRP` as an LP input.

`resolution` sets the declared `resolution`/`interval` of every attached `Deterministic`. When
`nothing` (the default) it is inferred from `full_grid` via [`_infer_resolution`](@ref): the
spacing between consecutive grid points, or `Minute(5)` if the grid has fewer than 2 points.
An irregular grid (unequal spacings) warns and falls back to the smallest spacing found rather
than throwing, since real caches can be gappy. Passing `resolution` explicitly skips inference
and validation — the caller is asserting it themselves.

Returns `(added, skipped)`: `added::Vector{String}` of `GENCONID`s successfully added, and
`skipped::Dict{String, Symbol}` mapping a skipped `GENCONID` to one reason — `:no_definition`
(no matching `GENCONDATA` version), `:no_terms` (no `SPD*` rows for its version),
`:unknown_duid`/`:unknown_region`/`:unknown_interconnector` (a term referenced a component
`sys` doesn't have), or `:no_region_devices` (a `RegionTerm`'s region has no matching
`Generator`/`Storage` unit in `sys`). Skips are reported as one summary `@warn`, not one per
constraint.

Throws an `ArgumentError` when `DISPATCHCONSTRAINT` isn't cached at all. If it *is* cached but
genuinely has no rows in `date_range`, that is a real answer, not a missing-data problem.
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

    data = _read_constraint_data(db, date_range, resolution; intervention = intervention)
    if DataFrames.isempty(data.invoked)
        @warn "No constraints invoked over $date_range; nothing added."
        return String[], Dict{String, Symbol}()
    end

    added, contributing_devices, skipped = _resolve_constraints(
        sys, data.definitions, data.invoked, data.terms_long, data.reqs_long,
    )

    _attach_services!(sys, added, contributing_devices)
    _attach_time_series!(
        sys, added, data.invoked, data.full_grid, data.resolution, start_date;
        include_solution = include_solution,
    )

    if !isempty(skipped)
        reason_counts = Dict{Symbol, Int}()
        for reason in values(skipped)
            reason_counts[reason] = get(reason_counts, reason, 0) + 1
        end
        @warn "add_nem_constraints!: skipped $(length(skipped)) of $(length(unique(data.invoked.GENCONID))) invoked constraints" reason_counts
    end

    return [gc.name for gc in added], skipped
end

"""
    _read_constraint_data(db, date_range, resolution; intervention = 0) -> NamedTuple

Reads every table [`add_nem_constraints!`](@ref) needs: `invoked` (`DISPATCHCONSTRAINT`,
[`read_invoked_constraints`](@ref)), and — only when `invoked` is non-empty, since
[`read_constraint_definitions`](@ref)/[`read_constraint_terms`](@ref) throw on an empty
version set — `definitions`, `terms_long`, and `reqs_long`. Also computes `full_grid` (every
interval any constraint was invoked at) and infers `resolution` from it via
[`_infer_resolution`](@ref) when the caller passed `nothing`.

Returns `(; invoked, definitions, terms_long, reqs_long, full_grid, resolution)`. Callers must
check `isempty(invoked)` before using the other fields, which come back as empty placeholders
in that case.
"""
function _read_constraint_data(db, date_range, resolution::Union{Nothing, Dates.Period}; intervention::Integer = 0)
    invoked = read_invoked_constraints(db, date_range; intervention = intervention)
    if DataFrames.isempty(invoked)
        return (;
            invoked = invoked,
            definitions = DataFrame(),
            terms_long = DataFrame(),
            reqs_long = DataFrame(),
            full_grid = DateTime[],
            resolution = resolution,
        )
    end

    # Every interval any constraint was invoked at — not just one constraint's own rows, since
    # no single GENCONID's coverage reliably represents "every interval NEMDE dispatched" (see
    # add_nem_constraints! docstring).
    full_grid = sort(unique(invoked.SETTLEMENTDATE))
    resolution = isnothing(resolution) ? _infer_resolution(full_grid) : resolution

    definitions = read_constraint_definitions(db, invoked)
    terms_long = read_constraint_terms(db, invoked, date_range)
    reqs_long = read_constraint_fcas_requirements(db, date_range; intervention = intervention)

    return (;
        invoked = invoked, definitions = definitions, terms_long = terms_long,
        reqs_long = reqs_long, full_grid = full_grid, resolution = resolution,
    )
end

"""
    _resolve_constraints(sys, definitions, invoked, terms_long, reqs_long) -> (added, contributing_devices, skipped)

For each `GENCONID` invoked, resolves its `SPD*` term rows against components already in
`sys` and, if every term resolves, builds a [`GenericConstraint`](@ref) — see
[`add_nem_constraints!`](@ref) for the exact skip conditions. Time series are *not* attached
here (see [`_attach_time_series!`](@ref)); the constraint's static `rhs` field is set from only
that constraint's own first invoked `RHS` row, not the full padded grid.

Returns `added::Vector{GenericConstraint}`, `contributing_devices::Dict{String, Vector{Device}}`
(each added constraint's name mapped to its resolved devices, for
[`_attach_services!`](@ref)), and `skipped::Dict{String, Symbol}`.
"""
function _resolve_constraints(sys, definitions, invoked, terms_long, reqs_long)
    # A Dict of DataFrameRow, not groupby: exactly one GENCONDATA row is expected per GENCONID
    # here (the exact-version join in read_constraint_definitions), and a DataFrameRow gives
    # scalar field access (def.CONSTRAINTVALUE etc.) where a group's SubDataFrame would not.
    def_by_id = Dict(row.GENCONID => row for row in eachrow(definitions))
    invoked_by_id = groupby(invoked, :GENCONID)
    req_by_id = groupby(reqs_long, :GENCONID)
    terms_by_id = groupby(terms_long, :GENCONID)

    added = GenericConstraint[]
    contributing_devices = Dict{String, Vector{Device}}()
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
        devices = Device[]
        skip_reason = nothing
        for row in eachrow(term_rows)
            if row.TERM_KIND == "UNIT"
                device = get_component(Device, sys, row.KEY)
                if isnothing(device)
                    skip_reason = :unknown_duid
                    break
                end
                push!(resolved_terms, UnitTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR))
                push!(devices, device)
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
                append!(devices, region_devices)
            else
                device = get_component(AreaInterchange, sys, row.KEY)
                if isnothing(device)
                    skip_reason = :unknown_interconnector
                    break
                end
                push!(resolved_terms, InterconnectorTerm(row.KEY, row.FACTOR))
                push!(devices, device)
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

        first_rhs = first(sort(invoked_by_id[(gencon_id,)], :SETTLEMENTDATE).RHS)

        gc = GenericConstraint(;
            name = gencon_id,
            sense = sense,
            rhs = coalesce(def.CONSTRAINTVALUE, first_rhs),
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
        push!(added, gc)
        contributing_devices[gencon_id] = unique(devices)
    end

    return added, contributing_devices, skipped
end

"""
    _attach_services!(sys, added, contributing_devices)

Attaches each [`GenericConstraint`](@ref) in `added` to `sys` as a `Service` via
`add_service!`, using the devices [`_resolve_constraints`](@ref) resolved for it.
"""
function _attach_services!(sys, added::Vector{GenericConstraint}, contributing_devices::Dict{String, Vector{Device}})
    for gc in added
        add_service!(sys, gc, contributing_devices[gc.name])
    end
    return nothing
end

"""
    _attach_time_series!(sys, added, invoked, full_grid, resolution, start_date; include_solution)

Attaches each [`GenericConstraint`](@ref) in `added` an `"rhs"` and `"invoked"` `Deterministic`
time series over `full_grid` (see [`add_nem_constraints!`](@ref) for their semantics), padded
via [`_pad_to_grid`](@ref) with the constraint's own static `rhs` as the fill value. When
`include_solution`, also attaches `"lhs"` (same padding) and `"marginal_value"` (`0.0`,
not carried forward, wherever `"invoked"` is `0.0`).
"""
function _attach_time_series!(
        sys, added::Vector{GenericConstraint}, invoked, full_grid::Vector{DateTime},
        resolution::Dates.Period, start_date; include_solution::Bool,
    )
    invoked_by_id = groupby(invoked, :GENCONID)
    for gc in added
        constraint_rows = sort(invoked_by_id[(gc.name,)], :SETTLEMENTDATE)
        rhs_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.RHS))
        rhs_series, invoked_series = _pad_to_grid(rhs_by_time, full_grid, gc.rhs)

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
    end
    return nothing
end
