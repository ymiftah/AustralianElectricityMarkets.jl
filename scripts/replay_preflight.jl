# Data-only checks run before constructing any PSY components or HDF5 time series.
function _check_mnsp_coverage(links, offers, required, grid)
    for name in required
        group = links[links.INTERCONNECTORID .== name, :]
        nrow(group) == 2 && length(unique(group.LINKID)) == 2 || throw(
            ArgumentError("preflight: MNSP $name requires two distinct directional links")
        )
        for link in group.LINKID
            stamps = sort(offers[offers.LINKID .== link, :INTERVAL_DATETIME])
            stamps == grid || throw(
                ArgumentError(
                    "preflight: MNSP $name link $link has $(length(stamps)) joined offers for $(length(grid)) intervals " *
                        "from $(first(grid)) to $(last(grid)); check DISPATCH_MNSPBIDTRK and its referenced MNSP_DAYOFFER/MNSP_BIDOFFERPERIOD versions"
                )
            )
        end
    end
    return
end

function _generic_invocations(invoked, fixed)
    fixed_stamps = Set(zip(fixed.DUID, fixed.INTERVAL_DATETIME))
    return filter(invoked) do row
        id = row.GENCONID
        return !(startswith(id, "\$") && (id[2:end], row.SETTLEMENTDATE) in fixed_stamps)
    end
end

function _check_constraint_versions(invoked, fixed, definitions)
    generic = _generic_invocations(invoked, fixed)
    versions = unique(select(generic, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
    undefined = AustralianElectricityMarkets._versions_without_definition(versions, definitions)
    builtins, _ = AustralianElectricityMarkets._zero_flow_constraint_definitions(undefined)
    missing = AustralianElectricityMarkets._versions_without_definition(undefined, builtins)
    isempty(missing) || throw(
        ArgumentError(
            "preflight: missing exact GENCONDATA definitions: " * join(
                ("$(r.GENCONID)@$(r.GENCONID_EFFECTIVEDATE)#$(r.GENCONID_VERSIONNO)" for r in eachrow(missing)), ", "
            )
        )
    )
    return
end

function _preflight_inputs(db, date_range; intervention = 0, parts = REPLICATION_PARTS)
    grid = collect(date_range)[1:(end - 1)]
    interconnectors = read_interconnectors(db; as_of = first(date_range))
    required = [r.INTERCONNECTORID for r in eachrow(interconnectors) if isequal(r.ICTYPE, "MNSP") && r.REGIONFROM != "SNOWY1" && r.REGIONTO != "SNOWY1"]
    if !isempty(required)
        _check_mnsp_coverage(read_mnsp_links(db, first(date_range)), read_mnsp_offers(db, date_range), required, grid)
    end
    if :generic_constraints in parts
        invoked = read_invoked_constraints(db, date_range; intervention)
        missing_intervals = setdiff(grid, invoked.SETTLEMENTDATE)
        isempty(missing_intervals) || throw(ArgumentError("preflight: missing DISPATCHCONSTRAINT intervals: $(first(missing_intervals))"))
        fixed = read_fixed_loads(db, date_range)
        generic = _generic_invocations(invoked, fixed)
        versions = unique(select(generic, :GENCONID, :GENCONID_EFFECTIVEDATE, :GENCONID_VERSIONNO))
        definitions = isempty(versions) ? AustralianElectricityMarkets._empty_definitions() : read_constraint_definitions(db, versions)
        _check_constraint_versions(invoked, fixed, definitions)
    end
    return
end
