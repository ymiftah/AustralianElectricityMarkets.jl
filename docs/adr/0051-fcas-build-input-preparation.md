# 0051. Prepare FCAS inputs once per model build

## Status

Accepted

## Context

FCAS variable construction reads and scales bids, then enablement preparation reads and scales
those same bids again. Constraint, objective and joint-ramping construction repeat these reads.
Moving the same work into system creation alone would reduce build timings without reducing the
combined time when historical replay creates a fresh system for each interval.

A general System can support dispatch, five-minute lookahead or thirty-minute lookahead. Effective
trapeziums depend on that process, the selected horizon and the model resolution. The offered bids
and raw telemetry therefore remain attached to components as the reusable system representation.

## Decision

During FCAS argument construction, prepare device telemetry once for the build horizon and prepare
one set of scaled trapeziums, offer curves, enablement masks and ramp capabilities per service and
bid direction. Both battery regulation sides share the device telemetry and service AGC inputs;
the combined stranded-unit test is evaluated after both sides are prepared.

Variable, constraint, ramping and objective construction consume these prepared values. The
private input object belongs to the build's JuMP model and passes data between PSI's argument and
model callbacks. It is not attached to the System or retained in a global cache. The pinned PSI
revision `93e1fb1469307d6bd78a90c8c4ad14f927bd4a90` resets a rebuilt DecisionModel with a new
optimisation container, so a rebuild prepares current input series afresh.

System preparation collects device lists once per setter call and regional devices once per
region during service creation. These temporary indexes do not survive System mutation.

## NEM semantics

This is a change to processing order, with no intended change to market equations or costs.
The reference is AEMO's [FCAS Model in NEMDE, version 3.0, effective 3 June 2024](https://aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf):

- Section 4, pages 14 to 17: AGC enablement, AGC ramp and UIGF scaling, including Table 1's
  dispatch and pre-dispatch timing. The existing scaling function is shared with preparation.
- Section 5, pages 18 to 19: enablement tests after scaling, including each battery bid side and
  combined stranded-unit checks. Existing enablement predicates are reused.
- Section 6, pages 20 to 28: joint capacity, energy/regulation and ramp constraints. Their equations,
  slack bounds and penalties remain in construction; only the numerical inputs are prepared earlier.
- Section 2, page 6: FCAS quantity and price bands. Offer-band bounds and cost coefficients remain
  unchanged, including the system-base and interval-duration conversions.

## Verification

Regressions cover process-specific scaling and rebuilding after telemetry replacement. Existing
FCAS model tests cover generator, load and battery dispatch and constraint behavior. Performance
verification measures system preparation and model building together, with numerical model
signatures checked against the previous implementation.

Local verification on Julia 1.13.1 passed the full root suite (1,519 checks), the full
Simulations suite (1,220 checks), and the isolated rebuild regression (9 checks). Runic and
all applicable pre-commit hooks passed. Julia 1.11 CI remains to be run when the branch is published.

The reproducible harness is `AustralianElectricityMarketsSimulations/scripts/benchmark_replication_build.jl`.
Run it with the Simulations test project, one Julia thread, the same interval and cache on both
revisions, and three warmed samples after one compilation warmup. It times system preparation and
model building separately and together, records Julia allocations, and hashes sorted affine
constraint coefficients, sets and objective coefficients. The signature also captures variable
bounds. Signature calculation and compilation warmup are excluded from the reported medians.

### Real-cache results

For dispatch interval `2026-06-06T11:15:00`, with the local `~/.nemdb_cache`, Julia 1.13.1,
one thread and a 2 GB heap hint, the medians of three warmed samples were:

| Measurement | Before | Prepared inputs | Reduction |
| --- | ---: | ---: | ---: |
| System preparation | 41.50 s | 37.11 s | 10.6% |
| Model build | 24.81 s | 21.11 s | 14.9% |
| Combined preparation and build | 66.11 s | 58.27 s | 11.9% |
| System allocations | 3.949 GB | 3.896 GB | 1.3% |
| Model build allocations | 12.535 GB | 12.336 GB | 1.6% |

The before revision was `83d32d2`, the demand-query change merged into the branch's base
`04bfb38`; the after measurement used this implementation. All warmup and measured builds had
58,851 variables and 111,062 constraints, with matching numerical signature
`b3bc18af21baa90bd58c6d86f1c8f69af4a3d2d7c1f890207da5b8eb87d2b1a6`.

Before combined samples ranged from 66.04 to 68.01 seconds; after samples ranged from 58.22
to 58.58 seconds. These are sequential measurements of one interval on a machine also running
an independent dispatch-validation job, so the observed timings are not a general speedup
guarantee. Allocations are cumulative Julia allocations, not peak memory. Solver runtime was
not measured. Signatures identify variables by creation index, so reordering equivalent model
construction would require a different comparison method.

Reproduce each revision's measurement with:

```bash
JULIA_NUM_THREADS=1 JULIA_PKG_PRECOMPILE_AUTO=0 julia \
    --project=AustralianElectricityMarketsSimulations/test --heap-size-hint=2G \
    AustralianElectricityMarketsSimulations/scripts/benchmark_replication_build.jl \
    2026-06-06T11:15:00 ~/.nemdb_cache current 3
```

The harness can be copied into the before checkout without modifying its package sources.
