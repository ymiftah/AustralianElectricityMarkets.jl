# # [Violations, tie-breaking and prices](@id nemde-prices)
#
# The earlier chapters describe what each participant can do. This chapter covers what ties
# them together: the network limits, what happens when the constraints cannot all be met,
# how NEMDE chooses between offers at the same price, and how prices are read from the
# solution. Symbols follow the [notation table](@ref nemde-notation).
#
# ## Generic constraints
#
# NEMDE has no model of individual transmission lines. A network limit is supplied as a
# **generic constraint**: a linear combination of unit outputs, FCAS enablement and
# interconnector flows, compared with a number.
#
# ```math
# \sum_uw_{g,u}\,p_u+\sum_{u,j}w_{g,u,j}\,f_{u,j}+\sum_iw_{g,i}\,x_i
# \;\{\le,\,=,\,\ge\}\;b_g.
# ```
#
# The coefficients ``w`` say how much each unit, service or interconnector contributes to
# the limit. AEMO's engineers derive them offline from network studies. The right-hand side
# ``b_g`` is recomputed for every interval from current system conditions, such as line
# ratings and the output of plant that is not dispatched.
#
# Generic constraints serve three purposes.
#
# - **Network limits.** A thermal, voltage or stability limit, written in terms of the
#   units and interconnectors that load the limiting element.
# - **FCAS requirements.** How much of each reserve service must be enabled, and where; see
#   [FCAS capability and co-optimisation](@ref nemde-fcas).
# - **Operational instructions**, such as holding an interconnector at zero flow during an
#   outage.
#
# Several hundred are active in a typical interval. Constraints are grouped into sets, and
# AEMO switches sets on and off as network conditions change. Each constraint also has
# versions over time, so the definition that applies is the one in force for the interval.
#
# The sign of a coefficient alone does not say whether a unit is held back or pushed up.
# In a ``\le`` constraint, a unit with a positive coefficient is held back when the
# constraint binds. In a ``\ge`` constraint, the same unit is pushed up. AEMO sets out the
# conventions in its
# [Constraint Formulation Guidelines, §§4-5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf).
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** computes each right-hand side from live system measurements. **This
#     package:** uses the right-hand side AEMO published for the interval. It does not
#     recompute it, so it reproduces the limits that applied and cannot answer what the
#     limit would have been under different conditions.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** every registered unit is in the problem, so every term of a constraint is
#     present. **This package:** a term for a unit outside the model is dropped and the
#     constraint is built from the rest. This is exact only if that unit's dispatch was
#     zero. A constraint with a region or interconnector term that cannot be matched is
#     left out entirely.
#
# ## When constraints cannot all be met
#
# A dispatch must be produced every five minutes, whatever the system conditions. Almost
# every constraint in NEMDE can therefore be violated, at a price. A violated constraint
# gets a slack ``\sigma`` on the side that relaxes it:
#
# ```math
# \mathrm{LHS}_g-\sigma_g^{\mathrm{sur}}\le b_g,\qquad
# \mathrm{LHS}_g+\sigma_g^{\mathrm{def}}\ge b_g,\qquad
# \mathrm{LHS}_g+\sigma_g^{\mathrm{def}}-\sigma_g^{\mathrm{sur}}=b_g.
# ```
#
# Each MW of slack costs the constraint's **constraint violation penalty (CVP) factor**
# ``v`` times the market price cap:
#
# ```math
# C_V=h\;\mathrm{MPC}\sum_nv_n\,\sigma_n.
# ```
#
# The factor is a pure number. Multiplying by the market price cap, the highest price any
# offer can have, guarantees that violating a constraint with a factor above 1 costs more
# than accepting any offer. The factors therefore act as a ranking. When two constraints
# conflict, the one with the lower factor gives way.
#
# The factors that matter for the constraints in these chapters are listed below, from
# AEMO's [Schedule of Constraint Violation Penalty Factors, v8.0, effective 2 December 2025](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
#
# | Item | Constraint | Factor | Chapter |
# | --- | --- | --- | --- |
# | 3 | Unit ramp rate | 1155 | [Energy](@ref nemde-energy) |
# | 4 | MNSP ramp rate | 1155 | [Interconnectors](@ref nemde-interconnectors) |
# | 5 | Interconnector flow limit | 1150 | [Interconnectors](@ref nemde-interconnectors) |
# | 8, 9 | Cleared bands equal the target, for units and for an MNSP | 1135 | [Energy](@ref nemde-energy) |
# | 10 | Fast-start inflexibility profile | 1130 | [Fast-start](@ref nemde-fast-start) |
# | 12 | Wind and solar forecast (UIGF) | 385 | [Energy](@ref nemde-energy) |
# | 14 | Unit availability | 370 | [Energy](@ref nemde-energy) |
# | 16, 17 | MNSP availability and losses | 365 | [Interconnectors](@ref nemde-interconnectors) |
# | 19 | FCAS maximum availability | 155 | [FCAS](@ref nemde-fcas) |
# | 20 | Joint energy and regulation ramping | 155 | [FCAS](@ref nemde-fcas) |
# | 21 | Regulation ramping shared by the two sides of a battery | 155 | [FCAS](@ref nemde-fcas) |
# | 22, 23 | Regional energy balance: unserved demand and excess generation | 150 | [Energy](@ref nemde-energy) |
# | 24 | FCAS trapezium and joint capacity limits | 70 | [FCAS](@ref nemde-fcas) |
# | | Generic constraints | Set per constraint | This chapter |
# | 53 | Tie-breaking | 0.000001 | This chapter |
#
# Read from the top, the table says what NEMDE protects most. It leaves demand unserved
# (150) before it exceeds a unit's declared availability (370), and it exceeds availability
# before it asks a unit to ramp faster than it can (1155). Generic constraints carry their
# own factor, and most network limits rank below the regional energy balance. The schedule
# lists further items that are outside these chapters.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** every item above has a priced violation. **This package:** items 3, 5, 19 to
#     24 and the generic constraints have one. Items 12 and 14 are hard limits adjusted before
#     the solve (see [Energy bids and participants](@ref nemde-energy)), items 4, 9, 16 and
#     17 are hard or absent (see [Interconnectors and losses](@ref nemde-interconnectors)),
#     and items 8 and 10 are absent. The market price cap comes from a built-in table by
#     financial year.
#
# ## Offers at the same price
#
# When two offer bands in a region have the same price, the cost is the same whichever one
# is used, and a linear programme would pick arbitrarily. NEMDE instead shares the dispatch
# between them in proportion to their size. Two bands ``a`` and ``b`` are **price-tied** if
# their loss-adjusted prices are within 0.000001 dollars per MWh of each other. For each
# tied pair NEMDE adds:
#
# ```math
# \frac{q_a}{Q_a}-\frac{q_b}{Q_b}+\sigma_{ab}^{+}-\sigma_{ab}^{-}=0.
# ```
#
# The constraint asks that both bands be used to the same fraction. Its slacks carry the
# smallest factor in the schedule, item 53, so any other constraint overrides it. A band
# held back by a ramp limit or a network constraint simply breaks the tie.
#
# Tie-breaking applies to energy offers and bids only. Equally priced FCAS offers are
# dispatched in whatever proportion the solver arrives at.
#
# For example, two generators each offer a band at \$50/MWh, of 100 MW and 50 MW, and 90 MW
# is needed from them. Tie-breaking gives 60 MW and 30 MW, 60 per cent of each.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** the tie-breaking slack is priced at its factor times the market price cap.
#     **This package:** it is priced at 0.000001 dollars per MWh, without the market price
#     cap. The proportional sharing is the same; the penalty is smaller.
#
# ## From the solution to prices
#
# ### Energy
#
# The price of energy in a region is the marginal value ``\lambda_r`` of its energy
# balance: the change in the objective if the region's demand rose by 1 MW. The objective
# is in dollars over an interval of ``h`` hours, so the price in dollars per MWh is
#
# ```math
# P_r=\frac{\lambda_r}{h}.
# ```
#
# With no binding network constraint and no interaction with FCAS, this is the loss-adjusted
# price of the most expensive band in use, the textbook marginal offer. With a binding constraint it need not be the price of any
# single offer. Serving one more MW may mean raising one unit and lowering another to keep
# within the limit, and the price is the net cost of that combination.
#
# This is also why a unit can be dispatched while its offer is above the regional price, or
# left idle while its offer is below it. A generic constraint is forcing the outcome. Every
# unit in the region is still settled at the regional price times its loss factor.
#
# ### FCAS
#
# The price of an FCAS service in a region is the sum of the marginal values ``\mu_g`` of
# the generic constraints that require that service from that region. More than one usually
# applies: a requirement for the whole market, and one for a region that could be cut off.
# See [FCAS prices](@ref fcas-pricing).
#
# ### What the published price adds
#
# The price straight from the optimisation is published as the **regional original price
# (ROP)**. The **regional reference price (RRP)**, used for settlement, is the same number
# in most intervals. It differs when one of the following applies.
#
# - **Cap and floor.** The price is limited to the market price cap and the market floor
#   price.
# - **Over-constrained dispatch.** If a constraint was violated, the marginal values contain
#   penalty prices, which are not market prices. AEMO relaxes the violated constraints and
#   solves again to obtain prices.
# - **Administered pricing.** After a sustained run of high prices, a lower administered
#   cap applies.
# - **Intervention.** If AEMO has directed a participant, prices come from a second solve
#   that removes the effect of the direction.
#
# AEMO describes these steps in its
# [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf).
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** publishes prices after the adjustments above. **This package:** returns the
#     marginal values of a single solve, with none of the adjustments. Its prices are
#     comparable with the ROP. In an interval with a violated constraint they contain
#     penalty prices and can be far from the published RRP.
#
# ## A worked example
#
# One region has a demand of 250 MW and two generators: G1 offers 200 MW at \$30/MWh and G2
# offers 200 MW at \$80/MWh. A network constraint limits G1's output: ``p_{G1}\le 180``.
#
# G1 is dispatched to 180 MW, its limit, and G2 supplies the remaining 70 MW. One more MW of
# demand must come from G2, so the regional price is \$80/MWh. G1 has 20 MW of offers below
# the price that are not dispatched: it is constrained off.
#
# The constraint's marginal value is the saving from relaxing it by 1 MW: one MW moves from
# G2 to G1, saving \$80 less \$30, or \$50 per MWh. Over a five-minute interval that is
# ``50/12`` = \$4.17.
#
# Now suppose G2 has only 60 MW available. Supply falls 10 MW short. The cheapest violation
# decides the outcome. If the network constraint has a factor of 30, below the energy
# balance's 150, NEMDE exceeds the network limit by 10 MW and serves all demand.
#
# ## References
#
# - AEMO, [Constraint Formulation Guidelines](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf), §§4-5: structure and sign conventions of generic constraints.
# - AEMO, [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf): all penalty items.
# - AEMO, [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf): over-constrained dispatch and pricing.
# - AEMO, [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/): column definitions.
#
# ## [Where the data lives](@id nemde-prices-data)
#
# The **Table** column is the MMSDM table and the cache directory; see
# [the cache layout](@ref nemde-data).
#
# | Symbol | Quantity | Table | Columns | Time key | Role |
# | --- | --- | --- | --- | --- | --- |
# | ``g`` | Constraints active in the interval, and the version in force | `DISPATCHCONSTRAINT` | `CONSTRAINTID`, `GENCONID_EFFECTIVEDATE`, `GENCONID_VERSIONNO` | Interval end | Input |
# | ``b_g`` | Right-hand side | `DISPATCHCONSTRAINT` | `RHS` | Interval end | Result, used as input |
# | | Sense of the constraint | `GENCONDATA` | `CONSTRAINTTYPE` | Effective date (`EFFECTIVEDATE`, `VERSIONNO`) | Input |
# | ``v_g`` | Penalty factor of the constraint | `GENCONDATA` | `GENERICCONSTRAINTWEIGHT` | Effective date | Input |
# | ``w_{g,u}``, ``w_{g,u,j}`` | Unit coefficients, for energy or an FCAS service | `SPDCONNECTIONPOINTCONSTRAINT` | `CONNECTIONPOINTID`, `BIDTYPE`, `FACTOR` | Effective date | Input |
# | | Regional coefficients | `SPDREGIONCONSTRAINT` | `REGIONID`, `BIDTYPE`, `FACTOR` | Effective date | Input |
# | ``w_{g,i}`` | Interconnector coefficients | `SPDINTERCONNECTORCONSTRAINT` | `INTERCONNECTORID`, `FACTOR` | Effective date | Input |
# | | Unit at each connection point | `DUDETAILSUMMARY` | `DUID`, `CONNECTIONPOINTID` | Effective date (`START_DATE`, `END_DATE`) | Input |
# | ``\mathrm{MPC}`` | Market price cap | `MARKET_PRICE_THRESHOLDS` (not cached) | `VOLL` | Effective date | Input |
# | ``\mu_g`` | Marginal value, left-hand side and violation | `DISPATCHCONSTRAINT` | `MARGINALVALUE`, `LHS`, `VIOLATIONDEGREE` | Interval end | Result |
# | ``P_r`` | Energy price from the optimisation | `DISPATCHPRICE` | `ROP` | Interval end | Result |
# | | Energy price after adjustments | `DISPATCHPRICE` | `RRP`, `APCFLAG` | Interval end | Result |
# | | FCAS prices | `DISPATCHPRICE` | `<SERVICE>ROP`, `<SERVICE>RRP` | Interval end | Result |
# | ``p_u`` | Energy target | `DISPATCHLOAD` | `TOTALCLEARED` | Interval end | Result |
#
# The three coefficient tables are matched to the constraint by the triple of identifier,
# effective date and version number published in `DISPATCHCONSTRAINT`. They are written only
# when a constraint changes, so the rows for a current interval can sit in an archive month
# years earlier.
#
# The dispatch tables hold one row per interval in normal operation, with `INTERVENTION = 0`.
# During an intervention they hold two: `INTERVENTION = 1` is the physical dispatch and
# `INTERVENTION = 0` is the pricing solve.
