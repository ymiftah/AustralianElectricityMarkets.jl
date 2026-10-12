using CairoMakie #hide

# # [Energy bids and participants](@id nemde-energy)
#
# Energy dispatch chooses generation and controllable consumption together with FCAS. This
# chapter writes the implemented energy equations in MW and prices in \$/MWh. Let ``h`` be
# interval hours, ``S`` system base MW, and ``p_u`` signed net injection. The default dispatch
# interval is five minutes, ``h=1/12``. Internal PSI quantities are per-unit of ``S``.
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
# `set_market_bids!` refers energy prices to the regional reference node and rounds to cents.
# Band MW are unchanged. A battery can have separate generation and load loss factors.
# `read_bids` returns prices before referral, whereas the attached market curves are referred.
# FCAS prices do not undergo this energy-price referral. AEMO explains division by the loss
# factor in [Treatment of Loss Factors, §12, pp. 25-28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/loss_factors_and_regional_boundaries/2016/treatment_of_loss_factors_in_the_nem.pdf).
# Its older settlement timing is not used here.
#
# ## Participant signs and regional balance
#
# | Participant | Model energy coordinate | Contribution to net injection |
# | --- | --- | --- |
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
# `set_demand!` attaches published `TOTALDEMAND` directly; the current reader does not perform
# an additional scheduled-load adjustment. A replay with explicit scheduled consumption must
# check that its demand convention matches this balance to avoid counting consumption twice. FCAS targets are capability, so they do not add MW to
# this balance. The [Constraint Formulation Guidelines, §§4-5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf)
# describe energy and FCAS terms; the detailed package loss balance is in
# [Interconnectors and losses](@ref nemde-interconnectors).
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
# Rates here are MW/h. ``p^0_u`` is metered `INITIALMW` in `NEMReplayDispatch`. In
# `NEMLookaheadDispatch`, the first interval uses initial conditions and subsequent intervals
# ramp from the preceding model target. These are different information assumptions.
# The energy and ramp limits follow the dispatch inputs described by
# [AEMO's Dispatch Procedure](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/power_system_ops/procedures/so_op_3705-dispatch.pdf)
# and the `DISPATCHLOAD` data-model fields; slack priorities follow the
# [CVP schedule v8.0, items 1 and 10](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
#
# On the current branch, replay raises the generator's `max_active_power` ceiling to at least
# ``p^0-R^{down}h`` to avoid a ramp-down conflict. For semi-scheduled generation the published
# availability is ``\min(\mathrm{MAXAVAIL},\mathrm{UIGF})`` before that adjustment. There is
# no separate factor-385 UIGF violation variable in this formulation. `SEMIDISPATCHCAP=0`
# does not mean the weather forecast is absent. The helper `energy_bounds` provides an
# inspection envelope; it does not replace the device constraints built by PSI.
#
# Pending PR #184 changes **thermal replay**: it retains the published availability as an
# elastic row and introduces separately priced offer excess. It does not make the same change
# to batteries, loads, renewable replay or lookahead. See [Fast-start dispatch](@ref nemde-fast-start).

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
# ## Battery directions and implementation coverage
#
# Battery energy uses
#
# ```math
# p_u=p_u^{out}-p_u^{in},\qquad
# 0\le p_u^{out}\le A_u^{GEN},\qquad0\le p_u^{in}\le A_u^{LOAD}.
# ```
#
# Both energy ramp rows act on this net coordinate, with the same slack signs as above.
# Replay raises the generation ceiling to a positive net ramp-down floor and raises the
# consumption ceiling when a negative net ramp-up ceiling requires continued charging:
# ``A^{GEN}_{eff}=\max(A^{GEN},p^0-R^{down}h)`` and
# ``A^{LOAD}_{eff}=\max(A^{LOAD},-(p^0+R^{up}h))``. The current branch can still retain a
# smaller static variable rating bound. The #182 fix inherited by the pending #183/#184 stack
# makes the finite directional ceiling the corresponding variable bound too.
#
# These NEM battery formulations do not impose charge/discharge exclusivity or a storage-energy
# balance. Net injection alone does not determine both side quantities. This is a package
# limitation, not a claim that NEMDE ignores stored energy. AEMO's
# [FCAS model, §5, pp. 18-19](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
# includes energy-related eligibility conditions that this replay omits.
#
# ## Input map
#
# | Input | Table and fields | Package path |
# | --- | --- | --- |
# | Energy prices | `BIDDAYOFFER_D.PRICEBAND1` to `PRICEBAND10`, `BIDTYPE=ENERGY` | `read_bids` / `set_market_bids!` |
# | Bands and directional availability | `BIDPEROFFER_D.BANDAVAIL1` to `BANDAVAIL10`, `MAXAVAIL`, `DIRECTION` | Market curves; battery `energy_max_avail[_decremental]` |
# | Reference-node loss factors | `DUDETAILSUMMARY.TRANSMISSIONLOSSFACTOR`, `DISTRIBUTIONLOSSFACTOR`, `SECONDARY_TLF` | `read_loss_factors`, direction-specific price referral |
# | Meter, rates, effective availability | `DISPATCHLOAD.INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`, `AVAILABILITY` | `set_nem_dispatch_limits!` |
# | Weather forecast | `DISPATCHLOAD.UIGF`, classification from `DUDETAILSUMMARY.SCHEDULE_TYPE` | `read_uigf` |
# | Regional demand | `DISPATCHREGIONSUM.TOTALDEMAND` (used directly) | `set_demand!` |
# | Device identity and region | `DUDETAILSUMMARY.DUID`, `DISPATCHTYPE`, `REGIONID`, effective dates | System construction |
#
# Bid joins retain `(market day, DUID, BIDTYPE, DIRECTION)` and interval timestamp, selecting
# applied versions. Dispatch inputs retain the matching intervention run. The
# [FCAS input map](@ref fcas-types-mapping) explains the daily-date versus interval-date distinction.
# Published `TOTALCLEARED` and `DISPATCHPRICE.RRP/ROP` are comparison outputs, not bounds or costs.
