begin
    using AustralianElectricityMarkets
    using PowerSystems
    using DuckDB
    using Dates
    using DataFrames
    using Statistics
    using Chain
    using AlgebraOfGraphics, CairoMakie
end

# # The National Electricity Market
#
# The **National Electricity Market (NEM)** is the wholesale electricity market covering
# Australia's eastern and south-eastern seaboard. It is a **long, thin, weakly-meshed**
# power system with no external interconnection - unlike Europe's synchronous grid, or the
# US grids that border Canada and Mexico, there is nowhere else to import from or export to
# when something goes wrong. That physical isolation, more than any single policy choice,
# explains several of the design decisions below.
#
# This page introduces the NEM's institutions, market design, and dispatch process, then
# contrasts it directly with the US ISO/RTO and European day-ahead market designs many
# readers of this package will already know. [FCAS in the NEM](@ref) picks up one part of
# this design - frequency control - in much greater depth.
#
# !!! note "References"
#     See [References](@ref nem-references) at the end for official sources - AEMO's
#     [*Fact Sheet: National Electricity
#     Market*](https://www.aemo.com.au/-/media/files/electricity/nem/national-electricity-market-fact-sheet.pdf)
#     for the market overview, and the AER's [*State of the Energy Market
#     2025*](https://www.aer.gov.au/system/files/2025-08/State%20of%20the%20energy%20market%202025%20-%20Chapter%202%20-%20National%20Electricity%20Market.pdf),
#     Chapter 2, for the regulatory and institutional detail.

db = aem_connect();
nothing #hide

# ## What the NEM is
#
# The NEM interconnects **five regions**, each simultaneously a state (or, for NSW, a state
# plus a territory) and a wholesale pricing zone:
#
# - **Queensland (QLD1)**
# - **New South Wales (NSW1)**, including the Australian Capital Territory
# - **Victoria (VIC1)**
# - **South Australia (SA1)**
# - **Tasmania (TAS1)**, connected to the mainland only via the Basslink HVDC undersea cable
#
# Western Australia and the Northern Territory are not part of the NEM; they run their own,
# separate electricity systems and are out of scope for this package. The NEM's transmission
# network spans around 40,000 km of lines and cables and serves more than 85% of Australia's
# population. It began operating as a wholesale spot market in December 1998, under the
# **National Electricity Law** and the **National Electricity Rules** - the legal instruments
# that, together, specify almost everything on this page.

# ## Who runs it
#
# | Body | Role |
# |---|---|
# | **AEMO** (Australian Energy Market Operator) | Operates the power system in real time and runs the wholesale market - the source of every dataset this package reads. A not-for-profit company, roughly 60% government-owned and 40% industry-owned, funded on a cost-recovery basis. |
# | **AER** (Australian Energy Regulator) | Economic regulation of electricity and gas networks and retail markets; monitors and enforces compliance with the National Electricity Rules. |
# | **AEMC** (Australian Energy Market Commission) | Makes and amends the National Electricity Rules; reviews and sets the annual reliability settings - the price cap and floor in [Prices, caps and floors](@ref nem-price-settings) below. |
# | TNSPs / DNSPs | State-based transmission and distribution network businesses that own and operate the physical wires between generators, substations, and customers. |
#
# This three-way split - operator, economic regulator, rule-maker - is the first thing that
# trips up readers used to a single body (a FERC, an Ofgem) covering all three roles.

# ## [How the market is organised](@id nem-organisation)
#
# Three design choices define the NEM:
#
# - **Mandatory gross pool.** Every megawatt-hour physically supplied to or consumed from the
#   grid is bought and sold through AEMO at the regional spot price. There is no physical
#   bilateral trading of the kind allowed in Great Britain's pre-2001 market design or in
#   NEM-adjacent markets elsewhere - a generator's own contracts (ASX futures, swaps, caps,
#   OTC hedges) are purely financial overlays settled against the spot price, not physical
#   delivery agreements.
# - **Energy-only.** Generators are paid only for the energy (and FCAS) they are dispatched
#   to supply. There is no separate capacity market and no explicit payment for being
#   available but undispatched. Resource adequacy instead relies on the high price cap
#   (below) giving peaking and firming capacity a chance to recover its costs in a small
#   number of extreme-price intervals, backstopped by the Retailer Reliability Obligation,
#   which requires retailers to contract sufficient firm capacity ahead of forecast shortfalls.
# - **Regional pricing, not nodal pricing.** Each of the five regions clears at a single spot
#   price, set at that region's **Regional Reference Node (RRN)**. This is a coarser
#   granularity than the nodal locational marginal pricing (LMP) used across most US
#   ISOs/RTOs - see [How the NEM differs from US and European markets](@ref nem-vs-world).
#
# !!! note "One price per region is not one price per unit"
#     Pricing regionally does not mean location stops mattering. NEMDE dispatches against
#     several hundred network constraint equations, so *which* units run is decided by the
#     constrained solution, not by regional merit order alone. A unit can be **constrained
#     on** - dispatched even though its own offer price sits well above its region's RRP -
#     because a bound constraint requires generation at that particular point in the network.
#     The mirror case, **constrained off**, leaves a unit offering *below* the RRP
#     undispatched. AEMO calls the resulting divergence between a unit's implied local price
#     and its regional price **mis-pricing**, and publishes the per-unit gap as a *Local Price
#     Adjustment* - the sum of `MarginalValue x Factor` over the bound constraints that unit
#     appears on (`DISPATCH_LOCAL_PRICE`).
#
#     The unit is nonetheless **settled at the RRP**, scaled by its Marginal Loss Factor - not
#     at its own offer, and not at its local price. US markets (PJM, CAISO, MISO) make uplift
#     or make-whole payments for exactly this situation; the NEM has no equivalent side
#     payment for ordinary network congestion, so a constrained-on generator wears the
#     difference. Compensation arises only for AEMO *directions* and administered price
#     periods, which are separate mechanisms. This is the sharpest practical consequence of
#     pricing regionally rather than nodally.

# ## [The dispatch process](@id nem-dispatch)
#
# AEMO schedules and prices the market every **5 minutes**, but that dispatch run sits at the
# end of a longer forecasting chain:
#
# 1. **Medium/Short-Term PASA** (Projected Assessment of System Adequacy) - a rolling
#    reliability forecast out to two years (MT PASA) and one week (ST PASA), used to flag
#    potential shortfalls well ahead of time.
# 2. **Pre-dispatch** - a 30-minute-resolution forecast schedule published every 30 minutes,
#    covering the next ~2 days. It gives participants an indicative view of their own future
#    dispatch and the forecast price, but commits nobody to anything.
# 3. **5-minute pre-dispatch (P5MIN)** - the same idea at 5-minute resolution, covering the
#    next hour.
# 4. **Dispatch** - the binding run. Every 5 minutes, **NEMDE** (the NEM Dispatch Engine)
#    solves a security-constrained economic dispatch: minimise the cost of meeting forecast
#    demand in every region, subject to each unit's offered bands, ramp rates, and several
#    hundred network and system-security constraints, jointly with the FCAS markets (see
#    [FCAS in the NEM](@ref)).
#
# **Bidding.** Each unit submits up to **ten price bands** per market per trading day via
# `BIDDAYOFFER_D` (read by [`read_bids`](@ref) for energy) - these prices are fixed once
# submitted, by 12:30pm the day before. What can still change, right up to **gate closure**
# (~20 seconds before each dispatch interval), is how many megawatts sit in each of those ten
# bands: rebids via `BIDPEROFFER_D`, in response to revised demand forecasts, plant
# availability, or market conditions. Absent binding network constraints AEMO dispatches in
# **merit order** - cheapest offered band first - and every dispatched unit in a region is
# paid the same **uniform clearing price**, set by the last (most expensive) band needed to
# meet demand, not by what each individual unit actually bid. Network constraints routinely
# override that ordering, though; see [Regional pricing, not nodal
# pricing](@ref nem-organisation) above.
#
# **Generator classes** matter for how tightly a unit is bound to AEMO's dispatch target:
# **scheduled** units must follow their dispatch target under the Rules; **semi-scheduled**
# units (most utility-scale wind and solar) submit bids like scheduled units, but their
# offered availability is capped by AEMO's own forecast of what they can physically produce
# (the Unconstrained Intermittent Generation Forecast, UIGF); **non-scheduled** units (small
# generators, most rooftop solar) run without following a AEMO-issued target at all.
#
# Settlement has matched dispatch resolution since **1 October 2021**: 288 five-minute
# trading intervals a day, priced at the dispatch price itself, rather than the earlier
# 30-minute trading interval settled at the average of six preceding dispatch prices.

# ## [Prices, caps and floors](@id nem-price-settings)
#
# The AEMC reviews and adjusts the NEM's reliability settings annually. For the
# **2026-27 financial year** (from 1 July 2026):
#
# | Setting | Value |
# |---|---|
# | Market price cap (MPC) | **\$23,200/MWh** |
# | Market floor price | **-\$1,000/MWh** |
# | Cumulative price threshold (CPT) | **\$2,225,900/MWh** |
# | Administered price cap (APC) | **\$600/MWh** |
#
# The market price cap and floor bound every dispatch price directly. The cumulative price
# threshold is different: if the sum of spot prices over a rolling window exceeds it, AEMO
# declares an **administered price period**, during which the price cap is temporarily
# replaced by the much lower administered price cap - a mechanism to limit total costs during
# an extended high-price event, rather than a single interval. The MPC and CPT are indexed to
# CPI each year, on a multi-year step-up path set by a December 2023 rule change; the
# FY2025-26 MPC was \$20,300/MWh.

# ## Regional pricing, in practice
#
# Five regions, one instant. Reading regional spot prices for **13 January 2025** with
# [`read_prices`](@ref) shows exactly what "regional pricing" buys over a single national
# price:

date_range = DateTime(2025, 1, 13, 0, 0):Minute(5):DateTime(2025, 1, 14, 0, 0)
prices = read_prices(db, date_range)
first(prices, 5)

#-
begin
    plt = data(prices) *
        mapping(:SETTLEMENTDATE => "Time (13 January 2025)", :RRP => "Spot price (\$/MWh)", color = :REGIONID => "Region") *
        visual(Lines)
    draw(
        plt;
        figure = (; size = (700, 400), title = "Regional energy prices, 13 January 2025"),
    )
end

# Every mainland region dips negative around the midday solar peak, while Tasmania - the one
# region without abundant mainland-scale solar feeding its own price - never drops below
# \$110/MWh all day:

@chain prices begin
    groupby(:REGIONID)
    combine(
        :RRP => (x -> round(minimum(x); digits = 1)) => :min,
        :RRP => (x -> round(mean(x); digits = 1)) => :mean,
        :RRP => (x -> round(maximum(x); digits = 1)) => :max,
    )
    sort(:REGIONID)
end

# A single national price would average these away entirely - hiding both the midday glut
# and Tasmania's comparative scarcity. That divergence is a direct, quantitative signature of
# interconnector congestion and regional supply mix, not a modelling artefact.

# ## [How the NEM differs from US and European markets](@id nem-vs-world)
#
# | | NEM | US ISO/RTO | European (day-ahead coupled) |
# |---|---|---|---|
# | Pricing granularity | 5 regional prices | Nodal LMP - thousands of nodes (e.g. PJM, CAISO) | Zonal - one price per bidding zone |
# | Day-ahead market | **None** - real-time only | Day-ahead SCUC, settled separately from real-time | Day-ahead auction is the primary liquidity venue |
# | Commitment | Self-commitment by each participant | Centrally co-optimised unit commitment | Self-commitment, adjusted in intraday/balancing markets |
# | Capacity mechanism | None (energy-only) | Common (PJM RPM, ISO-NE FCM); ERCOT is also energy-only | Some member states (e.g. France, GB); others energy-only |
# | Settlement interval | 5 minutes | Typically 5 minutes real-time / 60 minutes day-ahead | 15-60 minutes, moving toward 15 |
# | Price cap | \$23,200/MWh (FY2026-27) | Much lower - e.g. ERCOT's \$9,000/MWh system-wide offer cap | EU-harmonised \$4,000/MWh cap on day-ahead coupling |
#
# The pattern across most of these rows is the same: the NEM makes fewer things mandatory and
# fewer things centrally planned than a typical US ISO, while pricing at coarser spatial
# granularity than either. There is no day-ahead market to clear and no central unit
# commitment to solve - participants decide when to start and stop their own plant, and
# accept whatever the real-time price turns out to be. The trade-off for carrying that much
# more real-time price risk is a market price cap several times higher than anywhere else
# shown above: an energy-only design only works if the price is allowed to spike high enough,
# often enough, to remunerate capacity that runs for a handful of hours a year.
#
# The regional/zonal-vs-nodal split (row 1) is not unique to the NEM - most of Europe prices
# zonally too - but it is worth being explicit that the NEM's mandatory gross pool is the
# design Great Britain's own market abandoned in 2001 in favour of bilateral trading (NETA,
# later BETTA). The NEM kept it, and still runs on it today.

# ## How this maps onto the package
#
# Each NEM region becomes an `Area` component when building a system:

sys = nem_system(db, RegionalNetworkConfiguration())
get_component(Area, sys, "TAS1")

# The readers used on this page - [`read_prices`](@ref), and elsewhere in this package
# [`read_demand`](@ref), [`read_bids`](@ref), [`read_interconnectors`](@ref) - all read
# directly from the AEMO tables described above, keyed by the same five region codes. From
# here, [FCAS in the NEM](@ref) covers the ancillary-services markets co-optimised alongside
# the energy dispatch described here.

# ## [References](@id nem-references)
#
# 1. AEMO, [*Fact Sheet: National Electricity
#    Market*](https://www.aemo.com.au/-/media/files/electricity/nem/national-electricity-market-fact-sheet.pdf) -
#    regions, transmission scale, population coverage.
# 2. AER, [*State of the Energy Market 2025*, Chapter 2 - National Electricity
#    Market*](https://www.aer.gov.au/system/files/2025-08/State%20of%20the%20energy%20market%202025%20-%20Chapter%202%20-%20National%20Electricity%20Market.pdf) -
#    institutional roles, market structure.
# 3. AEMC, [*Schedule of reliability settings - 2026-27 financial
#    year*](https://www.aemc.gov.au/sites/default/files/2026-02/Schedule%20of%20reliability%20settings%20-%202026-27%20financial%20year.pdf) -
#    market price cap, floor, cumulative price threshold, administered price cap.
# 4. AEMO, [*Dispatch* operating procedure
#    (SO_OP_3705)](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch-draft.pdf) -
#    PASA, pre-dispatch, and dispatch timing and process.
# 5. AEMO, *MMS Data Model Report*, Electricity - per-table definitions for the table read on
#    this page,
#    [`DISPATCHPRICE`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS_130.htm),
#    and for
#    [`DISPATCH_LOCAL_PRICE`](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS_118.htm),
#    which carries the per-unit `LOCAL_PRICE_ADJUSTMENT` referenced in [How the market is
#    organised](@ref nem-organisation). That table is not currently ingested by this package.
# 6. AEMO, [*Guide to Mis-Pricing
#    Information*](https://aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/guide-to-mis-pricing-information.pdf),
#    effective 3 June 2024 - how AEMO defines and measures the gap between a unit's local
#    price and its regional reference price.
# 7. ERCOT, [*System-Wide Offer
#    Cap*](https://www.ercot.com/mp/data-products/data-product-details?id=NP4-791-CD) - the US
#    comparison figure in [How the NEM differs from US and European markets](@ref nem-vs-world).
# 8. ACER, [*Decision on the harmonised maximum and minimum clearing price for single
#    day-ahead coupling*](https://www.acer.europa.eu/sites/default/files/documents/Individual%20Decisions/ACER-Decision-02-2026-harmonised-clearing-prices-day-ahead.pdf) -
#    the European comparison figure in the same section.
