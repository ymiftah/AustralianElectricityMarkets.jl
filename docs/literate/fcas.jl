begin
    using AustralianElectricityMarkets
    using PowerSystems
    using DuckDB
    using Dates
    using DataFrames
    using Chain
    using AlgebraOfGraphics, CairoMakie
end

# # FCAS in the NEM
#
# **Frequency Control Ancillary Services (FCAS)** are the National Electricity Market's
# mechanism for keeping the power system's frequency at 50 Hz. Australia's mainland and
# Tasmania are (mostly) large, weakly-interconnected AC systems with no significant
# import/export capacity to the rest of the world - unlike Europe's synchronous grid, there
# is nowhere else to borrow inertia or reserve from. Every megawatt of frequency response has
# to come from a generator, load, or battery physically connected to the NEM, procured
# through a market AEMO runs alongside (and co-optimised with) the energy market.
#
# This page works through FCAS from AEMO's own primary documents - the trapezium, the
# generic-constraint mechanism that sets requirements, and the joint dispatch constraints -
# illustrating every concept with real NEMWEB data read straight through this package's
# `read_fcas_*` functions, for a single, real dispatch interval: **13 January 2025, interval
# ending 16:30, Tasmania (TAS1)**. That interval was picked because it happens to show three
# things worth seeing together: a scarce regulation market, a constraint that could not quite
# be satisfied, and a hydro unit visibly limited by its own trapezium.
#
# !!! note "Sources"
#     Every claim below is sourced. See [References](@ref fcas-references) at the end for
#     full citations - AEMO's [*Guide to Ancillary Services in the National Electricity
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
#   added on 9 October 2023 for very fast response (batteries, mostly) but this package
#   defers it for now (see [How this maps onto the package's types](@ref fcas-types-mapping)).
# - **Regulation FCAS** (`RAISEREG`/`LOWERREG`) continuously trims small, everyday frequency
#   deviations via AEMO's Automatic Generation Control (AGC) signal - not response-time
#   banded, since it is always "on" for an enabled unit.
#
# This package represents the eight in-scope markets as a scoped enum, [`BidType`](@ref):

FCAS_BID_TYPES

# ## Where the requirements come from
#
# Every dispatch interval, AEMO needs a target quantity (MW) of each FCAS service in each
# region - how much raise-6-second capability Tasmania needs right now, for instance. It is
# tempting to look for a single "requirements" table. Two exist, and both are dead ends:
#
# !!! warning "RESERVE and DISPATCHREGIONSUM's `*REQ` columns are unpopulated"
#     `RESERVE` and `DISPATCHREGIONSUM`'s `RAISE6SECREQ`/`LOWER6SECREQ`/etc. columns look
#     like exactly what's needed, and older NEM tooling reads them. AEMO stopped populating
#     both in **December 2003** - confirmed directly while building this page: every NEMWEB
#     monthly-archive URL for `RESERVE` returns HTTP 404. Do not build against them.
#
# The requirement is instead expressed the same way network limits are: as a **generic
# constraint**. `DISPATCH_FCAS_REQ` maps each `(region, service, interval)` to the
# `GENCONID` of the constraint governing it; `DISPATCHCONSTRAINT.RHS` is the requirement
# quantity that constraint actually enforced that interval, and `MARGINALVALUE` is its
# shadow price (used in [Pricing](@ref fcas-pricing) below). [`read_fcas_requirements`](@ref)
# does this join:

date_range = DateTime(2025, 1, 13, 16, 0):Minute(5):DateTime(2025, 1, 13, 17, 0)
requirements = read_fcas_requirements(db, date_range)
first(requirements, 5)

# A region/service is very often governed by *more than one* constraint at once - regional
# aggregate requirements, network-outage-specific requirements, islanding contingencies -
# so [`read_fcas_requirements`](@ref) returns one row **per governing constraint**, not one
# row per `(region, service)`. Most have a `DESCRIPTION` from `GENCONDATA`; a few of the
# broad regional aggregates (e.g. Tasmania's raise-regulation requirement below) do not - not
# every generic constraint has a published human-readable description, and this package
# doesn't invent one:

@chain requirements begin
    subset(:GENCONID => ByRow(==("F_T+NIL_ML_RECL_L5")), :BIDTYPE => ByRow(==(BidType.LOWER5MIN)))
    select(:GENCONID, :REQUIREMENT, :MARGINALVALUE, :DESCRIPTION)
end

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
#     can't be reproduced from public data the way the contingency figures above can - stated
#     here rather than fudged.

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
# requirement (`F_T+NIL_MG_R6` - a network-event contingency requirement) could not be fully
# satisfied: `MARGINALVALUE` on that single constraint is **\$140,000/MW**, AEMO's
# constraint-violation penalty rate, not a market-clearing price. That one dominant term is
# why the regional `RAISE6SEC` price this interval is over five thousand dollars per MW,
# an order of magnitude above the \$17,500/MWh energy market price cap:

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
# This package represents FCAS as `PowerSystems.jl` types, built with the same NEM data
# read above:
#
# - [`ContingencyFCASReserve`](@ref) / [`RegulationFCASReserve`](@ref) - one regional reserve
#   requirement per (market, region), added via [`add_fcas_reserves!`](@ref).
# - [`FCASTrapezium`](@ref) / [`FCASOffer`](@ref) - a device's offered trapezium and priced
#   offer curve for one market, attached via [`set_fcas_offers!`](@ref).
# - [`FCASNetworkConfiguration`](@ref) - a [`nem_system`](@ref) configuration that pulls in
#   all the tables this page reads and builds the reserves automatically.

sys = nem_system(db, FCASNetworkConfiguration())
get_component(Reserve, sys, "RAISE6SEC_TAS1")

# **Not (yet) modelled** by this package, stated plainly:
#
# - The trapezium and joint-capacity/ramping constraints in [Co-optimisation in
#   dispatch](@ref fcas-cooptimisation) are *read and explained* here, but not *enforced* in
#   a `PowerSimulations.jl` dispatch problem - `FCASTrapezium`'s docstring flags this
#   explicitly. Enabling that is on the [roadmap](@ref).
# - Mainland-vs-local contingency splits (e.g. South Australian islanding).
# - The `RAISE1SEC`/`LOWER1SEC` markets.
# - AGC ramp-rate scaling (the missing telemetry noted above).
# - FCAS cost recovery (`BASE_COST`/`ADJUSTED_COST`/CMPF/CRMPF in `DISPATCH_FCAS_REQ`).

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
