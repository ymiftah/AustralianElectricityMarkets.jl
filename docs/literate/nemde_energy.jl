using CairoMakie #hide

# # [Energy bids and participants](@id nemde-energy)
#
# Energy dispatch chooses generation and controllable consumption together with FCAS. This
# chapter expresses energy quantities in MW and prices in \$/MWh. Let ``h`` be interval
# hours and ``p_u`` signed net injection. A five-minute interval has ``h=1/12``.
#
# ## Offers, consumption value and price referral
#
# For a generating offer or consumption bid, each cleared band quantity has its own submitted
# bound. Write ``q^d_{u,b}`` for cleared MW and ``Q^d_{u,b}`` for offered MW in direction ``d``:
#
# ```math
# 0\le q^d_{u,b}\le Q^d_{u,b},\qquad
# p^{\mathrm{out}}_u=\sum_bq^{\mathrm{GEN}}_{u,b},\qquad
# p^{\mathrm{in}}_u=\sum_bq^{\mathrm{LOAD}}_{u,b}.
# ```
#
# Generation incurs cost; clearing consumption earns its bid value in the welfare objective:
#
# ```math
# C_E=h\left(\sum_{u,b}\widehat c^{\mathrm{GEN}}_{u,b}q^{\mathrm{GEN}}_{u,b}
# -\sum_{u,b}\widehat c^{\mathrm{LOAD}}_{u,b}q^{\mathrm{LOAD}}_{u,b}\right),\qquad
# \widehat c^d_{u,b}=\operatorname{round}_{0.01}\left(c^d_{u,b}/\mathrm{LF}^d_u\right).
# ```
#
# Energy prices are referred to the regional reference node by dividing by the applicable
# loss factor. This changes the price coordinate, not the offered MW. Generation and consumption
# can have different loss factors. FCAS offers do not use this energy-price referral. See
# [Treatment of Loss Factors, §12, pp. 25-28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2016/treatment_of_loss_factors_in_the_nem.pdf).
#
# ## Participant signs and regional balance
#
# | Participant | Model energy coordinate | Contribution to net injection |
# | --- | --- |
# | Generator | Positive output | ``+p^{out}`` |
# | Scheduled controllable load | Positive consumption | ``-p^{in}`` |
# | Battery | Separate nonnegative output/input | ``p^{out}-p^{in}`` |
# | Non-scheduled FCAS-only load | Energy variable fixed to zero | Consumption is already in regional demand |
#
# Regional energy balance is
#
# ```math
# \sum_{u\in r}p_u+\sum_i I_{r,i}(x_i,L_i)+s_r^{\mathrm{def}}-s_r^{\mathrm{sur}}=D_r.
# ```
#
# ``I_{r,i}`` is the interconnector's signed regional injection, including its loss allocation.
# Fixed demand is on the RHS; scheduled bid consumption is on the LHS with a minus sign.
# FCAS targets represent capability and do not add energy to this balance. See the
# [Constraint Formulation Guidelines, §§4-5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf)
# and [Interconnectors and losses](@ref nemde-interconnectors).
#
# !!! note "Demand convention"
#     When using published `TOTALDEMAND` with explicit scheduled consumption, check whether
#     that consumption is already included. Counting it on both sides changes the balance.
#
# ## Availability and ordinary energy ramps
#
# For an ordinary generator, the hard forms are ``0\le p_u\le A_u`` and
#
# ```math
# p_u-p^0_u-s_u^{\uparrow}\le R_u^{\uparrow}h,\qquad
# p^0_u-p_u-s_u^{\downarrow}\le R_u^{\downarrow}h.
# ```
#
# Rates here are MW/h. ``p^0_u`` is metered `INITIALMW` at the start of a dispatch interval,
# rather than the preceding dispatch target.
# The energy and ramp limits follow the dispatch inputs described by
# [AEMO's Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf)
# and the `DISPATCHLOAD` data-model fields; slack priorities follow the
# [CVP schedule v8.0, items 3 and 14](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
#
# Semi-scheduled generation is subject to offered availability and the unconstrained
# intermittent generation forecast (UIGF). `SEMIDISPATCHCAP=0` does not remove the weather
# forecast. Availability, forecast and ramp restrictions can conflict; the violation
# hierarchy determines which restriction relaxes. See [Violations and prices](@ref nemde-prices).
#
# !!! note "Reconstruction limits"
#     Availability adjustments used to maintain ramp feasibility are not equivalent to
#     separately penalised availability and UIGF violations. Distinguish these assumptions
#     when interpreting a target above published availability.

let #hide
    fig = Figure(size = (800, 300)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Net energy target (MW)", ylabel = "", title = "Illustrative battery net ramp envelope", yticks = (1:2, ["Directional range", "Five-minute ramp range"])) #hide
    lines!(ax, [-80, 100], [1, 1]; color = :gray, linewidth = 12) #hide
    lines!(ax, [-20, 40], [2, 2]; color = :steelblue, linewidth = 12) #hide
    vlines!(ax, [10]; color = :darkorange, linestyle = :dash, label = "Initial net injection: 10 MW") #hide
    axislegend(ax; position = :rb) #hide
    ylims!(ax, 0.5, 2.6) #hide
    fig #hide
end #hide

# *Constructed example: directional capability is 100 MW generation and 80 MW consumption.
# Initial net injection of 10 MW and a 30 MW movement allowance give net targets from -20 to
# 40 MW. Crossing zero is allowed; two separate positive-coordinate ramps would be different.*
#
# ## Battery directions
#
# Battery energy uses
#
# ```math
# p_u=p_u^{out}-p_u^{in},\qquad
# 0\le p_u^{out}\le A_u^{GEN},\qquad0\le p_u^{in}\le A_u^{LOAD}.
# ```
#
# Energy ramps act on net injection, allowing a transition between charging and discharging.
#
# !!! note "Battery energy limits"
#     This reconstruction does not enforce stored-energy feasibility or prevent
#     simultaneous positive generation and consumption quantities. Net injection alone
#     cannot determine those quantities. These omissions should not be interpreted as
#     NEMDE ignoring stored energy. AEMO describes energy-related FCAS eligibility in its
#     [FCAS model, §5, pp. 18-19](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# ## Input map
#
# | Input | Table and fields |
# | --- | --- |
# | Energy prices | `BIDDAYOFFER_D.PRICEBAND1` to `PRICEBAND10`, `BIDTYPE=ENERGY` |
# | Bands and directional availability | `BIDPEROFFER_D.BANDAVAIL1` to `BANDAVAIL10`, `MAXAVAIL`, `DIRECTION` |
# | Reference-node loss factors | `DUDETAILSUMMARY.TRANSMISSIONLOSSFACTOR`, `DISTRIBUTIONLOSSFACTOR`, `SECONDARY_TLF` |
# | Meter, rates, effective availability | `DISPATCHLOAD.INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`, `AVAILABILITY` |
# | Weather forecast | `DISPATCHLOAD.UIGF`, classification from `DUDETAILSUMMARY.SCHEDULE_TYPE` |
# | Regional demand | `DISPATCHREGIONSUM.TOTALDEMAND`  |
# | Device identity and region | `DUDETAILSUMMARY.DUID`, `DISPATCHTYPE`, `REGIONID`, effective dates |
#
# Bid joins retain `(market day, DUID, BIDTYPE, DIRECTION)` and interval timestamp, selecting
# applied versions. Dispatch inputs retain the matching intervention run. The
# [FCAS input map](@ref fcas-types-mapping) explains the daily-date versus interval-date distinction.
# Published `TOTALCLEARED` and `DISPATCHPRICE.RRP/ROP` are comparison outputs, not bounds or costs.
