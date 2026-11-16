# 0017 `FCASMarket`: joint capacity, per-side BDU regulation, §5 gating

## Status

Accepted; reads and units amended by [0098](0098-precomputed-observed-state-inputs.md) and [0101](0101-aem-writes-aemsim-reads.md), the AGC ramp by [0087](0087-agc-ramp-rate-from-mmsdm.md), load FCAS by [0038](0038-load-fcas-offers.md), elastic rows by [0023](0023-elastic-fcas-rows-and-area-balance-cvp.md). Source: AEMO *FCAS Model in NEMDE* v3.0.

## What

- Per offer, a capacity variable, `FCASOfferBandVariable`s bounded by band width and summing to it, and a `MaxAvail` row. Each band is priced at its own price; convexity fills the cheapest first.
- Both joint capacity forms apply to every service (§6.2, §6.3), using that service's own trapezium and capacity variable:
  - `energy + UpperSlopeCoeff × capacity + [RaiseReg target] ≤ EnablementMax`
  - `energy − LowerSlopeCoeff × capacity − [LowerReg target] ≥ EnablementMin`
  - A contingency service carries the regulation targets (`+RaiseReg` upper, `−LowerReg` lower; swapped for a load, [0038](0038-load-fcas-offers.md)). A regulation service has no cross term.
- Storage energy term: net `Out − In` for contingency; for regulation the bid side's own energy (`Out` for a GEN bid, `−In` for a LOAD bid), because net energy on both sides pins a two-sided unit at zero (§6.3 footnote 8, §2.4).
- A `PSY.Storage` bidding regulation on both sides gets two `FCASSideCapacityVariable`s (`"<service>_gen"`, `"<service>_load"`), each with its own rows, trapezium, energy term and offer curve. `FCASUnitRegulationTarget` is the unit total that §6.2's cross term and §6.4 read.
- §6.4 BDU row (`FCASUnitConstraint`, meta `"bdu_ramping"`): `Reg_gen + Reg_load ≤` the AGC ramping capability, for both-sided units only.
- §6.1 joint ramping row (meta `"joint_ramping"`): net energy plus the regulation target against `InitialMW ± AGC ramp`, for every regulation contributor. Fast-start units are exempt (Table 3 footnote 11).
- §5 pre-conditions, computed by AEM into the effective offer (`fcas_preconditions_ok`, `fcas_state_stranded_ok`, `fcas_both_sides_stranded_ok`): `MaxAvail > 0`, a priced band with quantity, `EnablementMax ≥ EnablementMin`, sign, energy max availability (bid `MAXAVAIL`, per side for storage), stranded (`InitialMW` against the trapezium), and AGC status for regulation. For a both-sided bid each side's own checks run first, then one combined stranded check `EnablementMin_LOAD ≤ InitialMW ≤ EnablementMax_GEN` gates both.
- A device may contribute to only one `FCASService` per market (the build throws); `check_fcas_services` rejects both directions of a contingency market, or of any market on a non-storage device.

## How

- A disabled offer is written as zero `MaxAvail`, slopes and widths, with limits `∓FCAS_INACTIVE_LIMIT_MW`.
- A malformed offered trapezium (breaking `EnablementMin ≤ LowBreakpoint ≤ HighBreakpoint ≤ EnablementMax` or `MaxAvail < 0`) is rejected on read, as AEMO rejects it on submission.

## Departures from AEMO and nempy

- **§5 disabled offers.** AEMO creates no variable for an offer failing §5. Here the zero-`MaxAvail` row is elastic at `FCAS_MAXAVAIL_CVP_FACTOR` (155, *Schedule of Constraint Violation Penalty Factors* v8.0 item 19), above the FCAS requirement and energy balance CVPs, so a disabled offer clears only by paying it.
- **§6.1 energy term.** nempy adds energy only for dispatch types carrying a regulation bid; we use net energy for every `PSY.Storage` unit (unit-level form, one signed `INITIALMW`).
- **§6.1 zero rate.** nempy builds rows at a zero ramp rate; we follow AEMO's "rate greater than zero".
- **§6.2 lower form.** nempy gives a load side's `lower_reg` coefficient `+1.0`; we subtract the whole unit `LowerRegTarget`.
- **No simultaneous charge and discharge.** Per-side energy terms assume it; [0020](0020-batteries-under-nem-dispatch.md) does not forbid it. The real-data suite asserts none occurs.
- **§5 daily or profiled energy** pre-conditions are not enforced.
- **§6.1 rate.** The ramp rate is derived, not the SCADA rate ([0087](0087-agc-ramp-rate-from-mmsdm.md)); §4 scaling is [0018](0018-fcas-trapezium-scaling.md).

## Why

- Building only the form matching a service's direction is wrong per §6.2: it lets a maximise-FCAS objective trade `RAISEREG` to zero to grow a contingency service.
- AEMO's amalgamated trapezium is for publication and §5 only; §6.3 footnote 8 and §6.4 give per-side targets.
