# 0100 One key type per formulation family and PSI role

## Status

Accepted. Builds on [0097](0097-stock-devices-for-nemde.md).

## What

- Each formulation family and PowerSimulations (PSI) role has one entry type; the variant is in the key's meta as `"<variant>|<existing meta>"`. The separator is `|`, never `__`. A type whose variant is the whole meta (a single-direction parameter) uses a bare variant such as `up`, `down`, `forward`, `reverse`, `surplus`, `deficit`.
- Merged types: `RampRateTimeSeriesParameter`, `MNSPOperatingParameter`, `MNSPBandWidthParameter`, `MNSPMaxAvailParameter`, `MNSPSlack`, `MNSPLinkConstraint`, `InterconnectorFlowSlack`, `InterconnectorLossConstraint`, `FCASSlack`, `FCASUnitConstraint`, `NEMUnitSlack`, `NEMUnitConstraint`, `EnergyLimitTimeSeriesParameter`. The metas of each are listed in its docstring.
- Not merged: the FCAS upper and lower slope parameters (PSI picks the tuple unwrap by parameter type in the pinned fork, so they need distinct types), `FixedLoadTimeSeriesParameter` and `FixedLoadInvokedTimeSeriesParameter` (different natural units), `InitialPowerTimeSeriesParameter`, `FCASJointCapacityConstraint` (its dual is the FCAS price). The stock `PSI.RampConstraint` keeps its `up` and `dn` metas.
- Device-type multiplicity is kept: the merge is across variants, not across device types.

## How

- A singleton tag type stands for each variant; one boundary (the meta parser or builder) recovers it. CVP penalties dispatch on the tags for the NEMUnit and MNSP families and are call-site constants for FCAS and interconnector flow. Constraint rows and per-step updates dispatch on the entry type. Only public PSI API is used.
- A union of key types on a per-step path holds at most four members; build-time and results-time parsers may return larger unions.
- Result names carry the composite meta (for example `NEMUnitSlack__ThermalStandard__energy_offer|surplus`). `|` in a key makes PSI CSV export filenames invalid on Windows; CI runs on Linux.

## Why

- PSI compiles a method for each distinct container key type, so compile time scales with the number of key types. Per-variant, per-device structs had inflated the run to about 200 key types; merging variants cut it by about a third without changing any result.

## Market correctness

No bound, constraint or cost term depends on the merge. Each CVP factor is checked against the AEMO *Schedule of Constraint Violation Penalty Factors* v8.0: unit ramp 1155 (item 3), energy offer 1135 (item 8), MNSP offer 1135 (item 9), UIGF 385 (item 12), fixed loading 380 (item 13), unit max availability 370 (item 14), MNSP availability 365 (item 16), interconnector capacity 1150 (item 5), MNSP ramp 1155 (item 4), FCAS max availability 155 (item 19), joint ramping 155 (item 20), BDU ramping 155 (item 21), FCAS enablement 70 (item 24), fast-start profile 1130 (item 10).
