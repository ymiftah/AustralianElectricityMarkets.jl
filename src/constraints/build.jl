"""
    add_nem_constraints!(sys, db, date_range; intervention = 0, include_solution = false)

Adds one [`GenericConstraint`](@ref) per constraint invoked in `date_range`
(`DISPATCHCONSTRAINT` membership) whose LHS terms all resolve against components already in
`sys` — a constraint with any unresolvable term is skipped entirely, never added with a
partial LHS. Each added constraint gets an `"rhs"` `Deterministic` time series replaying
`DISPATCHCONSTRAINT.RHS` per interval; `include_solution = true` additionally attaches
`"lhs"`/`"marginal_value"` series (validation-only — feeding a solved `MARGINALVALUE` back
into a dispatch simulation is the same category error as using `RRP` as an LP input).

Returns `(added, skipped)`: `added::Vector{String}` of `GENCONID`s successfully added, and
`skipped::Dict{String, Symbol}` mapping a skipped `GENCONID` to one reason — `:no_definition`
(no matching `GENCONDATA` version), `:no_terms` (no `SPD*` rows for its version),
`:unknown_duid`/`:unknown_region`/`:unknown_interconnector` (a term referenced a component
`sys` doesn't have), or `:partial_interval_coverage` (fewer `DISPATCHCONSTRAINT` rows than the
modal row count across all constraints invoked in `date_range` — the constraint stopped or
started applying partway through, so its `"rhs"` series would be shorter than the rest of
`sys`'s time series and fail PSY's cross-component horizon check). Skips are reported as one
summary `@warn`, not one per constraint.
"""
function add_nem_constraints!(sys, db, date_range; intervention::Integer = 0, include_solution::Bool = false)
    start_date = first(date_range)
    resolution = Minute(5)

    invoked = read_invoked_constraints(db, date_range; intervention = intervention)
    if DataFrames.isempty(invoked)
        @warn "No constraints invoked over $date_range; nothing added."
        return String[], Dict{String, Symbol}()
    end
    invoked_by_id = groupby(invoked, :GENCONID)

    row_count_tally = Dict{Int, Int}()
    for group in invoked_by_id
        n = nrow(group)
        row_count_tally[n] = get(row_count_tally, n, 0) + 1
    end
    modal_row_count = argmax(row_count_tally)

    gencon_versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    definitions = read_constraint_definitions(db, gencon_versions)
    def_by_id = Dict(row.GENCONID => row for row in eachrow(definitions))

    terms_long = read_constraint_terms(db, gencon_versions, date_range)
    terms_by_id = groupby(terms_long, :GENCONID)

    governs_long = read_constraint_governs(db, date_range; intervention = intervention)
    governs_by_id = groupby(governs_long, :GENCONID)

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
        skip_reason = nothing
        for row in eachrow(term_rows)
            if row.TERM_KIND == "UNIT"
                if isnothing(get_component(Device, sys, row.KEY))
                    skip_reason = :unknown_duid
                    break
                end
                push!(resolved_terms, UnitTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR))
            elseif row.TERM_KIND == "REGION"
                if isnothing(get_component(Area, sys, row.KEY))
                    skip_reason = :unknown_region
                    break
                end
                push!(resolved_terms, RegionTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR))
            else
                if isnothing(get_component(AreaInterchange, sys, row.KEY))
                    skip_reason = :unknown_interconnector
                    break
                end
                push!(resolved_terms, InterconnectorTerm(row.KEY, row.FACTOR))
            end
        end
        if !isnothing(skip_reason)
            skipped[gencon_id] = skip_reason
            continue
        end

        sense = def.CONSTRAINTTYPE == "<=" ? ConstraintSense.LE :
            def.CONSTRAINTTYPE == ">=" ? ConstraintSense.GE : ConstraintSense.EQ

        governs = haskey(governs_by_id, (gencon_id,)) ?
            [FCASRequirement(r.REGIONID, r.BIDTYPE) for r in eachrow(governs_by_id[(gencon_id,)])] :
            FCASRequirement[]

        constraint_rows = sort(invoked_by_id[(gencon_id,)], :SETTLEMENTDATE)
        if nrow(constraint_rows) < modal_row_count
            skipped[gencon_id] = :partial_interval_coverage
            continue
        end
        rhs_series = constraint_rows.RHS

        gc = GenericConstraint(;
            name = gencon_id,
            sense = sense,
            rhs = coalesce(def.CONSTRAINTVALUE, first(rhs_series)),
            constraint_weight = coalesce(def.GENERICCONSTRAINTWEIGHT, 1.0),
            terms = resolved_terms,
            governs = governs,
            ext = Dict{String, Any}(
                "description" => def.DESCRIPTION,
                "limit_type" => def.LIMITTYPE,
                "source" => def.SOURCE,
                "dynamic_rhs" => def.DYNAMICRHS,
                "effective_date" => string(def.EFFECTIVEDATE),
                "version_no" => def.VERSIONNO,
            ),
        )
        add_component!(sys, gc)

        add_time_series!(
            sys, gc,
            Deterministic(; name = "rhs", data = Dict(start_date => rhs_series), resolution = resolution, interval = resolution),
        )
        if include_solution
            add_time_series!(
                sys, gc,
                Deterministic(; name = "lhs", data = Dict(start_date => constraint_rows.LHS), resolution = resolution, interval = resolution),
            )
            add_time_series!(
                sys, gc,
                Deterministic(; name = "marginal_value", data = Dict(start_date => constraint_rows.MARGINALVALUE), resolution = resolution, interval = resolution),
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
