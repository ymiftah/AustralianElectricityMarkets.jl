"""
    TIE_BREAK_CVP_FACTOR

Constraint violation penalty factor (1e-6) of AEMO's tie-break constraint (`TBSlack1` and
`TBSlack2`, item 53 of the *Schedule of Constraint Violation Penalty Factors* v8.0). It is also
the price tolerance, in `\$/MWh` after loss-factor adjustment, within which two energy bands are
price-tied.
"""
const TIE_BREAK_CVP_FACTOR = 1.0e-6

# Build-time value of a bid slope or breakpoint, which is a parameter reference when the offers
# are time-variant. Recurrent solves leave the parameter unfixed and are rejected.
_is_fixed(x::Number) = true
_is_fixed(x::JuMP.VariableRef) = JuMP.is_fixed(x)
_is_fixed(x::JuMP.AffExpr) = all(_is_fixed(v) for (_, v) in JuMP.linear_terms(x))

function _fixed_value(x)
    _is_fixed(x) || throw(
        ArgumentError("tie-break: bid data must be fixed at build, as in a standalone `DecisionModel`"),
    )
    return Float64(PSI.jump_fixed_value(x))
end

# One energy band of a device at a time step: its price at the reference node in $/MWh, its
# width in system-base per-unit and its PSI block variable.
const _TieBand = @NamedTuple{price::Float64, width::Float64, var::JuMP.VariableRef, name::String, band::Int}

# Bands of every PSI market-bid block variable in `container`, grouped by
# (direction, region, time step).
function _tie_break_bands(container::PSI.OptimizationContainer, sys::PSY.System)
    groups = Dict{Tuple{Bool, String, Int}, Vector{_TieBand}}()
    base_power = PSI.get_base_power(container)
    for (key, variables) in PSI.get_variables(container)
        entry = PSI.IS.Optimization.get_entry_type(key)
        decremental = entry === PSI.PiecewiseLinearBlockDecrementalOffer
        (decremental || entry === PSI.PiecewiseLinearBlockIncrementalOffer) || continue
        T = PSI.IS.Optimization.get_component_type(key)
        by_device = Dict{Tuple{String, Int}, Vector{Tuple{Int, JuMP.VariableRef}}}()
        for ((name, band, t), var) in pairs(variables.data)
            push!(get!(by_device, (name, t), Tuple{Int, JuMP.VariableRef}[]), (band, var))
        end
        for ((name, t), bands) in by_device
            device = PSY.get_component(T, sys, name)
            region = PSY.get_name(PSY.get_area(PSY.get_bus(device)))
            breakpoints, slopes = PSI._get_pwl_data(decremental, container, device, t)
            for (band, var) in bands
                width = _fixed_value(breakpoints[band + 1]) - _fixed_value(breakpoints[band])
                push!(
                    get!(groups, (decremental, region, t), _TieBand[]),
                    (; price = _fixed_value(slopes[band]) / base_power, width, var, name, band),
                )
            end
        end
    end
    return groups
end

# Index pairs (i, j) of bands of different units that are price-tied. Bands are tied when
# consecutive sorted prices differ by at most `TIE_BREAK_CVP_FACTOR`, so a run of bands each within
# the tolerance of the next ties transitively. Zero-width bands are ignored.
function _tied_pairs(bands)
    order = sort!(
        [i for i in eachindex(bands) if bands[i].width > 1.0e-9];
        by = i -> (bands[i].price, bands[i].name, bands[i].band),
    )
    pairs = Tuple{Int, Int}[]
    start = 1
    for k in 1:length(order)
        if k == length(order) || bands[order[k + 1]].price - bands[order[k]].price > TIE_BREAK_CVP_FACTOR
            group = order[start:k]
            for a in 1:(length(group) - 1), b in (a + 1):length(group)
                bands[group[a]].name == bands[group[b]].name || push!(pairs, (group[a], group[b]))
            end
            start = k + 1
        end
    end
    return pairs
end

"""
    add_tie_break_constraints!(container, sys)

Dispatches price-tied energy bands in proportion to their size. Within each region, direction
(offer or load bid) and time step, bands whose prices at the reference node are within
[`TIE_BREAK_CVP_FACTOR`](@ref) of one another form a tie group, and every pair of bands of
different units in a group is constrained to equal fill fractions (cleared MW divided by band MW).
Each pair carries an up and a down slack on the fill fraction, priced at
[`TIE_BREAK_CVP_FACTOR`](@ref) in `\$` per dispatch interval, so a band held back by a ramp or
availability limit relaxes its pairs instead of changing the dispatch of other units. FCAS bands
are not tied, and bands of zero width are ignored. Reads the band prices and widths the market-bid
objective was built from, so it must run after every device model's objective, and it requires
bid data fixed at build. The slack penalty is below default MIP gap tolerances, so a model with
binary variables solved with default optimizer gaps may ignore ties.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` holding the built bid variables.
- `sys`: the `PowerSystems.System` the container was built from.

# Returns
The number of pairs added, as an `Int`.
"""
function add_tie_break_constraints!(container::PSI.OptimizationContainer, sys::PSY.System)
    jm = PSI.get_jump_model(container)
    coefficient = interval_cost_coefficient(TIE_BREAK_CVP_FACTOR, PSI.get_resolution(container))
    links = 0
    for ((decremental, region, t), bands) in _tie_break_bands(container, sys)
        for (i, j) in _tied_pairs(bands)
            a, b = bands[i], bands[j]
            up = JuMP.@variable(jm, base_name = "TieBreakSlackUp_{$region,$t,$links}", lower_bound = 0.0)
            down = JuMP.@variable(jm, base_name = "TieBreakSlackDown_{$region,$t,$links}", lower_bound = 0.0)
            JuMP.@constraint(jm, a.var / a.width - b.var / b.width + up - down == 0.0)
            PSI.add_to_objective_invariant_expression!(container, coefficient * (up + down))
            links += 1
        end
    end
    return links
end
