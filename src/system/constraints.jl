"Whether `load` carries a decremental FCAS trapezium series for any FCAS market."
_offers_fcas(load) = any(
    bt -> has_time_series(load, SingleTimeSeries, fcas_series_name("fcas_trapezium", bt, OfferSide.LOAD)), FCAS_BID_TYPES,
)


"""
    _region_devices(sys, region; loads = false) -> Vector{Device}

A [`RegionTerm`](@ref)'s contributing devices.

# Arguments
- `sys`: the `System` to search.
- `region`: an `Area` name.
- `loads`: also include the region's `InterruptiblePowerLoad`s that carry an FCAS bid series
  ([`set_fcas_bids!`](@ref) must have run); loads are not part of a region's energy aggregate.

# Returns
`Vector{Device}` of every `Generator`/`Storage` (and, with `loads`, `InterruptiblePowerLoad`) in
`sys` whose bus's area is named `region`.
"""
function _region_devices(sys, region::AbstractString; loads::Bool = false)
    devices = Device[]
    sources = (get_components(Generator, sys), get_components(Storage, sys))
    loads && (sources = (sources..., get_components(_offers_fcas, InterruptiblePowerLoad, sys)))
    for d in Iterators.flatten(sources)
        get_name(get_area(get_bus(d))) == region && push!(devices, d)
    end
    return devices
end


"""
    resolve_term_devices(sys, term::ConstraintTerm) -> Union{Vector{String}, Nothing}

Resolves a [`ConstraintTerm`](@ref) to the names of the devices it contributes in `sys`. A pure
lookup — never throws, warns, or applies policy.

# Arguments
- `sys`: the `System` to resolve against.
- `term`: a `UnitTerm`, `InterconnectorTerm`, or `RegionTerm`.

# Returns
`nothing` if `term` references something `sys` doesn't have. Otherwise a `Vector{String}` of
device names — a `UnitTerm`/`InterconnectorTerm` resolves to its own name, a `RegionTerm` to
every `Generator`/`Storage` in that region (possibly empty), plus every `InterruptiblePowerLoad`
when the term is an FCAS term.
"""
function resolve_term_devices(sys, term::UnitTerm)
    device = get_component(Device, sys, get_duid(term))
    return isnothing(device) ? nothing : [get_duid(term)]
end


function resolve_term_devices(sys, term::InterconnectorTerm)
    device = get_component(AreaInterchange, sys, get_interconnector(term))
    return isnothing(device) ? nothing : [get_interconnector(term)]
end


function resolve_term_devices(sys, term::RegionTerm)
    isnothing(get_component(Area, sys, get_region(term))) && return nothing
    loads = get_bid_type(term) != BidType.ENERGY
    return String[get_name(d) for d in _region_devices(sys, get_region(term); loads = loads)]
end

# Interconnector Zero constraints: one inequality per direction on a single interconnector flow,
# right-hand side zero. `(interconnector, factor)` is the term of `factor * flow <= 0`.
const _ZERO_FLOW_CONSTRAINTS = Dict{String, Tuple{String, Float64}}(
    "SVML_ZERO" => ("V-S-MNSP1", -1.0),
    "VSML_ZERO" => ("V-S-MNSP1", 1.0),
    "VT_ZERO" => ("T-V-MNSP1", -1.0),
    "TV_ZERO" => ("T-V-MNSP1", 1.0),
)


const _ZERO_FLOW_EFFECTIVEDATE = Date(2013, 8, 21)

const _ZERO_FLOW_VERSIONNO = 1


"""
    _zero_flow_constraint_definitions(gencon_versions) -> (definitions, terms)

Definition and term rows of the Interconnector Zero constraints (`SVML_ZERO`, `VSML_ZERO`,
`VT_ZERO`, `TV_ZERO`) for the versions in `gencon_versions`, shaped like the results of
[`read_constraint_definitions`](@ref) and [`read_constraint_terms`](@ref). Each constrains
one interconnector flow, `factor * flow <= 0` with factor `-1` or `1`. Only version
`2013-08-21 #1` is recognised; another version of these identifiers warns and gets no rows.

# Arguments
- `gencon_versions`: `DataFrame` with `GENCONID`, `GENCONID_EFFECTIVEDATE`, `GENCONID_VERSIONNO`
  (see [`read_invoked_constraints`](@ref)).

# Returns
`(definitions, terms)`: one definition row and one `INTERCONNECTOR` term row per recognised
version.
"""
function _zero_flow_constraint_definitions(gencon_versions)
    known = filter(r -> haskey(_ZERO_FLOW_CONSTRAINTS, r.GENCONID), unique(gencon_versions))
    is_recognised(r) = !ismissing(r.GENCONID_EFFECTIVEDATE) && !ismissing(r.GENCONID_VERSIONNO) &&
        Date(r.GENCONID_EFFECTIVEDATE) == _ZERO_FLOW_EFFECTIVEDATE &&
        r.GENCONID_VERSIONNO == _ZERO_FLOW_VERSIONNO
    for r in eachrow(known)
        is_recognised(r) || @warn "Interconnector Zero constraint $(r.GENCONID) is invoked at an unrecognised version ($(r.GENCONID_EFFECTIVEDATE) #$(r.GENCONID_VERSIONNO)); it has no definition and is skipped"
    end
    recognised = filter(is_recognised, known)
    definitions = DataFrame(
        GENCONID = recognised.GENCONID,
        EFFECTIVEDATE = recognised.GENCONID_EFFECTIVEDATE,
        VERSIONNO = recognised.GENCONID_VERSIONNO,
        CONSTRAINTTYPE = fill("<=", nrow(recognised)),
        GENERICCONSTRAINTWEIGHT = fill(1.0, nrow(recognised)),
        CONSTRAINTVALUE = fill(0.0, nrow(recognised)),
        DESCRIPTION = ["Interconnector Zero: $(_ZERO_FLOW_CONSTRAINTS[id][1]) flow" for id in recognised.GENCONID],
        LIMITTYPE = fill("Interconnector Zero", nrow(recognised)),
        SOURCE = fill("built-in", nrow(recognised)),
    )
    terms = DataFrame(
        GENCONID = recognised.GENCONID,
        EFFECTIVEDATE = recognised.GENCONID_EFFECTIVEDATE,
        VERSIONNO = recognised.GENCONID_VERSIONNO,
        TERM_KIND = fill("INTERCONNECTOR", nrow(recognised)),
        KEY = [_ZERO_FLOW_CONSTRAINTS[id][1] for id in recognised.GENCONID],
        BIDTYPE = fill(missing, nrow(recognised)),
        FACTOR = [_ZERO_FLOW_CONSTRAINTS[id][2] for id in recognised.GENCONID],
    )
    return definitions, terms
end

function _empty_definitions()
    return DataFrame(
        GENCONID = String[], EFFECTIVEDATE = DateTime[], VERSIONNO = Int[], CONSTRAINTTYPE = String[],
        GENERICCONSTRAINTWEIGHT = Float64[], CONSTRAINTVALUE = Float64[], DESCRIPTION = String[],
        LIMITTYPE = String[], SOURCE = String[],
    )
end


function _empty_terms()
    return DataFrame(
        GENCONID = String[], EFFECTIVEDATE = DateTime[], VERSIONNO = Int[], TERM_KIND = String[],
        KEY = String[], BIDTYPE = Union{Missing, String}[], FACTOR = Float64[],
    )
end


# Whether a `$<DUID>` DISPATCHCONSTRAINT id is an Energy Inflexible Offer constraint built from bids.
function _is_modelled_fixed_load(genconid::AbstractString, fixed_loads, interval::DateTime)
    return startswith(genconid, "\$") && haskey(fixed_loads, genconid[2:end]) && haskey(fixed_loads[genconid[2:end]], interval)
end


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
        @warn "nem constraints: grid spacing is not uniform (found $(join(distinct, ", "))); the stored series' fixed resolution will not match every SETTLEMENTDATE. Proceeding with the smallest spacing, $(first(distinct))."
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


# One JSON-serializable row of `get_skipped_constraints`.
function _skipped_row(name::String, reason::Symbol, missing_keys::Vector{String})
    return Dict{String, Any}(
        "constraint" => name, "reason" => String(reason), "missing" => missing_keys,
    )
end


# Whether a term row's key is absent from `sys`; keyed on `TERM_KIND` only, never builds a term.
function _key_missing(sys, row)
    type = row.TERM_KIND == "UNIT" ? Device : row.TERM_KIND == "REGION" ? Area : AreaInterchange
    return isnothing(get_component(type, sys, row.KEY))
end


"""
    _versions_without_definition(invoked, definitions) -> DataFrame

Returns invoked constraint versions that do not have a published definition in GENCONDATA.
Rows with a missing `GENCONID_EFFECTIVEDATE` are treated as having no definition.

# Arguments
- `invoked`: DataFrame with columns `GENCONID`, `GENCONID_EFFECTIVEDATE`, `GENCONID_VERSIONNO`.
- `definitions`: DataFrame with columns `GENCONID`, `EFFECTIVEDATE`, `VERSIONNO`.

# Returns
A DataFrame (subset of `invoked`) containing only versions without a matching definition.
"""
function _versions_without_definition(invoked, definitions)
    undefined = antijoin(
        invoked, definitions;
        on = [:GENCONID, :GENCONID_EFFECTIVEDATE => :EFFECTIVEDATE, :GENCONID_VERSIONNO => :VERSIONNO],
        matchmissing = :notequal,
    )
    return undefined
end


function _read_constraint_inputs(db, date_range; intervention = 0)
    _require_cached(db, :DISPATCHCONSTRAINT)
    for table in (:BIDPEROFFER_D, :BIDDAYOFFER_D)
        _require_cached(db, table; context = "the constraint build reads FIXEDLOAD and T1 from it.")
    end
    invoked = read_invoked_constraints(db, date_range; intervention)
    fixed = read_fixed_loads(db, date_range)
    return invoked, fixed
end


"""
    _add_nem_constraints!(sys, db, date_range, invoked_all, fixed; intervention = 0) -> (added, skipped)

Adds one [`GenericConstraint`](@ref) per exact `(GENCONID, EFFECTIVEDATE, VERSIONNO)` in `invoked_all`,
named `GENCONID@EFFECTIVEDATE#VERSIONNO` and attached via `add_service!` to its contributing devices.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `invoked_all`: the invoked constraint rows over `date_range`, as `_read_constraint_inputs` returns them.
- `fixed`: the fixed-loading rows over `date_range`, as `_read_constraint_inputs` returns them.
- `intervention`: the `DISPATCHCONSTRAINT.INTERVENTION` the rows were read with (default `0`).

# Returns
`(added, skipped)`: `added::Vector{String}` of component names, `skipped::Dict{String, Symbol}`
mapping a skipped name to `:no_definition`, `:no_terms`, `:unknown_duid`, `:unknown_region`, or
`:unknown_interconnector` (the kind of the first unresolved term). Dropped unit terms are read back
with [`get_dropped_terms`](@ref).

A unit's participant fixed loading (`\$<DUID>`) is not a generic constraint: its `DISPATCHCONSTRAINT`
row is neither added nor reported as skipped where `_set_nem_fixed_loads!` attaches the loading to the unit.

Each skipped version is also recorded on `sys`; read it with [`get_skipped_constraints`](@ref). The
intervals of `date_range` with no invoked constraint ([`get_missing_constraint_intervals`](@ref)) and
the constraints given the default weight 1.0 for a NULL `GENERICCONSTRAINTWEIGHT`
([`get_defaulted_constraint_weights`](@ref)) are recorded the same way.

A unit term whose DUID is absent from `sys` is dropped, as nempy does for a unit that is not in the
dispatch, and recorded in the constraint's `ext["dropped_terms"]` and in [`get_dropped_terms`](@ref).
An unresolved region or interconnector term, or a constraint with no resolvable term, skips the constraint.

Throws `ArgumentError` when a `RegionTerm` resolves to a region with no Generator/Storage in `sys`;
the throw leaves `sys` unmodified.
"""
function _add_nem_constraints!(sys, db, date_range, invoked_all, fixed; intervention = 0)
    start_date = first(date_range)
    base_power = get_base_power(sys)
    missing_intervals = setdiff(collect(date_range)[1:(end - 1)], invoked_all.SETTLEMENTDATE)
    # Fixed loadings are unit offer data (_set_nem_fixed_loads!), so their `$DUID` rows are not generic constraints.
    fixed_loads = _fixed_load_series(sys, fixed)
    if DataFrames.isempty(invoked_all) && isempty(fixed_loads)
        get_ext(sys)["skipped_constraints"] = Dict{String, Any}[]
        get_ext(sys)["defaulted_constraint_weights"] = String[]
        get_ext(sys)["dropped_terms"] = Dict{String, Any}[]
        get_ext(sys)["missing_constraint_intervals"] = string.(missing_intervals)
        @warn "No constraints invoked over $date_range; nothing added."
        return String[], Dict{String, Symbol}()
    end
    invoked = filter(r -> !_is_modelled_fixed_load(r.GENCONID, fixed_loads, r.SETTLEMENTDATE), invoked_all)
    # Grouped by the full (GENCONID, EFFECTIVEDATE, VERSIONNO) triple, not GENCONID alone: two
    # versions must never be merged into one "invoked"/"rhs" series.
    invoked_by_version = groupby(invoked, [:GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO])

    # Drop the last point: `date_range`'s N+1 timestamps label N interval starts, matching
    # `read_fcas_bids`/`_set_demand!`'s half-open convention.
    full_grid = collect(date_range)[1:(end - 1)]
    resolution = _infer_resolution(full_grid)

    grid_set = Set(full_grid)
    unaligned = setdiff(Set(invoked.SETTLEMENTDATE), grid_set)
    if !isempty(unaligned)
        @warn "nem constraints: $(length(unaligned)) invoked SETTLEMENTDATE(s) fall outside date_range's grid and will be dropped from every constraint's \"rhs\"/\"invoked\" series - check that date_range's step matches the cache's real dispatch cadence: $(sort(collect(unaligned)))"
    end

    gencon_versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    # Only fixed-load constraints were invoked: there is nothing to look up in the definition tables.
    only_fixed = DataFrames.isempty(gencon_versions)
    definitions = only_fixed ? _empty_definitions() : read_constraint_definitions(db, gencon_versions)
    def_by_version = Dict((row.GENCONID, row.EFFECTIVEDATE, row.VERSIONNO) => row for row in eachrow(definitions))

    terms_long = only_fixed ? _empty_terms() : read_constraint_terms(db, gencon_versions, date_range)

    # Only versions GENCONDATA does not define: a published definition always wins.
    undefined = _versions_without_definition(gencon_versions, definitions)
    zero_definitions, zero_terms = _zero_flow_constraint_definitions(undefined)
    if !isempty(zero_definitions)
        definitions = vcat(definitions, zero_definitions; cols = :union)
        terms_long = vcat(terms_long, zero_terms; cols = :union)
        def_by_version = Dict((row.GENCONID, row.EFFECTIVEDATE, row.VERSIONNO) => row for row in eachrow(definitions))
    end
    terms_by_version = groupby(terms_long, [:GENCONID, :EFFECTIVEDATE, :VERSIONNO])

    # Deliberately GENCONID alone, not the triple above: DISPATCH_FCAS_REQ_CONSTRAINT carries
    # no version columns, so a requirement attaches to every version of its GENCONID.
    reqs_long = read_constraint_fcas_requirements(db, date_range; intervention = intervention)
    req_by_id = groupby(reqs_long, :GENCONID)

    region_cache = Dict{Tuple{String, Bool}, Vector{Device}}()  # `_region_devices` scans every device
    added = String[]
    skipped = Dict{String, Symbol}()
    skipped_detail = Dict{String, Any}[]
    dropped = Dict{String, Vector{Dict{String, Any}}}()
    missing_weight = String[]
    empty_region_terms = @NamedTuple{constraint_name::String, region::String, bid_type::BidType}[]
    staged = @NamedTuple{
        gc::GenericConstraint, contributing_devices::Vector{Device},
        rhs_series::Vector{Float64}, invoked_series::Vector{Float64},
    }[]

    for key in eachrow(gencon_versions)
        gencon_id = key.GENCONID
        eff = key.GENCONID_EFFECTIVEDATE
        ver = key.GENCONID_VERSIONNO
        version_key = (gencon_id, eff, ver)
        versioned_name = "$(gencon_id)@$(string(eff))#$(ver)"

        if !haskey(def_by_version, version_key)
            skipped[versioned_name] = :no_definition
            push!(skipped_detail, _skipped_row(versioned_name, :no_definition, String[]))
            continue
        end
        if !haskey(terms_by_version, version_key)
            skipped[versioned_name] = :no_terms
            push!(skipped_detail, _skipped_row(versioned_name, :no_terms, String[]))
            continue
        end
        def = def_by_version[version_key]
        term_rows = terms_by_version[version_key]

        resolved_terms = ConstraintTerm[]
        contributing_devices = Device[]
        skip_reason = nothing  # the kind of the first unresolved term
        missing_keys = String[]
        dropped_terms = Dict{String, Any}[]
        unskippable = false  # an unresolved term that forces a skip
        for row in eachrow(term_rows)
            # Once the constraint is bound to be skipped, keep scanning only to list every missing key.
            if unskippable
                _key_missing(sys, row) && push!(missing_keys, row.KEY)
                continue
            end
            if row.TERM_KIND == "UNIT"
                term = UnitTerm(row.KEY, BidType(row.BIDTYPE), row.FACTOR)
                names = resolve_term_devices(sys, term)
                if isnothing(names)
                    isnothing(skip_reason) && (skip_reason = :unknown_duid)
                    push!(missing_keys, row.KEY)
                    push!(
                        dropped_terms,
                        Dict{String, Any}(
                            "kind" => "UNIT", "key" => row.KEY, "bid_type" => row.BIDTYPE, "factor" => row.FACTOR,
                        ),
                    )
                    continue
                end
                push!(resolved_terms, term)
                push!(contributing_devices, get_component(Device, sys, only(names)))
            elseif row.TERM_KIND == "REGION"
                bid_type = BidType(row.BIDTYPE)
                region_devices = isnothing(get_component(Area, sys, row.KEY)) ? nothing :
                    get!(() -> _region_devices(sys, row.KEY; loads = bid_type != BidType.ENERGY), region_cache, (row.KEY, bid_type != BidType.ENERGY))
                names = isnothing(region_devices) ? nothing : String[get_name(d) for d in region_devices]
                if isnothing(names)
                    isnothing(skip_reason) && (skip_reason = :unknown_region)
                    push!(missing_keys, row.KEY)
                    unskippable = true  # a region aggregate is never zero, so its term cannot be dropped
                    continue
                end
                isempty(names) && push!(
                    empty_region_terms, (constraint_name = versioned_name, region = row.KEY, bid_type = bid_type),
                )
                push!(resolved_terms, RegionTerm(row.KEY, bid_type, row.FACTOR, names))
                # Not a name-based re-lookup: `Device` is ambiguous by name across concrete
                # types (e.g. an interconnector's own `AreaInterchange` vs. a same-named
                # `Line`), so this reuses `_region_devices`'s own typed result directly.
                append!(contributing_devices, region_devices)
            else
                term = InterconnectorTerm(row.KEY, row.FACTOR)
                names = resolve_term_devices(sys, term)
                if isnothing(names)
                    isnothing(skip_reason) && (skip_reason = :unknown_interconnector)
                    push!(missing_keys, row.KEY)
                    unskippable = true  # a flow is not zero when unmodelled, so its term cannot be dropped
                    continue
                end
                push!(resolved_terms, term)
                push!(contributing_devices, get_component(AreaInterchange, sys, only(names)))
            end
        end
        # Under :drop only unit terms are dropped, and a constraint left with no term is skipped.
        if unskippable || (!isnothing(skip_reason) && isempty(resolved_terms))
            skipped[versioned_name] = skip_reason
            push!(skipped_detail, _skipped_row(versioned_name, skip_reason, unique(missing_keys)))
            continue
        end
        isempty(dropped_terms) || (dropped[versioned_name] = dropped_terms)

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

        ismissing(def.GENERICCONSTRAINTWEIGHT) && push!(missing_weight, versioned_name)
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
                "dropped_terms" => get(dropped, versioned_name, Dict{String, Any}[]),
            ),
        )

        push!(
            staged,
            (
                gc = gc, contributing_devices = unique(contributing_devices), rhs_series = rhs_series,
                invoked_series = invoked_series,
            ),
        )
        push!(added, versioned_name)
    end

    if !isempty(skipped)
        reason_counts = Dict{Symbol, Int}()
        for reason in values(skipped)
            reason_counts[reason] = get(reason_counts, reason, 0) + 1
        end
        @warn "nem constraints: skipped $(length(skipped)) of $(nrow(gencon_versions)) invoked constraint versions (by reason: $(join(("$r=$n" for (r, n) in sort(collect(reason_counts))), ", "))); see get_skipped_constraints" reason_counts
    end

    if !isempty(dropped)
        @warn "nem constraints: built $(length(dropped)) constraint(s) without $(sum(length, values(dropped))) unit term(s) whose DUID is absent from sys; see get_dropped_terms"
    end

    if !isempty(missing_weight)
        @warn "nem constraints: $(length(missing_weight)) constraint(s) have a NULL GENERICCONSTRAINTWEIGHT and were given constraint_weight = 1.0: $missing_weight"
    end

    if !isempty(empty_region_terms)
        # string(bid_type), not "$bid_type" - @scoped_enum overrides Base.show (see bid_types.jl).
        detail = join(
            (
                "constraint=$(e.constraint_name) region=$(e.region) bid_type=$(string(e.bid_type))"
                    for e in empty_region_terms
            ), "; ",
        )
        throw(
            ArgumentError(
                "nem constraints: $(length(empty_region_terms)) RegionTerm(s) resolved to a region with no Generator/Storage in sys: $detail.",
            ),
        )
    end

    get_ext(sys)["skipped_constraints"] = skipped_detail
    get_ext(sys)["defaulted_constraint_weights"] = missing_weight
    get_ext(sys)["missing_constraint_intervals"] = string.(missing_intervals)

    # sys is mutated only past this point - every throw above leaves it untouched.
    get_ext(sys)["dropped_terms"] = Dict{String, Any}[
        merge(term, Dict{String, Any}("constraint" => name)) for (name, terms) in sort!(collect(dropped); by = first)
            for term in terms
    ]
    for entry in staged
        add_service!(sys, entry.gc, entry.contributing_devices)
        add_time_series!(
            sys, entry.gc,
            single_series("rhs", start_date, entry.rhs_series, resolution),
        )
        add_time_series!(
            sys, entry.gc,
            single_series("invoked", start_date, entry.invoked_series, resolution),
        )
    end

    return added, skipped
end
