# Pairs `(name_a, band_a, name_b, band_b)` of price-tied bands of different units at stamp `i`.
function _tie_break_pairs(offers, i::Int)
    bands = _tie_break_stamp_bands(offers, i)
    pairs = Set{Tuple{String, Int, String, Int}}()
    for group in _tie_groups(bands), x in 1:(length(group) - 1), y in (x + 1):length(group)
        a, b = bands[group[x]], bands[group[y]]
        a.name == b.name || push!(pairs, (a.name, a.band, b.name, b.band))
    end
    return pairs
end


"""
    check_tie_break_pairs(sys, steps)

Verifies that the price-tied energy band pairs of `sys` ([`add_tie_break_constraints!`](@ref)) are
the same at every interval of `steps`, for every region and direction, as a model built once and
stepped through `steps` requires. Band prices change only between trading days, so a range inside
one trading day passes.

# Arguments
- `sys`: the system whose offer curves are checked.
- `steps`: the interval timestamps of the simulation.

# Returns
`nothing`. Throws `ArgumentError` naming the first interval whose pairs differ and up to five of
the differing pairs, or a step that is not on a region's offer curve timestamps.
"""
function check_tie_break_pairs(sys::PSY.System, steps)
    for ((decremental, region), (; stamps, offers)) in _tie_break_offers(sys)
        index = Dict(s => i for (i, s) in enumerate(stamps))
        position(t) = get(
            () -> throw(ArgumentError("tie-break: interval $t is not on the offer curve timestamps of region $region.")),
            index, t,
        )
        reference = _tie_break_pairs(offers, position(first(steps)))
        for t in Iterators.drop(steps, 1)
            pairs = _tie_break_pairs(offers, position(t))
            pairs == reference && continue
            changed = first(sort!(collect(symdiff(pairs, reference))), 5)
            throw(
                ArgumentError(
                    "tie-break: the price-tied $(decremental ? "load bid" : "offer") bands of region $region at $t " *
                        "differ from those at $(first(steps)), e.g. $(join(changed, ", ")). Band prices change " *
                        "between trading days; start the range at the first interval of a trading day (04:05).",
                ),
            )
        end
    end
    return
end
