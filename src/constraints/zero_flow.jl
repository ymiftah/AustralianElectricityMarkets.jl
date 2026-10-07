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
# CVP factor of the Unit and Interconnector Zero constraint type, applied to the Market Price Cap.
const _ZERO_FLOW_CVP_FACTOR = 1160.0

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
        GENERICCONSTRAINTWEIGHT = fill(_ZERO_FLOW_CVP_FACTOR, nrow(recognised)),
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
