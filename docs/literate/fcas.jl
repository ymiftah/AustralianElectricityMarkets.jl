begin
    using AustralianElectricityMarkets
    using PowerSystems
    using DuckDB
    using Dates
    using DataFrames
    using Chain
    using AlgebraOfGraphics, CairoMakie
end;

# # FCAS in the NEM
#
# **Frequency Control Ancillary Services (FCAS)** are the National Electricity Market's
# mechanism for keeping the power system's frequency at 50 Hz. Every megawatt of frequency response has
# to come from a generator, load, or battery physically connected to the NEM, procured
# through markets AEMO runs alongside (and co-optimised with) the energy market.
#
# This page works through FCAS from AEMO's own dispatch data - the
# generic-constraint mechanism that sets requirements, the trapezium rule applied to each unit, and the joint dispatch constraints -
# illustrating every concept with real NEMWEB data for a single dispatch interval: **13 January 2025, interval
# ending 16:30, Tasmania (TAS1)**. That interval was picked because it happens to show three
# things worth seeing together: a scarce regulation market, a constraint that could not quite
# be satisfied, and a hydro unit visibly limited by its own trapezium.
#
# !!! note "References"
#     See [References](@ref fcas-references) at the end for
#     official AEMO reference documents - AEMO's [*Guide to Ancillary Services in the National Electricity
#     Market*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-ancillary-services-in-the-national-electricity-market.pdf)
#     for FCAS mechanics generally, and [*FCAS Model in
#     NEMDE*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf)
#     for the trapezium and joint-constraint mathematics reproduced in
#     [The trapezium](@ref fcas-trapezium) and [Co-optimisation in dispatch](@ref fcas-cooptimisation).

db = aem_connect();
nothing #hide

# ## The ten market ancillary services
#
# AEMO procures ten separate FCAS markets, each cleared every 5-minute dispatch interval in
# every NEM region, split two ways:
#
# - **Contingency FCAS** responds to a sudden, large frequency deviation - a generator or
#   interconnector tripping - and comes in three response-time bands, each with a raise and a
#   lower direction: **6 second**, **60 second**, and **5 minute**. A **1 second** band was
#   added on 9 October 2023 for very fast response (batteries, mostly) - deferred by this
#   package for now (see [How this maps onto the package's types](@ref fcas-types-mapping)).
# - **Regulation FCAS** (`RAISEREG`/`LOWERREG`) continuously trims small, everyday frequency
#   deviations via AEMO's Automatic Generation Control (AGC) signal - not response-time
#   banded, since it is always "on" for an enabled unit.
#


# ## Where the requirements come from
#
# Every dispatch interval, AEMO needs a target quantity (MW) of each FCAS service in each
# region - how much raise-6-second capability Tasmania needs right now, for instance. The
# requirement is expressed the same way network limits are: as a **generic constraint**, a
# linear inequality `LHS CONSTRAINTTYPE RHS` that NEMDE enforces alongside every other network
# and market constraint. `DISPATCH_FCAS_REQ` maps each `(region, service, interval)` to the
# `GENCONID` of the constraint governing it; `DISPATCHCONSTRAINT.RHS`/`LHS` are that
# constraint's two sides as actually solved that interval, and `MARGINALVALUE` is its shadow
# price (used in [Pricing](@ref fcas-pricing) below). [`read_fcas_requirements`](@ref) does
# this join and returns `RHS` as `REQUIREMENT` alongside `LHS`:

date_range = DateTime(2025, 1, 13, 16, 0):Minute(5):DateTime(2025, 1, 13, 17, 0)
requirements = read_fcas_requirements(db, date_range)
first(requirements, 5)

# A region/service is very often governed by *more than one* constraint at once - regional
# aggregate requirements, network-outage-specific requirements, islanding contingencies -
# so [`read_fcas_requirements`](@ref) returns one row **per governing constraint**, not one
# row per `(region, service)`. When a row does resolve a `DESCRIPTION` from `GENCONDATA`, it
# reads like this:

@chain requirements begin
    subset(:GENCONID => ByRow(==("F_T+NIL_ML_RECL_L5")), :BIDTYPE => ByRow(==(BidType.LOWER5MIN)))
    select(:GENCONID, :REQUIREMENT, :MARGINALVALUE, :DESCRIPTION)
end

# But most rows don't: of the 148 distinct constraints `DISPATCH_FCAS_REQ` references on 13
# January 2025, only 23 (16%) resolve a `DESCRIPTION`/`CONSTRAINTTYPE` at all in this cache.
# `GENCONDATA` is a **change-only** table - a constraint version is published only in the
# archive month it first took effect - so `missing` here almost always means that month isn't
# in the local NEMWEB cache, not that AEMO never documented the constraint. In practice,
# expect to read `REQUIREMENT`/`LHS` **without** `CONSTRAINTTYPE` or `DESCRIPTION` most of the
# time; the next section works through exactly that case.

# ## [Reading `REQUIREMENT` and `LHS` together](@id fcas-requirement-reading)
#
# `REQUIREMENT` is not itself "the MW of FCAS this region needs" - it's just the right-hand
# side of whatever linear expression `LHS` computes, and by itself its sign carries no
# physical meaning. Reading it correctly means reading it alongside `LHS` and, when it
# resolves, `CONSTRAINTTYPE`. Two regimes show up constantly in real data:
#
# - **Disarmed.** AEMO frequently defines several *variants* of the same requirement (e.g.
#   one used only during a particular network outage) and switches the inapplicable ones off
#   by offsetting their `REQUIREMENT` by a large negative multiple of 10,000 - so far below
#   any plausible FCAS quantity that `LHS` can never reach it. `MARGINALVALUE` is always
#   `0.0` on these rows; they are noise to filter out, not deficits to explain.
# - **Armed.** `REQUIREMENT` is the real bound `LHS` is being held to. It can still be
#   negative here, because `LHS` isn't always "sum of enabled FCAS targets" either - it can
#   net FCAS against other terms (like an interconnector flow) with negative coefficients.
#   Whether the constraint is satisfied or violated is `LHS` vs. `REQUIREMENT`.
#
# Tasmania's `RAISE6SEC` requirement this hour is governed by two variants of the same
# underlying constraint, `F_T+NIL_MG_R6` and `F_T++NIL_MG_R6` - and, as is typical, *neither*
# resolves a `DESCRIPTION` or `CONSTRAINTTYPE` in this cache:

@chain requirements begin
    subset(:GENCONID => ByRow(in(["F_T+NIL_MG_R6", "F_T++NIL_MG_R6"])))
    select(:GENCONID, :DESCRIPTION, :CONSTRAINTTYPE)
    unique
end

# Two things make the pair readable anyway. First, `CONSTRAINTTYPE` does resolve for enough
# *other* FCAS requirement constraints in this cache (15,092 rows on 13 January 2025 alone) to
# establish the convention: every single one is `>=` - an FCAS requirement enforces "enough
# capability must be available", never a ceiling - so `LHS >= REQUIREMENT` is a safe reading
# even when `CONSTRAINTTYPE` itself is missing. Second, what `LHS` actually sums can be
# reverse-engineered directly from the numbers: cross-referencing `DISPATCHINTERCONNECTORRES`
# for Basslink (`T-V-MNSP1`) shows `LHS(F_T++NIL_MG_R6) == LHS(F_T+NIL_MG_R6) + MWFLOW` to
# three decimal places at every interval this hour - so `F_T++` is the variant that nets
# Basslink's flow into the raise-6-second requirement, and `F_T+` is the one that doesn't.
# No `DESCRIPTION` needed to establish that; the data says it directly.
#
# Which variant is armed changes mid-interval:

@chain requirements begin
    subset(:REGIONID => ByRow(==("TAS1")), :BIDTYPE => ByRow(==(BidType.RAISE6SEC)))
    subset(:GENCONID => ByRow(in(["F_T+NIL_MG_R6", "F_T++NIL_MG_R6"])))
    select(:SETTLEMENTDATE, :GENCONID, :REQUIREMENT, :LHS, :MARGINALVALUE)
    sort([:SETTLEMENTDATE, :GENCONID])
end

# Through 16:25, `F_T++NIL_MG_R6` is armed and comfortably satisfied (`LHS` well above
# `REQUIREMENT`) while `F_T+NIL_MG_R6` sits disarmed around −9,900. At **16:30 the two swap**:
# `F_T+NIL_MG_R6` arms with `REQUIREMENT = 137.5` against `LHS = 129.65` - short by 7.84 MW -
# and picks up the \$140,000/MW violation penalty as its `MARGINALVALUE`; `F_T++NIL_MG_R6`
# disarms to −9862.5. Nothing about "Tasmania needed −9862 MW of raise" - it's the same
# requirement, expressed two ways, and dispatch is reading whichever one currently applies.
# This is the mechanism behind the pricing anomaly in [Pricing](@ref fcas-pricing) below.

# ## How a bid is submitted
#
# A generator, load, or battery bids into each FCAS market separately from its energy bid,
# and separately from every *other* FCAS market - "Tungatinah" (a Tasmanian hydro station)
# offers a completely independent shape into `LOWER6SEC` than it does into `RAISEREG`. Each
# bid has two parts:
#
# - **Ten price-quantity bands** - the same shape as an energy bid (`BIDDAYOFFER_D` prices,
#   `BIDPEROFFER_D` per-interval quantities), read by [`read_fcas_bids`](@ref).
# - **Five technical limits** forming the *FCAS trapezium* - `ENABLEMENTMIN`,
#   `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ENABLEMENTMAX`, `MAXAVAIL` - which bound how much of
#   that offer can actually be enabled, as a function of the unit's *energy* dispatch level.
#   See [The trapezium](@ref fcas-trapezium) below.

lower6sec_bids = read_fcas_bids(db, date_range, BidType.LOWER6SEC)
tungatin_bid = subset(
    lower6sec_bids,
    :DUID => ByRow(==("TUNGATIN")),
    :INTERVAL_DATETIME => ByRow(==(DateTime(2025, 1, 13, 16, 30))),
)
select(tungatin_bid, :ENABLEMENTMIN, :LOWBREAKPOINT, :HIGHBREAKPOINT, :ENABLEMENTMAX, :MAXAVAIL, :piecewise_step_data)

# ## [The trapezium](@id fcas-trapezium)
#
# The five technical limits above define a trapezoid relating FCAS availability (MW, y-axis)
# to the unit's *energy* dispatch (MW, x-axis): zero below `ENABLEMENTMIN`, ramping linearly
# up to `MAXAVAIL` at `LOWBREAKPOINT`, flat until `HIGHBREAKPOINT`, then ramping back down to
# zero at `ENABLEMENTMAX` (AEMO, *FCAS Model in NEMDE*, §2, Figure 1). Below is Tungatinah's
# actual `LOWER6SEC` trapezium for this interval, with its energy dispatch target
# (`TOTALCLEARED`, from `DISPATCHLOAD`) marked.

dispatch = read_fcas_dispatch(db, date_range)
tungatin_dispatch = subset(
    dispatch,
    :DUID => ByRow(==("TUNGATIN")), :SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))),
)
energy_target = only(subset(tungatin_dispatch, :BIDTYPE => ByRow(==(BidType.LOWER6SEC))).TOTALCLEARED)

begin
    emin, lowbp, highbp, emax, maxavail = only(tungatin_bid.ENABLEMENTMIN), only(tungatin_bid.LOWBREAKPOINT),
        only(tungatin_bid.HIGHBREAKPOINT), only(tungatin_bid.ENABLEMENTMAX), only(tungatin_bid.MAXAVAIL)
    trapezium_x = [emin, lowbp, highbp, emax]
    trapezium_y = [0.0, maxavail, maxavail, 0.0]

    fig = Figure(size = (700, 400))
    ax = Axis(
        fig[1, 1], xlabel = "Energy dispatch (MW)", ylabel = "LOWER6SEC availability (MW)",
        title = "Tungatinah's offered LOWER6SEC trapezium, 2025-01-13 16:30",
    )
    lines!(ax, trapezium_x, trapezium_y; color = :steelblue, linewidth = 2)
    vlines!(ax, [energy_target]; color = :firebrick, linestyle = :dash, label = "Energy dispatch target")
    axislegend(ax; position = :rt)
    fig
end

# Tungatinah's `TOTALCLEARED` energy target (2.0 MW) sits between `ENABLEMENTMIN` (1 MW) and
# `LOWBREAKPOINT` (5 MW) - on the trapezium's rising edge, not its flat top. So even though
# the unit *offered* up to 4 MW of `LOWER6SEC`, only a fraction is actually deliverable at
# this energy level; the exact amount is worked out in the next section.

# ## [Co-optimisation in dispatch](@id fcas-cooptimisation)
#
# NEMDE (the NEM Dispatch Engine) does not just check "is the energy target inside the
# trapezium" - it *jointly* optimises energy and every enabled FCAS service for a unit,
# because they share the same physical capability. AEMO's *FCAS Model in NEMDE* defines three
# "unit FCAS constraints" for this (§6):
#
# - **Joint ramping** (regulation only): the combined change in energy + regulating FCAS
#   target can't exceed the unit's telemetered AGC ramp rate.
# - **Joint capacity** (every enabled contingency service): energy dispatch, offset by the
#   contingency service scaled by the trapezium's slope, plus any enabled regulating FCAS,
#   must stay inside `[EnablementMin, EnablementMax]`.
# - **Energy and regulating FCAS capacity** (regulation only): same idea, energy vs.
#   regulating FCAS alone.
#
# The joint capacity constraint (§6.2) is the one that limits Tungatinah's `LOWER6SEC` above:
#
# ```math
# \text{EnergyTarget} - \text{LowerSlopeCoeff} \times \text{ContingencyTarget}
#     - [\text{LowerReg enabled}] \times \text{LowerRegTarget} \geq \text{EnablementMin}
# ```
# ```math
# \text{LowerSlopeCoeff} = \frac{\text{LowBreakpoint} - \text{EnablementMin}}{\text{MaxAvail}}
# ```
#
# Working this out by hand with Tungatinah's own numbers - `LowerSlopeCoeff = (5 - 1) / 4 =
# 1.0`, `LowerReg` not enabled this interval - gives `2.0 - 1.0 × LOWER6SEC ≥ 1.0`, i.e.
# `LOWER6SEC ≤ 1.0`: a quarter of the 4 MW offered. `read_fcas_dispatch` shows AEMO enforced
# exactly that:

@chain dispatch begin
    subset(:DUID => ByRow(==("TUNGATIN")), :SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))))
    select(:BIDTYPE, :TARGET, :ACTUALAVAILABILITY)
end

# `RAISEREG` is enabled this interval (`TARGET = 9.0`), which brings the joint capacity
# constraint's upper form into play for the three raise contingency markets too - the
# constraint from §6.2 mirrors the one above with `UpperSlopeCoeff = (EnablementMax -
# HighBreakpoint) / MaxAvail` and a `+ [RaiseReg enabled] × RaiseRegTarget` term. Reading each
# market's own trapezium (`ENABLEMENTMAX`/`HIGHBREAKPOINT`/`MAXAVAIL`) from
# [`read_fcas_bids`](@ref) and repeating the arithmetic reproduces every published
# `ACTUALAVAILABILITY` in the table above:
#
# | service | `UpperSlopeCoeff` | `2.0 + coeff × target + 9.0 ≤ EnablementMax` | published |
# |---|---|---|---|
# | `RAISE6SEC` | `(27-11)/9 = 1.778` | `≤ 9.0` (capped by the 9 MW offer itself) | `9.0` |
# | `RAISE60SEC` | `(27-6)/21 = 1.0` | `≤ 16.0` | `16.0` |
# | `RAISE5MIN` | `(26-2)/26 = 0.923` | `≤ 16.25` | `16.25` |
#
# This is what AEMO calls being **"trapped within the FCAS trapezium"**: a unit's energy
# dispatch point, not just its own market's offer, sets how much of *every* FCAS service it
# can simultaneously deliver.
#
# !!! note "What isn't reconciled here"
#     `RAISEREG`'s own published availability (9.0 MW here) is *not* derived from the joint
#     capacity constraint above - regulation is instead limited by the **joint ramping**
#     constraint (§6.1), which compares the combined energy + regulation ramp against the
#     unit's *telemetered* AGC ramp rate. That telemetry isn't published in MMSDM, so it
#     can't be reproduced from public data the way the contingency figures above can.

# ## [Pricing](@id fcas-pricing)
#
# Each FCAS market's regional price is the sum of the marginal values of every constraint
# governing that `(region, service)` this interval - the same `MARGINALVALUE` column
# [`read_fcas_requirements`](@ref) returns. [`read_fcas_prices`](@ref) reads AEMO's own
# published price (`DISPATCHPRICE`) for comparison:

raisereg_req = @chain requirements begin
    subset(:SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))), :REGIONID => ByRow(==("TAS1")), :BIDTYPE => ByRow(==(BidType.RAISEREG)))
    subset(:MARGINALVALUE => ByRow(!=(0.0)))
    select(:GENCONID, :REQUIREMENT, :MARGINALVALUE)
end

# Two constraints are contributing to Tasmania's raise-regulation price this interval - the
# region's own raise-regulation requirement, and (because regulation counts toward the
# 5-minute contingency requirement too) a share of the raise-5-minute requirement:

raisereg_req

# Summed, this reproduces AEMO's own published `RAISEREGROP` (the pre-cap regional price)
# to five decimal places:

prices = read_fcas_prices(db, date_range)
raisereg_price = only(
    subset(
        prices, :SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))),
        :REGIONID => ByRow(==("TAS1")), :BIDTYPE => ByRow(==(BidType.RAISEREG)),
    ).ROP
)
(derived = sum(raisereg_req.MARGINALVALUE), published = raisereg_price)

# Not every FCAS price is this orderly. In the same interval, Tasmania's `RAISE6SEC`
# requirement could not be fully satisfied: this is the same `F_T+NIL_MG_R6`/`F_T++NIL_MG_R6`
# swap from [Reading `REQUIREMENT` and `LHS` together](@ref fcas-requirement-reading) - at
# 16:30 the armed variant needed `LHS ≥ 137.5` but only reached `129.65`, so `MARGINALVALUE`
# on that single constraint is **\$140,000/MW**, AEMO's constraint-violation penalty rate, not
# a market-clearing price. That one dominant term is why the regional `RAISE6SEC` price this
# interval is over five thousand dollars per MW - about sixteen times TAS1's own energy price
# (`RRP`) that same interval:

raise6sec_req = @chain requirements begin
    subset(:SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))), :REGIONID => ByRow(==("TAS1")), :BIDTYPE => ByRow(==(BidType.RAISE6SEC)))
    select(:GENCONID, :REQUIREMENT, :MARGINALVALUE)
    sort(:MARGINALVALUE, rev = true)
end
first(raise6sec_req, 3)

#-
raise6sec_price = only(
    subset(
        prices, :SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))),
        :REGIONID => ByRow(==("TAS1")), :BIDTYPE => ByRow(==(BidType.RAISE6SEC)),
    ).ROP
)
(derived = sum(raise6sec_req.MARGINALVALUE), published = raise6sec_price)

# ## The whole interval, end to end
#
# Pulling the pieces together: which Tasmanian units actually supplied `RAISE6SEC` this
# interval, and how much?

begin
    tas_units = @chain read_units(db) begin
        subset(:REGIONID => ByRow(==("TAS1")))
        select(:DUID, :STATIONNAME)
    end
    raise6sec_dispatch = @chain dispatch begin
        subset(:SETTLEMENTDATE => ByRow(==(DateTime(2025, 1, 13, 16, 30))), :BIDTYPE => ByRow(==(BidType.RAISE6SEC)))
        innerjoin(tas_units, on = :DUID)
        subset(:TARGET => ByRow(>(0)))
        sort(:TARGET, rev = true)
        select(:STATIONNAME, :DUID, :TARGET, :ACTUALAVAILABILITY)
    end
    raise6sec_dispatch
end

#-
begin
    plt = data(raise6sec_dispatch) *
        mapping(:DUID => "Unit", :TARGET => "RAISE6SEC target (MW)", color = :STATIONNAME => "Station") *
        visual(BarPlot)
    draw(
        plt;
        figure = (; size = (700, 350), title = "Tasmanian RAISE6SEC dispatch, 2025-01-13 16:30"),
        axis = (; xticklabelrotation = pi / 4),
    )
end

# ## [How this maps onto the package's types](@id fcas-types-mapping)
#
# This package represents FCAS requirements the same way it represents network limits -
# both are AEMO generic constraints, and both become the same type:
#
# - [`GenericConstraint`](@ref) - one component per `GENCONID` actually invoked in dispatch,
#   with its LHS `terms` ([`UnitTerm`](@ref)/[`RegionTerm`](@ref)/[`InterconnectorTerm`](@ref))
#   and, for FCAS requirements specifically, a non-empty `governs` list tagging which
#   regional `(service, region)` price its shadow price feeds - see
#   [`add_nem_constraints!`](@ref).
# - [`FCASTrapezium`](@ref)/[`FCASBid`](@ref) - a device's offered trapezium and priced
#   10-band offer curve for one FCAS market, attached as a `Deterministic` time series via
#   [`set_fcas_bids!`](@ref).
# - [`ConstrainedNetworkConfiguration`](@ref) - a [`nem_system`](@ref) configuration that
#   pulls in all the tables this page reads and builds both the bids and the constraints
#   automatically (it requires a `date_range` keyword, since both are interval-scoped).

sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
get_component(GenericConstraint, sys, "F_T+NIL_MG_R6")

# **Not (yet) modelled** by this package, stated plainly:
#
# - The trapezium and joint-capacity/ramping constraints in [Co-optimisation in
#   dispatch](@ref fcas-cooptimisation) are *read and explained* here, and their raw
#   parameters are retrievable from `FCASTrapezium`, but not *enforced* in a
#   `PowerSimulations.jl` dispatch problem - that is the intended next layer built on top of
#   `GenericConstraint`. Enabling that is on the [Roadmap](@ref).
# - Mainland-vs-local contingency splits (e.g. South Australian islanding).
# - The `RAISE1SEC`/`LOWER1SEC` markets.
# - AGC ramp-rate scaling (the missing telemetry noted above).
# - FCAS cost recovery (`BASE_COST`/`ADJUSTED_COST`/CMPF/CRMPF in `DISPATCH_FCAS_REQ`).
# - Recomputing `RHS` from AEMO's RPN expressions - NEMDE derives it from live SCADA that
#   MMSDM doesn't publish; `add_nem_constraints!` replays `DISPATCHCONSTRAINT.RHS` instead.

# ## [References](@id fcas-references)
#
# 1. AEMO, [*Guide to Ancillary Services in the National Electricity
#    Market*](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-ancillary-services-in-the-national-electricity-market.pdf) -
#    general description of FCAS requirements, offer structure and settlement.
# 2. AEMO, [*Market Ancillary Service Specification*](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/ancillary-services/market-ancillary-services-specification-and-fcas-verification-tool)
#    (MASS) - the current, binding technical specification for each FCAS product.
# 3. AEMO, [*FCAS Model in NEMDE: Scaling, Enablement, and Co-optimisation of FCAS Offers in
#    Central Dispatch*](https://nempy.readthedocs.io/en/latest/_downloads/e3c8a21d3084db332a30bd0d564e93c3/FCAS%20Model%20in%20NEMDE.pdf),
#    May 2017 - source for the trapezium (§2-3) and the joint ramping/capacity constraints
#    (§6) reproduced in [The trapezium](@ref fcas-trapezium) and [Co-optimisation in
#    dispatch](@ref fcas-cooptimisation). Predates the 1-second markets and later Primary
#    Frequency Response rule changes, but the trapezium and joint-constraint mathematics it
#    documents are unchanged.
# 4. AEMO, *MMS Data Model Report*, Electricity - per-table definitions for the tables read
#    on this page:
#    [`DISPATCH_FCAS_REQ`](https://visualisations.aemo.com.au/aemo/nemweb/mmsdatamodelreport/electricity/mms%20data%20model%20report_files/MMS_116.htm),
#    [`DISPATCHLOAD`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS_128.htm),
#    [`DISPATCHPRICE`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS_130.htm).
