# 0100. One key type per formulation family and PSI role

## Status

Accepted. Builds on [0097](0097-stock-devices-for-replay.md) and [0096](0096-per-step-state-updates.md).

## Context

PowerSimulations (PSI) compiles a method for each distinct optimisation-container key type it builds.
The compile cost of a build is a shared floor of about 95 s for PowerSystems, InfrastructureSystems and
PSI, plus a cost for each key type. The stock RTS-GMLC economic dispatch has 45 key types, with 158 s of
inference; its unit commitment has 57, with 175 s. The NEMDE replay had 197 key types on the mock cache
and 195 on the real NEM interval of 2026-06-04, and its inference took about 360 s.

The template sets the key types, not the data. Of the 197 mock-cache key types, 176 came from AEMSim.
They came from one struct per variant per device type: the updatable-parameter work (#206 to #209, #227,
7ebb250) and the elastic CVP slacks (#215, #217, #219) each added a type for every variant the formulation
needed.

## Decision

Each formulation family and PSI role has one entry type. The variant goes in the key's meta, a composite
string `"<variant>|<existing meta>"`. The separator is `|`, never `__`.

A singleton tag type stands for each variant. One boundary recovers the variant from the key's meta:
the parser or the meta builder. Everything downstream dispatches on those tags: CVP penalties, natural
units, constraint rows and the per-step updates. Only public PSI API is used.

Device-type multiplicity is kept. The stock `DeviceModel`s of [0097](0097-stock-devices-for-replay.md)
still give one key per device type, so the merge is across variants, not across devices.

Merged types:

- `RampRateTimeSeriesParameter`
- `MNSPOperatingParameter`, `MNSPBandWidthParameter`, `MNSPMaxAvailParameter`
- `MNSPSlack`, `MNSPLinkConstraint`
- `InterconnectorFlowSlack`, `InterconnectorLossConstraint`
- `FCASSlack`, `FCASUnitConstraint`
- `NEMUnitSlack`, `NEMUnitConstraint`
- `EnergyLimitTimeSeriesParameter`

Not merged:

- The FCAS upper and lower slope parameters. PSI picks the tuple unwrap by parameter type
  (`add_parameters.jl:541` and `:546`, and `update_container_parameter_values.jl:98` in the pinned fork),
  so the two must keep distinct types.
- `FixedLoad` and `FixedLoadInvoked`. Their natural units differ.
- `InitialPower`.
- `FCASJointCapacityConstraint`. Its dual is the FCAS price, so it keeps its own type.

Union cap: a union of key types on a per-step path holds at most four members. Build-time and
results-time parsers may flatten a larger union.

## Consequences

- Stored result names change. For example, `MNSPSlack__AreaInterchange__ramp_up` and
  `NEMUnitSlack__ThermalStandard__energy_offer_surplus`. The readers in `src/results` are updated, and
  nothing in `scripts/` parses the old names.
- Per key type removed, the build saves about 0.78 s. That is below the 1.0 to 1.4 s spike marginals,
  because shared specialisations are paid once.
- Remaining levers, none done here:
  - Shared component keys for device parameters, via a PSI fork change. This also enables the slope
    merge above.
  - Spike A key despecialisation in the fork, measured at a saving of 47 s.
  - The warm build gap of about 13 s per run, against 0.3 s for stock PSI.
  - The precompile workload.

## Market correctness

No bound, constraint, coefficient or cost changed. Every CVP factor was checked against the AEMO
Schedule of Constraint Violation Penalty factors v8.0:

| Penalty | Schedule item |
| --- | --- |
| Unit ramp | 1155 item 3 |
| Energy offer | 1135 item 8 |
| MNSP offer | 1135 item 9 |
| UIGF | 385 item 12 |
| Fixed loading | 380 item 13 |
| Unit max availability | 370 item 14 |
| MNSP availability | 365 item 16 |
| Interconnector capacity | 1150 item 5 |
| MNSP ramp | 1155 item 4 |
| FCAS max availability | 155 item 19 |
| Joint ramping | 155 item 20 |
| BDU ramping | 155 item 21 |
| FCAS enablement | 70 item 24 |

## Verification

Measured in fresh processes, with precompile workloads off.

| Measure | Before | After |
| --- | --- | --- |
| Mock key types | 197 | 125 |
| Mock inference | 367.6 s | 311.6 s |
| Mock cold workload | 366.8 s | 311.5 s |
| Mock warm run | 1.43 s | 1.39 s |
| Real NEM key types | 195 | 129 |
| Real NEM inference | 360.2 s | 309.5 s |
| Real NEM cold | 386.9 s | 331.2 s |
| Real NEM build! | 148.4 s | 113.4 s |
| Real NEM execute! | 69.2 s | 55.6 s |
| Real NEM warm | 23.1 s | 22.7 s |

Results are bit-identical on the mock two-interval replay and on the real two-interval replay of
2026-06-04. The full Simulations suite passed, 3970 of 3970 tests, and the root suite is green.
