# # [Violations, tie-breaking and prices](@id nemde-prices)
#
# Dispatch minimises cleared energy and FCAS offer costs plus violation penalties. Prices come
# from the resulting constraint duals. This chapter distinguishes the package's raw optimisation
# prices from AEMO's published adjusted prices and records which constraints are elastic.
#
# ## Objective units and penalty hierarchy
#
# Let ``h`` be interval hours, ``S`` base MW, ``\mathrm{MPC}`` the interval's market price cap,
# ``v_j`` a CVP factor and ``s_j`` violation MW. The physical-unit objective is
#
# ```math
# \min\ C_E+C_F+C_{MNSP}+h\,\mathrm{MPC}\sum_jv_js_j+C_{tie}.
# ```
#
# In PSI's per-unit coordinates, each violation term is ``hS\,\mathrm{MPC}v_js_j^{pu}``.
# The factor expresses priority; it is not itself a dollar-per-MW price. Supply the historical
# cap for the interval, rather than today's cap for an older replay. The
# [AEMO CVP schedule v8.0, effective 2 December 2025](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf)
# is the source for the following factors. The table describes implementation coverage too;
# the presence of an item in that schedule does not mean AEMSim builds it.
#
# | Row | Factor | Slack and implementation coverage |
# | --- | --- | --- |
# | Energy ramp up/down | 1155 | Separate nonnegative slacks in NEM dispatch |
# | Interconnector export/import limit | 1150 | Separate flow-surplus/deficit slacks; breakpoint span stays hard |
# | Thermal offer excess | 1135 | Pending #184, thermal replay only |
# | Fast-start profile | 1130 | Pending #184, lower deficit and fixed-profile upper surplus |
# | Thermal maximum availability | 370 | Pending #184, thermal replay only; current limits are hard/adjusted |
# | UIGF | 385 | AEMO schedule item, **no distinct implemented slack** |
# | FCAS maximum availability | 155 | Optional service slack; otherwise a hard bound |
# | Joint energy/regulation ramp | 155 | Optional service slack; raise/lower rows |
# | Shared BDU regulation ramp capability | 155 | Optional slack on total generation/load-side regulation against shared SCADA capability |
# | Regional energy balance | 150 | Deficit and surplus with network `use_slacks=true` |
# | Generic constraints, including FCAS procurement | Published weight | Service `use_slacks=true`, from `GENCONDATA.GENERICCONSTRAINTWEIGHT` |
# | FCAS capacity/trapezium rows | 70 | Optional service slacks |
#
# Generic FCAS requirement rows are not assigned factor 150 merely because they mention a
# region. Their own resolved generic-constraint weight applies. All listed optional FCAS
# slacks require the corresponding service model's `use_slacks` setting. Demand, offers and
# capability must still be valid when slacks are enabled.
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
# The readers match invoked sets, effective/versioned `GENCONDATA` definitions and
# `SPDCONNECTIONPOINTCONSTRAINT`, `SPDREGIONCONSTRAINT`, `SPDINTERCONNECTORCONSTRAINT` terms.
# RHS values come from the matching `DISPATCHCONSTRAINT` run. A missing definition must not be
# replaced by a guessed inequality from the constraint name. Procurement equations and the
# detailed MMSDM join map are in [FCAS capability and co-optimisation](@ref nemde-fcas).
#
# ## Equal-price energy tie-breaking
#
# AEMSim groups referred energy bands by region, direction and interval when their prices are
# within the fixed current tolerance of ``10^{-6}`` \$/MWh. It compares bands from different units with positive widths.
# For band MW ``q_a,q_b`` and offered MW ``Q_a,Q_b``, define
#
# ```math
# d_{ab}=\frac{q_aQ_b-q_bQ_a}{Q_{ref}},\qquad
# d_{ab}+s_{ab}^{def}-s_{ab}^{sur}=0,\qquad
# C_{tie}=h\,10^{-6}\sum_{ab}(s_{ab}^{def}+s_{ab}^{sur}).
# ```
#
# ``Q_{ref}`` is the widest band in the entire tied group, not just this pair.
# Minimising this absolute difference encourages equal utilisation fractions when other
# constraints permit. Grouping is transitive along the sorted price sequence; it does not
# impose a global band-order constraint. The ``10^{-6}`` is the package's dollar coefficient,
# **not** an MPC multiplier. Tie-breaking is currently installed with the elastic regional
# balance formulation and applies to energy bands, not FCAS or MNSP offers. Physical and generic
# constraints can legitimately prevent equal fractions. This small objective term is an
# approximation of the tie-breaking priority in the CVP schedule, not a complete account of
# AEMO's dispatch tie-resolution rules.
#
# ## Duals, mixed-integer decisions and price units
#
# With the balance written in per-unit MW and costs per interval, raw energy price is
#
# ```math
# \mathrm{ROP}_{r}=\frac{\pi_r^{balance}}{Sh}.
# ```
#
# The divisor removes both the base-MW scale and interval length. Taking the dual alone as
# \$/MWh gives a wrong price. AEMSim sums the duals of every requirement tagged for that
# region/service pair:
#
# ```math
# P_{r,s}^{FCAS}=\frac{1}{Sh}\sum_{k\in\mathcal G_{r,s}}\pi_k.
# ```
#
# JuMP dual signs depend on row sense. FCAS recovery retains the raw solver sign, typically
# positive for a binding lower-bound row and negative for a binding upper-bound row; it warns
# about missing recorded rows. `FCASRequirement` tags do not contain weighting coefficients.
# This mapping mirrors published requirement attribution; it does not infer a price from
# an arbitrary coefficient-weighted perturbation of a generic RHS. A shared requirement can
# contribute to several regional service prices. A raw constraint marginal value is not
# automatically the price of the entire service. See [FCAS price recovery](@ref fcas-pricing).
#
# Ordered loss segments and MNSP directions introduce integer decisions. The pinned PSI fork
# fixes those decisions after the MIP solve and solves an LP to recover requested duals.
# These prices describe marginal changes **with those integer decisions fixed**. They are not
# global sensitivity across a change of flow direction, loss segment or fast-start commitment.
# Record the relevant balance and generic-constraint duals in the decision model before solving.
#
# ## Comparison outputs and omitted price adjustments
#
# | Output | MMSDM comparison | Interpretation |
# | --- | --- | --- |
# | Energy target | `DISPATCHLOAD.TOTALCLEARED` | Compare the matching intervention run |
# | Raw energy price | `DISPATCHPRICE.ROP` | Closest published comparison to balance-dual recovery |
# | Adjusted energy price | `DISPATCHPRICE.RRP` | May include procedures not implemented here |
# | FCAS prices | `DISPATCHPRICE` raise/lower service RRP and ROP columns | Compare the same service and pricing run |
# | Generic RHS, LHS, marginal value and violation | `DISPATCHCONSTRAINT` | Diagnostics, not a substitute for matching definitions |
# | Market settings | `MARKET_PRICE_THRESHOLDS.EFFECTIVEDATE`, `VOLL` | Resolve the historical MPC for penalty costs |
#
# AEMO's [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf)
# describes over-constrained dispatch and price processing. AEMSim does not reproduce the full
# over-constrained-dispatch rerun, price scaling, administered pricing, intervention pricing
# or settlement adjustments. A large raw dual under a violated row is therefore not evidence
# that the published RRP should equal that penalty. Report model targets, violations and raw
# prices separately, and diagnose differences before claiming historical price replication.
