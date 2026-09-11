"""
    _pad_to_grid(values_by_time, grid, initial_fill) -> (series, invoked_mask)

Reindexes `values_by_time` onto `grid`, carrying the last known value forward across gaps.

# Returns
`(series, invoked_mask)`: both `Vector{Float64}` of `length(grid)`; `invoked_mask` is `1.0`
where a value was present, `0.0` where carried forward.
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

Spacing between consecutive points of a sorted `grid`. Falls back to `Minute(5)` for fewer
than 2 points; warns and uses the smallest spacing if unequal.
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
    add_nem_constraints!(sys, db, date_range; intervention = 0, include_solution = false, resolution = nothing, allow_empty_region_terms = false)

Adds one [`GenericConstraint`](@ref) per exact `(GENCONID, EFFECTIVEDATE, VERSIONNO)` invoked
in `date_range`, named `GENCONID@EFFECTIVEDATE#VERSIONNO` and attached via `add_service!` to
its contributing devices.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `intervention`: `DISPATCHCONSTRAINT.INTERVENTION` to read (default `0`).
- `include_solution`: also attach `"lhs"` and `"marginal_value"`.
- `resolution`: declared resolution of every attached series. Inferred from `date_range` when
  `nothing`.
- `allow_empty_region_terms`: default `false` throws on an empty `RegionTerm`; `true` warns and
  proceeds.

# Returns
`(added, skipped)`: `added::Vector{String}` of component names, `skipped::Dict{String, Symbol}`
mapping a skipped name to `:no_definition`, `:no_terms`, `:unknown_duid`, `:unknown_region`, or
`:unknown_interconnector`.

Throws `ArgumentError` when `DISPATCHCONSTRAINT` is not cached, or when an empty `RegionTerm` is
found and `allow_empty_region_terms = false`; either throw leaves `sys` unmodified.
"""
function add_nem_constraints!(
        sys, db, date_range; intervention::Integer = 0, include_solution::Bool = false,
        resolution::Union{Nothing, Dates.Period} = nothing,
        allow_empty_region_terms::Bool = false,
    )
    start_date = first(date_range)
    base_power = get_base_power(sys)

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
    # Grouped by the full (GENCONID, EFFECTIVEDATE, VERSIONNO) triple, not GENCONID alone: two
    # versions must never be merged into one "invoked"/"rhs" series.
    invoked_by_version = groupby(invoked, [:GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO])

    # Drop the last point: `date_range`'s N+1 timestamps label N interval starts, matching
    # `read_fcas_bids`/`set_demand!`'s half-open convention.
    full_grid = collect(date_range)[1:(end - 1)]
    resolution = isnothing(resolution) ? _infer_resolution(full_grid) : resolution

    grid_set = Set(full_grid)
    unaligned = setdiff(Set(invoked.SETTLEMENTDATE), grid_set)
    if !isempty(unaligned)
        @warn "add_nem_constraints!: $(length(unaligned)) invoked SETTLEMENTDATE(s) fall outside date_range's grid and will be dropped from every constraint's \"rhs\"/\"invoked\" series - check that date_range's step matches the cache's real dispatch cadence: $(sort(collect(unaligned)))"
    end

    gencon_versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    definitions = read_constraint_definitions(db, gencon_versions)
    def_by_version = Dict((row.GENCONID, row.EFFECTIVEDATE, row.VERSIONNO) => row for row in eachrow(definitions))

    terms_long = read_constraint_terms(db, gencon_versions, date_range)
    terms_by_version = groupby(terms_long, [:GENCONID, :EFFECTIVEDATE, :VERSIONNO])

    # Deliberately GENCONID alone, not the triple above: DISPATCH_FCAS_REQ_CONSTRAINT carries
    # no version columns, so a requirement attaches to every version of its GENCONID.
    reqs_long = read_constraint_fcas_requirements(db, date_range; intervention = intervention)
    req_by_id = groupby(reqs_long, :GENCONID)

    added = String[]
    skipped = Dict{String, Symbol}()
    empty_region_terms = @NamedTuple{constraint_name::String, region::String, bid_type::BidType}[]
    staged = @NamedTuple{
        gc::GenericConstraint, contributing_devices::Vector{Device},
        rhs_series::Vector{Float64}, invoked_series::Vector{Float64},
        lhs_series::Union{Nothing, Vector{Float64}},
        marginal_value_series::Union{Nothing, Vector{Float64}},
    }[]

    for key in eachrow(gencon_versions)
        gencon_id = key.GENCONID
        eff = key.GENCONID_EFFECTIVEDATE
        ver = key.GENCONID_VERSIONNO
        version_key = (gencon_id, eff, ver)
        versioned_name = "$(gencon_id)@$(string(eff))#$(ver)"

        if !haskey(def_by_version, version_key)
            skipped[versioned_name] = :no_definition
            continue
        end
        if !haskey(terms_by_version, version_key)
            skipped[versioned_name] = :no_terms
            continue
        end
        def = def_by_version[version_key]
        term_rows = terms_by_version[version_key]

        resolved_terms = ConstraintTerm[]
        contributing_devices = Device[]
        skip_reason = nothing
        for row in eachrow(term_rows)
            if row.TERM_KIND == "UNIT"
                term = UnitTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR)
                names = resolve_term_devices(sys, term)
                if isnothing(names)
                    skip_reason = :unknown_duid
                    break
                end
                push!(resolved_terms, term)
                push!(contributing_devices, get_component(Device, sys, only(names)))
            elseif row.TERM_KIND == "REGION"
                bid_type = BidType(row.BIDTYPE)
                names = resolve_term_devices(sys, RegionTerm(row.KEY, bid_type, row.FACTOR))
                if isnothing(names)
                    skip_reason = :unknown_region
                    break
                end
                isempty(names) && push!(
                    empty_region_terms, (constraint_name = versioned_name, region = row.KEY, bid_type = bid_type),
                )
                push!(resolved_terms, RegionTerm(row.KEY, bid_type, row.FACTOR, names))
                # Not a name-based re-lookup: `Device` is ambiguous by name across concrete
                # types (e.g. an interconnector's own `AreaInterchange` vs. a same-named
                # `Line`), so this reuses `_region_devices`'s own typed result directly.
                append!(contributing_devices, _region_devices(sys, row.KEY))
            else
                term = InterconnectorTerm(row.KEY, row.FACTOR)
                names = resolve_term_devices(sys, term)
                if isnothing(names)
                    skip_reason = :unknown_interconnector
                    break
                end
                push!(resolved_terms, term)
                push!(contributing_devices, get_component(AreaInterchange, sys, only(names)))
            end
        end
        if !isnothing(skip_reason)
            skipped[versioned_name] = skip_reason
            continue
        end

        sense = def.CONSTRAINTTYPE == "<=" ? ConstraintSense.LE :
            def.CONSTRAINTTYPE == ">=" ? ConstraintSense.GE : ConstraintSense.EQ

        # GENCONID alone, not the version triple - fcas_requirements has no version to match
        # against on recent data, so every version of a GENCONID gets the same attribution.
        reqs = haskey(req_by_id, (gencon_id,)) ?
            [FCASRequirement(r.REGIONID, r.BIDTYPE) for r in eachrow(req_by_id[(gencon_id,)])] :
            FCASRequirement[]

        constraint_rows = sort(invoked_by_version[version_key], :SETTLEMENTDATE)
        rhs_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.RHS))
        default_rhs_mw = coalesce(def.CONSTRAINTVALUE, first(constraint_rows.RHS))
        rhs_series_mw, invoked_series = _pad_to_grid(rhs_by_time, full_grid, default_rhs_mw)
        # rhs/lhs are per-unitized here, once, before either is stored - the "rhs" time series
        # and GenericConstraint.rhs must agree with PSY.get_value's SYSTEM_BASE/NATURAL_UNITS
        # convention for every other power quantity on this System.
        rhs_series = rhs_series_mw ./ base_power

        gc = GenericConstraint(;
            name = versioned_name,
            sense = sense,
            rhs = default_rhs_mw / base_power,
            constraint_weight = coalesce(def.GENERICCONSTRAINTWEIGHT, 1.0),
            description = coalesce(def.DESCRIPTION, ""),
            terms = resolved_terms,
            fcas_requirements = reqs,
            ext = Dict{String, Any}(
                "gencon_id" => gencon_id,
                "limit_type" => def.LIMITTYPE,
                "source" => def.SOURCE,
                "effective_date" => string(def.EFFECTIVEDATE),
                "version_no" => def.VERSIONNO,
            ),
        )

        lhs_series = nothing
        marginal_value_series = nothing
        if include_solution
            lhs_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.LHS))
            lhs_series_mw, _ = _pad_to_grid(lhs_by_time, full_grid, first(constraint_rows.LHS))
            # Same convention as "rhs" - lhs is the constraint's achieved level, directly
            # compared against rhs, so it is per-unitized the same way.
            lhs_series = lhs_series_mw ./ base_power
            mv_by_time = Dict(zip(constraint_rows.SETTLEMENTDATE, constraint_rows.MARGINALVALUE))
            # Not carried forward like rhs/lhs: an interval this constraint wasn't invoked at
            # genuinely has zero shadow price, so 0.0 is a fact here, not a filler value.
            # A $/MW price, not a power quantity - not per-unitized, unlike rhs/lhs.
            marginal_value_series = [get(mv_by_time, t, 0.0) for t in full_grid]
        end

        push!(
            staged,
            (
                gc = gc, contributing_devices = unique(contributing_devices), rhs_series = rhs_series,
                invoked_series = invoked_series, lhs_series = lhs_series,
                marginal_value_series = marginal_value_series,
            ),
        )
        push!(added, versioned_name)
    end

    if !isempty(skipped)
        reason_counts = Dict{Symbol, Int}()
        for reason in values(skipped)
            reason_counts[reason] = get(reason_counts, reason, 0) + 1
        end
        @warn "add_nem_constraints!: skipped $(length(skipped)) of $(nrow(gencon_versions)) invoked constraint versions" reason_counts
    end

    if !isempty(empty_region_terms)
        # string(bid_type), not "$bid_type" - @scoped_enum overrides Base.show (see parser.jl).
        detail = join(
            (
                "constraint=$(e.constraint_name) region=$(e.region) bid_type=$(string(e.bid_type))"
                    for e in empty_region_terms
            ), "; ",
        )
        if allow_empty_region_terms
            @warn "add_nem_constraints!: $(length(empty_region_terms)) RegionTerm(s) resolved to a region with no Generator/Storage in sys; proceeding with empty devices (allow_empty_region_terms=true): $detail"
        else
            throw(
                ArgumentError(
                    "add_nem_constraints!: $(length(empty_region_terms)) RegionTerm(s) resolved to a region with no Generator/Storage in sys: $detail. " *
                        "Pass allow_empty_region_terms=true to add these constraints anyway with an empty RegionTerm.devices.",
                ),
            )
        end
    end

    # sys is mutated only past this point - every throw above leaves it untouched, so a caller
    # retrying with allow_empty_region_terms=true on the same sys never double-adds anything.
    for entry in staged
        add_service!(sys, entry.gc, entry.contributing_devices)
        add_time_series!(
            sys, entry.gc,
            Deterministic(; name = "rhs", data = Dict(start_date => entry.rhs_series), resolution = resolution, interval = resolution),
        )
        add_time_series!(
            sys, entry.gc,
            Deterministic(; name = "invoked", data = Dict(start_date => entry.invoked_series), resolution = resolution, interval = resolution),
        )
        if include_solution
            add_time_series!(
                sys, entry.gc,
                Deterministic(; name = "lhs", data = Dict(start_date => entry.lhs_series), resolution = resolution, interval = resolution),
            )
            add_time_series!(
                sys, entry.gc,
                Deterministic(; name = "marginal_value", data = Dict(start_date => entry.marginal_value_series), resolution = resolution, interval = resolution),
            )
        end
    end

    return added, skipped
end
