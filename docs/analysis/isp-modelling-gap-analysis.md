# ISP modelling capability gaps

Assessed on 28 October 2026 against the downloaded September 2026 ISP package and the
reviewed Sienna sources. The investment comparison includes the open draft PR #72 stack,
not only the older PSINV default branch. Inspection is static; package interoperability,
formulation correctness and NEM-scale performance have not been tested here.

The reusable foundation includes JuMP optimisation, technology portfolios, investment
variables, standard cost accounting, battery dispatch, transport networks and probabilistic
adequacy. Most project-specific work is interpretation, additional model formulations,
model sequencing and validation.

## Scope and evidence

The cached Step Change model has 590 `Constraint` objects. Categories include REZ import
and export limits, shared REZ upgrades, connection build limits, distribution constraints,
gas infrastructure limits, hydrogen consumption, hydro minimum releases, emissions,
policies and system-strength requirements. Category labels establish the presence of
source objects, not that every object is active in every period or selected configuration.

Its selected LT Plan object is named `Fitted 6 LBs day - Central - 6 year steps No Perpetuity`,
with `Block Count = 6` and `At a Time = 6`. Other explicit records include `Max Cycles Day`,
`Natural Inflow`, `Pump Load`, `Pump Units`, `Max Energy Day`, `Max Energy Year`, and
forward/backward `Loss Incr2` terms.

The local evidence comes from joins of `step_change.t_object`, `t_class`, `t_category`,
`t_attribute_data`, `t_attribute`, `t_data` and `t_property` in the extracted cache.

The target should be the subset actually used by this package. For example, Step Change's
tags have action ID `0` (assignment) or no explicit action; the presence of other operators
in the schema dictionary is not evidence that they are used. Unsupported source constructs
should produce a clear coverage error rather than silently disappearing from the model.

For the overall workflow and modelling conventions, the reference is the
[AEMO ISP Methodology, June 2025](https://www.aemo.com.au/-/media/files/stakeholder_consultation/consultations/nem-consultations/2024/2026-isp-methodology/isp-methodology-june-2025.pdf):
sections 2.2, 2.4.2, 2.4.3, 3.1, 3.3.3, 4, 5 and 6. These cover planning stages,
chronology, adequacy feedback, operational validation and development-path assessment.

## Capability matrix

Engineering sizes below are qualitative judgments about scope, not effort estimates.
"Absent" means no corresponding implementation was found in the reviewed interfaces and
source paths; it does not establish that no external Julia package implements the feature.

| Area | Reusable capability | Remaining engineering | Assessment |
| --- | --- | --- | --- |
| PLEXOS input interpretation | Raw XML/CSV cache and AEM's limited scalar property resolver | Resolve the used date, band, timeslice, Variable and Data File semantics; preserve membership and property identity; map units and reference years; distinguish existing assets, candidates and fixed pathway assumptions | Large adapter task |
| Generic planning constraints | JuMP and PSINV requirement extension mechanisms | Translate the cached constraint coefficients and scope into expressions over dispatch, installed/built capacity, storage, fuel, demand and transport, including daily/annual aggregations | Large compiler and formulation task |
| REZ and connection development | Transport capacity and discrete line investments in draft upstream work | Represent shared upgrades, resource and connection limits, build-rate restrictions, project dependencies and staged options | Large ISP-specific extension |
| Chronology and rolling planning | Investment periods and weighted operating slices | Construct compatible time aggregation; implement unequal-duration fitted blocks if required; transfer assets, budgets and operational state between rolling planning solves | Large controller/temporal task |
| Asset lifecycles | Build variables; portfolio retirement and lifetime metadata | Enforce closures, vintage expiry, retirement choices, replacement and commissioning delays where needed; validate consistency of financial horizon treatment | Large investment-model extension |
| Reservoir hydro and pumped hydro | A simple hydro energy budget in PSINV; storage and hydro representations elsewhere in Sienna | Connect reservoir/waterway balances, inflows, spills, releases and carry-over to investment choices; support the required pump/turbine configuration | Large for full representation; budgets provide a simpler initial approximation |
| Battery operating details | MW/MWh sizing, efficiency, duration limits and state of charge | Add used cycle restrictions; configure initial/final states and cross-window carry-over; add operational validation strategies where required | Targeted extensions plus temporal integration |
| Fuel availability and changing fuel economics | Linear fuel consumption/cost expressions in draft work | Support time-varying prices, shared daily fuel limits and multi-fuel obligations as required; a full gas supply-development model would be a separate larger undertaking | Medium for fixed caps; large for gas-network co-optimisation |
| Hydrogen and flexible demand | Portfolio demand types and static demand formulations | Add production/energy obligations, flexibility windows, siting decisions and links to fuel or other commodity constraints | Large if enabled in the initial study |
| Distributed resources and DNSP limits | Standard supply and storage candidates | Bind distributed generation, storage and flexible loads to the cached distribution envelopes and coefficients; preserve embedded-PV accounting | ISP-specific extension |
| Firm-capacity calibration | PRAS assessment and capacity-credit routines | Build the planning-to-adequacy loop, map firm contribution factors, reserve sharing and weather/outage cases back into planning inputs | Mostly integration, with additional planning constraints |
| Detailed operations | PowerSimulations and AEM dispatch, FCAS and loss formulations outside the three packages | Materialise investment results into operational systems; add future cost/bid assumptions, outage/maintenance scenarios and energy targets | Substantial integration; many formulations can be reused |
| Security and engineering validation | Importable proxy constraints; separate network/dynamics tools | Preserve supplied security proxies; separate studies are needed to derive or update detailed engineering limits for changed systems | Separate engineering workstream for a full ISP process |
| Scenario and development-path selection | Individual optimisation runs and results | Orchestrate comparable cases, counterfactuals, pathway comparisons and decision analysis | Analysis/controller task rather than a new optimisation engine |

## Concrete limitations in the inspected investment branch

The following examples are from
`PowerSystemsInvestments.jl` revision `0e318ef036a018dcdd937b30fca912029909f2b1`,
the head of [open draft PR #72](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/72)
at the time of inspection.

### Fitted-block durations

`_get_time_step_length` checks that all timestamps within an operating slice are evenly
spaced and errors otherwise. A single-step slice is treated as one hour. The mapping stores
one duration per slice, rather than a duration per fitted block.
See [time_mapping.jl](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/0e318ef036a018dcdd937b30fca912029909f2b1/src/base/time_mapping.jl).

This is not a general unequal-duration fitted-block implementation. Uniform hourly or
half-hourly steps can avoid that feature gap initially, at a greater model size. Reproducing
the compression requires extending the time mapping and checking every duration-dependent
energy, ramp, cost and state equation. The choice of aggregation also needs validation.

### Capacity accumulation and retirement

The inspected cumulative supply-capacity expressions add each period's build to existing
capacity. Those expressions do not remove capacity through expiry or retirement. Portfolio
retirement metadata is not equivalent to a retirement decision variable or an enforced
closure schedule.
See [supply_tech.jl](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/0e318ef036a018dcdd937b30fca912029909f2b1/src/technology_models/technologies/supply_tech.jl)
and [open retirement issue #38](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/issues/38).

### Storage boundary conditions

`ChronologicalStorageDispatch` explicitly initializes stored energy to zero at the start of
each investment stage. It links state across the operating slices within that stage.
`CyclicalStorageDispatch` instead wraps within a slice. Neither behaviour is automatically
the desired rule for seasonal storage or a chain of rolling planning solves.
The inspected storage formulation has no explicit daily cycle counter corresponding to the
source model's `Max Cycles Day` property.
See [storage_tech.jl](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/0e318ef036a018dcdd937b30fca912029909f2b1/src/technology_models/technologies/storage_tech.jl).

Storage operating strategies used to validate limited foresight belong in the operational
validation workflow, rather than being assumed to be the expansion model's operating rule.
This distinction is described in AEMO's methodology, section 3.3.3.

### Fuel prices and thermal detail

The fuel-curve implementation accepts a constant fuel price and explicitly rejects a
time-series price. It supports linear cost/fuel curves; other curve types error.
The thermal draft describes relaxed commitment and does not provide a completed integer
commitment implementation merely by defining the `IntegerUnitCommitment` type.
See [fuel_curve.jl](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/0e318ef036a018dcdd937b30fca912029909f2b1/src/technology_models/technologies/common/fuel_curve.jl)
and [PR #69](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/69).

Detailed commitment should first be evaluated using the existing operational modelling
stack. A full unit-commitment formulation is not necessary for every planning approximation.

### Hydro budgets versus water systems

`BasicDispatchWithBudget` limits generation over operating slices. It is not a complete
optimisable reservoir and waterway model. A data-level hydro type or a PRAS reservoir mapping
does not fill the investment-model gap.
See [supply_tech.jl](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/0e318ef036a018dcdd937b30fca912029909f2b1/src/technology_models/technologies/supply_tech.jl)
and [open hydro investment issue #42](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/issues/42).

### Reserve margins versus firm capacity

The draft requirement counts supply capacity, time-varying renewable output and storage
net injection according to its selected formulation. PR #72 explicitly lists reserve-margin
derating factors as not included. These equations should not be assumed equivalent to the
source model's firm-capacity contribution rules.
See [capacity_reserve_margin.jl](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/blob/0e318ef036a018dcdd937b30fca912029909f2b1/src/requirement_models/capacity_reserve_margin.jl)
and [PR #72](https://github.com/Sienna-Platform/PowerSystemsInvestments.jl/pull/72).

PRAS already offers EFC and ELCC through `PRASCapacityCredits`; these calculations should
be reused. The missing part is configuring appropriate cases and feeding the resulting
planning assumptions back into the investment model.
See the [PRAS capacity-credit documentation](https://github.com/NatLabRockies/PRAS/blob/main/docs/src/PRAS/capacitycredit.md).

## Work that should be reused

The draft upstream stack already contains continuous/discrete build decisions, standard
investment costs, storage sizing, thermal operating extensions, transport/PTDF work and
several policy formulations. These need independent checks and compatible pins, not blanket
replacement with AEM-specific implementations.

PRAS provides the Monte Carlo engine, shortfall metrics and capacity-credit algorithms.
PowerSimulations and HydroPowerSimulations are the first places to evaluate detailed
operational formulations. AEM already has dispatch, FCAS, constraint and loss modelling that
can contribute to validation, although the PLEXOS planning constraints bind different
variables and cannot simply be treated as historical NEMWEB dispatch constraints.

Finance requires an explicit convention audit against the source model, including money
basis, per-MW/per-unit definitions, recovery periods and horizon boundaries. Existing
discounting and annualisation machinery should be reused where conventions match.

## Practical investment-first priorities

1. Establish compatible, pinned upstream revisions and small independently checked models.
2. Build a semantic ISP adapter and constraint representation, with source provenance for
   each interpreted parameter and constraint.
3. Add the lifecycle, chronology and resource constraints required by the chosen investment
   experiment. Explicitly document any initial approximation of hydro, fuels or demand.
4. Materialise investment results into operating/adequacy systems and automate validation
   feedback and comparisons.

The adapter must identify which inputs represent committed assets, policy obligations,
physical limits or an imposed development path. Releasing a build fixing to explore an
alternative must be a deliberate study setting, not a side effect of incomplete parsing.

The published package is a DLT configuration that incorporates some SSLT outputs. AEMO
also says confidential inputs were removed, so exact reproduction of the published ISP
outcomes is not guaranteed even with the supplied PLEXOS model. The public configuration
is a more defensible first numerical benchmark.
Source: [2026 ISP Model Instructions, sections 1 and important notice](https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-plexos-model-instructions.pdf?rev=79d503ba4e584fa88c65ee90e25ad7a2&sc_lang=en).

This is a capability assessment. It does not select the eventual approximation level or
constitute an implementation design.
