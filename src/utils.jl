"""
    _infer_resolution(grid) -> Dates.Period

Spacing between consecutive points of a sorted `grid`. Throws `ArgumentError` for fewer than
2 points or for unequal spacings, naming the distinct spacings found.
"""
function _infer_resolution(grid::Vector{DateTime})
    length(grid) < 2 && throw(
        ArgumentError("cannot infer a resolution from $(length(grid)) point(s); at least 2 are needed"),
    )
    distinct = sort(unique(diff(grid)))
    length(distinct) > 1 && throw(
        ArgumentError(
            "grid spacing is not uniform: found $(join(_canonical_period.(distinct), ", ")); " *
                "the resolution is ambiguous",
        ),
    )
    return _canonical_period(only(distinct))
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
