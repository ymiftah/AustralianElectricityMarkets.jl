"""
    TIE_BREAK_CVP_FACTOR

Constraint violation penalty factor (1e-6) of AEMO's tie-break constraint (`TBSlack1` and
`TBSlack2`, item 53 of the *Schedule of Constraint Violation Penalty Factors* v8.0). It is also
the price tolerance, in `\$/MWh` after loss-factor adjustment, within which two energy bands are
price-tied.
"""
const TIE_BREAK_CVP_FACTOR = 1.0e-6

_fixed_value(x::Real) = Float64(x)
_fixed_value(x) = JuMP.value(x)

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

"""
    add_tie_break_constraints!(container, sys)

Dispatches price-tied energy bands in proportion to their size. Within each region, direction
(offer or load bid) and time step, bands whose prices at the reference node are within
[`TIE_BREAK_CVP_FACTOR`](@ref) of one another form a tie group, and consecutive bands of a group
are constrained to equal fill fractions (cleared MW divided by band MW). Each link carries an
up and a down slack priced at [`TIE_BREAK_CVP_FACTOR`](@ref) per unit of fill fraction in `\$`
per dispatch interval per MW of system base, so a band held back by a ramp or availability limit
relaxes the link instead of changing the dispatch of other units. Bands of zero width are
ignored, and FCAS bands are not tied. Reads the band prices and widths the market-bid objective
was built from, so it must run after every device model's objective.

# Arguments
- `container`: the `PowerSimulations.OptimizationContainer` holding the built bid variables.
- `sys`: the `PowerSystems.System` the container was built from.

# Returns
The number of links added, as an `Int`.
"""
function add_tie_break_constraints!(container::PSI.OptimizationContainer, sys::PSY.System)
    jm = PSI.get_jump_model(container)
    resolution = PSI.get_resolution(container)
    coefficient = PSI.get_base_power(container) * interval_cost_coefficient(TIE_BREAK_CVP_FACTOR, resolution)
    links = 0
    for ((decremental, region, t), bands) in _tie_break_bands(container, sys)
        bands = sort!(filter(b -> b.width > 1.0e-9, bands); by = b -> (b.price, b.name, b.band))
        for k in 2:length(bands)
            a, b = bands[k - 1], bands[k]
            b.price - a.price <= TIE_BREAK_CVP_FACTOR || continue
            up = JuMP.@variable(jm, base_name = "TieBreakSlackUp_{$region,$t,$links}", lower_bound = 0.0)
            down = JuMP.@variable(jm, base_name = "TieBreakSlackDown_{$region,$t,$links}", lower_bound = 0.0)
            JuMP.@constraint(jm, a.var / a.width - b.var / b.width + up - down == 0.0)
            PSI.add_to_objective_invariant_expression!(container, coefficient * (up + down))
            links += 1
        end
    end
    return links
end
