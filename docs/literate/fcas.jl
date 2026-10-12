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

# ## [The cases in AEMO's FCAS model](@id fcas-cases)
#
# AEMO's *FCAS Model in NEMDE* describes the trapezium through a sequence of cases, and this
# section follows that document's order (the section numbers below are AEMO's): the trapezium
# of each type of participant (§2), where the energy target falls on it (§3), how NEMDE scales
# the bid before the optimisation (§4), the pre-conditions for enabling a service (§5), the
# constraints that couple energy and FCAS on a unit (§6) and how the availability that AEMO
# publishes is calculated (§7). The charts use illustrative numbers, not market data, so every
# case can be seen on its own.

const FCAS_COLORS = Makie.wong_colors()

function trapezoid(t)
    emin, low, high, emax, fmax = t
    return Point2f[(emin, 0), (low, fmax), (high, fmax), (emax, 0)]
end

function draw_trapezium!(ax, t; color = FCAS_COLORS[1], filled = true, linestyle = :solid)
    poly!(
        ax, trapezoid(t);
        color = filled ? (color, 0.25) : :transparent, strokecolor = color, strokewidth = 2, linestyle,
    )
    return nothing
end

# ### [The trapezium of each type of participant (§2)](@id fcas-cases-participants)
#
# An FCAS bid always has ten price bands and the same five technical limits. What changes with
# the type of participant is what the horizontal axis means and the signs the limits may take:
#
# | Participant | Horizontal axis | Limits | AEMO figure |
# | --- | --- | --- | --- |
# | Scheduled or semi-scheduled generating unit | generation (MW) | all positive | 1, 2 |
# | Scheduled load | consumption (MW) | all positive | 3 |
# | Wholesale demand response unit | load reduction (MW), equivalent to generation | all positive | 4 |
# | Bidirectional unit (BDU), contingency service | net injection, consumption to the left of 0 and generation to the right | Max Availability positive; the other limits may be positive or negative, and Enablement Max always allows generation | 5 |
# | BDU, regulation service, generation side only | generation (MW) | non-negative, as a generator | 6 |
# | BDU, regulation service, load side only | consumption (MW) | all non-positive | 7 |
# | BDU, regulation service, both sides | the two bids are optimised individually but amalgamated for validation, the enablement pre-condition, the "trapped" test and the availability calculation | contiguous at 0 (see below) | 8, 9 |
# | FCAS-only unit | none: the unit has no energy dispatch | a vertical line at 0 up to Max Availability | 10 |
#
# A BDU's contingency bid is for the whole unit and is a single trapezium straddling zero. A
# regulation bid may be on either side or on both, and when it is on both sides the rules are:
#
# - the bids are contiguous: Enablement Max (load) = 0 = Enablement Min (generation);
# - both trapeziums have the same upper angle and the same lower angle;
# - if the upper angle is below 90 degrees, the generation side is a triangle
#   (High Breakpoint = Low Breakpoint = 0);
# - if the lower angle is below 90 degrees, the load side is a triangle
#   (High Breakpoint = Low Breakpoint = 0).

let
    fig = Figure(size = (1000, 520))
    panels = [
        ("Generator, load, demand response (Figs 1-4)", [(150, 200, 350, 450, 60)], "Energy (MW)"),
        ("BDU contingency (Fig 5)", [(-80, -30, 100, 200, 50)], "Net injection (MW)"),
        ("BDU regulation, generation side (Fig 6)", [(0, 30, 90, 130, 30)], "Generation (MW)"),
        ("BDU regulation, load side (Fig 7)", [(-130, -90, -30, 0, 30)], "Net injection (MW, load side)"),
    ]
    for (i, (title, ts, xlabel)) in enumerate(panels)
        ax = Axis(fig[1, i]; title, titlesize = 11, xlabel, ylabel = i == 1 ? "FCAS (MW)" : "")
        foreach(t -> draw_trapezium!(ax, t), ts)
        vlines!(ax, 0; color = (:gray, 0.5), linestyle = :dot)
    end
    ## Figs 8-9: amalgamated regulation trapezium of a BDU bidding on both sides.
    ax = Axis(fig[2, 1]; title = "BDU regulation, both sides, amalgamated I (Fig 8)", titlesize = 11, xlabel = "Net injection (MW)", ylabel = "FCAS (MW)")
    poly!(ax, Point2f[(-60, 0), (-60, 30), (100, 0)]; color = (FCAS_COLORS[2], 0.25), strokecolor = FCAS_COLORS[2], strokewidth = 2)
    vlines!(ax, 0; color = (:gray, 0.5), linestyle = :dot)
    ax = Axis(fig[2, 2]; title = "BDU regulation, both sides, amalgamated II (Fig 9)", titlesize = 11, xlabel = "Net injection (MW)")
    poly!(ax, Point2f[(-60, 0), (-60, 30), (30, 30), (100, 0)]; color = (FCAS_COLORS[2], 0.25), strokecolor = FCAS_COLORS[2], strokewidth = 2)
    vlines!(ax, 0; color = (:gray, 0.5), linestyle = :dot)
    ax = Axis(fig[2, 3]; title = "FCAS-only unit (Fig 10)", titlesize = 11, xlabel = "Energy (MW)")
    lines!(ax, [0, 0], [0, 40]; color = FCAS_COLORS[3], linewidth = 4)
    xlims!(ax, -50, 50)
    Label(
        fig[2, 4], "Figs 8 and 9 show the amalgamated\ntrapezium (right-hand panels of\nAEMO's figures). The two sides\nare optimised individually.";
        fontsize = 11, tellwidth = false,
    )
    fig
end

# ### [Where the energy target falls (§3)](@id fcas-cases-application)
#
# The FCAS a unit can deliver is read off the trapezium at its energy dispatch target. There
# are exactly four cases (Figures 11 to 13 and the closing paragraph of §3):
#
# | Energy target | Available FCAS |
# | --- | --- |
# | between Low and High Breakpoint | `MaxAvailability` |
# | between Enablement Min and Low Breakpoint | `MaxAvailability × (Energy − EnablementMin) / (LowBreakpoint − EnablementMin)` |
# | between High Breakpoint and Enablement Max | `MaxAvailability × (EnablementMax − Energy) / (EnablementMax − HighBreakpoint)` |
# | below Enablement Min or above Enablement Max | zero |
#
# For a scheduled load the roles of the lower and upper slopes are swapped, because its axis
# is consumption.

let
    t = (150.0, 200.0, 350.0, 450.0, 60.0)
    emin, low, high, emax, fmax = t
    available(x) = x < emin || x > emax ? 0.0 :
        x < low ? fmax * (x - emin) / (low - emin) : x <= high ? fmax : fmax * (emax - x) / (emax - high)
    targets = [("below Emin", 120.0), ("lower slope", 170.0), ("plateau", 280.0), ("upper slope", 410.0), ("above Emax", 480.0)]
    fig = Figure(size = (900, 340))
    ax = Axis(fig[1, 1]; xlabel = "Energy dispatch target (MW)", ylabel = "FCAS (MW)", title = "Available FCAS in each case")
    draw_trapezium!(ax, t)
    for (i, (label, x)) in enumerate(targets)
        color = FCAS_COLORS[mod1(i + 1, 7)]
        lines!(ax, [x, x], [0, available(x)]; color, linewidth = 4)
        scatter!(ax, x, available(x); color, markersize = 10)
        text!(ax, x, 66; text = label, align = (:center, :bottom), fontsize = 11, color)
    end
    ylims!(ax, -3, 80)
    fig
end

# ### [Scaling the bid within technical limits (§4)](@id fcas-cases-scaling)
#
# Before optimising, NEMDE can shrink the bid trapezium to what the unit can currently do. There
# are three cases, and all of them keep the *angles* of the slopes, so the breakpoints slide
# along with the limit that moved:
#
# | Scaling | Applies to | Effective trapezium |
# | --- | --- | --- |
# | **AGC enablement limits** (§4.1, Fig. 14) | regulation services | the telemetered AGC Enablement Min and Max replace the bid's when more restrictive; the breakpoints slide to keep the angles. No scaling if the AGC limit is zero or absent. |
# | **AGC ramp rates** (§4.2, Fig. 15) | regulation services | Max Availability becomes `AGC ramp rate × time period` (for example 5 MW/min × 5 min = 25 MW) when more restrictive; the breakpoints slide to keep the angles. No scaling if the ramp rate is zero or absent. |
# | **UIGF** (§4.3, Fig. 16) | every service of a semi-scheduled unit | Enablement Max becomes the UIGF when more restrictive; the high breakpoint slides to keep the upper angle. |
#
# The three can combine (Figure 17), and scaling can only shrink the trapezium. No AGC scaling
# applies to contingency services, and a scheduled unit's contingency bid is not scaled at all:
# if the unit lowers its energy availability below the bid's Enablement Max, NEMDE does not move
# that limit.

function scale_agc_enablement(t, agc_min, agc_max)
    emin, low, high, emax, fmax = t
    new_min, new_max = max(emin, agc_min), min(emax, agc_max)
    return (new_min, new_min + (low - emin), new_max - (emax - high), new_max, fmax)
end
function scale_agc_ramp(t, capability)
    emin, low, high, emax, fmax = t
    new_fmax = min(fmax, capability)
    k = new_fmax / fmax
    return (emin, emin + (low - emin) * k, emax - (emax - high) * k, emax, new_fmax)
end
function scale_uigf(t, uigf)
    emin, low, high, emax, fmax = t
    new_max = min(emax, uigf)
    return (emin, low, new_max - (emax - high), new_max, fmax)
end

let
    bid = (100.0, 160.0, 340.0, 400.0, 30.0)
    cases = [
        ("AGC enablement limits (Fig 14)", scale_agc_enablement(bid, 130.0, 370.0)),
        ("AGC ramp rate (Fig 15)", scale_agc_ramp(bid, 18.0)),
        ("UIGF (Fig 16)", scale_uigf(bid, 330.0)),
        ("All three (Fig 17)", scale_uigf(scale_agc_ramp(scale_agc_enablement(bid, 130.0, 370.0), 18.0), 330.0)),
    ]
    fig = Figure(size = (1000, 300))
    for (i, (title, effective)) in enumerate(cases)
        ax = Axis(fig[1, i]; title, titlesize = 11, xlabel = "Energy (MW)", ylabel = i == 1 ? "FCAS (MW)" : "")
        draw_trapezium!(ax, bid; color = :gray, filled = false)
        draw_trapezium!(ax, effective; color = FCAS_COLORS[6])
        ylims!(ax, -2, 36)
    end
    Legend(
        fig[2, 1:4], [PolyElement(color = :gray), PolyElement(color = FCAS_COLORS[6])],
        ["bid trapezium", "effective trapezium"]; orientation = :horizontal, tellheight = true,
    )
    fig
end

# Which scaling is applied depends on the process (Table 1 of AEMO's document):
#
# | | Dispatch | 5-minute pre-dispatch | Pre-dispatch |
# | --- | --- | --- | --- |
# | AGC enablement limits | all intervals | first | first |
# | AGC ramp rates | all intervals | first | none |
# | UIGF | all intervals | all intervals | all intervals |
#
# ### [Pre-conditions for enabling a service (§5)](@id fcas-cases-preconditions)
#
# After scaling, a unit is considered for a service only if every one of these holds:
#
# | Pre-condition | Test | Exceptions |
# | --- | --- | --- |
# | Positive availability | `Max Availability > 0` | |
# | Offered quantity | at least one price band has a capacity above zero | |
# | Sign of the limits | `Enablement Max ≥ 0` | regulation on the load side of a BDU requires `Enablement Min (load) ≤ 0`; contingency from a BDU may have any sign |
# | Energy can reach the trapezium | `Energy Max Availability ≥ Enablement Min` | semi-scheduled: `min(Energy Max Availability, UIGF) ≥ Enablement Min`; BDU load side: `−Energy Max Availability (load) ≤ Enablement Max (load)`; BDU generation side: as above on the generation side; BDU contingency: both |
# | Operating inside the trapezium at the start | `Enablement Min ≤ max(Initial MW, 0) ≤ Enablement Max` | BDU with regulation on both sides: `Enablement Min (load) ≤ Initial MW ≤ Enablement Max (gen)`; other BDU bids: `Enablement Min ≤ Initial MW ≤ Enablement Max` |
#
# A unit that fails any of them cannot be enabled for that service, and its availability for it
# is zero.
#
# ### [Joint energy and FCAS constraints (§6)](@id fcas-cases-joint)
#
# A trapezium describes the capability of a unit for *one* service. If the unit provides several
# at once, NEMDE adds four families of constraints, together called the *unit FCAS constraints*,
# so that the unit can physically deliver everything it is dispatched and enabled for:
#
# | Constraint | Regulation service | Contingency service | Dispatch | 5-min pre-dispatch | Pre-dispatch |
# | --- | --- | --- | --- | --- | --- |
# | Joint ramping (§6.1) | applied | not applied | all | first | none |
# | Joint capacity (§6.2) | applied | applied | all | all | all |
# | Energy and regulating FCAS capacity (§6.3) | applied | not applied | all | all | all |
# | BDU regulating FCAS SCADA ramping (§6.4) | applied, BDUs only | not applied | all | first | none |
#
# **Joint ramping.** The combined change of energy and a regulation service has to fit the
# unit's telemetered AGC ramp rate over the time period (5 minutes). For a generating unit, BDU
# or demand response unit:
#
# ```math
# \text{Energy} + \text{RaiseReg} \le \text{InitialMW} + R^{\uparrow}_{\text{SCADA}}\, T, \qquad
# \text{Energy} - \text{LowerReg} \ge \text{InitialMW} - R^{\downarrow}_{\text{SCADA}}\, T
# ```
#
# and for a scheduled load the raise and lower services swap places. Graphically the first row
# cuts a wedge off the *upper* slope of the regulation-raise trapezium and the second off the
# *lower* slope of regulation lower (Figures 18 and 19).

let
    initial, ramp = 300.0, 30.0
    raise = (200.0, 230.0, 330.0, 360.0, 30.0)     # a 45 degree upper slope
    lower = (240.0, 270.0, 370.0, 400.0, 30.0)     # a 45 degree lower slope
    fig = Figure(size = (900, 320))
    ax = Axis(fig[1, 1]; title = "Regulation raise (Fig 18)", titlesize = 12, xlabel = "Energy (MW)", ylabel = "FCAS (MW)")
    draw_trapezium!(ax, raise; color = :gray, filled = false)
    draw_trapezium!(ax, (raise[1], raise[2], initial, initial + ramp, ramp); color = FCAS_COLORS[6])
    lines!(ax, [initial, initial + ramp], [ramp, 0]; color = :tomato, linewidth = 3, label = "joint ramping")
    vlines!(ax, initial; color = (:white, 0.6), linestyle = :dot)
    text!(ax, initial, 33; text = "InitialMW", align = (:center, :bottom), fontsize = 11)
    axislegend(ax; position = :lb)
    ylims!(ax, -2, 40)
    ax = Axis(fig[1, 2]; title = "Regulation lower (Fig 19)", titlesize = 12, xlabel = "Energy (MW)")
    draw_trapezium!(ax, lower; color = :gray, filled = false)
    draw_trapezium!(ax, (initial - ramp, initial, lower[3], lower[4], ramp); color = FCAS_COLORS[6])
    lines!(ax, [initial - ramp, initial], [0, ramp]; color = :tomato, linewidth = 3)
    vlines!(ax, initial; color = (:white, 0.6), linestyle = :dot)
    text!(ax, initial, 33; text = "InitialMW", align = (:center, :bottom), fontsize = 11)
    ylims!(ax, -2, 40)
    fig
end

# **Joint capacity.** For every contingency service the unit is enabled for, energy plus the
# contingency service scaled by the slope, plus any enabled regulation, has to stay inside the
# enablement limits (the constraint used for Tungatinah above). For a generating unit, BDU or
# demand response unit:
#
# ```math
# \begin{aligned}
# \text{Energy} + \text{UpperSlope}\cdot\text{Contingency} + [\text{RaiseRegEnabled}]\,\text{RaiseReg} &\le \text{EnablementMax} \\
# \text{Energy} - \text{LowerSlope}\cdot\text{Contingency} - [\text{LowerRegEnabled}]\,\text{LowerReg} &\ge \text{EnablementMin}
# \end{aligned}
# ```
#
# with `UpperSlope = (EnablementMax − HighBreakpoint) / MaxAvail` and `LowerSlope =
# (LowBreakpoint − EnablementMin) / MaxAvail`. For a scheduled load the two regulation terms
# swap. Because energy and regulation trade one-for-one (a megawatt less energy frees a megawatt
# of raise regulation), AEMO draws the three-dimensional relation in two dimensions: enabling
# regulation *shifts* the sloped edge of the contingency trapezium towards the energy target
# (Figures 21 to 24). One consequence is that a unit enabled for any contingency service is
# *trapped*: its energy dispatch must stay within Enablement Min and Max.

let
    t = (150.0, 200.0, 350.0, 450.0, 60.0)
    emin, low, high, emax, fmax = t
    reg = 20.0
    fig = Figure(size = (900, 330))
    ax = Axis(fig[1, 1]; title = "With regulation raise enabled (Figs 21, 23)", titlesize = 12, xlabel = "Energy (MW)", ylabel = "Contingency FCAS (MW)")
    draw_trapezium!(ax, t; color = :gray, filled = false)
    draw_trapezium!(ax, (emin, low, high - reg, emax - reg, fmax); color = FCAS_COLORS[6])
    text!(ax, emax - reg - 4, 8; text = "upper edge shifted\nleft by RaiseReg", align = (:right, :bottom), fontsize = 11)
    ylims!(ax, -2, 70)
    ax = Axis(fig[1, 2]; title = "With regulation lower enabled (Figs 22, 24)", titlesize = 12, xlabel = "Energy (MW)")
    draw_trapezium!(ax, t; color = :gray, filled = false)
    draw_trapezium!(ax, (emin + reg, low + reg, high, emax, fmax); color = FCAS_COLORS[6])
    text!(ax, emin + reg + 4, 8; text = "lower edge shifted\nright by LowerReg", align = (:left, :bottom), fontsize = 11)
    ylims!(ax, -2, 70)
    fig
end

# **Energy and regulating FCAS capacity.** The same idea applied to a regulation service on its
# own: energy plus the slope times the regulation target stays under Enablement Max, and
# energy minus the slope times the target stays over Enablement Min (Figure 25). The two
# constraints lie exactly on the slopes of the regulation trapezium, so a unit enabled for
# regulation is also *trapped*.
#
# ```math
# \text{Energy} + \text{UpperSlope}\cdot\text{Reg} \le \text{EnablementMax}, \qquad
# \text{Energy} - \text{LowerSlope}\cdot\text{Reg} \ge \text{EnablementMin}
# ```
#
# **BDU regulating FCAS SCADA ramping.** A BDU may bid regulation on both sides, and each side
# is scaled by the unit's SCADA ramp rate. To avoid counting that rate twice, the unit as a
# whole is held to it: `RaiseReg ≤ R↑ × T` and `LowerReg ≤ R↓ × T` (§6.4).
#
# ### [How the published availability is calculated (§7)](@id fcas-cases-availability)
#
# The availability AEMO publishes is not the quantity bid, but the quantity that the unit can
# deliver at its energy target while delivering everything else it is enabled for. It is the
# smallest of five limits, evaluated on the effective (scaled) trapezium (Figure 26):
#
# 1. the trapezium's Max Availability,
# 2. the upper slope,
# 3. the lower slope,
# 4. the joint capacity constraint (one per enabled contingency service, when computing a
#    regulation service's availability),
# 5. the joint ramping constraint (regulation only).
#
# If the unit's Initial MW is outside its enablement limits, or it fails a pre-condition, the
# availability is zero.

let
    t = (100.0, 120.0, 380.0, 420.0, 40.0)
    emin, low, high, emax, fmax = t
    x, initial, ramp, contingency, upper = 390.0, 380.0, 30.0, 10.0, 1.5
    limits = [
        ("1 Max Availability", fmax),
        ("2 upper slope", fmax * (emax - x) / (emax - high)),
        ("3 lower slope", fmax * (x - emin) / (low - emin)),
        ("4 joint capacity", emax - x - upper * contingency),
        ("5 joint ramping", initial + ramp - x),
    ]
    fig = Figure(size = (900, 320))
    ax = Axis(fig[1, 1]; title = "Regulation raise availability at an energy target of $(Int(x)) MW", titlesize = 12, xlabel = "Energy (MW)", ylabel = "FCAS (MW)")
    draw_trapezium!(ax, t)
    xs = range(300, 440; length = 2)
    lines!(ax, xs, fill(fmax, 2); color = FCAS_COLORS[2], label = limits[1][1])
    lines!(ax, xs, fmax .* (emax .- xs) ./ (emax - high); color = FCAS_COLORS[3], label = limits[2][1])
    lines!(ax, xs, emax .- xs .- upper * contingency; color = FCAS_COLORS[4], label = limits[4][1])
    lines!(ax, xs, initial + ramp .- xs; color = FCAS_COLORS[5], label = limits[5][1])
    vlines!(ax, x; color = (:white, 0.6), linestyle = :dot)
    availability = minimum(last, limits)
    scatter!(ax, x, availability; color = :tomato, markersize = 14, label = "availability = $(round(availability; digits = 1)) MW")
    xlims!(ax, 300, 440)
    ylims!(ax, -2, 60)
    axislegend(ax; position = :rt, labelsize = 11)
    fig
end

# The joint capacity constraint (4) is the smallest here, so it sets the availability.
#
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
#   and, for FCAS requirements specifically, a non-empty `fcas_requirements` list tagging which
#   regional `(service, region)` price its shadow price feeds - see
#   [`add_nem_constraints!`](@ref).
# - [`FCASTrapezium`](@ref)/[`FCASBid`](@ref) - a device's offered trapezium and priced
#   10-band offer curve for one FCAS market, attached as a `Deterministic` time series via
#   [`set_fcas_bids!`](@ref).
# - [`ConstrainedNetworkConfiguration`](@ref) - a [`nem_system`](@ref) configuration that
#   pulls in all the tables this page reads and builds both the bids and the constraints
#   automatically (it requires a `date_range` keyword, since both are interval-scoped).

sys = nem_system(db, ConstrainedNetworkConfiguration(); date_range = date_range)
only(filter(gc -> get_gencon_id(gc) == "F_T+NIL_MG_R6", collect(get_components(GenericConstraint, sys))))

# **Not (yet) modelled** by this package, stated plainly:
#
# - The trapezium and joint-capacity/ramping constraints in [Co-optimisation in
#   dispatch](@ref fcas-cooptimisation) are *read and explained* here, and their raw
#   parameters are retrievable from `FCASTrapezium`, but not *enforced* in a
#   `PowerSimulations.jl` dispatch problem - that is the intended next layer built on top of
#   `GenericConstraint`. Enabling that is on the [Roadmap](@ref).
# - Mainland-vs-local contingency splits (e.g. South Australian islanding).
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
#    dispatch](@ref fcas-cooptimisation). The 1-second markets (version 2.0 onwards of the
#    document) follow the same trapezium and joint-constraint mathematics as the other
#    contingency services.
# 4. AEMO, *MMS Data Model Report*, Electricity - per-table definitions for the tables read
#    on this page:
#    [`DISPATCH_FCAS_REQ`](https://visualisations.aemo.com.au/aemo/nemweb/mmsdatamodelreport/electricity/mms%20data%20model%20report_files/MMS_116.htm),
#    [`DISPATCHLOAD`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS_128.htm),
#    [`DISPATCHPRICE`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS_130.htm).
