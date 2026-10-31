# Pairs `(name_a, band_a, name_b, band_b)` of price-tied bands of different units at stamp `i`, the
# `(name, band)` of `a` ordered before that of `b`.
function _tie_break_pairs(offers, i::Int, active, decremental::Bool)
    bands = _tie_break_stamp_bands(offers, i, active, decremental)
    pairs = Set{Tuple{String, Int, String, Int}}()
    for group in tie_groups(bands), x in 1:(length(group) - 1), y in (x + 1):length(group)
        a, b = bands[group[x]], bands[group[y]]
        a.name == b.name && continue
        lo, hi = minmax((a.name, a.band), (b.name, b.band))
        push!(pairs, (lo..., hi...))
    end
    return pairs
end


# Pair membership depends on active prices, not the widths used to scale the tie-break rows.
function _tie_break_prices_unchanged(offers, i::Int, reference::Int, active, decremental::Bool)
    for (device, curves) in offers
        current = PSY.get_y_coords(curves[i])
        initial = PSY.get_y_coords(curves[reference])
        length(current) == length(initial) || return false
        for k in get(active, (decremental, PSY.get_name(device)), ())
            k <= length(current) || continue
            current[k] == initial[k] || return false
        end
    end
    return true
end


"""
    check_tie_break_pairs(sys, steps)

Verifies that the price-tied energy band pairs of `sys` ([`TieBreakMarket`](@ref)) are
the same at every interval of `steps`, for every region and direction, as a model built once and
stepped through `steps` requires. Band prices change only between trading days, so a range inside
one trading day passes. Unchanged active-band prices and band counts reuse the first interval's
pair set; other intervals retain the full pair comparison.

# Arguments
- `sys`: the system whose offer curves are checked.
- `steps`: the interval timestamps the simulation solves, including the lookahead timestamps when
  its horizon is longer than one interval.

# Returns
`nothing`. Throws `ArgumentError` naming the first interval whose pairs differ and up to five of
the differing pairs, or a step that is not on a region's offer curve timestamps.
"""
function check_tie_break_pairs(sys::PSY.System, steps)
    all_offers = _tie_break_offers(sys)
    active = _tie_break_active_bands(all_offers)
    for ((decremental, region), (; stamps, offers)) in all_offers
        index = Dict(s => i for (i, s) in enumerate(stamps))
        position(t) = get(
            () -> throw(ArgumentError("tie-break: interval $t is not on the offer curve timestamps of region $region.")),
            index, t,
        )
        reference_index = position(first(steps))
        reference = _tie_break_pairs(offers, reference_index, active, decremental)
        for t in Iterators.drop(steps, 1)
            i = position(t)
            _tie_break_prices_unchanged(offers, i, reference_index, active, decremental) && continue
            pairs = _tie_break_pairs(offers, i, active, decremental)
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
