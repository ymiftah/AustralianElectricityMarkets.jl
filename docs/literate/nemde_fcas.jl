using CairoMakie #hide

# # [FCAS capability and co-optimisation](@id nemde-fcas)
#
# Energy dispatch and frequency response draw on the same generators, batteries and loads.
# NEMDE therefore chooses energy targets and **frequency control ancillary service (FCAS)**
# enablements together. This chapter starts with the services and their procurement requirements;
# the capability constraints explain how much each provider can contribute.
#
# ## Services and procurement requirements
#
# ### What is being procured?
#
# The NEM's nominal frequency is 50 Hz. Raise response increases net injection to correct a
# frequency fall; lower response decreases net injection to correct a rise. A generator can
# change its output, a load can change its consumption, and a battery can change either side of
# its net injection. The direction describes the effect on the power system, rather than the
# sign of the provider's energy dispatch.
#
# **Regulation** follows AEMO's automatic generation control (AGC) signals to manage routine
# imbalances. **Contingency** response is enabled in advance for disturbances and delivered when
# a frequency event calls for it. The eight contingency markets cover four response timeframes,
# each with a raise and a lower service; the two regulation markets complete the ten services.
# AEMO describes these roles in its [Guide to Frequency Control Ancillary Services, v4.0,
# §§2-3, pp. 5-8](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf).
#
# | Service family | Response timeframe | Raise market | Lower market |
# | --- | --- | --- | --- |
# | Regulation | Continuous AGC control | `RAISEREG` | `LOWERREG` |
# | Very fast contingency | 1 second | `RAISE1SEC` | `LOWER1SEC` |
# | Fast contingency | 6 seconds | `RAISE6SEC` | `LOWER6SEC` |
# | Slow contingency | 60 seconds | `RAISE60SEC` | `LOWER60SEC` |
# | Delayed contingency | 5 minutes | `RAISE5MIN` | `LOWER5MIN` |
#
# These are distinct products, not successive energy-dispatch intervals. A provider may offer
# several services, with a separate bid for each. The table names the response timeframes;
# measurement and delivery obligations are specified in AEMO's
# [Market Ancillary Service Specification](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/ancillary-services/market-ancillary-service-specification-and-fcas-verification-tool).
#
# ### Enablement is capacity, not energy already delivered
#
# Let ``f_{u,k}`` be the MW of service ``k`` enabled on provider ``u`` for one dispatch interval.
# It is a reserved response capability. It is distinct from the provider's energy target ``p_u``
# and from the response it subsequently delivers. Enabling 10 MW of raise FCAS does not add
# 10 MW to the regional energy balance: the provider must be able to change its injection if
# called on, while its energy target remains a separate decision.
#
# Each service has its own offer bands and technical envelope. Meeting a requirement therefore
# means selecting deliverable capability, rather than summing every submitted offer. AEMO's
# [FCAS Model in NEMDE, v3.0, §§2-3, pp. 6-13](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
# defines the offer and its dependence on energy dispatch.
#
# ### Local and shared requirements
#
# A simple requirement for service ``k`` in region ``r`` is
#
# ```math
# \sum_{u\in\mathcal U_r} f_{u,k}\ge \mathrm{REQ}_{r,k},
# ```
#
# where ``\mathcal U_r`` is the set of eligible providers in that region. A shared requirement
# sums eligible providers across several regions. A local requirement can apply alongside it,
# restricting how much of the shared total may be supplied elsewhere. Thus a single regional
# service can be governed by several equations at once.
#
# AEMO represents FCAS requirements using generic constraints. Their applicability and terms
# depend on network conditions; some include interconnector flow as well as FCAS enablement.
# See the [Constraint Formulation Guidelines, v13, §5, pp. 16-20](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf).
# A general requirement row can therefore have the form
#
# ```math
# \sum_{u,k} a_{g,u,k}f_{u,k}+\sum_u b_{g,u}p_u+\sum_i c_{g,i}x_i
# \;\{\le,=,\ge\}\;\mathrm{RHS}_g.
# ```
#
# Here ``g`` identifies the equation, ``x_i`` is signed interconnector flow, and the coefficients
# define which responses and dispatch decisions count towards it. The simple regional sum is
# one case of this form. Its right-hand side is not a universal interpretation of every
# published requirement value: read the complete left-hand side and constraint sense.
#
# ### An illustrative procurement example
#
# Consider one contingency service and three providers with 60 MW of usable capability each.
# A shared requirement needs 100 MW in total. Suppose providers A, B and C offer at
# \$2, \$5 and \$9/MWh respectively, and C is the only provider in the local region.
# Holding energy dispatch fixed and assuming no other capability limits, the cheapest shared
# allocation is 60 MW from A, 40 MW from B and none from C.
#
# Add a local requirement of 30 MW. C must now supply at least that amount, so the cheapest
# allocation becomes 60 MW from A, 10 MW from B and 30 MW from C. C's capability counts towards
# **both** the local and shared equations; the requirements do not call for 130 MW in total.

let #hide
    offered = [60.0, 60.0, 60.0] #hide
    shared = [60.0, 40.0, 0.0] #hide
    local_and_shared = [60.0, 10.0, 30.0] #hide
    labels = ["A: outside local region", "B: outside local region", "C: local region"] #hide
    colors = Makie.wong_colors()[1:3] #hide
    fig = Figure(size = (1000, 420)) #hide
    for (col, enabled, title) in ( #hide
            (1, shared, "Shared requirement only: 100 MW"), #hide
            (2, local_and_shared, "Shared 100 MW + local 30 MW"), #hide
        ) #hide
        ax = Axis( #hide
            fig[1, col]; title, ylabel = "Enabled capability (MW)", #hide
            xticks = (1:3, ["A (\$2)", "B (\$5)", "C (\$9)"]), #hide
            xlabel = "Provider (offer price in \$/MWh)", #hide
        ) #hide
        barplot!(ax, 1:3, offered; color = (:gray, 0.18), strokecolor = :gray, strokewidth = 1) #hide
        barplot!(ax, 1:3, enabled; color = colors, width = 0.65) #hide
        for j in 1:3 #hide
            text!(ax, j, enabled[j] + 2; text = "$(Int(enabled[j])) MW", align = (:center, :bottom)) #hide
        end #hide
        ylims!(ax, 0, 72) #hide
    end #hide
    Legend( #hide
        fig[2, 1:2], [PolyElement(color = c) for c in colors], labels; #hide
        orientation = :horizontal, tellwidth = false, #hide
    ) #hide
    Label(fig[3, 1:2], "Grey outlines: usable offered capability. Coloured bars: enabled capability."; fontsize = 13) #hide
    fig #hide
end #hide

# *Illustrative allocations for one service. These are constructed examples, not historical
# dispatch outcomes; energy dispatch and provider capability are held fixed.*
#
# In a full dispatch problem, NEMDE can also change energy targets to make FCAS provision
# feasible or cheaper. That is why a merit-order calculation alone cannot reproduce the
# enablement: the offers, regional requirements and unit capability constraints must be solved
# together. AEMO describes this joint choice in [FCAS Model in NEMDE, §1.1, p. 4](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# ### Interpreting published requirements
#
# Published FCAS requirement mappings identify the constraints governing each regional service.
# A service can have several governing equations, and an equation can govern several regions.
# The solved left-hand side, right-hand side and marginal value describe the dispatch outcome;
# they do not prescribe the energy targets or FCAS enablements for another optimisation.
#
# !!! note "A requirement needs its complete equation"
#     A missing constraint definition prevents a reliable interpretation of the requirement.
#     A negative right-hand side alone neither proves a deficit nor shows that a requirement
#     is inactive. Read the coefficients, constraint sense and invocation status together.

# ## [Mapping the formulation inputs to MMSDM](@id fcas-types-mapping)
#
# An FCAS dispatch analysis needs offers, operating limits and the complete generic equations
# that procure each service. Column definitions and record keys are documented in AEMO's
# [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS%20Data%20Model%20Report_toc.htm).
#
# ### Submitted offers and participant identity
#
# | Quantity | MMSDM source | Meaning |
# | --- | --- | --- |
# | Band prices ``c_{u,k,b}`` | `BIDDAYOFFER_D.PRICEBAND1` to `PRICEBAND10`, for the service's `BIDTYPE` | Price offered for each band, in \$/MWh |
# | Band MW ``q_{u,k,b}`` | `BIDPEROFFER_D.BANDAVAIL1` to `BANDAVAIL10`, for the same `BIDTYPE` | Response capability offered in each band |
# | ``E_{\min},L,H,E_{\max},F`` | `BIDPEROFFER_D.ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ENABLEMENTMAX`, `MAXAVAIL` | The five technical limits of the capability trapezium |
# | Bid side | Bid-table `DIRECTION`: `GEN`, `LOAD`, `BIDIRECTIONAL` | Distinguishes generation-side, load-side and whole-unit offers |
# | Provider and location | `DUDETAILSUMMARY.DUID`, `CONNECTIONPOINTID`, `REGIONID`, `START_DATE`, `END_DATE` | Unit identity and location for the applicable date |
# | Scheduling classification | `DUDETAILSUMMARY.SCHEDULE_TYPE` | Identifies semi-scheduled units, whose FCAS capability is also limited by UIGF |
#
# Match the daily prices and interval quantities by service, market day, unit and direction.
# Retaining `DIRECTION` preserves both regulation offers from a bidirectional unit.
# Bid `SETTLEMENTDATE` identifies the market day; `INTERVAL_DATETIME` identifies the dispatch
# interval. Dispatch-table `SETTLEMENTDATE` identifies the interval instead. NEM timestamps
# use fixed AEST, and a dispatch timestamp denotes the interval end.
#
# !!! note "Offers applied in dispatch"
#     The public `_D` bid tables describe the offers applied in dispatch. They do not provide
#     a complete submission history for every rebid. Daily bid dates must be matched to the
#     market day, rather than joined directly to dispatch timestamps.
#
# ### Operating limits, scaling and eligibility
#
# | Quantity | MMSDM source | Meaning |
# | --- | --- | --- |
# | Initial operating point ``e_0`` | `DISPATCHLOAD.INITIALMW` | Metered MW at the start of the interval |
# | Energy availability | `DISPATCHLOAD.AVAILABILITY` | Bid maximum availability for scheduled units; the lower of bid availability and UIGF for semi-scheduled units |
# | Bidirectional energy availability | `BIDPEROFFER_D.MAXAVAIL` for `BIDTYPE = ENERGY`, separately for `GEN` and `LOAD` | Reachable generation and consumption limits |
# | Raise-regulation energy limits | `DISPATCHLOAD.RAISEREGENABLEMENTMIN`, `RAISEREGENABLEMENTMAX` | More restrictive of bid and telemetered enablement limits |
# | Lower-regulation energy limits | `DISPATCHLOAD.LOWERREGENABLEMENTMIN`, `LOWERREGENABLEMENTMAX` | Corresponding lower-regulation enablement limits |
# | Ramp rates | `DISPATCHLOAD.RAMPUPRATE`, `RAMPDOWNRATE` | Rates used in dispatch, taking the lesser of bid and telemetered rates |
# | AGC status | `DISPATCHLOAD.AGCSTATUS` | 1 means on AGC; 0 means off AGC |
# | Weather ceiling | `DISPATCHLOAD.UIGF` | Unconstrained intermittent generation forecast supplied to NEMDE for a semi-scheduled unit |
#
# `BIDPEROFFER_D.ROCUP` and `ROCDOWN` describe energy-bid ramp rates. They are not independent
# AGC telemetry. Rates and interval durations must use matching units: MW/min multiplied
# by minutes, or MW/h multiplied by hours, yields MW of ramp capability.
#
# !!! note "Published limits and missing telemetry"
#     Published dispatch limits combine bid and telemetered values. Using those limits to
#     reconstruct FCAS capability does not recover independent raw AGC rates. An absent
#     observation is unknown, whereas a genuine zero UIGF is a binding weather ceiling.
#     During intervention, compare physical dispatch and pricing-run records with their
#     corresponding outputs.
#
# ### Procurement equations
#
# | Part of equation ``g`` | MMSDM source | Meaning |
# | --- | --- | --- |
# | Invoked equation and definition version | `DISPATCHCONSTRAINT.CONSTRAINTID`, `GENCONID_EFFECTIVEDATE`, `GENCONID_VERSIONNO` | Identifies the exact equation used in the interval |
# | Bound ``\mathrm{RHS}_g`` | `DISPATCHCONSTRAINT.RHS` | Published interval right-hand side |
# | Sense and violation weighting | `GENCONDATA.CONSTRAINTTYPE`, `GENERICCONSTRAINTWEIGHT` | Inequality or equality sense and relative violation penalty |
# | Unit energy/FCAS coefficients | `SPDCONNECTIONPOINTCONSTRAINT.CONNECTIONPOINTID`, `BIDTYPE`, `FACTOR` | Contribution of energy or FCAS at a connection point |
# | Regional coefficients | `SPDREGIONCONSTRAINT.REGIONID`, `BIDTYPE`, `FACTOR` | Contribution of regional energy or a regional service |
# | Interconnector coefficients | `SPDINTERCONNECTORCONSTRAINT.INTERCONNECTORID`, `FACTOR` | Contribution of signed interconnector flow |
# | Regional service mapping | `DISPATCH_FCAS_REQ` or `DISPATCH_FCAS_REQ_CONSTRAINT` | Identifies which region and service a requirement equation governs |
#
# Match the definition and coefficient records to the invoked
# `(GENCONID, EFFECTIVEDATE, VERSIONNO)` triple. Change-only definition tables may require
# records from months preceding the dispatch interval. A regional service mapping alone
# supplies neither coefficients nor constraint sense.
#
# !!! note "Requirement mapping and run identity"
#     Historical archives use `DISPATCH_FCAS_REQ`; newer archives use
#     `DISPATCH_FCAS_REQ_CONSTRAINT`. The latter uses `CONSTRAINTID` and `INTERVAL_DATETIME`,
#     and can contain several processor runs. It has no `INTERVENTION` or definition-version
#     fields. Obtain the invoked definition version from `DISPATCHCONSTRAINT`, and check
#     run identity before comparing requirement mappings and solved outcomes.
#
# ### Published outcomes used for comparison
#
# | Outcome | MMSDM source | Meaning |
# | --- | --- | --- |
# | Unit FCAS targets | `DISPATCHLOAD.<SERVICE>`, such as `RAISE6SEC` or `RAISEREG` | MW enabled for the service |
# | Actual service availability | `DISPATCHLOAD.<SERVICE>ACTUALAVAILABILITY`, where present | Capability at the dispatched operating point after allowing for other enabled services |
# | Unit energy target | `DISPATCHLOAD.TOTALCLEARED` | Dispatched energy operating point |
# | Solved equation and marginal value | `DISPATCHCONSTRAINT.LHS`, `MARGINALVALUE` | Achieved left-hand side and the value associated with relaxing the constraint |
# | Regional service prices | `DISPATCHPRICE.<SERVICE>RRP`, `<SERVICE>ROP`, `<SERVICE>APCFLAG` | Regional price, original price and administered price cap flag |
#
# Targets, actual availability and prices are dispatch outputs. Actual availability and
# regulation `RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY` must not replace submitted bid
# `MAXAVAIL`: they describe different stages of the capability calculation.
#
# ## [Guide to AEMO's participant cases](@id fcas-cases)
#
# The FCAS Model in NEMDE distinguishes participant coordinates, the energy operating point,
# scaling, eligibility, joint constraints and post-dispatch availability. The sections below
# explain these stages for generators, scheduled loads and bidirectional units.
#
# ## [Offers and capability trapezia](@id fcas-trapezium)
#
# ### Price bands and enabled capacity
#
# Each unit offers a separate ten-band price-quantity curve for each service. Let
# ``q_{u,k,b}`` be its offered MW in band ``b``, ``c_{u,k,b}`` the price in \$/MWh, and
# ``z_{u,k,b}`` the MW selected from that band. The band formulation is
#
# ```math
# 0\le z_{u,k,b}\le q_{u,k,b},\qquad
# f_{u,k}=\sum_b z_{u,k,b},\qquad
# C_{\mathrm{FCAS}}=\Delta h\sum_{u,k,b}c_{u,k,b}z_{u,k,b}.
# ```
#
# Here ``\Delta h`` is the interval duration in hours, so five minutes gives ``1/12``.
# This is the FCAS contribution to the dispatch objective; energy offers and violation
# penalties contribute their own terms. The charge is for enabled response capability over
# the interval, even if no frequency event occurs. The offer structure and joint least-cost
# choice are described in [FCAS Model in NEMDE, §§1.1-2, pp. 4-6](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# The offered band total and the technical maximum are separate limits. Available band
# quantities do not guarantee that the unit can deliver their sum at its energy target.
#
# ### The five technical limits
#
# For one eligible unit and service, write the trapezium parameters as follows. All five
# are MW; the horizontal coordinate ``e`` is the unit's energy operating point.
#
# | Symbol | Bid field | Meaning |
# | --- | --- | --- |
# | ``E_{\min}`` | `ENABLEMENTMIN` | Left edge of the energy range |
# | ``L`` | `LOWBREAKPOINT` | Start of full offered capability |
# | ``H`` | `HIGHBREAKPOINT` | End of full offered capability |
# | ``E_{\max}`` | `ENABLEMENTMAX` | Right edge of the energy range |
# | ``F`` | `MAXAVAIL` | Maximum service capability |
#
# The submitted shape satisfies ``E_{\min}\le L\le H\le E_{\max}`` and ``F\ge0``.
# For ``F>0``, define energy-per-FCAS coefficients
#
# ```math
# \alpha^- = \frac{L-E_{\min}}{F},\qquad
# \alpha^+ = \frac{E_{\max}-H}{F}.
# ```
#
# The standalone capability envelope is expressed by linear inequalities:
#
# ```math
# 0\le f\le F,\qquad
# e-\alpha^-f\ge E_{\min},\qquad
# e+\alpha^+f\le E_{\max}.
# ```
#
# These coefficients measure horizontal movement per MW of FCAS, the reciprocal of the
# sloping edge's rise-over-run. A zero coefficient represents a vertical edge and needs no
# division by an energy-axis width. A zero-availability offer cannot be enabled. See [FCAS Model in NEMDE, §§2-3, pp. 6-13](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

function fcas_review_envelope(e, emin, emax, fmax, lower, upper) #hide
    left = iszero(lower) ? (e >= emin ? Inf : 0.0) : (e - emin) / lower #hide
    right = iszero(upper) ? (e <= emax ? Inf : 0.0) : (emax - e) / upper #hide
    return max(0.0, min(fmax, left, right)) #hide
end #hide
#hide
let #hide
    xs = range(0, 320; length = 641) #hide
    ys = fcas_review_envelope.(xs, 40.0, 280.0, 40.0, 1.5, 2.0) #hide
    fig = Figure(size = (850, 360)) #hide
    ax = Axis(fig[1, 1]; xlabel = "Energy operating point (MW)", ylabel = "FCAS capability (MW)", title = "Illustrative offered trapezium") #hide
    band!(ax, xs, zero.(xs), ys; color = (:steelblue, 0.18)) #hide
    lines!(ax, xs, ys; color = :steelblue, linewidth = 3) #hide
    scatter!(ax, [40, 100, 200, 280], [0, 40, 40, 0]; color = :steelblue, markersize = 9) #hide
    ax.xticks = ([40, 100, 200, 280], ["Emin = 40", "L = 100", "H = 200", "Emax = 280"]) #hide
    ax.yticks = ([0, 20, 40], ["0", "20", "F = 40"]) #hide
    for (e, f) in ((70, 20), (150, 40), (240, 20)) #hide
        vlines!(ax, [e]; color = (:black, 0.25), linestyle = :dash) #hide
        scatter!(ax, [e], [f]; color = :darkorange, markersize = 11) #hide
    end #hide
    ylims!(ax, 0, 48) #hide
    fig #hide
end #hide

# *Constructed example: the envelope allows 20 MW at an energy target of 70 MW,
# 40 MW at 150 MW, and 20 MW at 240 MW, before any joint constraints are applied.*
#
# ### [Participant coordinates](@id fcas-cases-participants)
#
# A generator's coordinate is positive generation. A scheduled load's coordinate is
# positive consumption, even though its contribution to regional net injection is negative.
# Consequently, increasing consumption provides lower response, and reducing consumption
# provides raise response. A battery's contingency coordinate is signed net injection.
# These conventions follow [FCAS Model in NEMDE, §§2.1-2.4, pp. 7-10](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
# The energy coordinate must be interpreted consistently in every capability equation.
#
# ### [Applying the envelope at the energy target](@id fcas-cases-application)
#
# The trapezium limits capability at the selected energy target. On its plateau, up to
# ``F`` MW is available; on either slope, available capability falls towards zero.
# Joint capacity constraints also account for regulation delivered at the same time.
# AEMO describes a unit subject to these energy-envelope limits as trapped within its
# FCAS trapezium. Eligibility at the initial operating point is a separate condition:
# a unit initially outside its range can be stranded and unavailable for that service.
# See [FCAS Model in NEMDE, §§3, 5-6, pp. 12-13, 18-28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# ## Scaling and eligibility before optimisation
#
# ### [From the submitted bid to the effective envelope](@id fcas-cases-scaling)
#
# The submitted trapezium may exceed the capability available this interval. AEMO scales it
# before optimisation, preserving the coefficients ``\alpha^-`` and ``\alpha^+``.
# Denote effective parameters with a prime. When the corresponding inputs apply,
#
# ```math
# \begin{aligned}
# E'_{\min}&=\max(E_{\min},E^{\mathrm{AGC}}_{\min}),\\
# E'_{\max}&=\min(E_{\max},E^{\mathrm{AGC}}_{\max},\mathrm{UIGF}),\\
# F'&=\min(F,R^{\mathrm{AGC}}_k T),\\
# L'&=E'_{\min}+\alpha^-F',\qquad
# H'=E'_{\max}-\alpha^+F'.
# \end{aligned}
# ```
#
# ``T`` is minutes when the telemetered ramp rate is MW/min. Omit a bound when it does not
# apply: AGC limits and ramp scaling apply to regulation; UIGF applies to all FCAS from
# semi-scheduled units. A zero or absent AGC limit/rate causes no scaling on that input.
# A zero UIGF remains a binding weather ceiling. Scheduled units' contingency trapezia
# are not automatically rescaled to their energy availability. These rules come from
# [FCAS Model in NEMDE, §4, pp. 14-17](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

let #hide
    xs = range(0, 320; length = 641) #hide
    bid = fcas_review_envelope.(xs, 40.0, 280.0, 40.0, 1.5, 2.0) #hide
    cases = [ #hide
        ("AGC energy limits: 70 to 250 MW", 70.0, 250.0, 40.0), #hide
        ("AGC ramp capability: 25 MW", 40.0, 280.0, 25.0), #hide
        ("Semi-scheduled UIGF: 230 MW", 40.0, 230.0, 40.0), #hide
    ] #hide
    fig = Figure(size = (1100, 350)) #hide
    for (i, (title, emin, emax, fmax)) in enumerate(cases) #hide
        ax = Axis(fig[1, i]; title, titlesize = 14, xlabel = "Energy (MW)", ylabel = i == 1 ? "FCAS capability (MW)" : "") #hide
        effective = fcas_review_envelope.(xs, emin, emax, fmax, 1.5, 2.0) #hide
        lines!(ax, xs, bid; color = :gray, linestyle = :dash, linewidth = 2, label = "Submitted") #hide
        band!(ax, xs, zero.(xs), effective; color = (:steelblue, 0.18)) #hide
        lines!(ax, xs, effective; color = :steelblue, linewidth = 3, label = "Effective") #hide
        ylims!(ax, 0, 48) #hide
        i == 1 && axislegend(ax; position = :rt, labelsize = 12) #hide
    end #hide
    fig #hide
end #hide

# *Each panel applies one scaling input to the preceding constructed bid. Scaling can also
# act in combination. The sloped edges retain their energy-per-FCAS coefficients.*
#
# If ``L'>H'``, the two slopes intersect below ``F'``; the linear inequalities then
# describe a reduced peak rather than a full-height plateau. If
# ``E'_{\max}<E'_{\min}``, there is no feasible enablement range.
#
# ### [Eligibility is an input check](@id fcas-cases-preconditions)
#
# Eligibility determines whether the optimiser may select a service. It does not imply
# a positive enablement. AEMO specifies the following conditions after scaling in
# [FCAS Model in NEMDE, §5, pp. 18-19](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# | Check | Ordinary generator or scheduled load | Battery exception |
# | --- | --- | --- |
# | Positive offer | ``F'>0`` and a positive-quantity price band | Each regulation side checked separately |
# | Nonempty range and sign | ``E'_{\min}\le E'_{\max}``, ``E'_{\max}\ge0`` | Load-side regulation requires ``E'_{\min}\le0``; contingency has no sign restriction |
# | Reachable energy range | Energy availability reaches ``E'_{\min}`` | Generation availability reaches the left edge; negative load availability reaches the right edge, as applicable |
# | Initial operating point | ``E'_{\min}\le\max(\mathrm{INITIALMW},0)\le E'_{\max}`` | Signed initial MW; combined load-to-generation range when both regulation sides qualify |
# | AGC status for regulation | Must be on AGC in dispatch and the first pre-dispatch interval | Same rule |
#
# For semi-scheduled generation, energy reachability also uses the UIGF ceiling. `INITIALMW`
# is the metered initial operating point, rather than the preceding dispatch target.
#
# !!! note "Pre-dispatch energy eligibility"
#     AEMO also specifies daily energy and profiled storage eligibility conditions for
#     30-minute pre-dispatch. Those conditions are not covered by this reconstruction;
#     interval capability alone cannot establish energy feasibility over that horizon.
#
# Telemetry treatment depends on the dispatch process. AEMO specifies the timing in
# [FCAS Model in NEMDE, §4.4 and §6.5, pp. 17, 28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf):
#
# | Scaling or constraint | Dispatch | 5-minute pre-dispatch | 30-minute pre-dispatch |
# | --- | --- | --- | --- |
# | AGC enablement-limit scaling | Every interval | First interval | First interval |
# | AGC ramp-rate scaling | Every interval | First interval | None |
# | Joint ramping and BDU SCADA ramping | Every interval | First interval | None |
# | UIGF scaling and capacity constraints | Every interval | Every interval | Every interval |
#
# AEMO also excludes joint ramping for fast-start units initially in modes 0, 1 or 2 in
# the commitment and final dispatch passes. See [Fast-start dispatch](@ref nemde-fast-start).
#
# !!! note "Fast-start coverage"
#     The initial-mode exception to joint ramping for fast-start units is not covered by
#     this reconstruction. Results for those units can differ from AEMO's commitment and
#     final dispatch passes. See [Fast-start dispatch](@ref nemde-fast-start).
#
# ## [Joint energy and FCAS constraints](@id fcas-cooptimisation)
#
# ### [Capacity and ramping together](@id fcas-cases-joint)
#
# The envelope for one service is insufficient when a unit supplies several services.
# The following equations describe capability without constraint violations. A relaxation
# penalises departure from a limit; it does not represent additional physical capability.
#
# ### Contingency and regulation share energy headroom
#
# Let ``r^+`` and ``r^-`` denote the unit's total raise- and lower-regulation enablements.
# For each contingency service ``k`` on a generator or battery, joint capacity requires
#
# ```math
# e+\alpha_k^+f_k+r^+\le E_{\max,k},\qquad
# e-\alpha_k^-f_k-r^-\ge E_{\min,k}.
# ```
#
# All parameters here are effective values. Regulation shifts the appropriate sloped edge
# inward by its enabled MW, leaving less headroom for contingency. For a scheduled load,
# whose ``e`` is consumption, swap the regulation terms: ``r^-`` enters the upper row and
# ``r^+`` the lower. The formulation is given in
# [FCAS Model in NEMDE, §6.2, pp. 22-26](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# Each contingency product has its own pair of rows. The formulation does not replace
# ``f_k`` with the sum of every contingency enablement: those products have different
# delivery timeframes. Generic requirements may combine products, but that is a separate
# equation from the unit's capability envelope.

let #hide
    xs = range(0, 320; length = 641) #hide
    fig = Figure(size = (950, 360)) #hide
    for (i, title, emin, emax) in ( #hide
            (1, "20 MW raise regulation", 40.0, 260.0), #hide
            (2, "20 MW lower regulation", 60.0, 280.0), #hide
        ) #hide
        ax = Axis(fig[1, i]; title, xlabel = "Generation target (MW)", ylabel = i == 1 ? "Contingency capability (MW)" : "") #hide
        original = fcas_review_envelope.(xs, 40.0, 280.0, 40.0, 1.5, 2.0) #hide
        joint = fcas_review_envelope.(xs, emin, emax, 40.0, 1.5, 2.0) #hide
        lines!(ax, xs, original; color = :gray, linestyle = :dash, linewidth = 2, label = "Without regulation") #hide
        band!(ax, xs, zero.(xs), joint; color = (:steelblue, 0.18)) #hide
        lines!(ax, xs, joint; color = :steelblue, linewidth = 3, label = "With regulation") #hide
        ylims!(ax, 0, 48) #hide
        i == 1 && axislegend(ax; position = :rt, labelsize = 12) #hide
    end #hide
    fig #hide
end #hide

# *For the constructed generator, 20 MW of raise regulation shifts the contingency upper
# edge left by 20 MW; lower regulation shifts its lower edge right by 20 MW.*
#
# ### Regulation's own capacity and joint ramping
#
# Each regulation service also retains its own trapezium inequalities,
# ``e+\alpha^+r\le E_{\max}`` and ``e-\alpha^-r\ge E_{\min}``, with ``0\le r\le F``.
# These are the energy-and-regulation capacity rows in
# [FCAS Model in NEMDE, §6.3, pp. 26-27](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# Separately, a generator or battery must have sufficient AGC ramp capability to move from
# its initial operating point ``e_0`` to the energy target and deliver regulation:
#
# ```math
# e+r^+\le e_0+R^{\uparrow}_{\mathrm{AGC}}T,\qquad
# e-r^-\ge e_0-R^{\downarrow}_{\mathrm{AGC}}T.
# ```
#
# For a scheduled load these become ``e+r^-\le e_0+R^{\uparrow}_{\mathrm{AGC}}T`` and
# ``e-r^+\ge e_0-R^{\downarrow}_{\mathrm{AGC}}T``. The rates refer to increasing and
# decreasing consumption, respectively. See
# [FCAS Model in NEMDE, §6.1, pp. 21-22](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# For example, with ``e_0=150`` MW and 30 MW of upward ramp capability, a generator target
# of 170 MW leaves only 10 MW for raise regulation, even if its scaled trapezium allows more.
# Scaling caps regulation alone; joint ramping accounts for energy moving in the same interval.
# Joint ramping applies when the unit is eligible, the relevant rate is nonzero and known,
# and the process timing requires it. An absent initial MW prevents reconstruction of this limit.
#
# ### Batteries: side-specific regulation, unit-level delivery
#
# Write generation and consumption as nonnegative ``p^{\mathrm{out}}`` and
# ``p^{\mathrm{in}}``, with signed net injection ``e=p^{\mathrm{out}}-p^{\mathrm{in}}``.
# Contingency uses this net coordinate and a whole-unit bid. Regulation may have independent
# generation-side and load-side bids, with their own prices, band quantities and trapezia.
# Their capacity rows use ``p^{\mathrm{out}}`` and ``-p^{\mathrm{in}}`` respectively.
# AEMO describes these bids in [FCAS Model in NEMDE, §2.4, pp. 8-10](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# The unit total for each regulation service is the sum of its side-specific enablements:
#
# ```math
# r^+=r^+_{\mathrm{gen}}+r^+_{\mathrm{load}},\qquad
# r^-=r^-_{\mathrm{gen}}+r^-_{\mathrm{load}}.
# ```
#
# These totals enter regional requirements, contingency joint capacity and the net-energy
# joint-ramping rows. When both regulation sides are present, an additional shared SCADA
# limit prevents double-counting the rate used to scale each side:
#
# ```math
# r^+_{\mathrm{gen}}+r^+_{\mathrm{load}}\le R^{\uparrow}_{\mathrm{AGC}}T,\qquad
# r^-_{\mathrm{gen}}+r^-_{\mathrm{load}}\le R^{\downarrow}_{\mathrm{AGC}}T.
# ```
#
# See [FCAS Model in NEMDE, §6.4, p. 27](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
# The combined range used for initial-point eligibility does not merge the two priced
# regulation offers into one optimisation curve.
#
# These rows describe feasible enablements. AEMO's published actual FCAS availability is a
# post-dispatch calculation at the selected energy target, accounting for the other enabled
# services. It is distinct from bid `MAXAVAIL` and the selected FCAS target; see
# [FCAS Model in NEMDE, §7, pp. 29-33](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

# ## [Availability at the dispatched operating point](@id fcas-cases-availability)
#
# Four quantities describe different stages of an FCAS offer: submitted `MAXAVAIL`, effective
# ``F'`` after scaling, selected target ``f_k``, and actual capability at the solved energy
# point while delivering other enabled services. A unit can have unused capability, or its
# capability can be below its submitted maximum. Neither difference alone identifies an error.
# For a generator's contingency service, holding all other targets fixed, hard-row capability is
#
# ```math
# A_k(e,r^+,r^-)=\max\left(0,\min\left\{
# F_k,\frac{e-E_{\min,k}-r^-}{\alpha_k^-},
# \frac{E_{\max,k}-e-r^+}{\alpha_k^+}\right\}\right).
# ```
#
# A zero slope coefficient contributes no quotient: its energy-side inequality must still
# hold. An ineligible service has zero availability. For raise regulation, also take the
# minimum with residual upward joint-ramp capability and the upper headroom of each
# applicable contingency row; lower regulation uses the corresponding lower headroom.
# For example, a contingency row supplies ``r^+\le E_{\max,k}-e-\alpha_k^+f_k``.
# Scheduled-load directions swap as above. This follows
# [FCAS Model in NEMDE, §7.1, pp. 29-32](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# !!! note "Actual availability and feasible enablement"
#     These equations explain the capability limits; they do not reproduce AEMO's complete
#     post-dispatch availability calculation for every participant and service. Use the
#     published availability where available, and check constraint violations before
#     interpreting a target above the unviolated capability envelope.

let #hide
    fig = Figure(size = (850, 300)) #hide
    ax = Axis(fig[1, 1]; ylabel = "MW", title = "Stages of one illustrative FCAS offer", xticks = (1:4, ["Bid maximum", "Scaled maximum", "Capability at target", "Enabled target"])) #hide
    barplot!(ax, 1:4, [40, 30, 20, 12]; color = Makie.wong_colors()[1:4]) #hide
    for (i, mw) in enumerate([40, 30, 20, 12]) #hide
        text!(ax, i, mw + 1; text = "$mw MW", align = (:center, :bottom)) #hide
    end #hide
    ylims!(ax, 0, 47) #hide
    fig #hide
end #hide

# *Constructed quantities, not a historical result. Procurement can select less than the
# unit's available capability.*
#
# ## [Prices and binding requirements](@id fcas-pricing)
#
# A regional FCAS price reflects the marginal cost of meeting its service requirements.
# Several local and shared equations can contribute to that price. An extra MW of local
# requirement can require a different, more expensive allocation even when the shared
# requirement is already satisfied. The constraint's marginal value measures that change
# in the least-cost dispatch outcome; a unit capability constraint's marginal value is
# not itself the regional service price.
# AEMO describes FCAS requirement equations in the
# [Constraint Formulation Guidelines, §5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf).
#
# In the three-provider example the shared requirement's marginal MW costs \$5/MWh. With the
# local row binding, replacing one MW of B with C costs another \$4/MWh. The local price has
# shared and local contributions, \$5 + \$4 = \$9/MWh, while outside providers face the shared
# contribution. This example holds energy and all other limits fixed.
#
# Penalty slack can set a requirement's marginal value when capability is insufficient. A high
# shadow price then describes the cost of relaxing a row, rather than a provider's offered price.
# Published requirement marginal values may already reflect regional attribution; check that
# mapping before substituting raw `DISPATCHCONSTRAINT.MARGINALVALUE` for each contribution.
# `DISPATCHPRICE.<SERVICE>ROP` reports the original regional price; `<SERVICE>RRP` includes
# applicable price adjustments. See [Violations, tie-breaking and prices](@ref nemde-prices).
#
# !!! note "Price comparison"
#     This reconstruction does not reproduce administered price adjustments. Compare its
#     unadjusted prices with original prices, and match the dispatch interval, service,
#     region and intervention run before attributing any difference to capability limits.
#
# ## [Worked interval: Tasmania, 13 January 2025](@id fcas-requirement-reading)
#
# The following queries examine 16:30 AEST on 13 January 2025 using a cache containing
# the bid, dispatch and historical constraint-definition tables listed above.
#
# ```julia
# using AustralianElectricityMarkets, Dates, DataFrames
# db = aem_connect()
# interval = DateTime(2025, 1, 13, 16, 30)
# window = interval:Minute(5):(interval + Minute(5))
# bids = read_fcas_bids(db, window, BidType.LOWER6SEC)
# unit_bid = subset(bids, :DUID => ByRow(==("TUNGATIN")))
# outcomes = read_fcas_dispatch(db, window; intervention = 0)
# unit_outcomes = subset(outcomes, :DUID => ByRow(==("TUNGATIN")))
# requirements = read_fcas_requirements(db, window; intervention = 0)
# tas_requirements = subset(requirements, :REGIONID => ByRow(==("TAS1")))
# prices = read_fcas_prices(db, window; intervention = 0)
# ```
#
# For a lower-side capability calculation, consider an offer with ``E_{\min}=1``,
# ``L=5`` and ``F=4`` MW, at an energy target of 2 MW with no lower regulation. Its lower-side limit is
# ``2-((5-1)/4)f_{\mathrm{LOWER6SEC}}\ge1``, giving 1 MW capability. Verify all five bid
# parameters and other enabled services before treating this as the full availability.
# With 9 MW of raise regulation, the following upper-side examples illustrate reduced
# contingency headroom:
#
# | Service | Submitted upper coefficient | Upper-row capability at 2 MW energy and 9 MW raise regulation |
# | --- | --- | --- |
# | `RAISE6SEC` | ``(27-11)/9`` | 9 MW after applying the offered maximum |
# | `RAISE60SEC` | ``(27-6)/21`` | 16 MW |
# | `RAISE5MIN` | ``(26-2)/26`` | 16.25 MW |
#
# !!! note "Illustrative arithmetic"
#     These calculations illustrate the equations and are not verified outcomes from the
#     queries above. Check the interval's complete offer, effective limits and other enabled
#     services before comparing them with published availability.
#
# Requirement variants such as `F_T+NIL_MG_R6` and `F_T++NIL_MG_R6` must be interpreted
# from their exact invoked definitions. For a row with RHS 137.5 MW and LHS 129.65 MW,
# the shortfall is 7.85 MW **if the sense is `>=`**. A very negative RHS can make an invoked
# variant nonbinding; it need not represent negative physical demand. Invocation and
# economic binding are different.
#
# ```julia
# invoked = read_invoked_constraints(db, window; intervention = 0)
# definitions = read_constraint_definitions(db, invoked)
# terms = read_constraint_terms(db, invoked, window)
# # Inspect the exact version, sense and terms of each requirement variant.
# providers = subset(outcomes, :BIDTYPE => ByRow(==(BidType.RAISE6SEC)))
# providers = subset(providers, :TARGET => ByRow(>(0)))
# # Join read_units(db) on DUID to select TAS1 providers.
# ```
#
# Compare attributed marginal values returned for the same interval, region and service by
# `read_fcas_requirements` with the corresponding `ROP` in `read_fcas_prices`. Neither price
# becomes an optimisation input. Published targets show what was enabled; offers alone do not.
#
# ## [Scope and references](@id fcas-references)
#
# The equations above cover ten service offers, capability trapezia, contingency/regulation
# coupling, joint ramping and side-specific bidirectional regulation. Complete requirement
# equations are needed to represent shared and local procurement together.
#
# !!! note "Reconstruction coverage"
#     FCAS cost recovery, live-SCADA reconstruction of requirement right-hand sides, complete
#     post-dispatch availability and daily/profiled pre-dispatch energy eligibility are outside
#     this formulation. Published operating limits supply the interval inputs. Generator and
#     storage scaling/status inputs are available through the standard data workflow;
#     scheduled-load scaling/status inputs require separate provision.
#
# Official sources are [FCAS Model in NEMDE v3.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf),
# [Guide to Frequency Control Ancillary Services v4.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf)
# and the [Market Ancillary Service Specification](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/ancillary-services/market-ancillary-service-specification-and-fcas-verification-tool).
