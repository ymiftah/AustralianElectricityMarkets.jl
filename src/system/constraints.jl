"Whether `load` holds a load-side FCAS bid for any FCAS market."
function _offers_fcas(load)
    cost = _nem_offer_cost(load)
    return !isnothing(cost) && any(b -> _fcas_bid_side(load, b) == OfferSide.LOAD, get_fcas_bids(cost))
end


"""
    _region_devices(sys, region; loads = false) -> Vector{Device}

A [`RegionTerm`](@ref)'s contributing devices.

# Arguments
- `sys`: the `System` to search.
- `region`: an `Area` name.
- `loads`: also include the region's `ControllableLoad`s that carry a load-side FCAS bid
  ([`set_market_bids!`](@ref) must have run); loads are not part of a region's energy aggregate.

# Returns
`Vector{Device}` of every `Generator`/`Storage` (and, with `loads`, `ControllableLoad`) in
`sys` whose bus's area is named `region`.
"""
function _region_devices(sys, region::AbstractString; loads::Bool = false)
    devices = Device[]
    sources = (get_components(Generator, sys), get_components(Storage, sys))
    loads && (sources = (sources..., get_components(_offers_fcas, ControllableLoad, sys)))
    for d in Iterators.flatten(sources)
        get_name(get_area(get_bus(d))) == region && push!(devices, d)
    end
    return devices
end


"""
    resolve_term_devices(sys, term::ConstraintTerm) -> Union{Vector{String}, Nothing}

Resolves a [`ConstraintTerm`](@ref) to the names of the devices it contributes in `sys`. Never
throws or warns.

# Arguments
- `sys`: the `System` to resolve against.
- `term`: a `UnitTerm`, `InterconnectorTerm`, or `RegionTerm`.

# Returns
`nothing` if `term` references something `sys` does not have. Otherwise a `Vector{String}`: a
`UnitTerm`/`InterconnectorTerm` resolves to its own name, a `RegionTerm` to every
`Generator`/`Storage` in that region (possibly empty), plus every `ControllableLoad` for an FCAS term.
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


const _ZERO_FLOW_CONSTRAINTS_TABLE = DataFrame(
    GENCONID = collect(keys(_ZERO_FLOW_CONSTRAINTS)),
    INTERCONNECTOR = first.(values(_ZERO_FLOW_CONSTRAINTS)),
    FACTOR = last.(values(_ZERO_FLOW_CONSTRAINTS)),
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
    recognised = @chain known begin
        filter(is_recognised, _)
        select(:GENCONID, :GENCONID_EFFECTIVEDATE => :EFFECTIVEDATE, :GENCONID_VERSIONNO => :VERSIONNO)
        innerjoin(_ZERO_FLOW_CONSTRAINTS_TABLE; on = :GENCONID, order = :left)
    end
    definitions = @chain recognised begin
        insertcols(
            :CONSTRAINTTYPE => "<=", :GENERICCONSTRAINTWEIGHT => 1.0, :CONSTRAINTVALUE => 0.0,
            :DESCRIPTION => "Interconnector Zero: " .* recognised.INTERCONNECTOR .* " flow",
            :LIMITTYPE => "Interconnector Zero", :SOURCE => "built-in",
        )
        select(Not(:INTERCONNECTOR, :FACTOR))
    end
    terms = @chain recognised begin
        insertcols(:TERM_KIND => "INTERCONNECTOR", :BIDTYPE => missing)
        select(:GENCONID, :EFFECTIVEDATE, :VERSIONNO, :TERM_KIND, :INTERCONNECTOR => :KEY, :BIDTYPE, :FACTOR)
    end
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


"""
    _pad_to_grid(rows, grid, initial_fill) -> (series, invoked_mask)

Reindexes `rows` onto `grid`, carrying the last known value forward across gaps.

# Arguments
- `rows`: `DataFrame` with `SETTLEMENTDATE` and `RHS`, one row per interval with a value.
- `grid`: the `DateTime` intervals to fill.
- `initial_fill`: the value before the first row.

# Returns
`(series, invoked_mask)`: both `Vector{Float64}` of `length(grid)`; `invoked_mask` is `1.0`
where a value was present, `0.0` where carried forward.
"""
function _pad_to_grid(rows, grid::Vector{DateTime}, initial_fill::Float64)
    padded = leftjoin(DataFrame(SETTLEMENTDATE = grid), select(rows, :SETTLEMENTDATE, :RHS); on = :SETTLEMENTDATE, order = :left)
    series = accumulate((last_value, rhs) -> coalesce(rhs, last_value), padded.RHS; init = initial_fill)
    return Float64.(series), Float64.(.!ismissing.(padded.RHS))
end


# Absolute tolerance (MW) on `0 == RHS` for an equality constraint with an empty left-hand side.
const _VACUOUS_EQ_TOLERANCE = 1.0e-6

# The sense of a GENCONDATA `CONSTRAINTTYPE`; only "<=", ">=" and "=" are defined.
function _constraint_sense(gencon_id, constraint_type)
    isequal(constraint_type, "<=") && return ConstraintSense.LE
    isequal(constraint_type, ">=") && return ConstraintSense.GE
    isequal(constraint_type, "=") && return ConstraintSense.EQ
    throw(
        ArgumentError(
            "GENCONDATA $gencon_id has CONSTRAINTTYPE $(repr(constraint_type)); expected \"<=\", \">=\" or \"=\"",
        ),
    )
end

# Whether `0 sense rhs` holds at every invoked interval; a missing RHS never qualifies.
function _is_vacuous(gencon_id, constraint_type, rhs)
    sense = _constraint_sense(gencon_id, constraint_type)
    any(ismissing, rhs) && return false
    return all(rhs) do r
        sense == ConstraintSense.LE ? r >= 0 :
            sense == ConstraintSense.GE ? r <= 0 : abs(r) <= _VACUOUS_EQ_TOLERANCE
    end
end


# Whether a term row's key is absent from `sys`; keyed on `TERM_KIND` only, never builds a term.
function _key_missing(sys, row)
    type = row.TERM_KIND == "UNIT" ? Device : row.TERM_KIND == "REGION" ? Area : AreaInterchange
    return isnothing(get_component(type, sys, row.KEY))
end


"""
    add_nem_constraints!(sys, db, date_range; intervention::Integer = 0) -> (added, skipped)

Reads the invoked constraints and participant fixed loadings over `date_range` from `db` and attaches
them to `sys`: one [`GenericConstraint`](@ref) per exact `(GENCONID, EFFECTIVEDATE, VERSIONNO)` invoked,
named `GENCONID@EFFECTIVEDATE#VERSIONNO` and attached via `add_service!` to its contributing devices.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to run; its last timestamp ends the final interval.
- `intervention`: the `DISPATCHCONSTRAINT.INTERVENTION` run to read: `0` for the pricing run. `1` for the physical run where the interval has one, else the pricing run.

# Returns
`(added, skipped)`: `added::Vector{String}` of component names, `skipped::Dict{String, Symbol}`
mapping a skipped name to `:no_definition`, `:no_terms`, `:unknown_duid`, `:vacuous_unknown_duid`,
`:unknown_region`, or `:unknown_interconnector` (the kind of the first unresolved term). Dropped unit
terms are read back with [`get_dropped_terms`](@ref). A second call on the same system throws an
`ArgumentError` at the first constraint already attached.

A participant fixed-loading row (`\$<DUID>`) is not added nor reported as skipped at intervals with a
fixed-loading row for an available device in `sys`; for an unavailable or absent device it is skipped.
Skipped versions ([`get_skipped_constraints`](@ref)), intervals with no invoked constraint
([`get_missing_constraint_intervals`](@ref)) and constraints given the default weight 1.0
([`get_defaulted_constraint_weights`](@ref)) are recorded on `sys`.

A unit term whose DUID is absent from `sys` is dropped and recorded ([`get_dropped_terms`](@ref)). An
unresolved region or interconnector term, or no resolvable term, skips the constraint. A constraint whose
every term was dropped is skipped as `:vacuous_unknown_duid` when `0 sense RHS` holds at every invoked
interval, else as `:unknown_duid`.

Throws `ArgumentError` when a `RegionTerm` resolves to a region with no Generator/Storage in `sys`, or
when an invoked `SETTLEMENTDATE` falls outside `date_range`'s grid; the throw leaves `sys` unmodified.
"""
function add_nem_constraints!(sys, db, date_range; intervention::Integer = 0)
    _require_cached(db, :DISPATCHCONSTRAINT)
    for table in (:BIDPEROFFER_D, :BIDDAYOFFER_D)
        _require_cached(db, table; context = "the constraint build reads FIXEDLOAD and T1 from it.")
    end
    invoked_all = read_invoked_constraints(db, date_range; intervention)
    fixed = read_fixed_loads(db, date_range)
    start_date = first(date_range)
    missing_intervals = setdiff(collect(date_range)[1:(end - 1)], invoked_all.SETTLEMENTDATE)
    # Fixed loadings are unit offer data, so their `$DUID` rows are not generic constraints.
    targets = _fixed_load_series(sys, fixed)
    if DataFrames.isempty(invoked_all) && DataFrames.isempty(targets)
        set_build_report!(sys, NEMBuildReport(; missing_constraint_intervals = missing_intervals))
        @warn "No constraints invoked over $date_range; nothing added."
        return String[], Dict{String, Symbol}()
    end
    modelled = transform(
        targets,
        :DUID => ByRow(duid -> "\$" * duid) => :GENCONID,
        :INTERVAL_DATETIME => :SETTLEMENTDATE,
    )
    invoked = antijoin(invoked_all, select(modelled, :GENCONID, :SETTLEMENTDATE); on = [:GENCONID, :SETTLEMENTDATE])
    # Grouped by the full (GENCONID, EFFECTIVEDATE, VERSIONNO) triple, not GENCONID alone: two
    # versions must never be merged into one constraint's invoked or rhs series.
    invoked_by_version = groupby(invoked, [:GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO])

    # Drop the last point: `date_range`'s N+1 timestamps label N interval starts, matching
    # `read_fcas_bids`/`_set_demand!`'s half-open convention.
    full_grid = collect(date_range)[1:(end - 1)]
    resolution = step(date_range)

    grid_set = Set(full_grid)
    unaligned = setdiff(Set(invoked.SETTLEMENTDATE), grid_set)
    if !isempty(unaligned)
        shown = sort(collect(unaligned))[1:min(3, length(unaligned))]
        throw(
            ArgumentError(
                "nem constraints: $(length(unaligned)) invoked SETTLEMENTDATE(s) fall outside date_range's grid " *
                    "(e.g. $(join(shown, ", "))); check that date_range's step matches the cache's real dispatch cadence",
            ),
        )
    end

    gencon_versions = unique(select(invoked, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    # Only fixed-load constraints were invoked: there is nothing to look up in the definition tables.
    only_fixed = DataFrames.isempty(gencon_versions)
    definitions = only_fixed ? _empty_definitions() : read_constraint_definitions(db, gencon_versions)

    terms_long = only_fixed ? _empty_terms() : read_constraint_terms(db, gencon_versions, date_range)

    # Only versions GENCONDATA does not define: a published definition always wins.
    undefined = antijoin(
        gencon_versions, definitions;
        on = [:GENCONID, :GENCONID_EFFECTIVEDATE => :EFFECTIVEDATE, :GENCONID_VERSIONNO => :VERSIONNO],
        matchmissing = :notequal,
    )
    zero_definitions, zero_terms = _zero_flow_constraint_definitions(undefined)
    if !isempty(zero_definitions)
        definitions = vcat(definitions, zero_definitions; cols = :union)
        terms_long = vcat(terms_long, zero_terms; cols = :union)
    end
    def_by_version = groupby(definitions, [:GENCONID, :EFFECTIVEDATE, :VERSIONNO])
    terms_by_version = groupby(terms_long, [:GENCONID, :EFFECTIVEDATE, :VERSIONNO])

    # Deliberately GENCONID alone, not the triple above: DISPATCH_FCAS_REQ_CONSTRAINT carries
    # no version columns, so a requirement attaches to every version of its GENCONID.
    reqs_long = read_constraint_fcas_requirements(db, date_range; intervention = intervention)
    req_by_id = groupby(reqs_long, :GENCONID)

    region_cache = Dict{Tuple{String, Bool}, Vector{Device}}()  # `_region_devices` scans every device
    added = String[]
    skipped_rows = @NamedTuple{constraint::String, reason::String, missing::Vector{String}}[]
    DroppedRow = @NamedTuple{constraint::String, kind::String, key::String, bid_type::String, factor::Float64}
    dropped_rows = DroppedRow[]  # terms dropped from built constraints
    vacuous_rows = DroppedRow[]  # terms dropped from constraints skipped as vacuous
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
            push!(skipped_rows, (constraint = versioned_name, reason = "no_definition", missing = String[]))
            continue
        end
        if !haskey(terms_by_version, version_key)
            push!(skipped_rows, (constraint = versioned_name, reason = "no_terms", missing = String[]))
            continue
        end
        def = only(eachrow(def_by_version[version_key]))
        term_rows = terms_by_version[version_key]

        resolved_terms = ConstraintTerm[]
        contributing_devices = Device[]
        skip_reason = nothing  # the kind of the first unresolved term
        missing_keys = String[]
        dropped_terms = DroppedRow[]
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
                        (constraint = versioned_name, kind = "UNIT", key = row.KEY, bid_type = row.BIDTYPE, factor = row.FACTOR),
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
        # One whose terms were all dropped has a zero left-hand side: skipped as vacuous if satisfiable.
        if !unskippable && skip_reason == :unknown_duid && isempty(resolved_terms) &&
                _is_vacuous(gencon_id, def.CONSTRAINTTYPE, invoked_by_version[version_key].RHS)
            push!(skipped_rows, (constraint = versioned_name, reason = "vacuous_unknown_duid", missing = unique(missing_keys)))
            append!(vacuous_rows, dropped_terms)
            continue
        end
        if unskippable || (!isnothing(skip_reason) && isempty(resolved_terms))
            push!(skipped_rows, (constraint = versioned_name, reason = String(skip_reason), missing = unique(missing_keys)))
            continue
        end
        append!(dropped_rows, dropped_terms)

        sense = _constraint_sense(gencon_id, def.CONSTRAINTTYPE)

        # GENCONID alone, not the version triple - fcas_requirements has no version to match
        # against on recent data, so every version of a GENCONID gets the same attribution.
        reqs = haskey(req_by_id, (gencon_id,)) ?
            [FCASRequirement(r.REGIONID, r.BIDTYPE) for r in eachrow(req_by_id[(gencon_id,)])] :
            FCASRequirement[]

        constraint_rows = sort(invoked_by_version[version_key], :SETTLEMENTDATE)
        default_rhs_mw = coalesce(def.CONSTRAINTVALUE, first(constraint_rows.RHS))
        rhs_series_mw, invoked_series = _pad_to_grid(constraint_rows, full_grid, default_rhs_mw)
        ismissing(def.GENERICCONSTRAINTWEIGHT) && push!(missing_weight, versioned_name)
        gc = GenericConstraint(;
            name = versioned_name,
            sense = sense,
            rhs = default_rhs_mw,
            constraint_weight = coalesce(def.GENERICCONSTRAINTWEIGHT, 1.0),
            description = coalesce(def.DESCRIPTION, ""),
            gencon_id = gencon_id,
            limit_type = def.LIMITTYPE,
            source = def.SOURCE,
            effective_date = def.EFFECTIVEDATE,
            version_no = def.VERSIONNO,
            terms = resolved_terms,
            fcas_requirements = reqs,
        )

        push!(
            staged,
            (
                gc = gc, contributing_devices = unique(contributing_devices), rhs_series = rhs_series_mw,
                invoked_series = invoked_series,
            ),
        )
        push!(added, versioned_name)
    end

    skipped_report = DataFrame(skipped_rows)
    if !isempty(skipped_rows)
        reason_counts = @chain skipped_report begin
            groupby(:reason)
            combine(nrow => :n)
            sort(:reason)
        end
        @warn "nem constraints: skipped $(nrow(skipped_report)) of $(nrow(gencon_versions)) invoked constraint versions (by reason: $(join(("$(r.reason)=$(r.n)" for r in eachrow(reason_counts)), ", "))); see get_skipped_constraints" reason_counts
    end

    # A dropped DUID registered in the window is a unit the build left out; one that is not was retired or not yet registered.
    dropped = sort(DataFrame(vcat(dropped_rows, vacuous_rows)), :constraint; alg = MergeSort)
    dropped_keys = dropped.key
    registered = Readers._registered_duids(db, dropped_keys, start_date, last(date_range) - resolution)
    transform!(dropped, :key => ByRow(in(registered)) => :registered)

    if !isempty(dropped_rows)
        @warn "nem constraints: built $(length(unique(getfield.(dropped_rows, :constraint)))) constraint(s) without $(length(dropped_rows)) unit term(s) whose DUID is absent from sys; see get_dropped_terms"
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

    # sys is mutated only past this point - every throw above leaves it untouched.
    set_build_report!(
        sys,
        NEMBuildReport(;
            skipped_constraints = skipped_report,
            missing_constraint_intervals = missing_intervals,
            defaulted_constraint_weights = missing_weight,
            dropped_terms = dropped,
        ),
    )
    for entry in staged
        _add_nem_service!(sys, entry.gc, entry.contributing_devices)
        entry.gc.rhs = add_time_series!(
            sys, entry.gc,
            single_series(NEM_CONSTRAINT_SERIES.rhs, start_date, entry.rhs_series, resolution),
        )
        entry.gc.invoked = add_time_series!(
            sys, entry.gc,
            single_series(NEM_CONSTRAINT_SERIES.invoked, start_date, entry.invoked_series, resolution),
        )
    end

    return added, Dict{String, Symbol}(r.constraint => Symbol(r.reason) for r in skipped_rows)
end
