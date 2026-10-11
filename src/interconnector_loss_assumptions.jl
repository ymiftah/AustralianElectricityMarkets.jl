const _INTERCONNECTOR_LOSS_REPORTS = Dict(
    2024 => (
        url = "https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2024-25-financial-year/mlfs-for-the-2024-25-financial-year.pdf?la=en",
        sections = "§3 pp. 54-57; §4 p. 58; §5.1 p. 61",
    ),
    2025 => (
        url = "https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2025-26-marginal-loss-factors/marginal-loss-factors-for-the-2025-26-fin-year.pdf?la=en",
        sections = "§3 p. 56 footnote 11, Table 25 p. 59; §4 p. 60; §5.1 p. 63",
    ),
    2026 => (
        url = "https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2026-27/marginal-loss-factors-for-the-2026-27-financial-year.pdf",
        sections = "§3-4 pp. 57-70; §5.1 pp. 71-74; Appendix A2.5.2 pp. 95-96",
    ),
)

# Corrections require both source versions and the remaining published equation to match.
const _INTERCONNECTOR_DEMAND_CORRECTIONS = (
    (
        id = "vsa_nsw_demand_fy2025_26",
        interconnector = "V-SA", region = "NSW1", value = 1.6981e-6,
        valid_from = Date(2025, 7, 1), valid_until = Date(2026, 7, 1),
        effective_date = DateTime(2025, 7, 1), version_no = 1,
        loss_constant = 0.9721, loss_flow_coefficient = 0.00026801,
        demand_coefficients = Dict("VIC1" => -1.4896e-5, "SA1" => 5.108e-5),
        source = _INTERCONNECTOR_LOSS_REPORTS[2025].url,
        location = "§3 p. 56 footnote 11; Table 25 p. 59",
        reason = "Audited July 2025 and June 2026 LOSSFACTORMODEL archives omit the report's NSW1 term.",
    ),
)

# The static Basslink share is a nempy replication fallback when no directional offers are attached.
const _LOSS_SHARE_OVERRIDES = Dict("T-V-MNSP1" => 1.0)
const _STATIC_LOSS_SHARE_SOURCE = "https://nempy.readthedocs.io/en/latest/historical.html#nempy.historical_inputs.interconnectors.InterconnectorData.get_interconnector_definitions"
const _INTERCONNECTOR_LOSS_DEFAULTS = (
    from_region_loss_share = 0.5, loss_constant = 1.0, loss_flow_coefficient = 0.0,
)

"""
    interconnector_loss_assumptions(as_of) -> NamedTuple

Returns the annual report, candidate demand-term corrections and dispatch loss conventions for
`as_of`. Corrections additionally require matching source versions and coefficients during assembly.

# Arguments
- `as_of`: A `Date` or `DateTime` in NEM market time.

# Returns
`financial_year` (starting year), `report` (`url`, `sections`, or `nothing` for an unregistered
year), `corrections`, `curve_reference`, and `directional_allocation`. Mutable records are copied.
"""
function interconnector_loss_assumptions(as_of::Union{Date, DateTime})
    date = Date(as_of)
    financial_year = year(date) - (month(date) < 7)
    corrections = filter(c -> c.valid_from <= date < c.valid_until, _INTERCONNECTOR_DEMAND_CORRECTIONS)
    return (
        financial_year = financial_year,
        report = get(_INTERCONNECTOR_LOSS_REPORTS, financial_year, nothing),
        corrections = deepcopy(corrections),
        curve_reference = :zero_flow,
        directional_allocation = :sending_terminal,
    )
end

"""
    loss_curve_vertex_values(model, demand) -> Vector{Float64}

Returns dispatch loss vertices at `model.breakpoints`, subtracting the interpolated zero-flow
value when a chord strictly brackets zero. One-sided ranges retain their analytic anchoring.

# Arguments
- `model`: An [`InterconnectorLossModel`](@ref).
- `demand`: Regional demand values in the same units as `model`.

# Returns
Vertex losses in `model`'s units, with the slopes from [`loss_segments`](@ref) preserved.
"""
function loss_curve_vertex_values(model::InterconnectorLossModel, demand::AbstractDict)
    breakpoints = model.breakpoints
    values = [interconnector_losses(model, bp, demand) for bp in breakpoints]
    crossing = findfirst(i -> breakpoints[i] < 0.0 < breakpoints[i + 1], 1:(length(breakpoints) - 1))
    isnothing(crossing) && return values

    a, z = breakpoints[crossing:(crossing + 1)]
    offset = -model.loss_flow_coefficient * a * z / 2
    return values .- offset
end

"""
    interconnector_loss_allocation(model; directional_offers=false) -> Symbol

Returns the regional allocation convention for `model`: static sharing, or sending-terminal
allocation when paired directional MNSP offers are attached.

# Arguments
- `model`: An [`InterconnectorLossModel`](@ref).
- `directional_offers`: Whether both directional offers and availability series are present.

# Returns
`:static_share` uses `model.from_region_loss_share`; `:sending_terminal` supplies DC losses at
the active sending terminal, referred to its region using the directional terminal loss factor.
"""
function interconnector_loss_allocation(model::InterconnectorLossModel; directional_offers::Bool = false)
    return directional_offers ? :sending_terminal : :static_share
end

"""
    get_loss_model_provenance(model) -> Dict{String, Any}

Returns a copy of the selected MMSDM source versions, report references, applied corrections and
fallback assumptions recorded when `model` was assembled.

# Arguments
- `model`: An [`InterconnectorLossModel`](@ref).

# Returns
Source metadata, or an empty dictionary for a model constructed without recorded provenance.
"""
function get_loss_model_provenance(model::InterconnectorLossModel)
    return deepcopy(get(IS.get_ext(model.internal), "loss_model_provenance", Dict{String, Any}()))
end

function _matches_loss_source(row, correction)
    return !ismissing(row.EFFECTIVEDATE) && !ismissing(row.VERSIONNO) &&
        DateTime(row.EFFECTIVEDATE) == correction.effective_date && row.VERSIONNO == correction.version_no
end

function _matches_loss_equation(param, coefficients, correction)
    _matches_loss_source(param, correction) || return false
    for (column, expected) in ((:LOSSCONSTANT, correction.loss_constant), (:LOSSFLOWCOEFFICIENT, correction.loss_flow_coefficient))
        value = getproperty(param, column)
        ismissing(value) && return false
        isapprox(value, expected; atol = 1.0e-12, rtol = 0.0) || return false
    end
    return all(
        haskey(coefficients, region) && isapprox(coefficients[region], value; atol = 1.0e-12, rtol = 0.0)
            for (region, value) in correction.demand_coefficients
    )
end

function _resolve_interconnector_demand_coefficients(coefficients, params, as_of::Union{Date, DateTime})
    demand_coefficients = Dict{String, Dict{String, Float64}}()
    for row in eachrow(coefficients)
        d = get!(demand_coefficients, row.INTERCONNECTORID, Dict{String, Float64}())
        d[row.REGIONID] = row.DEMANDCOEFFICIENT
    end
    applied = Dict{String, Vector{Dict{String, Any}}}()
    for correction in interconnector_loss_assumptions(as_of).corrections
        id = correction.interconnector
        terms = get(demand_coefficients, id, Dict{String, Float64}())
        haskey(terms, correction.region) && continue
        selected_params = @chain params begin
            filter(:INTERCONNECTORID => ==(id), _)
        end
        nrow(selected_params) == 1 || continue
        _matches_loss_equation(only(eachrow(selected_params)), terms, correction) || continue
        selected_coefficients = @chain coefficients begin
            filter(:INTERCONNECTORID => ==(id), _)
        end
        all(row -> _matches_loss_source(row, correction), eachrow(selected_coefficients)) || continue
        terms[correction.region] = correction.value
        push!(
            get!(applied, id, Dict{String, Any}[]),
            Dict{String, Any}(
                "id" => correction.id, "region" => correction.region, "value" => correction.value,
                "valid_from" => string(correction.valid_from), "valid_until" => string(correction.valid_until),
                "source" => correction.source, "location" => correction.location, "reason" => correction.reason,
            ),
        )
    end
    return demand_coefficients, applied
end

function _interconnector_demand_coefficients_by_id(coefficients, params, as_of::Union{Date, DateTime})
    resolved, _ = _resolve_interconnector_demand_coefficients(coefficients, params, as_of)
    return resolved
end

function _loss_source_version(rows, id)
    selected = @chain rows begin
        filter(:INTERCONNECTORID => ==(id), _)
    end
    isempty(selected) && return nothing
    row = first(eachrow(selected))
    return Dict{String, Any}("effective_date" => string(row.EFFECTIVEDATE), "version_no" => row.VERSIONNO)
end

function _record_loss_model_provenance!(model, as_of, params, coefficients, breakpoints, corrections)
    assumptions = interconnector_loss_assumptions(as_of)
    id = model.interconnector
    report = assumptions.report
    fallbacks = String[]
    if haskey(_LOSS_SHARE_OVERRIDES, id)
        push!(fallbacks, "Static loss share $(model.from_region_loss_share) from nempy: $_STATIC_LOSS_SHARE_SOURCE")
    end
    param = only(eachrow(filter(:INTERCONNECTORID => ==(id), params)))
    defaults = _INTERCONNECTOR_LOSS_DEFAULTS
    for (column, default) in (
            (:FROMREGIONLOSSSHARE, defaults.from_region_loss_share),
            (:LOSSCONSTANT, defaults.loss_constant), (:LOSSFLOWCOEFFICIENT, defaults.loss_flow_coefficient),
        )
        column == :FROMREGIONLOSSSHARE && haskey(_LOSS_SHARE_OVERRIDES, id) && continue
        ismissing(getproperty(param, column)) && push!(fallbacks, "Missing $column defaults to $default")
    end
    IS.get_ext(model.internal)["loss_model_provenance"] = Dict{String, Any}(
        "interconnector" => id, "as_of" => string(as_of), "financial_year" => assumptions.financial_year,
        "report" => isnothing(report) ? nothing : Dict("url" => report.url, "sections" => report.sections),
        "data_model" => "https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/",
        "region_source" => "Newest cached INTERCONNECTOR partition",
        "tables" => Dict(
            "INTERCONNECTORCONSTRAINT" => _loss_source_version(params, id),
            "LOSSFACTORMODEL" => _loss_source_version(coefficients, id),
            "LOSSMODEL" => _loss_source_version(breakpoints, id),
        ),
        "corrections" => get(corrections, id, Dict{String, Any}[]),
        "curve_reference" => string(assumptions.curve_reference),
        "directional_allocation" => string(assumptions.directional_allocation),
        "fallbacks" => fallbacks,
    )
    return
end
