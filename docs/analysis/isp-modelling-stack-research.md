# ISP investment modelling with the Sienna packages

Research snapshot: 28 October 2026. This is a documentation and source review, not a
runtime compatibility test or an approved implementation design.

The first modelling milestone requested is to optimise alternative investments.
Resource adequacy assessment will evaluate the resulting portfolios.

## Agreed portfolio architecture

Decision recorded on 28 October 2026: keep integration with PSIP abstractions and interfaces,
extending `AEMInvestmentPortfolio` only where ISP data or behaviour requires it.

`AEMInvestmentPortfolio` will compose a real `PSIP.Portfolio`. Existing assets belong in its
`PSY.System`; planning resources, topology, finance and standard requirements use PSIP's
concrete types. Use `ExistingDevices` and `TopologyMapping` to connect the planning and
physical representations, and reuse retirement and retrofit attributes where their meanings fit.

The AEM-owned layer retains scenario and release identity, source provenance, complete dated,
banded and tagged property records, lazy DuckDB trace references and interpretation coverage.
It supplies ISP-specific assumptions or planning constraint data when the standard PSIP types
cannot express them. These additions must identify the unsupported meaning and its consumer.
Standard asset and candidate fields remain in PSY/PSIP objects, with source records retained
separately for provenance and later reinterpretation.

Use PSIP's registration, lookup, time-series, supplemental-attribute and serialization
interfaces. Pass the wrapped `PSIP.Portfolio` to PSINV. Add a custom `Technology` or
`Requirement` subtype only after checking the standard types and attribute mechanisms;
each such subtype also needs explicit solver and serialization support where applicable.

This replaces the earlier proposal for a separate AEM asset hierarchy and subsequent wholesale
translation to PSIP. The source interpretation layer remains AEM-owned and lossless.

The [implementation plan](../superpowers/plans/2026-10-28-isp-investment-portfolio.md)
records the sequence, interfaces, compatibility gate and acceptance checks.

## Package names and documentation

The current repositories use these names:

| Package | Role | Starting documentation |
| --- | --- | --- |
| `PowerSystemsInvestmentsPortfolios.jl` (PSIP) | Investment data container around a `PowerSystems.System` | [Portfolio explanation](https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl/blob/main/docs/src/explanation/portfolio.md), [quick start](https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl/blob/main/docs/src/quick_start_guide.md), [technology types](https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl/blob/main/docs/src/explanation/technology_types.md) |
| `PowerSystemsInvestments.jl` (PSINV) | Capacity and transmission expansion optimisation | [Repository](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl), [working model tests](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/main/test/test_model.jl), [PSY5 integration PR](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/68) |
| `SiennaPRASInterface.jl` | Converts a PowerSystems system into a PRAS adequacy model | [Getting started](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/docs/src/index.md), [outage data](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/docs/src/how_to_guides/how_do_i_add_outage_data.md), [formulation definitions](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/src/formulation_definitions.jl) |

README documentation links point to
`https://sienna-platform.github.io/PowerSystemsInvestmentsPortfolios.jl/stable`,
`https://sienna-platform.github.io/PowerSystemsInvestments.jl/stable`, and
`https://sienna-platform.github.io/SiennaPRASInterface.jl/dev`.
Those sites were not retrievable through the web tool during this review, so the documentation
source and examples were read through GitHub instead.

PSINV's default-branch overview and quick start remain placeholders. Its tests, implementation
and current integration PRs provide considerably more information than those pages.
PSIP's documentation describes data types; the existence of a data type does not establish
that a corresponding optimisation formulation is implemented in the selected PSINV revision.

## What each package contributes

PSIP's `Portfolio` references an existing `PowerSystems.System` through `base_system` and adds
candidate technologies, planning regions, time series, financial data and requirements.
It supports supply, storage, co-located supply/storage, transport and demand technology types.
It also defines carbon, energy-share, capacity and hourly-matching requirement data.
See the [stack explanation](https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl/blob/main/docs/src/explanation/sienna_stack.md)
and [requirements documentation](https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl/blob/main/docs/src/explanation/requirements.md).

PSINV's default-branch tests demonstrate investment periods, weighted representative operating
days, thermal and renewable supply, inter-zone transport, battery storage and co-located
resources. Templates select the investment, operating and feasibility formulations, and
`InvestmentModel` builds and solves the JuMP model. Its tests include continuous investment
with both chronological and cyclical storage formulations. These examples are small test
systems, not evidence of NEM-scale performance or PLEXOS equivalence.

SiennaPRASInterface accepts a PowerSystems system and an aggregation or resource-adequacy
template. It exposes sequential Monte Carlo assessment, EUE, LOLE, shortfalls and standard
errors. Its source defines generator, storage, hydro reservoir and line/interface mappings.
It assesses adequacy of a supplied fleet; it does not choose least-cost investments or replace
a detailed market-bidding simulation. See the [public module](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/src/SiennaPRASInterface.jl).

## Version alignment and upstream development

Default-branch compatibility declarations are currently inconsistent across the investment
stack. AEM declares PowerSystems `5.10.0` and InfrastructureSystems `^3.1`; PSIP main declares
PowerSystems `^5.3` and InfrastructureSystems `^3.1`; SiennaPRASInterface declares PowerSystems
`~5` and InfrastructureSystems `~3`. PSINV main still declares PowerSystems `4` and
InfrastructureSystems `2`.

These are compatibility ranges, not statements that AEM must stay on exactly 5.10.0.
There is no common PowerSystems major version for all those default branches.
The PSY5 integration branch is more relevant than PSINV main for this project.
Sources: [PSIP Project.toml](https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl/blob/main/Project.toml),
[PSINV Project.toml](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/main/Project.toml),
[PRAS interface Project.toml](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/Project.toml).

| PSINV work | Status observed | Relevance |
| --- | --- | --- |
| [PR #68](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/68), `rh/psy5_update` | Open, not merged | PSY5/IS3, nodal transport balance, hydro energy budgets, storage duration limits, energy-share requirement, investment/cost revisions |
| [PR #69](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/69), `jp/thermal_formulations` | Open draft, based on #68 | Fuel costs, non-hourly time-step handling and relaxed thermal commitment |
| [PR #71](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/71), `jp/ptdf` | Open draft, based on #69 | PTDF expansion, iterative flow monitoring, HVDC and lossy controllable links |
| [PR #72](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/72), `jp/requirement_formulations` | Open draft, based on #71 | Carbon, reserve, capacity and hourly-matching formulations, policy slacks and duals |

PR #68 depends on PSIP's `jp/capex` branch through a `[sources]` entry. Its Project.toml
declares PowerSystems `5.12.3` and InfrastructureSystems `3.6.3`, both using Julia's normal
caret compatibility semantics. Resolution against AEM's pinned operational stack still needs
testing. The PR also changes operational weights to per-year occurrences, so copying weights
from main's examples would use a different convention.

The fuller feature set is stacked across draft PRs. It must not be represented as a released,
validated solver capability. PR authors' test results and performance claims were not
independently reproduced during this research.

PSINV snapshots inspected:

- `rh/psy5_update`: `7874984b6fa53e0463931c8e769c0e356df71910`.
- `jp/thermal_formulations`: `c78a0283ba721d90557eaa1846445e0242da67ba`.
- `jp/ptdf`: `b272f7aa760e9beb0b6285d2d1e0dc47859b4804`.
- `jp/requirement_formulations`: `0e318ef036a018dcdd937b30fca912029909f2b1`.

Further relevant open issues include [hydro reservoir investments #42](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/issues/42),
[retirement #38](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/issues/38),
and [demand-side technology formulations #73](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/issues/73).
An energy-budget hydro formulation does not establish full reservoir/waterway optimisation.

## Relation to AEMO's ISP workflow

AEMO separates capacity outlook modelling, detailed time-sequential modelling, power-system
assessment, gas modelling and cost-benefit assessment. SSLT optimises the whole horizon;
DLT uses sequential windows. More detailed dispatch and outage simulations feed information
back into planning. Capacity reserve constraints are an adequacy proxy, distinct from a
probabilistic reliability calculation. Source: [AEMO ISP Methodology, June 2025, sections 1,
2.2, 2.4.3 and 3](https://www.aemo.com.au/-/media/files/stakeholder_consultation/consultations/nem-consultations/2024/2026-isp-methodology/isp-methodology-june-2025.pdf).

The following is a proposed division of responsibility for AEM, inferred from that workflow
and the package interfaces:

| Responsibility | Candidate implementation |
| --- | --- |
| Raw source storage | Existing ISP DuckDB cache |
| ISP interpretation and shared data | AEM readers, domain types and PowerSystems builders |
| Alternative candidate sets and investment assumptions | PSIP Portfolio |
| Build decisions and aggregate operating economics | PSINV with a deliberately pinned, tested revision |
| Chronological operational validation | PowerSimulations plus the AEM operational/hydro extensions |
| Probabilistic adequacy of resulting fleets | SiennaPRASInterface/PRAS |
| Scenario comparisons and development-path analysis | New AEM orchestration and reporting |

This stack could support an open ISP-style market-planning workflow. Matching AEMO results
requires explicit assumptions and benchmarks; the package selection alone does not establish
equivalent formulation, chronology, reliability, economics or network behaviour.

## Mapping the cached ISP inputs

The source cache is fully extracted, but converting its relational records into executable
planning inputs is still required. The following are proposed mappings, not completed adapters:

| Cached ISP content | Modelling destination | Main interpretation work |
| --- | --- | --- |
| Objects, categories and memberships | Base System, PSIP technologies and topology | Preserve file namespace; distinguish existing assets from candidates; retain attachment and direction |
| Build limits, capacity, life and costs | Investment limits and financial/capital data | Resolve date/band/tag/variable context; reconcile per-unit versus aggregate limits, money basis and unit conventions |
| Demand, renewable and embedded-PV files | Operational profiles and demand technology | Calendar/reference-year mapping, aligned resolutions, quantity meaning and PV accounting |
| Battery properties | Storage technology and operating parameters | Separate power and energy sizing, efficiency, duration and state boundaries |
| Hydro/storage/waterway records | Hydro budgets initially; reservoir models where needed | Inflow units, energy limits, topology and seasonal carry-over |
| Lines, losses and constraint records | Transport technologies and explicit constraints | ISP sub-region transfer limits, asymmetric ratings, generic coefficients and augmentation options |
| Emissions, policy and capacity constraints | PSIP requirement data plus supported PSINV formulations | Preserve scope, target period, eligibility and coefficients; verify actual formulation support |
| Forced-outage rates and repair times | PRAS outage attributes | Translate to the transition process and chosen time-step resolution |

The default PRAS outage documentation describes ERCOT-derived defaults and zero outage rates
for unmatched component classes. Those are unsuitable as implicit NEM assumptions; populate
the ISP inputs explicitly and validate conversions. Source: [default outage documentation](https://github.com/Sienna-Platform/SiennaPRASInterface.jl/blob/main/docs/src/explanations/default_outage_values.md).

## Investment-first exploration

The immediate technical investigation should be an isolated dependency and model spike,
leaving AEM's existing operational environment intact. First test the PSY5 integration and
its paired PSIP branch, then evaluate the policy branch if the investment experiment requires
carbon caps, reserve requirements or other policies beyond energy share.

A manageable first investment experiment would use a small set of ISP sub-regions, fixed
existing assets, wind/solar/battery/gas candidates, a short sequence of investment periods,
and consistent demand/resource profiles. Compare build choices, investment and operating
costs, transmission use and curtailment while varying candidate costs or transfer capacity.
This is a proposed scope for agreement, not a selected formulation or implementation plan.

The success criterion should include sensitivity to chronology and energy constraints,
especially for storage and hydro. After the investment solve, materialise the chosen fleet
into a System and assess operational feasibility and adequacy. This requires an explicit
results-to-System adapter; the existence of update helpers is not evidence that every asset
class and investment action is handled correctly.

Before adding dependencies to AEM, establish a reproducible package set and independent
small-system checks for capital/operating costs, period weights, storage energy accounting,
transmission and the policies actually used. Full ISP-scale optimisation and matching AEMO's
development path are later validation tasks.

### Tested portfolio dependency set

The isolated compatibility gate in `test/isp_portfolio/compatibility` resolves PSIP
`c1150d6eadaa3d28f36575e7232d8d77dc722cca` (`jp/capex`, which merged PSIP main on
30 October 2026) and PSINV `7874984b6fa53e0463931c8e769c0e356df71910` (`rh/psy5_update`,
PR #68) with PowerSystems 5.12.4, InfrastructureSystems 3.6.3 and the existing
PowerSimulations fork `fc30a298afb314d563488db852387e145ec97f9a`, under Julia 1.13.3. These PowerSystems, InfrastructureSystems and PowerSimulations versions
are the ones in AEM's root manifest, so the investment packages need no change to
AEM's operational pins. PR #68
tracks the `jp/capex` branch head, so this PSIP revision matches what PSINV resolves today.
The gate checks data interfaces and package loading, not an investment optimisation
formulation. Checked on 4 November 2026: 12/12 data-contract checks pass, and the
extension mechanism loads with PSIP present and stays inactive with PSIP absent.

Findings from running the gate:

- At the earlier candidate `31716701`, technology requirement associations were lost on a
  JSON round trip, because requirements were deserialized after the technologies that
  reference them by ID. PSIP PR #117 (order-independent requirement deserialization)
  fixes this, and `c1150d6` includes it. Older `jp/capex` revisions are unsuitable.
- At `c1150d6`, `ExistingDevices` requires an explicit `id`, as `Zone` and the
  requirement types already do. The AEM adapter must assign IDs to supplemental attributes
  as well as components.
- Printing a PSIP requirement, for example `show(CapacityReserveMargin(...))`, throws
  `MethodError: no method matching get_ext(::CapacityReserveMargin)`. PowerSystems' `show`
  calls `PSY.get_ext`, and PSIP defines a separate `get_ext` instead of extending it. This
  affects display and failing-test output only, not construction or serialization. AEM
  tests must not depend on displaying requirements.
