# 0051: Replication build avoids per-item scans of the system

## Status

Accepted.

## Context

A warm replication interval took about 60 s before the solve (system 34 s, build 21 s, solve 4 s).
Profiling attributed almost all of it to repeated work, not to formulation arithmetic:

- `PowerSystems.get_contributing_device_mapping` rescans every device for every service. With 1241
  services (1185 generic constraints) and 728 devices it took 14.9 s, once in PSI's template
  finalisation.
- `add_nem_constraints!` called `_region_devices`, which walks all generators, storages and loads
  and runs seven time-series metadata queries per load, three times per region term.
- `set_fcas_bids!` read `BIDPEROFFER_D` and `BIDDAYOFFER_D` once per FCAS bid type (eleven times),
  each with a schema probe and a windowed query.
- `filter_buildable_generic_constraints` called `get_contributing_devices` once per constraint.

## Decision

Replace each scan with one pass and reuse the result, without introducing cache objects or hidden
state:

- The pinned PowerSimulations revision builds the service to devices mapping in one pass over the
  devices.
- `add_nem_constraints!` keeps a local `(region, loads)` to devices table for the call.
- `read_fcas_bids` takes a vector of bid types and queries each table once with `BIDTYPE IN (...)`,
  partitioning and joining on `BIDTYPE`; the single-type method delegates to it.
- `filter_buildable_generic_constraints` builds a service UUID to devices index once.

Warm timings after the change, same interval and cache: system 15 s, build 4 s, solve 4 s.
The model has the same 58,851 variables and 39,727 constraints.

## Consequences

The first interval in a process still pays about 300 s of compilation; the target applies to a
reused Julia process. The mapping fix lives in the PowerSimulations fork, so the pinned revision must
be kept when the fork is rebased.
