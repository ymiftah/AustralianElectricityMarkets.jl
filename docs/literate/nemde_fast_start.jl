using CairoMakie #hide

# # [Fast-start dispatch](@id nemde-fast-start)
#
# Fast-start inflexibility profiles constrain a unit after a commitment decision. They are
# not an ordinary minimum-generation bound or a price-based classification of observed targets.
# **The equations in this chapter describe pending PR #184.** The current branch reads profile
# fields but does not enforce this two-pass formulation. The proposed implementation supports
# `ThermalStandard` with `NEMReplayDispatch`; it does not add multi-interval unit commitment.
#
# ## Profile modes and interval-end output
#
# A profile has minimum load ``M`` (MW) and four durations ``T_1,\ldots,T_4`` (minutes).
# Its state is a mode and elapsed minutes in that mode. Following AEMO's
# [Fast Start Unit Inflexibility Profile, §§2-5, pp. 5-14](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf),
# the proposed replay advances this state to the dispatch interval's end:
#
# | Mode | Meaning | Profile restriction at elapsed time ``\tau`` |
# | --- | --- | --- |
# | 0 | Offline, available for commitment | Fixed zero |
# | 1 | Synchronising | Fixed zero for ``T_1`` minutes |
# | 2 | Ramping to minimum load | Fixed ``M\tau/T_2`` |
# | 3 | Minimum-load hold | At least ``M`` for ``T_3`` minutes |
# | 4 | Release of minimum-load restriction | At least ``M\max(0,1-\tau/T_4)`` |
#
# Mode 4 does not force a shutdown: output can remain above this declining lower bound.
# Completing ``T_4`` alone does not return the unit to mode 0. Zero-duration segments are
# skipped, avoiding division by zero. Units with all four timings zero are treated as
# ordinary units. The package preserves a positive-duration mode at its exact endpoint;
# it enters the next mode when the elapsed interval crosses that endpoint.
#
# With interval-end profile ``\phi_u`` and nonnegative slacks, the dispatch pass builds
#
# ```math
# p_u+s_u^{profile,def}\ge\phi_u,\qquad
# p_u-s_u^{profile,sur}\le\phi_u\quad\text{only in modes 0, 1, 2}.
# ```
#
# Modes 3 and 4 have only the lower row. Both profile slacks have CVP factor 1130; they
# preserve the distinction between a profile violation and a ramp or availability violation.

let #hide
    minutes = [0.0, 2, 6, 9, 13, 16] #hide
    lower = [0.0, 0, 40, 40, 0, 0] #hide
    fig = Figure(size = (800, 340)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Minutes since commitment", ylabel = "Profile output (MW)", title = "Illustrative fast-start minimum-load profile") #hide
    lines!(ax, minutes, lower; linewidth = 3, color = :steelblue, label = "Profile lower bound") #hide
    lines!(ax, [0, 2, 6], [0, 0, 40]; linewidth = 6, color = (:darkorange, 0.5), label = "Fixed-output modes 1 and 2") #hide
    vlines!(ax, [2, 6, 9, 13]; linestyle = :dash, color = (:black, 0.25)) #hide
    axislegend(ax; position = :rt, labelsize = 12) #hide
    fig #hide
end #hide

# *Constructed profile: ``M=40`` MW and ``(T_1,T_2,T_3,T_4)=(2,4,3,4)`` minutes.
# From an offline start, a five-minute dispatch interval ends in mode 2 at 30 MW. Mode 4
# releases the floor from 40 to zero; the actual target need not trace that decline.*
#
# ## Two passes and available ramp time
#
# The first, commitment pass solves energy and FCAS without profile rows. For units initially
# in modes 0, 1 or 2, it also omits ordinary energy ramps and joint FCAS ramp rows. An initially
# offline unit with candidate energy above the package's 0.005 MW threshold is committed.
# Existing active profiles continue irrespective of that candidate. The proposed pipeline
# advances each profile by five minutes and rebuilds a second, dispatch pass with its envelope.
#
# If a unit starts in modes 0-2 and reaches mode 3 or 4 during the interval, define ``t_M``
# as minutes from the initial state to minimum load. Remaining ramp minutes are
# ``\delta=\max(0,5-t_M)``. The second pass energy ramps are
#
# ```math
# p_u-M-s_u^{up}\le R_u^{up}\delta/60,\qquad
# M-p_u-s_u^{down}\le R_u^{down}\delta/60.
# ```
#
# The minimum-load anchor and remaining-time algebra are a project derivation from AEMO
# explanatory material, corroborated by inspected replay examples. AEMO does not expose the
# complete transition equation; this is not a claim of exact reproduction of its internal rows.
#
# Initially operating units in modes 3-4 instead ramp from metered ``p^0`` for all five minutes.
# Units ending before minimum load have their fixed profile rows and no ordinary energy ramps.
# The joint FCAS ramp exception depends on the **initial** mode: initial modes 0-2 omit those
# rows in both passes, even if the interval ends in mode 3. Capacity, trapezium and procurement
# rows still apply. AEMO describes this separation in the
# [FCAS model in NEMDE, §6](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
# and the fast-start two-pass description above.
#
# A completed mode-4 unit is marked offline only if the final target is at most 0.005 MW
# and ``p^0-R^{down}(5/60)\le0.005`` MW. The proposed state cache carries the final state to
# the next replay interval; the commitment pass is an intermediate solve, not a reported dispatch.
#
# ## Availability and offers remain separate constraints
#
# PR #184 adds these elastic rows for **all thermal replay units**, including ordinary units:
#
# ```math
# p_u-s_u^{avail}\le A_u,\qquad
# p_u=\sum_bq_{u,b}+s_u^{offer},\qquad0\le q_{u,b}\le Q_{u,b}.
# ```
#
# ``A_u`` remains the published availability. Its slack has factor 370; offer excess has factor
# 1135. Excess MW receives the offer penalty rather than an invented price band. Profile, energy
# ramp (1155), offer and availability penalties are additive. These priorities follow the
# [CVP schedule v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
# This differs from raising the hard availability ceiling to the ramp-down floor on the current
# branch. It does not soften renewable UIGF, scheduled load or battery limits.
#
# ## Input map and preprocessing
#
# | Input | MMSDM source | Timing |
# | --- | --- | --- |
# | ``M,T_1,T_2,T_3,T_4`` | `BIDDAYOFFER_D.MINIMUMLOAD`, `T1`, `T2`, `T3`, `T4`, generation ENERGY offer | Applied offer for this interval |
# | ``p^0,R^{up},R^{down},A`` | `DISPATCHLOAD.INITIALMW`, `RAMPUPRATE`, `RAMPDOWNRATE`; `BIDPEROFFER_D.MAXAVAIL` | Current interval inputs |
# | Initial mode and elapsed time | `DISPATCHLOAD.DISPATCHMODE`, `DISPATCHMODETIME` | Previous five-minute interval, matching intervention run |
# | Previous target | `DISPATCHLOAD.TOTALCLEARED` | Previous interval only, for preprocessing |
# | Final mode, elapsed time, target | Replay state and second-pass solution | Outputs, then next interval's state |
#
# Current-interval published `TOTALCLEARED` or `DISPATCHMODE` must not be fed back as the
# commitment decision. That would reveal the dispatch result being replicated. The new reader
# `read_fast_start_inputs` separates current inputs from previous-interval state.
#
# Preprocessing handles inconsistent telemetry. If the preceding target is positive while the
# reported initial mode is offline and availability is positive, an initial meter below 1 MW
# resets to mode 0/time 0; otherwise it resets to mode 4/time ``T_4``. With zero availability,
# an offline unit metering below 1 MW stays offline, while other states reset to completed mode 4.
# These are documented input corrections from AEMO's fast-start preprocessing description,
# not inference of the current target from price or actual output.
#
# ## Coverage
#
# The pending pipeline prepares inputs, performs the commitment solve, applies profile and ramp
# envelopes, solves dispatch, and finalises state. A thermal replay build without prepared
# inputs must be diagnosed before treating it as fast-start replay. No eligible fast-start
# inputs require no commitment solve. Lookahead, nonthermal profiles, market price adjustments,
# and a full reproduction of AEMO's internal commitment algorithm remain outside this change.
