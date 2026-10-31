# 0078. Reduce repeated market-input work during system construction

## Status

Accepted.

## Context

A warmed full-day NEMDE system build for 22 January 2026 issued 78 SQL queries and
allocated approximately 5 GB. Repeated reads matter, but the largest individual query
spent approximately four seconds deduplicating historical generic-constraint terms
before selecting the exact versions invoked during the day.

## Decision

Filter each SPD term source to the requested `(GENCONID, EFFECTIVEDATE, VERSIONNO)`
tuples before its latest-archive window. Keep the existing upper effective-date bound,
window partition keys, final equality joins and connection-point validity conditions.
A selection on fields included in every window partition commutes with that window;
this removes unrelated partitions without changing the selected archive copy.

At native resolution, project the six FCAS trapezium columns with the offer quantities
and prices from the same latest-period query. This removes a second period scan and
DataFrames join. Keep the existing path for explicitly aggregated requests, whose
averaged quantities and native trapezium timestamps have different semantics.

Group prepared energy bids by unit and direction once. Device branches use this lookup
instead of scanning the whole bid table repeatedly. Copy each selected curve vector
before storing it in a time series so that it owns its vector independently of the
full prepared table. Preserve row order, missing-side behavior and diagnostics.

Keep public readers fresh on every call. Do not introduce a connection-wide SQL cache:
queries may reference temporary registered tables, and consumers mutate returned data.
Other duplicate reads remain candidates for a separately measured change.

## Market correctness

This changes query execution and conversion work, with no new dispatch bound,
constraint or cost term and no departure from AEMO's model.

The exact constraint-version tuple and the separate connection point, region and
interconnector keys follow AEMO's [Electricity Data Model Package Summary 5.6,
Generic Constraints entity diagram](https://di-help.docs.public.aemo.com.au/Content/Data_Model/Electricity_Data_Model_Package_Summary_56.pdf).
FCAS quantities and capability fields remain attributes of the same period offer,
as defined in AEMO's [Electricity Data Model Report 5.5, BIDPEROFFER_D](https://di-help.docs.public.aemo.com.au/Content/Data_Model/MMS_Data_Model_Report_55.pdf).
The direction, trading-day, interval and latest-version keys are retained.

## Validation

The isolated real-day constraint query returned identical 21,303-row results for the
original and proposed SQL in four paired runs. Warm median query time fell from
3.616 to 0.767 seconds. Julia allocation stayed approximately 3.6 MB; DuckDB's native
working memory is not included in that allocation measure.

Regression checks cover duplicate and absent requested versions, later-archive
coefficient corrections in all three SPD term tables, and FCAS equivalence against
the previous two-read construction at native, five-minute and fifteen-minute
resolution. Whole-system timing and allocation results are recorded with the paired
benchmark artifacts under `scripts/results/market_input_reuse_20261026/`.

Three warmed whole-system builds per implementation, without overlapping test runs,
measured mean construction time of 24.418 seconds for the original and 18.823 seconds
for the optimized implementation, a 22.9% reduction. Mean Julia allocations fell from
5,027,112,939 to 4,526,388,336 bytes, a 10.0% reduction. Measured compilation time was
zero in all six samples. These figures cover system construction only, exclude DuckDB
native allocation, and do not measure solve time or peak resident memory savings.
All 456,042 FCAS bid rows and the system component counts matched the original.
The full root suite passed 1,467 checks and the full Simulations suite passed 1,925.
