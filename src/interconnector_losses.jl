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
- `loss_flow_coefficient`: `LOSSFLOWCOEFFICIENT`.
- `demand_coefficients`: `REGIONID => DEMANDCOEFFICIENT`.
- `breakpoints`: `MWBREAKPOINT` values, ascending.
"""
struct InterconnectorLossModel
    interconnector::String
    from_region::String
    to_region::String
    from_region_loss_share::Float64
    loss_constant::Float64
    loss_flow_coefficient::Float64
    demand_coefficients::Dict{String, Float64}
    breakpoints::Vector{Float64}
end

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

Throws `ArgumentError` when `model` carries fewer than two breakpoints.
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
    read_interconnector_loss_breakpoints(db, as_of) -> DataFrame

`LOSSMODEL`'s segment breakpoints, version-resolved as of `as_of` (a `Date` or `DateTime`):
`INTERCONNECTORID`, `LOSSSEGMENT`, `MWBREAKPOINT`.

`LOSSMODEL` is a versioned `MARKET_CONFIG` table — rows are keyed by `EFFECTIVEDATE`, not by the
dispatch interval they are used in — so this filters on `EFFECTIVEDATE <= as_of` and takes the
highest `VERSIONNO`, never on `archive_month`.

Throws an `ArgumentError` when `LOSSMODEL` isn't cached at all.
"""
function read_interconnector_loss_breakpoints(db, as_of::Union{Date, DateTime})
    _table_is_cached(db, :LOSSMODEL) || throw(
        ArgumentError(
            "LOSSMODEL is not cached — run `populate(db, :LOSSMODEL, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :LOSSMODEL)
    return _query(
        db,
        """
        WITH raw AS (
            SELECT * FROM $table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, LOSSSEGMENT
                ORDER BY archive_month DESC
            ) = 1
        ),
        latest AS (
            SELECT INTERCONNECTORID, max_by(EFFECTIVEDATE, (EFFECTIVEDATE, VERSIONNO)) AS EFFECTIVEDATE,
                   max_by(VERSIONNO, (EFFECTIVEDATE, VERSIONNO)) AS VERSIONNO
            FROM raw GROUP BY INTERCONNECTORID
        )
        SELECT r.INTERCONNECTORID, r.LOSSSEGMENT, TRY_CAST(r.MWBREAKPOINT AS DOUBLE) AS MWBREAKPOINT
        FROM raw r
        INNER JOIN latest l
          ON r.INTERCONNECTORID = l.INTERCONNECTORID
             AND r.EFFECTIVEDATE = l.EFFECTIVEDATE AND r.VERSIONNO = l.VERSIONNO
        WHERE r.MWBREAKPOINT IS NOT NULL
        ORDER BY r.INTERCONNECTORID, MWBREAKPOINT
        """,
        [as_of],
    )
end

"""
    read_interconnector_demand_coefficients(db, as_of) -> DataFrame

`LOSSFACTORMODEL`'s per-region demand coefficients, version-resolved as of `as_of` the same way
[`read_interconnector_loss_breakpoints`](@ref) resolves `LOSSMODEL`: `INTERCONNECTORID`,
`REGIONID`, `DEMANDCOEFFICIENT`.

Throws an `ArgumentError` when `LOSSFACTORMODEL` isn't cached at all.
"""
function read_interconnector_demand_coefficients(db, as_of::Union{Date, DateTime})
    _table_is_cached(db, :LOSSFACTORMODEL) || throw(
        ArgumentError(
            "LOSSFACTORMODEL is not cached — run " *
                "`populate(db, :LOSSFACTORMODEL, <from>, <to>)` first.",
        ),
    )
    table = read_hive(db, :LOSSFACTORMODEL)
    return _query(
        db,
        """
        WITH raw AS (
            SELECT * FROM $table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO, REGIONID
                ORDER BY archive_month DESC
            ) = 1
        ),
        latest AS (
            SELECT INTERCONNECTORID, max_by(EFFECTIVEDATE, (EFFECTIVEDATE, VERSIONNO)) AS EFFECTIVEDATE,
                   max_by(VERSIONNO, (EFFECTIVEDATE, VERSIONNO)) AS VERSIONNO
            FROM raw GROUP BY INTERCONNECTORID
        )
        SELECT r.INTERCONNECTORID, r.REGIONID,
               TRY_CAST(r.DEMANDCOEFFICIENT AS DOUBLE) AS DEMANDCOEFFICIENT
        FROM raw r
        INNER JOIN latest l
          ON r.INTERCONNECTORID = l.INTERCONNECTORID
             AND r.EFFECTIVEDATE = l.EFFECTIVEDATE AND r.VERSIONNO = l.VERSIONNO
        WHERE r.DEMANDCOEFFICIENT IS NOT NULL
        ORDER BY r.INTERCONNECTORID, r.REGIONID
        """,
        [as_of],
    )
end

"""
    read_interconnector_loss_parameters(db, as_of) -> DataFrame

`INTERCONNECTORCONSTRAINT`'s loss parameters joined to `INTERCONNECTOR`'s region pair,
version-resolved as of `as_of`: `INTERCONNECTORID`, `REGIONFROM`, `REGIONTO`,
`FROMREGIONLOSSSHARE`, `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`, `ICTYPE`.

Differs from [`read_interconnectors`](@ref), which resolves to the latest version overall.

Throws `ArgumentError` when either table isn't cached.
"""
function read_interconnector_loss_parameters(db, as_of::Union{Date, DateTime})
    for table in (:INTERCONNECTORCONSTRAINT, :INTERCONNECTOR)
        _table_is_cached(db, table) || throw(
            ArgumentError(
                "$table is not cached — run `populate(db, :$table, <from>, <to>)` first.",
            ),
        )
    end
    icc_table = read_hive(db, :INTERCONNECTORCONSTRAINT)
    ic_table = read_hive(db, :INTERCONNECTOR)
    return _query(
        db,
        """
        WITH icc AS (
            SELECT * FROM $icc_table
            WHERE EFFECTIVEDATE <= ?
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID, EFFECTIVEDATE, VERSIONNO ORDER BY archive_month DESC
            ) = 1
        ),
        resolved AS (
            SELECT * FROM icc
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID ORDER BY EFFECTIVEDATE DESC, VERSIONNO DESC
            ) = 1
        ),
        ic AS (
            SELECT INTERCONNECTORID, REGIONFROM, REGIONTO FROM $ic_table
            QUALIFY row_number() OVER (
                PARTITION BY INTERCONNECTORID ORDER BY archive_month DESC
            ) = 1
        )
        SELECT r.INTERCONNECTORID, ic.REGIONFROM, ic.REGIONTO,
               TRY_CAST(r.FROMREGIONLOSSSHARE AS DOUBLE) AS FROMREGIONLOSSSHARE,
               TRY_CAST(r.LOSSCONSTANT AS DOUBLE) AS LOSSCONSTANT,
               TRY_CAST(r.LOSSFLOWCOEFFICIENT AS DOUBLE) AS LOSSFLOWCOEFFICIENT,
               r.ICTYPE
        FROM resolved r
        INNER JOIN ic ON ic.INTERCONNECTORID = r.INTERCONNECTORID
        ORDER BY r.INTERCONNECTORID
        """,
        [as_of],
    )
end

"""
    interconnector_loss_models(db, as_of) -> Dict{String, InterconnectorLossModel}

Every interconnector's [`InterconnectorLossModel`](@ref), assembled from
[`read_interconnector_loss_parameters`](@ref),
[`read_interconnector_demand_coefficients`](@ref) and
[`read_interconnector_loss_breakpoints`](@ref) as of `as_of`.

An interconnector with loss parameters but no `LOSSMODEL` breakpoints is skipped, reported in
one summary `@warn`.

Throws `ArgumentError` when no interconnector survives.
"""
function interconnector_loss_models(db, as_of::Union{Date, DateTime})
    params = read_interconnector_loss_parameters(db, as_of)
    coefficients = read_interconnector_demand_coefficients(db, as_of)
    breakpoints = read_interconnector_loss_breakpoints(db, as_of)

    by_interconnector = Dict{String, Vector{Float64}}()
    for row in eachrow(breakpoints)
        push!(get!(by_interconnector, row.INTERCONNECTORID, Float64[]), row.MWBREAKPOINT)
    end
    demand_coefficients = Dict{String, Dict{String, Float64}}()
    for row in eachrow(coefficients)
        d = get!(demand_coefficients, row.INTERCONNECTORID, Dict{String, Float64}())
        d[row.REGIONID] = row.DEMANDCOEFFICIENT
    end

    models = Dict{String, InterconnectorLossModel}()
    skipped = String[]
    for row in eachrow(params)
        id = row.INTERCONNECTORID
        bps = sort(get(by_interconnector, id, Float64[]))
        if length(bps) < 2
            push!(skipped, id)
            continue
        end
        models[id] = InterconnectorLossModel(
            id,
            row.REGIONFROM,
            row.REGIONTO,
            coalesce(row.FROMREGIONLOSSSHARE, 0.5),
            coalesce(row.LOSSCONSTANT, 1.0),
            coalesce(row.LOSSFLOWCOEFFICIENT, 0.0),
            get(demand_coefficients, id, Dict{String, Float64}()),
            bps,
        )
    end
    isempty(skipped) ||
        @warn "interconnector_loss_models: $(length(skipped)) interconnector(s) have no LOSSMODEL breakpoints as of $as_of; skipped" skipped
    isempty(models) && throw(
        ArgumentError(
            "no interconnector has a complete loss model as of $as_of. Check that " *
                "LOSSMODEL/LOSSFACTORMODEL/INTERCONNECTORCONSTRAINT are cached and that their " *
                "EFFECTIVEDATEs precede $as_of.",
        ),
    )
    return models
end
