# # [The NEMDE formulation](@id nemde-model)
#
# Every five minutes, NEMDE chooses energy targets, interconnector transfers and FCAS enablement
# from offers, forecasts and measured starting conditions. Energy and FCAS share physical
# capability, so they are co-optimised. These chapters explain the physical constraints,
# offer costs and pricing principles using MW quantities and published AEMO references.
#
# !!! note "Scope"
#     The equations provide an explanatory reconstruction of NEM dispatch. Known gaps and
#     assumptions are identified where they affect interpretation of results.
#
# ## Reading the formulation
#
# | Chapter | Equations and inputs |
# | --- | --- |
# | [Energy bids and participants](@ref nemde-energy) | Generation, scheduled consumption, battery directions, price referral, availability, ramps and regional balance |
# | [FCAS capability and co-optimisation](@ref nemde-fcas) | The ten services, procurement, offers, scaling, trapezia, joint capacity/ramping, battery regulation and a worked MMSDM interval |
# | [Interconnectors and losses](@ref nemde-interconnectors) | Signed flow, piecewise losses, regional sharing and MNSP directional offers |
# | [Fast-start dispatch](@ref nemde-fast-start) | Profile modes, two-pass commitment, ramp time and distinct violations |
# | [Violations, tie-breaking and prices](@ref nemde-prices) | Generic rows, penalty hierarchy, equal-price bands, marginal prices and price adjustments |
#
# Each chapter maps mathematical inputs to MMSDM tables. Figures illustrate the constraints
# with constructed examples; the FCAS chapter also includes a worked historical interval.
#
# ## Notation and information timing
#
# | Symbol | Meaning and units |
# | --- | --- |
# | ``u,r,i,b,k`` | Unit, region, interconnector, band, generic constraint |
# | ``s`` | FCAS service index; a subscripted ``s_j`` denotes violation slack |
# | ``h`` | Dispatch interval hours, normally ``5/60`` |
# | ``p_u`` | Signed net energy injection in MW |
# | ``q_{u,b}``, ``Q_{u,b}`` | Cleared and offered band MW |
# | ``r_{u,s}`` | Enabled FCAS MW |
# | ``x_i,L_i`` | Signed interconnector flow and loss MW |
# | ``c`` | Energy price in \$/MWh or FCAS price in \$/MW/h |
#
# An MMSDM dispatch timestamp identifies the interval **end**, in fixed AEST. `INITIALMW` is the
# metered starting output, not the preceding dispatch target. Historical reconstruction uses
# the starting conditions known before dispatch. Multi-interval studies may instead use the
# previous calculated target; this changes the information available to each interval.
# Published `TOTALCLEARED`, RRP and FCAS targets are comparison outputs. A published generic RHS
# is used to reconstruct the invoked network equation; its definition and version still matter.
#
# The physical-unit objective has the shape
#
# ```math
# \min\ h\left(\sum c^{GEN}q^{GEN}-\sum c^{LOAD}q^{LOAD}
# +\sum c^{FCAS}q^{FCAS}+\sum c^{MNSP}q^{MNSP}
# +\mathrm{MPC}\sum_jv_js_j\right)+C_{tie}.
# ```
#
# Generation and FCAS incur offer cost, while controllable consumption earns bid value. Losses
# enter regional balance rather than a separate offer-cost term. The detailed signs, referral,
# limits and slack conditions are defined in the linked chapters. Constraint duals express
# the marginal cost of changing a requirement; their units depend on objective scaling.
#
# For worked examples, see [NEMDE as a JuMP model](@ref nemde-jump) and the following
# tutorials. Their reduced markets illustrate the equations rather than a complete NEM replay.
#
# ## [Official references](@id nemde-model-references)
#
# - AEMO, [Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf): dispatch inputs, runs and pricing procedures.
# - AEMO, [FCAS Model in NEMDE](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf): capability, scaling, eligibility and joint constraints.
# - AEMO, [Fast Start Unit Inflexibility Profile](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf): preprocessing, modes and two passes.
# - AEMO, [Constraint Formulation Guidelines](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf) and [CVP schedule](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf): equations and violation priorities.
# - AEMO, [Loss factors and regional boundaries](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/market-operations/loss-factors-and-regional-boundaries): annual reports and loss-factor methodology.
# - AEMO, [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/): table schemas, keys and input/output definitions.
