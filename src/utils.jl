"""
    _infer_resolution(grid) -> Dates.Period

Spacing between consecutive points of a sorted `grid`. Falls back to `Minute(5)` for fewer
than 2 points; warns and uses the smallest spacing if unequal.
"""
function _infer_resolution(grid::Vector{DateTime})
    length(grid) < 2 && return Minute(5)
    distinct = sort(unique(diff(grid)))
    if length(distinct) > 1
        @warn "grid spacing is not uniform (found $(join(distinct, ", "))); the stored series' fixed resolution will not match every SETTLEMENTDATE. Proceeding with the smallest spacing, $(first(distinct))."
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
