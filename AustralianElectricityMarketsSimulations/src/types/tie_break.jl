# One energy band in a tie-break group: its reference-node price, PSI block variable, unit name,
# segment index on the unit's offer curve and component type.
const _TieBand = @NamedTuple{price::Float64, var::JuMP.VariableRef, name::String, band::Int, type::DataType}


"""
    TieBreakScaleParameter

Constraint-coefficient parameter of one energy offer band's tie-break scale `w / w_ref`, the band's
width over the widest band of its price-tied group, read from the device's
`"tie_break_scale_<k>[_decremental]"` series ([`AustralianElectricityMarkets.set_tie_break_scales!`](@ref)). In the tie-break row
of bands `a` and `b`, band `b`'s scale is the coefficient of `a`'s cleared MW and minus band `a`'s
scale that of `b`'s. Keyed by device type with meta `"<k>[_decremental]"`, `k` being the segment
index on the offer curve.
"""
struct TieBreakScaleParameter <: PSI.ConstraintCoefficientParameter end


"""
    TieBreakMarket

Formulation for an [`EnergyTieBreak`](@ref): one elastic row per pair of price-tied energy bands of
different contributing units, dispatching the bands of a tie group in proportion to their size.
"""
struct TieBreakMarket <: PSI.AbstractServiceFormulation end


"""
    TieBreakSlackUp

Variable type for the upward slack of a tie-break row, in system-base per-unit MW, keyed
`(label, pair, t)` with `label` the region and direction (`"<region>_offer"` or `"<region>_bid"`)
and `pair` the row's index among that label's rows at time step `t`.
"""
struct TieBreakSlackUp <: PSI.SparseVariableType end


"""
    TieBreakSlackDown

Variable type for the downward slack of a tie-break row, keyed like [`TieBreakSlackUp`](@ref).
"""
struct TieBreakSlackDown <: PSI.SparseVariableType end


function PSI.should_write_resulting_value(::Type{TieBreakSlackUp})
    return false
end

function PSI.should_write_resulting_value(::Type{TieBreakSlackDown})
    return false
end


"""
    TieBreakConstraint

Constraint type of the tie-break rows `s_b x_a - s_a x_b + up - down = 0`, in a sparse container
keyed like [`TieBreakSlackUp`](@ref).
"""
struct TieBreakConstraint <: PSI.ConstraintType end
