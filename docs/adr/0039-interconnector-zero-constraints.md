# 0039 Interconnector Zero constraints without a published definition

## Status

Accepted. Made redundant once the cache is backfilled by [0050](0050-pre-2015-constraint-definitions.md); the built-in stays and a published definition wins.

## What

- `SVML_ZERO`, `VSML_ZERO` (Murraylink, `V-S-MNSP1`), `VT_ZERO` and `TV_ZERO` (Basslink, `T-V-MNSP1`) appear in `GENCONSET`, `GENCONSETINVOKE` and `DISPATCHCONSTRAINT` (always version `2013-08-21 #1`, `RHS` 0) but in no definition table, so `add_nem_constraints!` skipped them as `no_definition`. One-sided invocation happens (`VSML_ZERO` alone for 79 intervals in 2020), so each is built on its own.
- They are the "Unit and Interconnector Zero constraint" of the CVP Schedule (item 1, factor 1160, "Interconnector <= 0 MW and Interconnector >= 0 MW"), holding an out-of-service interconnector at zero. Penalty is 1160 x the Market Price Cap (the `MARGINALVALUE` NEMDE reports when one binds).
- Without them Murraylink flowed 45 to 80 MW on binding intervals, with knock-on VIC to SA flow, VIC1/SA1 price and VIC wind errors.

## How

- `_zero_flow_constraint_definitions` (`src/system/constraints.jl`) synthesises a `GENCONDATA`-shaped definition (`<=`, weight 1160, RHS 0, `SOURCE = "built-in"`) and one `INTERCONNECTOR` term (`factor x flow <= 0`) per constraint, from `_ZERO_FLOW_CONSTRAINTS`:

| ID | Term |
| --- | --- |
| `SVML_ZERO` | -1 x `V-S-MNSP1` |
| `VSML_ZERO` | +1 x `V-S-MNSP1` |
| `VT_ZERO` | -1 x `T-V-MNSP1` |
| `TV_ZERO` | +1 x `T-V-MNSP1` |

- Applied only to invoked versions that `GENCONDATA` does not define, and only for version `2013-08-21 #1`; a published definition wins. Any other version of these ids warns and stays `no_definition`.
- The constraint then flows through the usual `GenericConstraint` machinery: an `InterconnectorTerm` on the interconnector's net flow (forward minus reverse for an MNSP), elastic at `INTERCONNECTOR_ZERO_CVP_FACTOR` times the cap.

## Why

- The definitions come from the NEMDE case file (`NEMSPDOutputs_*.loaded`, `LHSFactorCollection`, `ViolationPrice` 23,548,000 at the 2025-26 cap). They are four constants, constant over the cached years.
- Rejected: a new XML ingest path (the Data package has no XML dependency and the case files are not on NEMWEB's MMSDM path); and zero flow bounds from `DISPATCHINTERCONNECTORRES` limits, which are computed after the solve ([0028](0028-interval-inputs-limits-and-as-of-tables.md)) and would feed a NEMDE output back as an input.
- A zero net flow does not zero Basslink's link variables; the always-on direction binary ([0035](0035-mnsp-link-offers.md)) prevents the circulation that would otherwise be feasible.

## Sources

- CVP Schedule v8.0, Table 1 item 1; constraint naming guidelines, discretionary constraint sets (`QN_ZERO`); NEMDE case files for 2026-06-09 15:00 and 2026-06-30 17:25 (`ConstraintSolution` `MarginalValue = -23548000`).
- Other no-definition `_ZERO` ids (`V_MACARTHUR_ZERO`, `T_MRWF_ZERO`, `NQ_ZERO`, `F_T_ME_ZERO_*`) are not covered.
