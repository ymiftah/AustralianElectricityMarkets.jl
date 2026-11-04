"""
    _check_mnsp_coverage(links, offers, required, grid)

Throws unless each MNSP in `required` has two distinct directional links, each with an offer at every
interval of `grid`.

# Arguments
- `links`: the MNSP link table, with `INTERCONNECTORID` and `LINKID`.
- `offers`: the joined MNSP offers, with `LINKID` and `INTERVAL_DATETIME`.
- `required`: the MNSP `INTERCONNECTORID`s to check.
- `grid`: the interval-ending timestamps that must each carry an offer.

# Returns
`nothing`. Throws an `ArgumentError` naming the MNSP and link at fault.
"""
function _check_mnsp_coverage(links, offers, required, grid)
    for name in required
        group = links[links.INTERCONNECTORID .== name, :]
        nrow(group) == 2 && length(unique(group.LINKID)) == 2 || throw(
            ArgumentError("check_replay_inputs: MNSP $name requires two distinct directional links")
        )
        for link in group.LINKID
            stamps = sort(offers[offers.LINKID .== link, :INTERVAL_DATETIME])
            stamps == grid || throw(
                ArgumentError(
                    "check_replay_inputs: MNSP $name link $link has $(length(stamps)) joined offers for $(length(grid)) intervals " *
                        "from $(first(grid)) to $(last(grid)); check DISPATCH_MNSPBIDTRK and its referenced MNSP_DAYOFFER/MNSP_BIDOFFERPERIOD versions"
                )
            )
        end
    end
    return
end

"""
    _generic_invocations(invoked, fixed) -> DataFrame

The rows of `invoked` that are not fixed-load constraints, that is, whose `GENCONID` starts with `\$` and
whose fixed load is reported at the same `SETTLEMENTDATE`.

# Arguments
- `invoked`: the invoked constraint rows, with `GENCONID` and `SETTLEMENTDATE`.
- `fixed`: the fixed-load rows, with `DUID` and `INTERVAL_DATETIME`.

# Returns
The filtered rows of `invoked`.
"""
function _generic_invocations(invoked, fixed)
    fixed_stamps = Set(zip(fixed.DUID, fixed.INTERVAL_DATETIME))
    return filter(invoked) do row
        id = row.GENCONID
        return !(startswith(id, "\$") && (id[2:end], row.SETTLEMENTDATE) in fixed_stamps)
    end
end

"""
    _check_constraint_versions(invoked, fixed, definitions)

Throws unless every generic constraint version invoked in `invoked` has an exact `GENCONDATA` definition
in `definitions` or a built-in zero-flow definition.

# Arguments
- `invoked`: the invoked constraint rows.
- `fixed`: the fixed-load rows, which separate out fixed-load constraints.
- `definitions`: the `GENCONDATA` definitions read for the invoked versions.

# Returns
`nothing`. Throws an `ArgumentError` listing each version without a definition.
"""
function _check_constraint_versions(invoked, fixed, definitions)
    generic = _generic_invocations(invoked, fixed)
    versions = unique(select(generic, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    undefined = _versions_without_definition(versions, definitions)
    builtins, _ = _zero_flow_constraint_definitions(undefined)
    missing = _versions_without_definition(undefined, builtins)
    isempty(missing) || throw(
        ArgumentError(
            "check_replay_inputs: missing exact GENCONDATA definitions: " * join(
                ("$(r.GENCONID)@$(r.GENCONID_EFFECTIVEDATE)#$(r.GENCONID_VERSIONNO)" for r in eachrow(missing)), ", "
            )
        )
    )
    return
end

"""
    check_replay_inputs(db, date_range; intervention = 0, template = template_nemde()) -> Nothing

Verifies, from the cache alone, that every MNSP has two directional links with offers at every interval
of `date_range` except its last, and, when `template` models `GenericConstraint`, that every interval has
`DISPATCHCONSTRAINT` rows and every invoked constraint version has an exact `GENCONDATA` definition. Runs
before any PSY component or time series is built.

# Arguments
- `db`: an `AEMDB` connection to the cache.
- `date_range`: the interval-ending `SETTLEMENTDATE`s the replay builds over, including the replay horizon.
- `intervention`: 0 for the pricing run, 1 for the physical run.
- `template`: the `PSI.ProblemTemplate` the replay builds.

# Returns
`nothing`. Throws an `ArgumentError` naming the first missing input.
"""
function check_replay_inputs(db, date_range; intervention::Integer = 0, template::PSI.ProblemTemplate = template_nemde())
    grid = collect(date_range)[1:(end - 1)]
    interconnectors = read_interconnectors(db; as_of = first(date_range))
    required = [r.INTERCONNECTORID for r in eachrow(interconnectors) if isequal(r.ICTYPE, "MNSP") && r.REGIONFROM != "SNOWY1" && r.REGIONTO != "SNOWY1"]
    if !isempty(required)
        _check_mnsp_coverage(read_mnsp_links(db, first(date_range)), read_mnsp_offers(db, date_range), required, grid)
    end
    if _has_service_model(template, GenericConstraint)
        invoked = read_invoked_constraints(db, date_range; intervention)
        missing_intervals = setdiff(grid, invoked.SETTLEMENTDATE)
        isempty(missing_intervals) || throw(ArgumentError("check_replay_inputs: missing DISPATCHCONSTRAINT intervals: $(first(missing_intervals))"))
        fixed = read_fixed_loads(db, date_range)
        generic = _generic_invocations(invoked, fixed)
        versions = unique(select(generic, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
        definitions = isempty(versions) ? _empty_definitions() : read_constraint_definitions(db, versions)
        _check_constraint_versions(invoked, fixed, definitions)
    end
    return
end
