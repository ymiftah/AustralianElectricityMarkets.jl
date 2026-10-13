# # [Violations, tie-breaking and prices](@id nemde-prices)
#
# Dispatch minimises cleared energy and FCAS offer costs plus violation penalties. Prices come
# from marginal values of the dispatch constraints. Published prices can also reflect
# over-constrained dispatch and other pricing procedures.
#
# ## Objective units and penalty hierarchy
#
# Let ``h`` be interval hours, ``\mathrm{MPC}`` the interval's market price cap,
# ``v_j`` a CVP factor and ``s_j`` violation MW. The physical-unit objective is
#
# ```math
# \min\ C_E+C_F+C_{MNSP}+h\,\mathrm{MPC}\sum_jv_js_j+C_{tie}.
# ```
#
# The factor expresses relative priority, rather than a dollar price by itself. Use the
# market price cap and penalty schedule applicable to the interval. The
# [AEMO CVP schedule v8.0, effective 2 December 2025](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf)
# gives the following selected factors.
#
# | Restriction | CVP factor |
# | --- | --- |
# | Unit energy ramp up/down | 1155 |
# | Interconnector capacity limit | 1150 |
# | Total band MW offer | 1135 |
# | Fast-start inflexibility profile | 1130 |
# | UIGF | 385 |
# | Unit maximum availability | 370 |
# | FCAS maximum availability | 155 |
# | Joint energy/regulation ramp | 155 |
# | Shared bidirectional-unit regulation SCADA ramp | 155 |
# | Regional energy balance | 150 |
# | FCAS joint capacity | 70 |
# | Generic constraints, including FCAS procurement | Constraint-specific weight |
#
# Generic FCAS requirements use their resolved constraint weights, rather than the regional
# energy-balance factor. The schedule includes other restrictions and exceptions; this table
# is not a complete dispatch specification.
#
# !!! note "Violation coverage"
#     A restricted reconstruction may keep a limit hard or omit its separate violation
#     quantity. A published CVP factor does not establish that the corresponding violation
#     is represented in a particular study.
#
# ## Generic constraint signs
#
# A generic row combines energy, FCAS and interconnector terms:
#
# ```math
# g_k=\sum_ua_{k,u}p_u+\sum_{u,s}b_{k,u,s}r_{u,s}+\sum_ic_{k,i}x_i.
# ```
#
# Elastic versions use ``g_k-s_k^{sur}\le B_k``, ``g_k+s_k^{def}\ge B_k``, or
# ``g_k+s_k^{def}-s_k^{sur}=B_k``. Equality needs both directions. A positive coefficient
# does not by itself identify a unit as constrained on or off: the sense and marginal value
# are essential. See [Constraint Formulation Guidelines, §§4-5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf).
#
# Reconstructing a constraint requires matching invoked sets, effective/versioned `GENCONDATA` definitions and
# `SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT` terms.
# RHS values come from the matching `DISPATCHCONSTRAINT` run. A missing definition must not be
# replaced by a guessed inequality from the constraint name. Procurement equations and the
# detailed MMSDM join map are in [FCAS capability and co-optimisation](@ref nemde-fcas).
#
# ## Equal-price energy tie-breaking
#
# Energy bands with equal loss-adjusted prices are dispatched proportionally to their
# offered MW when the other constraints permit. AEMO’s CVP schedule, item 53, treats prices
# within ``10^{-6}`` \$/MWh as tied and applies this rule to energy bids and offers. FCAS
# offers are not subject to the same default tie-breaking rule.
#
# For two tied bands, equal utilisation means
#
# ```math
# \frac{q_a}{Q_a}=\frac{q_b}{Q_b}.
# ```
#
# Physical and generic constraints can prevent equal utilisation. The tie-breaking priority
# is sufficiently small that it does not override the higher-priority dispatch restrictions.
#
# ## Marginal prices and units
#
# With energy balance in MW and offer costs measured over ``h`` hours, its marginal value
# ``\pi_r`` is converted to a price in \$/MWh by
#
# ```math
# P_r^{energy}=\frac{\pi_r}{h}.
# ```
#
# A different objective scaling requires the corresponding conversion. FCAS prices reflect
# the marginal cost of the requirements procuring that service for a region, including shared
# requirements. A generic constraint’s marginal value is not automatically a service price:
# its coefficients, scope and requirement attribution matter. See
# [FCAS price recovery](@ref fcas-pricing).
#
# !!! note "Local marginal values"
#     Prices calculated with commitment or flow-direction choices held fixed describe local
#     sensitivity. They do not measure the cost of changing those choices.
#
# ## Published outputs and price adjustments
#
# | Output | MMSDM comparison | Interpretation |
# | --- | --- | --- |
# | Energy target | `DISPATCHLOAD.TOTALCLEARED` | Compare the matching intervention run |
# | Raw energy price | `DISPATCHPRICE.ROP` | Closest published comparison to balance-dual recovery |
# | Adjusted energy price | `DISPATCHPRICE.RRP` | Includes applicable price processing |
# | FCAS prices | `DISPATCHPRICE` raise/lower service RRP and ROP columns | Compare the same service and pricing run |
# | Generic RHS, LHS, marginal value and violation | `DISPATCHCONSTRAINT` | Diagnostics, not a substitute for matching definitions |
# | Market settings | `MARKET_PRICE_THRESHOLDS.EFFECTIVEDATE`, `VOLL` | Resolve the historical MPC for penalty costs |
#
# AEMO's [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf)
# describes over-constrained dispatch and price processing.
#
# !!! note "Price-reconstruction limits"
#     The reconstruction does not reproduce all over-constrained-dispatch reruns, price
#     scaling, administered pricing or intervention-pricing procedures. A large marginal
#     value under a violated restriction need not equal published RRP. Compare targets,
#     violations and raw prices separately when assessing historical agreement.
