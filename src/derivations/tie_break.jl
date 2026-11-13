"""
    tie_break_scale(width::Float64, reference_width::Float64)::Float64

The tie-break scale of a price-tied energy band: its `width` over the widest band of its tie group,
`reference_width`, and zero when the group has no width.

# Arguments
- `width`: the band's MW width at the interval.
- `reference_width`: the widest band width in the tie group at the interval.

# Returns
A `Float64`.
"""
tie_break_scale(width::Float64, reference_width::Float64)::Float64 = reference_width > 0.0 ? width / reference_width : 0.0


"""
    tie_groups(bands) -> Vector{Vector{Int}}

Price-tied groups of `bands` (each with `price`, `name` and `band`): runs of the bands sorted by
price whose consecutive prices differ by at most [`TIE_BREAK_CVP_FACTOR`](@ref), kept when they
hold bands of two or more units. Each group lists indices into `bands` in sorted order. Throws an
`ArgumentError` for a run spanning more than [`TIE_BREAK_CVP_FACTOR`](@ref), which only
transitive ties produce.

# Returns
`Vector{Vector{Int}}`.
"""
function tie_groups(bands)
    order = sort!(collect(eachindex(bands)); by = i -> (bands[i].price, bands[i].name, bands[i].band))
    groups = Vector{Int}[]
    start = 1
    for k in eachindex(order)
        (k == length(order) || bands[order[k + 1]].price - bands[order[k]].price > TIE_BREAK_CVP_FACTOR) || continue
        group = order[start:k]
        start = k + 1
        lo, hi = bands[first(group)], bands[last(group)]
        hi.price - lo.price > TIE_BREAK_CVP_FACTOR && throw(
            ArgumentError(
                "tie-break: the prices of $(lo.name) band $(lo.band) ($(lo.price)) and $(hi.name) band $(hi.band) " *
                    "($(hi.price)) are tied only through bands between them; transitive ties are not supported.",
            ),
        )
        length(unique(bands[i].name for i in group)) > 1 && push!(groups, group)
    end
    return groups
end
