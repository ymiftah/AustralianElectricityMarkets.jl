using CairoMakie #hide

# # [Fast-start dispatch](@id nemde-fast-start)
#
# The NEM has no central unit commitment. A participant decides for itself when to start a
# slow plant, and offers it into dispatch once it is running. The exception is the
# **fast-start unit**: a generator, typically a gas turbine or a hydro unit, that can
# synchronise and reach its minimum load within minutes. Such a unit can ask NEMDE to start
# it when the price justifies it. In return NEMDE must respect the shape of its start-up,
# which the unit declares as a **dispatch inflexibility profile**.
#
# This chapter explains the profile, the constraints it adds to dispatch, and the two solves
# NEMDE uses to decide which units to start. It follows AEMO's
# [Fast Start Unit Inflexibility Profile](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf).
# Symbols follow the [notation table](@ref nemde-notation).
#
# ## The inflexibility profile
#
# A profile has a minimum load ``M`` in MW and four durations in minutes, submitted with the
# unit's daily energy offer.
#
# | Parameter | Meaning |
# | --- | --- |
# | ``T_1`` | Time to synchronise after the instruction to start. Output is zero |
# | ``T_2`` | Time to ramp from zero to minimum load |
# | ``T_3`` | Time the unit must stay at or above minimum load |
# | ``T_4`` | Time to shut down from minimum load |
#
# The four durations are non-negative, at least one is positive, and they sum to less than
# 60 minutes. A unit that offers all four as zero is dispatched as an ordinary unit.
#
# The position of a unit on its profile is its **mode**, together with the minutes ``\tau``
# it has spent in that mode. NEMDE receives both at the start of each interval.
#
# | Mode | AEMO's name | Lasts | Output at the end of the interval |
# | --- | --- | --- | --- |
# | 0 | Offline | Until committed | Zero |
# | 1 | Synchronising | ``T_1`` | Zero |
# | 2 | Start up | ``T_2`` | Exactly ``M\,\tau/T_2`` |
# | 3 | Minimum loading | ``T_3`` | At least ``M`` |
# | 4 | Normal operation, first ``T_4`` minutes | ``T_4`` | At least ``M\,(1-\tau/T_4)`` |
# | 4 | Normal operation, after ``T_4`` | Until the target reaches zero | Unrestricted by the profile |
#
# In modes 1 and 2 the output is fixed: the unit follows its start-up and cannot be
# dispatched up or down. In modes 3 and 4 the profile is only a floor, and the unit can be
# dispatched anywhere above it. The floor in mode 4 falls from ``M`` to zero over ``T_4``
# minutes, which lets the unit shut down no faster than it declared. A segment with zero
# duration is skipped.

let #hide
    minutes = [0.0, 2, 6, 9, 13, 16] #hide
    lower = [0.0, 0, 40, 40, 0, 0] #hide
    fig = Figure(size = (800, 340)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Minutes since the instruction to start", ylabel = "Profile (MW)", title = "Illustrative inflexibility profile") #hide
    lines!(ax, minutes, lower; linewidth = 3, color = :steelblue, label = "Floor in modes 3 and 4") #hide
    lines!(ax, [0, 2, 6], [0, 0, 40]; linewidth = 6, color = (:darkorange, 0.5), label = "Fixed output in modes 1 and 2") #hide
    vlines!(ax, [2, 6, 9, 13]; linestyle = :dash, color = (:black, 0.25)) #hide
    axislegend(ax; position = :rt, labelsize = 12) #hide
    fig #hide
end #hide

# *Constructed profile with ``M=40`` MW and ``(T_1,T_2,T_3,T_4)=(2,4,3,4)`` minutes. The
# dashed lines mark the changes of mode at 2, 6, 9 and 13 minutes.*
#
# ## The constraints the profile adds
#
# Write ``\phi_u`` for the profile value at the end of the interval, from the table above.
# The unit's target ``p_u`` must satisfy:
#
# ```math
# p_u+\sigma_u^{\mathrm{def}}\ge\phi_u\quad\text{in every mode},\qquad
# p_u-\sigma_u^{\mathrm{sur}}\le\phi_u\quad\text{in modes 0, 1 and 2}.
# ```
#
# The first constraint is the floor. The second, present only while the output is fixed,
# turns the floor into an equality. Both slacks have a penalty factor of 1130, item 10 of
# AEMO's [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf).
# That is below the ramp-rate factor of 1155 and above the availability factor of 370, so a
# unit on its profile is held there even above its declared availability.
#
# ## Deciding which units to start: two solves
#
# A start is a yes-or-no decision, which a linear programme cannot take. If the profiles were
# simply enforced, NEMDE could not tell whether starting a unit is worthwhile. AEMO resolves
# this with two solves in every interval.
#
# 1. **First solve, without profiles.** All profile constraints are ignored. Units that
#    start the interval in modes 0, 1 or 2 are also freed from their energy ramp rates and
#    from the joint energy and FCAS ramping constraints. The solve shows how much each
#    fast-start unit would produce if it were fully flexible.
# 2. **Commitment.** Each unit's mode at the end of the interval is set from its mode at the
#    start and its first-solve result.
#    - An offline unit is **started** if its first-solve target is positive. It then moves
#      along its profile; if ``T_1+T_2`` is under five minutes it is already in mode 3 by the
#      end of the interval.
#    - A unit already on its profile **continues** along it.
#    - A unit that has completed ``T_4`` runs as an ordinary unit until its target reaches
#      zero.
# 3. **Second solve, with profiles.** The profile constraints are enforced for the modes
#    found in step 2. This solve produces the published targets and prices.
#
# In mode 4, before ``T_4`` has elapsed, the unit's lower limit is the tighter of its
# ramp-down limit and the falling profile floor. Units that begin the interval in modes 0, 1
# or 2 have no joint energy and FCAS ramping constraints in either solve
# ([FCAS Model in NEMDE, §6.5, p. 28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)).
#
# ## Correcting the starting mode
#
# Before the first solve AEMO corrects the starting mode in two cases, using the unit's
# metered output ``p^0_u``.
#
# | Case | Condition | Mode passed to NEMDE |
# | --- | --- | --- |
# | The unit was running outside any profile, and now offers one | It had a positive target in the previous interval, was in mode 0, and is offered available | Mode 0 if ``p^0_u`` is below 1 MW; otherwise mode 4 with ``T_4`` completed |
# | The unit is on its profile and is now offered unavailable | Availability is zero | Mode 0 if it was in mode 0 and ``p^0_u`` is below 1 MW; otherwise mode 4 with ``T_4`` completed |
#
# In both cases, mode 4 with ``T_4`` completed means the unit is treated as an ordinary
# running unit that can be ramped down and shut down.
#
# ## A worked example
#
# Take the profile in the figure: ``M=40`` MW and durations of 2, 4, 3 and 4 minutes. The
# unit is offline, and the first solve gives it a target of 25 MW. That is positive, so the
# unit is started.
#
# | Interval end | Minutes since start | Mode | Constraint on the target |
# | --- | --- | --- | --- |
# | First | 5 | 2, with ``\tau=3`` | Exactly ``40\times3/4`` = 30 MW |
# | Second | 10 | 4, with ``\tau=1`` | At least ``40\times(1-1/4)`` = 30 MW |
# | Third | 15 | 4, ``T_4`` completed | None from the profile |
#
# The unit spends minutes 6 to 9 in mode 3, entirely inside the second interval. In the first
# interval it produces 30 MW whatever the price turns out to be. The cost of those fixed MW
# is the risk the two-solve scheme is designed to weigh.
#
# ## How the replay implements it
#
# `nem_dispatch_sequence` builds the replay of each interval as two PowerSimulations decision
# models that run in order at the same timestamp, when the `System` has an available
# fast-start unit (a unit whose energy offer has a positive ``T_1`` to ``T_4``):
#
# 1. **Commitment run.** The full dispatch without profile rows. A fast-start unit that
#    starts the interval in mode 0, 1 or 2 has no energy ramp rows and no joint ramping rows.
# 2. **End state.** From the commitment run's target, `fast_start_end_state` commits a unit
#    starting in mode 0 when that target is above 0 MW, then advances it through modes 1, 2
#    and 3 by the five minutes of the interval. A unit never leaves mode 4 in the replay.
# 3. **Dispatch run.** The same dispatch with the profile rows of the end mode, elastic at the
#    fast-start penalty factor of 1130 times the Market Price Cap (`FAST_START_CVP_FACTOR`).
#    Its targets, prices and violations are the replay's results.
#
# | End mode | Row of the dispatch run |
# | --- | --- |
# | 0 or 1 | ``p_u\le 0`` |
# | 2 | ``p_u=M\,\tau/T_2`` |
# | 3 | ``p_u\ge M`` |
# | 4 | ``p_u\ge M\,(1-\tau/T_4)``, a lower bound only |
#
# In the dispatch run a unit ending in mode 0, 1 or 2 has no energy ramp rows. A unit that
# left mode 2 during the interval ramps up from its minimum load instead of its starting
# output, ``p_u\le M+R^{\uparrow}t_2``, where ``t_2`` is the time since the end of mode 2 and
# ``R^{\uparrow}`` the lesser of the offered and telemetered ramp-up rates per minute. Every other
# unit keeps its usual ramp rows. Participant fixed loadings are dropped while the unit starts
# the interval in mode 1 or 2.
#
# The starting mode and minutes in mode come from the previous interval's `DISPATCHMODE` and
# `DISPATCHMODETIME` in `DISPATCHLOAD`, the minutes capped at the length of the mode. The
# profile and ``M`` come from the unit's energy offer in `BIDDAYOFFER_D`. Pass
# `fast_start = false` to `nem_dispatch_sequence`, or `--fast-start false` to the batch
# runner, to solve one model per interval, without profiles.
#
# !!! note "Deviation in AustralianElectricityMarketsSimulations"
#     **AEMO:** corrects the starting mode before the first solve, follows the profile from
#     the end state of the previous interval, and applies the profile to every fast-start
#     unit. **AustralianElectricityMarketsSimulations:**
#     - does not model the corrections of the starting mode above, so a unit that NEMDE returns
#       to mode 0 starts from its published mode;
#     - in a closed-loop replay, still starts each unit from AEMO's observed mode and minutes in
#       mode, not from the end state of the previous solve;
#     - gives batteries no profile rows; a battery with a profile keeps its usual rows;
#     - decides the regulation joint ramping exemption from the starting mode in both runs; see
#       [FCAS joint ramping](@ref nemde-fcas).
#
# ## References
#
# - AEMO, [Fast Start Unit Inflexibility Profile](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fast-start-unit-inflexibility-profile.pdf), §§2-5, pp. 5-11: profile, modes, corrections and the two solves.
# - AEMO, [FCAS Model in NEMDE](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf), §6.5, p. 28: joint ramping exception.
# - AEMO, [Schedule of Constraint Violation Penalty Factors, v8.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/schedule-of-constraint-violation-penalty-factors.pdf), item 10.
#
# ## [Where the data lives](@id nemde-fast-start-data)
#
# The **Table** column is the MMSDM table and the cache directory; see
# [the cache layout](@ref nemde-data).
#
# | Symbol | Quantity | Table | Columns | Time key | Role |
# | --- | --- | --- | --- | --- | --- |
# | ``M`` | Minimum load | `BIDDAYOFFER_D` | `MINIMUMLOAD`, with `BIDTYPE = ENERGY` | Trading day | Input |
# | ``T_1`` to ``T_4`` | Profile durations, minutes | `BIDDAYOFFER_D` | `T1`, `T2`, `T3`, `T4` | Trading day | Input |
# | | Availability | `BIDPEROFFER_D` | `MAXAVAIL` | Trading day and interval end | Input |
# | ``p^0_u`` | Metered starting output | `DISPATCHLOAD` | `INITIALMW` | Interval end | Input |
# | | Mode and minutes in mode at the start | `DISPATCHLOAD` | `DISPATCHMODE`, `DISPATCHMODETIME` | Interval end of the **previous** interval | Input |
# | | Target of the previous interval | `DISPATCHLOAD` | `TOTALCLEARED` | Interval end of the previous interval | Input |
# | | Mode and minutes in mode at the end | `DISPATCHLOAD` | `DISPATCHMODE`, `DISPATCHMODETIME` | Interval end | Result |
# | ``p_u`` | Energy target | `DISPATCHLOAD` | `TOTALCLEARED` | Interval end | Result |
#
# `DISPATCHMODE` and `DISPATCHMODETIME` are results of the interval they are stamped with.
# The starting state of an interval is therefore read from the row of the interval before it.
