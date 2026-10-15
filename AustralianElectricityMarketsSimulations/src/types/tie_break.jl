# One energy band in a tie-break group: its reference-node price, PSI block variable, unit name,
# segment index on the unit's offer curve and component type.
const _TieBand = @NamedTuple{price::Float64, var::JuMP.VariableRef, name::String, band::Int, type::DataType}


"""
    TieBreakScaleParameter

Constraint-coefficient parameter of one energy offer band's tie-break scale `w / w_ref`, the band's
width over the widest band of its price-tied group, read from the device's
`"tie_break_scale_<k>[_decremental]"` series ([`set_tie_break_scales!`](@ref)). In the tie-break row
of bands `a` and `b`, band `b`'s scale is the coefficient of `a`'s cleared MW and minus band `a`'s
scale that of `b`'s. Keyed by device type with meta `"<k>[_decremental]"`, `k` being the segment
index on the offer curve.
"""
struct TieBreakScaleParameter <: PSI.ConstraintCoefficientParameter end
