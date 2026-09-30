# Interconnector losses design (Phase 2.10)

## Goal

Add `NEMInterconnectorLoss`, a `PSY.AreaInterchange` device formulation in
`AustralianElectricityMarketsSimulations` that reproduces NEMDE's interconnector loss curve inside
the regional power balance, reading Phase 1's `InterconnectorLossModel` supplemental attribute.
AEMSim must never query DuckDB directly.

## AEMO sources

- `LOSSMODEL` (`references/data-model/LOSSMODEL.md`, AEMO Electricity Data Model Report 5.7.0,
  pp. 409-410): `MWBREAKPOINT` segment breakpoints per interconnector, 1-80 segments.
- `LOSSFACTORMODEL` (`references/data-model/LOSSFACTORMODEL.md`, same report, pp. 408-409):
  `DEMANDCOEFFICIENT` per `(INTERCONNECTORID, REGIONID)`.
- `INTERCONNECTORCONSTRAINT`: `FROMREGIONLOSSSHARE`, `LOSSCONSTANT`, `LOSSFLOWCOEFFICIENT`.
- `references/marginal-loss-factors/05-interregional-loss-factor-equations.md` (Marginal Loss
  Factors FY2026-27, pp. 57-63): confirms the loss-factor form `constant + flow_coeff * transfer +
  Σ demand_coeff * regional demand` used by AEMO's own published inter-regional equations, the
  same functional form `LOSSCONSTANT`/`LOSSFLOWCOEFFICIENT`/`DEMANDCOEFFICIENT` implement inside
  NEMDE.
- `DISPATCHINTERCONNECTORRES` (`MWFLOW`, `MWLOSSES`): published per-interval flow and loss, the
  real-data comparison target.

## nempy cross-check

`nempy` represents loss using interpolation weights at breakpoints, with SOS2 restricting the
nonzero weights to adjacent breakpoints. This formulation instead uses bounded segment flow
allocations. For a convex curve and positive weighted marginal loss price, the objective fills
segments in slope order and reproduces the same interpolation. At zero or negative weighted
price, that ordering is not guaranteed; the diagnostic compares solved loss to breakpoint
interpolation and reports excess loss. AEMO's data model describes breakpoints and loss-factor
coefficients but does not establish its internal solver encoding. ADR 0022 records this limit.

## Salvage diff vs what must change

The salvage commit `8365d62` reads a `Dict{String,InterconnectorLossModel}` from the `DeviceModel`'s
`"loss_models"` attribute (populated by a caller calling `interconnector_loss_models(db, as_of)`
directly against DuckDB). Since Phase 1 landed, `attach_interconnector_losses!` already stamps each
`AreaInterchange` with its own per-unitized `InterconnectorLossModel` as a `PSY.SupplementalAttribute`.
Changes on the way in:

- Drop `"loss_models"` attribute / `_loss_models` / `_missing_loss_model_error`. Read the model with
  `only(PSY.get_supplemental_attributes(InterconnectorLossModel, device))`, throwing a clear
  `ArgumentError` when zero or more than one is attached.
- The attached model is **already per-unit** of the system base power (`_to_pu` in
  `src/interconnector_losses.jl`). The salvage code divided its own (raw-MW) model by
  `base_power` at every use; that division is now wrong and is removed. Regional demand
  (`_area_demand`) is likewise read directly in per-unit (PSY components are already pu under
  `UnitSystem.SYSTEM_BASE`), not rescaled by `base_power`.
- `_narrow_breakpoint_interconnectors`'s flow-limit comparison compares two already-per-unit
  quantities (`get_flow_limits` and the attached model's `breakpoints`) directly, no rescale.
- Everything else (segment variables/constraints, `FlowLimitConstraint` duplication, warnings, the
  convexity check) ports unchanged.

## Design

- `InterconnectorLossVariable`, `InterconnectorLossSegmentVariable` (`PSI.VariableType`).
- `InterconnectorFlowSegmentConstraint`: `flow == breakpoints[1] + Σ segment flows`.
- `InterconnectorLossDefinitionConstraint`: `loss == loss@breakpoints[1] + Σ slope_s * segment_s`.
- Loss terms enter `PSI.ActivePowerBalance` for `PSY.Area`: `-share * loss` on the from-area,
  `-(1-share) * loss` on the to-area, on top of PSI's own `∓flow` terms (inherited, not
  overridden).
- `ArgumentConstructStage`: variables/constraints/loss terms (mirrors salvage `8365d62`, since loss
  terms only reference the interconnector's own flow variable, already present by then).
- `ModelConstructStage`: `FlowLimitConstraint` (duplicated from PSI's `AreaInterchange`/
  `StaticBranch` builder, since that method dispatches on the concrete formulation type).

## Departures from AEMO / recorded gaps

- The quadratic loss arithmetic follows the published coefficients. Segment accumulation can
  over-dissipate when the weighted marginal price is zero or negative. Enforcing contiguous
  segment allocation remains a Phase 3 follow-up, recorded in ADR 0022.

## Tests

- Toy test: hand-computed loss for a known flow and a 2-segment loss model (values chosen so
  the algebra is checkable by hand), asserting `InterconnectorLossVariable` equals the hand
  computation after solve.
- Split test: same toy system, asserting the from/to area balance each receive
  `share * loss` / `(1 - share) * loss` respectively.
- Ported: missing supplemental attribute throws, non-convex segment slopes throw, narrow
  breakpoints warn, `FlowLimitConstraint` bounds both from time series and static limits.

## Files

- `AustralianElectricityMarketsSimulations/src/devices/interconnector_losses.jl` (new)
- `AustralianElectricityMarketsSimulations/src/AustralianElectricityMarketsSimulations.jl` (include/export)
- `AustralianElectricityMarketsSimulations/test/interconnector_losses.jl` (new)
- `AustralianElectricityMarketsSimulations/test/runtests.jl` (register group)
- `docs/adr/0022-interconnector-loss-formulation.md` (new)
- `CHANGELOG.md`
