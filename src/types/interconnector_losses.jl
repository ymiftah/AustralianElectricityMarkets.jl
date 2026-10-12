"""
    InterconnectorLossModel

One interconnector's NEMDE loss model, resolved to a single `EFFECTIVEDATE`/`VERSIONNO`.

NEMDE treats interconnector losses as a quadratic in flow whose linear coefficient shifts with
regional demand: the *loss factor* at flow `f` is

```
lf(f) = loss_constant + loss_flow_coefficient * f + Σ_r demand_coefficients[r] * demand[r]
```

and the losses themselves are the integral of `lf(f) - 1` over `[0, f]` — see
[`interconnector_losses`](@ref). `MWBREAKPOINT` (`LOSSMODEL`) supplies the breakpoints NEMDE
linearises that quadratic on, reproduced by [`loss_segments`](@ref).

# Fields
- `interconnector`: `INTERCONNECTORID`.
- `from_region`/`to_region`: `REGIONFROM`/`REGIONTO`; flow is positive from → to.
- `from_region_loss_share`: fraction of losses attributed to `from_region`.
- `loss_constant`: `LOSSCONSTANT`.
- `loss_flow_coefficient`: `LOSSFLOWCOEFFICIENT`, natural-units MW unless the model has been
  per-unitized (see [`attach_interconnector_losses!`](@ref)).
- `demand_coefficients`: `REGIONID => DEMANDCOEFFICIENT`, same units convention as
  `loss_flow_coefficient`.
- `breakpoints`: `MWBREAKPOINT` values, ascending, same units convention as
  `loss_flow_coefficient`.
- `internal`: `InfrastructureSystems` bookkeeping.

A model returned by [`interconnector_loss_models`](@ref) carries natural-units MW throughout;
one attached to a `System` by [`attach_interconnector_losses!`](@ref) is per-unit of that
`System`'s base power instead. [`loss_factor`](@ref)/[`interconnector_losses`](@ref)/
[`loss_segments`](@ref) are unit-agnostic - `flow`/`demand` must be passed in whichever
convention `model` itself uses.
"""
struct InterconnectorLossModel <: PSY.SupplementalAttribute
    interconnector::String
    from_region::String
    to_region::String
    from_region_loss_share::Float64
    loss_constant::Float64
    loss_flow_coefficient::Float64
    demand_coefficients::Dict{String, Float64}
    breakpoints::Vector{Float64}
    internal::IS.InfrastructureSystemsInternal
end


function InterconnectorLossModel(;
        interconnector::AbstractString,
        from_region::AbstractString,
        to_region::AbstractString,
        from_region_loss_share::Real,
        loss_constant::Real,
        loss_flow_coefficient::Real,
        demand_coefficients::AbstractDict,
        breakpoints::AbstractVector,
        internal::IS.InfrastructureSystemsInternal = IS.InfrastructureSystemsInternal(),
    )
    # JSON round-trips deliver demand_coefficients as Dict{String, Any} (JSON.jl doesn't know
    # the value type), hence the coercion here rather than a Dict{String, Float64} annotation.
    return InterconnectorLossModel(
        String(interconnector),
        String(from_region),
        String(to_region),
        Float64(from_region_loss_share),
        Float64(loss_constant),
        Float64(loss_flow_coefficient),
        Dict{String, Float64}(String(k) => Float64(v) for (k, v) in demand_coefficients),
        Float64.(breakpoints),
        internal,
    )
end


IS.get_internal(model::InterconnectorLossModel) = model.internal


"""
    loss_factor(model, flow, demand) -> Float64

`model`'s loss factor at `flow` MW, given `demand` (`REGIONID => MW`). A region in
`model.demand_coefficients` but absent from `demand` contributes nothing.
"""
function loss_factor(model::InterconnectorLossModel, flow::Real, demand::AbstractDict)
    offset = sum(
        (c * get(demand, r, 0.0) for (r, c) in model.demand_coefficients);
        init = 0.0,
    )
    return model.loss_constant + model.loss_flow_coefficient * flow + offset
end


"""
    interconnector_losses(model, flow, demand) -> Float64

MW lost on `model` at `flow`, the integral of `loss_factor(model, f, demand) - 1` over
`[0, flow]`:

```
(loss_constant - 1 + Σ_r demand_coefficients[r] * demand[r]) * flow
    + 0.5 * loss_flow_coefficient * flow^2
```

`LOSSCONSTANT` is a loss *factor* quoted relative to unity, hence the `- 1`.
"""
function interconnector_losses(model::InterconnectorLossModel, flow::Real, demand::AbstractDict)
    linear = loss_factor(model, 0.0, demand) - 1.0
    return linear * flow + 0.5 * model.loss_flow_coefficient * flow^2
end


"""
    loss_segments(model, demand) -> Vector{NamedTuple}

`model`'s quadratic loss curve linearised on its own `MWBREAKPOINT`s, as
`(; from_mw, to_mw, slope)` per segment, ascending. `slope` is the average MW of loss per MW of
flow across the segment — the chord of [`interconnector_losses`](@ref), which is exact at every
breakpoint and is what NEMDE's LP sees.

Throws `ArgumentError` when `model` carries fewer than two breakpoints or has duplicate adjacent breakpoints.
"""
function loss_segments(model::InterconnectorLossModel, demand::AbstractDict)
    length(model.breakpoints) < 2 && throw(
        ArgumentError(
            "interconnector $(model.interconnector) has $(length(model.breakpoints)) loss " *
                "breakpoint(s); at least 2 are needed to define a segment. Run " *
                "`populate(db, :LOSSMODEL, <from>, <to>)` and check the effective date.",
        ),
    )
    bps = model.breakpoints
    any(bps[i] == bps[i + 1] for i in 1:(length(bps) - 1)) && throw(
        ArgumentError(
            "interconnector $(model.interconnector) has duplicate adjacent loss breakpoints " *
                "$(bps) - cannot compute a segment slope. Check LOSSMODEL for the affected " *
                "EFFECTIVEDATE/VERSIONNO.",
        ),
    )
    return [
        (
            from_mw = bps[i],
            to_mw = bps[i + 1],
            slope = (
                interconnector_losses(model, bps[i + 1], demand) -
                    interconnector_losses(model, bps[i], demand)
            ) / (bps[i + 1] - bps[i]),
        )
            for i in 1:(length(bps) - 1)
    ]
end


"""
    _to_pu(model::InterconnectorLossModel, base_power::Real) -> InterconnectorLossModel

Rescales `model`'s MW-based fields to per-unit of `base_power`. `breakpoints` divide by
`base_power`; `loss_flow_coefficient` and `demand_coefficients` (both 1/MW) multiply by
`base_power`; `loss_constant` and `from_region_loss_share` are dimensionless and unchanged.
"""
function _to_pu(model::InterconnectorLossModel, base_power::Real)
    return InterconnectorLossModel(;
        interconnector = model.interconnector,
        from_region = model.from_region,
        to_region = model.to_region,
        from_region_loss_share = model.from_region_loss_share,
        loss_constant = model.loss_constant,
        loss_flow_coefficient = model.loss_flow_coefficient * base_power,
        demand_coefficients = Dict(k => v * base_power for (k, v) in model.demand_coefficients),
        breakpoints = model.breakpoints ./ base_power,
    )
end
