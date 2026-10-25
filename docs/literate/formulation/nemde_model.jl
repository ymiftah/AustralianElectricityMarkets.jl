# # [The NEMDE formulation](@id nemde-model)
#
# The National Electricity Market (NEM) is cleared by a single optimisation, the **NEM Dispatch
# Engine (NEMDE)**, run by the Australian Energy Market Operator (AEMO) every five minutes.
# These chapters explain that optimisation: what it decides, which constraints it respects,
# what it costs and how prices come out of it. They assume familiarity with electricity
# markets in general, but none with the NEM. For the market's institutions and history, see
# [The dispatch process](@ref nem-dispatch).
#
# ## What happens every five minutes
#
# The NEM is a gross pool with no day-ahead market and no central unit commitment. All energy
# is traded through one real-time auction, repeated 288 times a day. Each run covers one
# **dispatch interval** of five minutes and proceeds as follows.
#
# 1. **Offers are frozen.** Each participant has submitted, per unit and per market, ten price
#    bands for the trading day and a quantity in each band for every interval. Prices are
#    fixed the day before; quantities can be changed (rebid) until shortly before the interval.
# 2. **The starting point is measured.** AEMO reads each unit's output and each
#    interconnector's flow from its telemetry system (SCADA) at the start of the interval.
# 3. **Forecasts are prepared.** AEMO forecasts each region's demand at the end of the
#    interval, and the maximum output of each wind and solar farm.
# 4. **Network limits are modelled.** The transmission network is not modelled line by
#    line. AEMO expresses each limit as a linear inequality over unit outputs and
#    interconnector flows, called a **generic constraint**, and computes its right-hand side
#    from current system conditions.
# 5. **NEMDE solves one linear programme** for all five regions together. It chooses energy
#    targets, interconnector flows and reserve enablement at least cost.
# 6. **Targets and prices are published.** Each unit receives the output it should reach by
#    the end of the interval. Each region receives one energy price and ten reserve prices.
#
# Two features set the NEM apart from most other markets. Reserves, called **frequency control
# ancillary services (FCAS)**, are cleared in the same optimisation as energy, because they
# draw on the same plant. And prices are **regional**: every unit in a region is settled at
# the price of one node, the regional reference node, adjusted by a fixed loss factor.
#
# ## What is given, decided and published
#
# | Given to NEMDE | Decided by NEMDE | Published afterwards |
# | --- | --- | --- |
# | Energy and FCAS offers | Energy target of each unit | Unit targets and FCAS enablement |
# | Metered starting output and flow | MW cleared in each offer band | Interconnector flows and losses |
# | Regional demand forecast | FCAS enabled on each unit, per service | Regional energy and FCAS prices |
# | Wind and solar forecasts | Flow on each interconnector | Left-hand side and marginal value of each constraint |
# | Generic constraints and their right-hand sides | Violation of any constraint that cannot be met | Violation quantities |
# | Loss factors and loss equations | | |
#
# The published prices and targets for each units are results of the optimisation.
#
# ## The optimisation in one view
#
# NEMDE minimises the cost of the offers it accepts, plus a penalty for every constraint it
# has to violate:
#
# ```math
# \min\; h\Big(\underbrace{\sum \widehat c\,q^{\mathrm{GEN}}-\sum \widehat c\,q^{\mathrm{LOAD}}}_{\text{energy}}
# +\underbrace{\sum c\,q^{\mathrm{FCAS}}}_{\text{reserves}}
# +\underbrace{\sum c\,q^{\mathrm{MNSP}}}_{\text{offered transfers}}
# +\underbrace{\mathrm{MPC}\sum_n v_n\sigma_n}_{\text{violations}}\Big)+C_{\mathrm{tie}}.
# ```
#
# Each ``q`` is the MW cleared from an offer band and each ``c`` is its price. Generation
# offers are a cost. Consumption bids are a benefit, so they enter with a minus sign. The
# hat on the energy prices marks their adjustment to the regional reference node. Every
# constraint ``n`` that can be violated has a slack ``\sigma_n``, priced at a penalty factor
# ``v_n`` times the market price cap (MPC). ``C_{\mathrm{tie}}`` is a negligible term that
# shares dispatch between equally priced offers.
#
# The constraints are grouped into five chapters.
#
# | Chapter | Constraints and inputs it explains |
# | --- | --- |
# | [Energy bids and participants](@ref nemde-energy) | Offer bands, loss-factor adjustment of prices, availability, ramp rates, batteries and the regional energy balance |
# | [FCAS capability and co-optimisation](@ref nemde-fcas) | The ten reserve services, how much is required, how much each unit can provide, and how reserves compete with energy for the same plant |
# | [Interconnectors and losses](@ref nemde-interconnectors) | Flows between regions, the losses they incur, and transfers offered by a market interconnector |
# | [Fast-start dispatch](@ref nemde-fast-start) | Unit commitment of `fast-start` units |
# | [Violations, tie-breaking and prices](@ref nemde-prices) | Generic constraints, violation penalties, equally priced offers, and how marginal values become published prices |
#
# ## [Notation](@id nemde-notation)
#
# All chapters use the same symbols. Quantities are in MW and prices in dollars per MWh
# unless stated.
#
# | Symbol | Meaning |
# | --- | --- |
# | ``u``, ``r``, ``i`` | Unit, region, interconnector |
# | ``b`` | Offer band, 1 to 10 |
# | ``j`` | FCAS service |
# | ``g`` | Generic constraint |
# | ``h`` | Length of the dispatch interval in hours, ``1/12`` |
# | ``p_u`` | Energy target of a unit, as net injection into the grid |
# | ``p^0_u`` | Metered output of the unit at the start of the interval |
# | ``q_{u,b}``, ``Q_{u,b}`` | MW cleared from a band, and MW offered in it |
# | ``c_{u,b}``, ``\widehat c_{u,b}`` | Band price as offered, and adjusted to the regional reference node |
# | ``f_{u,j}`` | MW of FCAS service ``j`` enabled on a unit |
# | ``A_u`` | Maximum output available from a unit in this interval |
# | ``R^{\uparrow}_u``, ``R^{\downarrow}_u`` | Ramp-up and ramp-down rates, in MW per hour |
# | ``x_i``, ``L_i`` | Flow on an interconnector, positive in its defined direction, and its losses |
# | ``D_r`` | Demand forecast of a region |
# | ``\sigma`` | Slack: the MW by which a constraint is violated |
# | ``v`` | Penalty factor of a constraint, a pure number |
# | ``\mathrm{MPC}`` | Market price cap |
# | ``\lambda_r`` | Marginal value of the energy balance of a region |
# | ``\mu_g`` | Marginal value of a generic constraint |
#
# ## Time conventions
#
# - A dispatch interval is identified by the time at which it **ends**. The interval stamped
#   18:00 covers 17:55 to 18:00.
# - All market times are Australian Eastern Standard Time (UTC+10) all year. The market does
#   not observe daylight saving.
# - A **trading day** runs from 04:00 to 04:00 the next calendar day. Offer prices are fixed
#   per trading day, so the interval ending 03:30 on 2 March uses offers for 1 March.
# - Ramp rates in this text are in MW per hour, so ``R\,h`` is the MW a unit can move in one
#   interval. Some published fields are in MW per minute; the conversion is a factor of 60.
#
# ## [Glossary](@id nemde-glossary)
#
# | Term | Meaning |
# | --- | --- |
# | AGC | Automatic generation control. AEMO's system that sends setpoints to units every few seconds to correct small frequency deviations |
# | Bidirectional unit (BDU) | A unit that can both generate and consume, in practice a battery |
# | CVP factor | Constraint violation penalty factor. A number that ranks how reluctantly a constraint is violated |
# | Dispatch interval | The five-minute period cleared by one NEMDE run |
# | DUID | Dispatchable unit identifier. The name of one unit in the market data |
# | FCAS | Frequency control ancillary services. The ten reserve products |
# | Generic constraint | A linear inequality over unit outputs, FCAS enablement and interconnector flows, used for network limits and FCAS requirements |
# | Interconnector | The modelled transfer path between two adjacent regions |
# | Intervention | An interval in which AEMO directs a participant outside the market. NEMDE is then run twice: once for physical dispatch and once for pricing |
# | Loss factor | A fixed ratio, set yearly per connection point, that converts a price at the unit's location into a price at the regional reference node |
# | MMSDM | The Market Management System Data Model. AEMO's published database of market inputs and results |
# | MNSP | Market network service provider. An interconnector that earns revenue by offering transfer capacity at a price |
# | MPC | Market price cap. The highest allowed energy price, set each financial year |
# | Regional reference node (RRN) | The node in each region at which the regional price is defined |
# | Region | One of five pricing zones: NSW1, QLD1, VIC1, SA1 and TAS1 |
# | ROP | Regional original price. The price straight from the optimisation |
# | RRP | Regional reference price. The price used for settlement, after caps and other adjustments |
# | SCADA | The telemetry system that reports metered output and flow to AEMO |
# | Scheduled unit | A unit that offers into dispatch and must follow its target |
# | Semi-scheduled unit | A wind or solar farm. It offers like a scheduled unit, and its output is capped by AEMO's forecast |
# | Non-scheduled unit | A unit that does not take part in dispatch. Its output is netted from demand |
# | UIGF | Unconstrained intermittent generation forecast. AEMO's forecast of the output a wind or solar farm could reach |
#
# ## [Where this package differs](@id nemde-deviations)
#
# These chapters describe AEMO's dispatch. The following limitations apply to the NEM dispatch
# formulations and replay workflow in `AustralianElectricityMarketsSimulations.jl`; other
# PowerSimulations formulations can behave differently. The chapter notes give the details.
# Availability, UIGF and total offered energy are enforced with separate priced violations.
#
# | Area | Deviation | Chapter |
# | --- | --- | --- |
# | Units outside dispatch | Wholesale demand response units are not modelled | [Energy](@ref nemde-energy) |
# | FCAS scaling for loads | The standard input setter omits scheduled loads, so their telemetered scaling and joint ramping are absent | [FCAS](@ref nemde-fcas) |
# | Market interconnector | Hard availability, no ramp rate or fixed loading, no converter losses or no-go zone | [Interconnectors](@ref nemde-interconnectors) |
# | Fast-start units | No profiles or two-pass commitment; participant fixed loadings are omitted for units with a positive T1 for the whole trading day | [Fast-start](@ref nemde-fast-start) |
#
# ## [Official references](@id nemde-model-references)
#
# - AEMO, [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf): dispatch inputs, runs and pricing procedures.
# - AEMO, [FCAS Model in NEMDE](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf): capability, scaling, eligibility and joint constraints.
# - AEMO, [Fast Start Unit Inflexibility Profile](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf): profiles, modes and the two-pass solve.
# - AEMO, [Constraint Formulation Guidelines](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf) and [Schedule of Constraint Violation Penalty Factors](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf): generic constraints and violation priorities.
# - AEMO, [Loss factors and regional boundaries](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/market-operations/loss-factors-and-regional-boundaries): yearly loss factors and loss equations.
# - AEMO, [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/): table schemas and column definitions.
#
# ## [Where the data lives](@id nemde-data)
#
# AEMO publishes every input and result of dispatch as tables of the MMSDM, in monthly
# archives. The cache built by `AustralianElectricityMarketsData` stores each table under its
# MMSDM name, one directory per archive month:
#
# ```text
# ~/<.nemdb_cache>/<TABLE>/archive_month=YYYY-MM-01/*.parquet
# ```
#
# Each chapter ends with a table that maps its symbols to MMSDM tables and columns. In those
# tables the **Table** column is both the MMSDM table name and the cache directory, and
# **Time key** says which row applies to an interval. Three kinds of time key occur.
#
# | Time key | Tables | How the row for an interval is found |
# | --- | --- | --- |
# | Interval end | Dispatch results: `DISPATCHLOAD`, `DISPATCHREGIONSUM`, `DISPATCHPRICE`, `DISPATCHCONSTRAINT`, `DISPATCHINTERCONNECTORRES` | `SETTLEMENTDATE` equals the interval end. Rows are also keyed by `INTERVENTION`, which is 0 except during an intervention; see [Prices](@ref nemde-prices-data) |
# | Trading day | Offers: `BIDDAYOFFER_D`, `BIDPEROFFER_D`, `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD` | The date column is the trading day. Per-interval quantities carry the interval end or a period number as well |
# | Effective date | Standing data: `DUDETAILSUMMARY`, `GENCONDATA`, the `SPD*` tables, `INTERCONNECTORCONSTRAINT`, `LOSSMODEL`, `LOSSFACTORMODEL`, `MNSP_INTERCONNECTOR` | The latest row whose effective date is on or before the interval. These rows are published only when they change, so the row in force can sit in an archive month long before the interval |
#
# The archive month is the month in which AEMO published a row. It locates the file and says
# nothing about when the row applies.
#
# | Chapter | Tables used |
# | --- | --- |
# | [Energy](@ref nemde-energy-data) | `BIDDAYOFFER_D`, `BIDPEROFFER_D`, `DUDETAILSUMMARY`, `DISPATCHLOAD`, `DISPATCHREGIONSUM` |
# | [FCAS](@ref fcas-types-mapping) | `BIDDAYOFFER_D`, `BIDPEROFFER_D`, `DUDETAILSUMMARY`, `DISPATCHLOAD`, `DISPATCHCONSTRAINT`, `GENCONDATA`, `SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT`, `DISPATCH_FCAS_REQ`, `DISPATCH_FCAS_REQ_CONSTRAINT`, `DISPATCHPRICE` |
# | [Interconnectors](@ref nemde-interconnectors-data) | `INTERCONNECTOR`, `INTERCONNECTORCONSTRAINT`, `LOSSFACTORMODEL`, `LOSSMODEL`, `DISPATCHINTERCONNECTORRES`, `DISPATCHREGIONSUM`, `MNSP_INTERCONNECTOR`, `MNSP_DAYOFFER`, `MNSP_BIDOFFERPERIOD` |
# | [Fast-start](@ref nemde-fast-start-data) | `BIDDAYOFFER_D`, `BIDPEROFFER_D`, `DISPATCHLOAD` |
# | [Prices](@ref nemde-prices-data) | `DISPATCHCONSTRAINT`, `GENCONDATA`, the three `SPD*` tables, `DISPATCHPRICE`, `DISPATCHLOAD`, `MARKET_PRICE_THRESHOLDS` (not cached) |
