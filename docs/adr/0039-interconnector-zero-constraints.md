# 0039. Interconnector Zero constraints without a published definition

## Status

Accepted

## Context

`DISPATCHCONSTRAINT` reports four constraints that no definition table carries: `SVML_ZERO`,
`VSML_ZERO` (Murraylink, `V-S-MNSP1`), `VT_ZERO` and `TV_ZERO` (Basslink, `T-V-MNSP1`). Over the full
cache there is no `GENCONDATA`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT` or
`SPDCONNECTIONPOINTCONSTRAINT` row for any of them. They appear in `GENCONSET` (members of
`I-MURRAYLINK` and `I-BL_ZERO`), `GENCONSETINVOKE` and `DISPATCHCONSTRAINT`, always at one version
(`GENCONID_EFFECTIVEDATE` 2013-08-21, `GENCONID_VERSIONNO` 1, `RHS` 0). The pairs are not always invoked
together: `VSML_ZERO` alone is invoked for 79 intervals in 2020 (2020-02-16 11:50 to 2020-03-02
16:50, `INTERVENTION` 0), so one-sided invocation happens and each constraint is built on its own. `add_nem_constraints!`
therefore skipped them as `no_definition`.

They are the "Unit and Interconnector Zero constraint" of the constraint violation penalty factors
(item 1, CVP factor 1160, form "Interconnector <= 0 MW and Interconnector >= 0 MW", used to hold an
out-of-service interconnector at zero energy and FCAS targets). At the 2025-26 market price cap of
$20,300/MWh the penalty is 1160 x 20,300 = $23,548,000, the `MARGINALVALUE` that NEMDE reports when
one binds. The naming guidelines list `QN_ZERO` ("flow on QNI is equal to zero") as the same kind.

In the 11-interval validation sample `SVML_ZERO` binds on 2026-06-09, 06-10, 06-12 and 06-13 and
`VT_ZERO` on 06-30. `DISPATCHINTERCONNECTORRES` shows `EXPORTLIMIT = IMPORTLIMIT = 0` on those
intervals. Without the constraint our model flows Murraylink at 45 to 80 MW, with knock-on VIC to SA
flow, VIC1/SA1 price and VIC wind dispatch errors.

## Where the definition lives

The NEMDE case file (`NEMSPDOutputs_*.loaded`, read by nempy's `xml_cache`) carries each constraint
with its `LHSFactorCollection`:

| ID | Type | LHS | RHS | `ViolationPrice` | Invoked via |
| --- | --- | --- | --- | --- | --- |
| `SVML_ZERO` | LE | -1 x `V-S-MNSP1` | 0 | 23,548,000 | `I-MURRAYLINK` |
| `VSML_ZERO` | LE | +1 x `V-S-MNSP1` | 0 | 23,548,000 | `I-MURRAYLINK` |
| `VT_ZERO` | LE | -1 x `T-V-MNSP1` | 0 | 23,548,000 | `I-BL_ZERO` |
| `TV_ZERO` | LE | +1 x `T-V-MNSP1` | 0 | 23,548,000 | `I-BL_ZERO` |

The case-file version (`20130821000000_1`, effective 2013-08-21) is the version `DISPATCHCONSTRAINT`
reports whenever it is invoked: `SVML_ZERO` and `VSML_ZERO` from 2015-02-03 to 2026-09-01, `VT_ZERO`
and `TV_ZERO` from 2015-01-07 to 2026-07-02. None of the four is invoked in every month. Each constraint is a one-term inequality on an
interconnector flow, and an invoked pair pins the flow to zero. The XML needs no new ingest path:
the term set is one fixed fact per constraint, constant for the 11 years in the cache.

## Decision

Option (a): a built-in definition. `zero_flow_constraint_definitions` (`src/constraints/zero_flow.jl`)
holds the four rows above and synthesises a `GENCONDATA`-shaped definition (`<=`, weight 1160, RHS 0)
and an `INTERCONNECTOR` term for each. `add_nem_constraints!` applies it only to invoked versions
that `GENCONDATA` does not define, and only for the version 2013-08-21 #1. A published definition
always wins; any other version stays `no_definition`. The constraint then flows through the existing
`GenericConstraint` machinery: an `InterconnectorTerm` on the MNSP flow, with the elastic row priced
at the weight times the market price cap.

Rejected:

- A new XML ingest path. The Data package has no XML dependency and the case files are not on
  NEMWEB's MMSDM path; for four constants it adds an input of a different kind to the pipeline.
- Option (b), `DISPATCHINTERCONNECTORRES` limits of zero as flow bounds on the affected intervals.
  `EXPORTLIMIT` and `IMPORTLIMIT` are computed after the solve (see ADR 0028), so this feeds a NEMDE
  output back as an input, and it only covers intervals chosen by looking at which constraint
  bound. It would also leave the constraint's penalty and the MNSP offer availability logic out of
  the model. It is acceptable only as a diagnostic isolating flow gaps, not for validation.

## Consequences

- Murraylink and Basslink outages are modelled from the data the cache holds, with no use of solved
  quantities.
- A built-in definition is applied only to version 2013-08-21 #1. A known identifier invoked at any
  other version logs a warning naming it and stays `no_definition`, so a revised AEMO definition is
  noticed rather than silently dropped.
- The term constrains the interconnector's net flow. With per-link MNSP modelling (PR #175) the
  `InterconnectorTerm` resolves to `FlowActivePowerVariable[AreaInterchange]`, forward minus reverse.
  A zero net flow therefore does not zero Basslink's link variables: the circulation binary only
  bites when the two links' lowest offers sum below zero, so forward = reverse = q > 0 stays
  feasible and creates or destroys (tlf_r.to + tlf_f.to - tlf_f.from - tlf_r.from) q MW of energy.
  Murraylink is a regulated DC interconnector and is unaffected.
- The constraint is a hard-zero in NEMDE's own terms (CVP factor 1160, above the unit ramp and
  offer CVPs), so in the replica it is elastic at 1160 times the Market Price Cap like any other
  generic constraint.
- Only these four identifiers are recognised. The other `_ZERO` identifiers with no definition are
  unit constraints (below); they are not covered.

## Follow-up

- Fix on the PR #175 side: force the direction binary of an MNSP whenever a zero constraint names
  its interconnector, so that an out-of-service link carries no flow in either direction. Until
  then Basslink's `VT_ZERO`/`TV_ZERO` replicate NEMDE's net flow, not its link variables.

## Remaining constraints without a definition that bind

Of the 71 distinct `no_definition` identifiers over the 11 sample intervals, those with a non-zero
`MARGINALVALUE` are, by impact:

| Constraint | Intervals bound | `MARGINALVALUE` | Note |
| --- | --- | --- | --- |
| `VT_ZERO`, `SVML_ZERO` | 1, 4 | -23,548,000 | Covered by this decision. |
| `$CPP_3` | 2 (06-09, 06-30) | -7,714,000 | Unit fix (EQ, 1 x `CPP_3` energy = availability), violated by 21 and 9 MW; NEMDE clears the ramp floor above availability. |
| `$CPP_4` | 1 (06-29) | +20,255 | Same form, unit fix at 380 MW. |
| `N_NIL_TE_B` | 1 (06-22) | -49.5 | Network constraint, not defined in the cache; the only one with a material price impact. |
| `$STAN-1` | 1 (06-22) | +1.92 | Unit fix at 150 MW. |
| `N_MBTE1_B` | 1 (06-03) | -0.89 | |
| `F_MAIN+NIL_MG_R5/R6/R60` | 4 each | 0.01 to 0.08 | Mainland FCAS, negligible. |

The `$`-prefixed constraints are AEMO unit-fix constraints (`Type EQ`, one `ENOF` term for the DUID,
the right-hand side a dispatch-time value) and are the next candidates for a built-in rule.
Other no-definition `_ZERO` identifiers in the cache (`V_MACARTHUR_ZERO`, `V_MTMERCER_ZERO`,
`T_MRWF_ZERO`, `T_LE_ZERO`, `NQ_ZERO`, `NV_ZERO`, `F_T_ME_ZERO_*`) are unit or `QNI`/`VIC1-NSW1`
zero constraints that a verified case-file extract could add to the same table; none binds in the
sample.

## Evidence

- NEMDE case files for 2026-06-09 15:00 (`SVML_ZERO`, `VSML_ZERO`) and 2026-06-30 17:25 (`VT_ZERO`,
  `TV_ZERO`): constraint blocks and `ConstraintSolution` rows with `MarginalValue = -23548000`.
- Constraint violation penalty factors, Table 1 item 1.
- Constraint naming guidelines, discretionary constraint sets (`QN_ZERO`).
