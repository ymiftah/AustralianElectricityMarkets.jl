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
# ### How this appears in AEM and AEMSim
#
# AEMSim models all ten services. An `FCASService` groups the providers for one region and
# service; `FCASMarket` constructs their enabled-capacity variables, offer costs and capability
# rows. The procurement requirements are separate `GenericConstraint`s under `LinearFactorLimit`.
# A service is therefore not itself a single regional requirement row.
#
# `read_fcas_requirements` returns the published requirement mapping with one row per governing
# constraint, region, service and interval. It joins `DISPATCHCONSTRAINT` for the solved left-hand
# side and right-hand side. Those values are useful for interpreting an outcome. In replay,
# `add_nem_constraints!` supplies the published right-hand side and resolved coefficients;
# AEMSim builds a new left-hand side from its own decision variables. Published enabled targets,
# solved left-hand sides and prices are comparison outputs, not prescribed dispatch decisions.
#
# A missing definition in the local cache does not justify assuming a constraint sense or
# reconstructing coefficients from its name. In particular, a negative right-hand side alone
# neither proves a deficit nor proves that a requirement is inactive. Interpretation requires
# the equation's terms, sense and invocation status.

# ## [Mapping the formulation inputs to MMSDM](@id fcas-types-mapping)
#
# An FCAS replay needs the submitted offers, the published operating limits, and the complete
# generic constraints that procure the service. The following maps describe the data used by
# AEM and AEMSim. Column definitions are documented in AEMO's
# [MMS Data Model Report](https://visualisations.aemo.com.au/aemo/nemweb/MMSDataModelReport/Electricity/MMS%20Data%20Model%20Report_files/MMS%20Data%20Model%20Report_toc.htm);
# the tables below identify the particular columns used by this implementation.
#
# ### Submitted offers and participant identity
#
# | Model input | MMSDM source | Package representation |
# | --- | --- | --- |
# | Band prices ``c_{u,k,b}`` | `BIDDAYOFFER_D.PRICEBAND1` to `PRICEBAND10`, filtered by FCAS `BIDTYPE` | Offer curve returned by `read_fcas_bids`; attached by `set_fcas_bids!` |
# | Band MW ``q_{u,k,b}`` | `BIDPEROFFER_D.BANDAVAIL1` to `BANDAVAIL10`, same `BIDTYPE` | Cumulative MW coordinates of `fcas_curve_<SERVICE>` |
# | ``E_{\min},L,H,E_{\max},F`` | `BIDPEROFFER_D.ENABLEMENTMIN`, `LOWBREAKPOINT`, `HIGHBREAKPOINT`, `ENABLEMENTMAX`, `MAXAVAIL` | `FCASTrapezium`, stored in `fcas_trapezium_<SERVICE>` |
# | Bid side | `DIRECTION` in both bid tables: `GEN`, `LOAD`, `BIDIRECTIONAL` | `LOAD` uses the `_decremental` series suffix; `GEN` and whole-unit `BIDIRECTIONAL` use the plain name |
# | Unit, connection point and region | `DUDETAILSUMMARY.DUID`, `CONNECTIONPOINTID`, `REGIONID`, with applicable `START_DATE`/`END_DATE` | Device identity, region membership and connection-point term resolution |
# | Scheduled/semi-scheduled classification | `DUDETAILSUMMARY.SCHEDULE_TYPE` | Determines whether `read_uigf` returns a weather ceiling for the unit |
#
# `read_fcas_bids` selects one service at a time. Within that service it resolves the highest
# `VERSIONNO` per daily `(SETTLEMENTDATE, DUID, DIRECTION)` price row and per interval
# `(SETTLEMENTDATE, INTERVAL_DATETIME, DUID, DIRECTION)` quantity/trapezium row. It joins the
# daily and interval offers on market date, unit and direction. Retaining `DIRECTION` is
# necessary to preserve both battery regulation offers.
#
# Bid `SETTLEMENTDATE` identifies the market day; `INTERVAL_DATETIME` identifies the dispatch
# interval. Dispatch-table `SETTLEMENTDATE` identifies the interval instead. NEM timestamps
# use fixed AEST, and a dispatch timestamp denotes the interval end. Do not join a daily bid
# date directly to the dispatch timestamp. The public `_D` bid tables describe offers applied
# in dispatch; this path does not reconstruct every submitted rebid from the private bid tables.
#
# `BIDPEROFFER_D.ROCUP`/`ROCDOWN` are energy-bid ramp fields in AEMO's schema. Although the
# FCAS parser retains them when present, `FCASMarket` obtains its AGC ramp capability from the
# dispatch-limit series below. They must not be substituted for AGC telemetry.
#
# ### Operating limits, scaling and eligibility
#
# | Model input | MMSDM source | Reader and attached series |
# | --- | --- | --- |
# | Initial energy ``e_0`` | `DISPATCHLOAD.INITIALMW` | `read_dispatch_limits` → `set_nem_dispatch_limits!` → `initial_mw` |
# | Non-battery energy reachability | `DISPATCHLOAD.AVAILABILITY` | Same path → `availability`; for semi-scheduled units this is already the lower of energy bid availability and UIGF |
# | Battery generation/load reachability | `BIDPEROFFER_D.MAXAVAIL` for `BIDTYPE = ENERGY`, separately for `GEN` and `LOAD` | `set_market_bids!` → `energy_max_avail` and `energy_max_avail_decremental`; static ratings are the fallback if those series are unavailable |
# | Raise-regulation energy limits | `DISPATCHLOAD.RAISEREGENABLEMENTMIN`, `RAISEREGENABLEMENTMAX` | `read_fcas_scaling_inputs` → `set_fcas_scaling_inputs!` → `fcas_agc_enablement_min_RAISEREG` / `fcas_agc_enablement_max_RAISEREG` |
# | Lower-regulation energy limits | `DISPATCHLOAD.LOWERREGENABLEMENTMIN`, `LOWERREGENABLEMENTMAX` | Same path, with `LOWERREG` suffix |
# | Upward/downward ramp capability | `DISPATCHLOAD.RAMPUPRATE`, `RAMPDOWNRATE` | Same path → `fcas_agc_ramp_rate_RAISEREG` / `fcas_agc_ramp_rate_LOWERREG`; rate multiplied by interval hours |
# | AGC eligibility | `DISPATCHLOAD.AGCSTATUS` | Same path → `fcas_agc_status`, retaining the raw 0/1 flag |
# | Weather ceiling | `DISPATCHLOAD.UIGF`, restricted to semi-scheduled units using `DUDETAILSUMMARY` | `read_uigf` → `set_fcas_scaling_inputs!` → `fcas_uigf` |
#
# These are published dispatch inputs, rather than a separate raw-SCADA feed. The regulation
# enablement minimum is already the greater of bid and telemetered limits; the maximum is the
# lesser. The ramp fields report rates used in dispatch, combining bid and telemetered limits.
# AEMSim uses those published rates for both energy-ramp inputs and FCAS ramp capability.
# This is a replay convention, not evidence that the archive exposes independent raw AGC rates.
# The UIGF reader uses the value published for the dispatch interval in `DISPATCHLOAD`, rather
# than selecting another forecast run from `INTERMITTENT_DS_RUN`.
#
# MW quantities and MW/h ramp rates are stored per-unit of the system base; prices and AGC
# status retain their original units. An absent scaling observation is stored as `NaN` and
# treated as unknown on read. It must not be confused with a genuine zero UIGF. The
# dispatch readers select `INTERVENTION` consistently where available. During intervention,
# pricing-run inputs and physical-run inputs need to be compared with their matching outputs.
#
# ### Procurement equations
#
# | Required part of equation ``g`` | MMSDM source | How it enters the model |
# | --- | --- | --- |
# | Invoked equation and exact definition version | `DISPATCHCONSTRAINT.CONSTRAINTID`, `GENCONID_EFFECTIVEDATE`, `GENCONID_VERSIONNO` | `read_invoked_constraints` selects the rows replayed by `add_nem_constraints!` |
# | Interval bound ``\mathrm{RHS}_g`` | `DISPATCHCONSTRAINT.RHS` | Attached `rhs` series; AEMSim replays this value rather than recomputing it from live SCADA |
# | Sense and violation weighting | Matching `GENCONDATA.CONSTRAINTTYPE`, `GENERICCONSTRAINTWEIGHT` | `GenericConstraint` definition |
# | Unit energy/FCAS coefficients | `SPDCONNECTIONPOINTCONSTRAINT.CONNECTIONPOINTID`, `BIDTYPE`, `FACTOR` | Joined through `DUDETAILSUMMARY` to a `DUID`; resolved as unit terms |
# | Regional energy/FCAS coefficients | `SPDREGIONCONSTRAINT.REGIONID`, `BIDTYPE`, `FACTOR` | Regional terms over the corresponding devices/service |
# | Interconnector coefficients | `SPDINTERCONNECTORCONSTRAINT.INTERCONNECTORID`, `FACTOR` | Terms on signed interconnector flow |
# | Governing regional service mapping | `DISPATCH_FCAS_REQ` or `DISPATCH_FCAS_REQ_CONSTRAINT`: region, service and constraint identifier | `read_fcas_requirements` / `read_constraint_fcas_requirements`; tags the regional services governed by each equation |
#
# Constraint definitions and all coefficient rows are matched to the exact invoked
# `(GENCONID, EFFECTIVEDATE, VERSIONNO)` triple. These change-only tables may require archive
# months preceding the replay window. A region/service requirement mapping alone supplies
# neither the coefficients nor the constraint sense.
#
# The requirement reader supports the archive transition from `DISPATCH_FCAS_REQ` through
# May 2025 to `DISPATCH_FCAS_REQ_CONSTRAINT` from June 2025. It normalises the successor's
# `CONSTRAINTID` to `GENCONID` and `INTERVAL_DATETIME` to `SETTLEMENTDATE`. The successor
# has no `INTERVENTION` or definition-version fields, and may contain several processor runs;
# the mapping reader does not provide a raw run-by-run reconstruction. The exact model
# definition version still comes from `DISPATCHCONSTRAINT`, not from a latest-version guess
# in the requirement mapping.
#
# ### Published outcomes used for comparison
#
# | Outcome | MMSDM source | Reader |
# | --- | --- | --- |
# | Unit FCAS targets | `DISPATCHLOAD.<SERVICE>`, such as `RAISE6SEC` or `RAISEREG` | `read_fcas_dispatch`, returned as `TARGET` |
# | Published service availability | `DISPATCHLOAD.<SERVICE>ACTUALAVAILABILITY`, where present | Same reader, returned as `ACTUALAVAILABILITY` |
# | Unit energy target | `DISPATCHLOAD.TOTALCLEARED` | Energy context in `read_fcas_dispatch` |
# | Solved equation value and shadow price | `DISPATCHCONSTRAINT.LHS`, `MARGINALVALUE` | Constraint comparison data; requirement readers also expose marginal values |
# | Regional service prices | `DISPATCHPRICE.<SERVICE>RRP`, `<SERVICE>ROP`, `<SERVICE>APCFLAG` | `read_fcas_prices` |
#
# These quantities are results to compare with a new solve. They do not prescribe its unit
# energy or FCAS decisions. In particular, `<SERVICE>ACTUALAVAILABILITY` and regulation
# `RAISEREGAVAILABILITY`/`LOWERREGAVAILABILITY` must not replace the submitted bid `MAXAVAIL`:
# they describe different stages of the capability calculation. The current reader checks
# which actual-availability columns exist in the cached schema and returns missing values
# where they are absent.
#
# ## [Guide to AEMO's participant cases](@id fcas-cases)
#
# The FCAS Model in NEMDE distinguishes participant coordinates, the energy operating point,
# scaling, eligibility, joint constraints and post-dispatch availability. The sections below
# follow those cases, with the package's implementation coverage stated alongside each.
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
# AEMSim represents the curve with `FCASBid` and `PiecewiseStepData`. Its bounded band
# variables sum to the capacity variable. Quantities are internally in per-unit, so the
# objective also multiplies by the system base power to recover the MW-based cost above.
# The offered band total and the technical maximum are separate limits: neither replaces
# the other.
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
# division by an energy-axis width. A zero-availability offer is disabled before building
# its capability rows. See [FCAS Model in NEMDE, §§2-3, pp. 6-13](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).

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
# These conventions follow [FCAS Model in NEMDE, §§2.1-2.4, pp. 7-10](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf)
# and are used by `FCASMarket` when it selects the energy variable in each row.
#
# ### [Applying the envelope at the energy target](@id fcas-cases-application)
#
# In the current AEMSim formulation, passing the eligibility checks causes the energy-envelope
# rows to be built even if the optimiser selects zero FCAS. Those rows then keep the energy
# coordinate within the effective enablement limits. Eligibility is determined before the
# solve; it is not a binary decision that switches these rows off when the target is zero.
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
# `scale_fcas_trapezium` implements these transformations; `get_scaled_fcas_trapezium`
# supplies the interval series consumed by `FCASMarket`. Effective breakpoints are not
# clamped into their submitted order. If ``L'>H'``, the two slopes intersect below ``F'``;
# the same linear inequalities describe that reduced peak. If ``E'_{\max}<E'_{\min}``,
# the service is ineligible.
# The package stores AGC ramp rates in MW/h (or the corresponding per-unit rate); its accessors
# multiply by interval hours. The equations above use MW/min and interval minutes for clarity.
#
# ### [Eligibility is an input check](@id fcas-cases-preconditions)
#
# Eligibility determines whether the optimiser may select a service. It does not imply
# a positive enablement. AEMSim checks the following after scaling, based on
# [FCAS Model in NEMDE, §5, pp. 18-19](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf).
#
# | Check | Ordinary generator or scheduled load | Battery exception |
# | --- | --- | --- |
# | Positive offer | ``F'>0`` and a positive-quantity price band | Each regulation side checked separately |
# | Nonempty range and sign | ``E'_{\min}\le E'_{\max}``, ``E'_{\max}\ge0`` | Load-side regulation requires ``E'_{\min}\le0``; contingency has no sign restriction |
# | Reachable energy range | Energy availability reaches ``E'_{\min}`` | Generation availability reaches the left edge; negative load availability reaches the right edge, as applicable |
# | Initial operating point | ``E'_{\min}\le\max(\mathrm{INITIALMW},0)\le E'_{\max}`` | Signed initial MW; combined load-to-generation range when both regulation sides qualify |
# | AGC status for regulation | Known off-AGC status disables the service | Same rule |
#
# For semi-scheduled generation, energy reachability also uses the UIGF ceiling. `INITIALMW`
# is the metered initial operating point, rather than the preceding dispatch target.
# AEMSim fixes an ineligible capacity variable to zero and omits its energy-envelope rows,
# so an unavailable FCAS bid cannot force an energy target into its trapezium.
# Missing telemetry leaves the corresponding computable check unapplied. The daily/profiled
# energy eligibility checks in AEMO §5 are not implemented because the required inputs are
# unavailable; this limits equivalence with those pre-dispatch cases.
#
# Telemetry timing also matters for a lookahead model. The implemented schedule follows
# [FCAS Model in NEMDE, §4.4 and §6.5, pp. 17, 28](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf):
#
# | Input or constraint | Dispatch replay | 5-minute lookahead | Longer-resolution lookahead |
# | --- | --- | --- | --- |
# | AGC enablement limits and initial eligibility telemetry | Every interval | First interval | First interval |
# | AGC ramp scaling and joint/BDU SCADA ramping | Every interval | First interval | None |
# | UIGF scaling and capacity envelopes | Every interval | Every interval | Every interval |
#
# `NEMLookaheadDispatch` selects the lookahead timing; other NEM dispatch formulations use
# dispatch timing. A horizon by itself does not select pre-dispatch treatment.
# AEMO's Table 3 additionally excludes joint ramping for fast-start units initially in modes
# 0, 1 or 2 during the commitment and final dispatch passes. The current `FCASMarket` timing
# logic does not implement that fast-start exception.
# Pending PR #184 adds it for thermal replay, based on the preprocessed initial mode in both
# passes. See [Fast-start dispatch](@ref nemde-fast-start).
#
# ## [Joint energy and FCAS constraints](@id fcas-cooptimisation)
#
# ### [Capacity and ramping together](@id fcas-cases-joint)
#
# The envelope for one service is insufficient when a unit supplies several services.
# The following rows are the hard, unviolated forms. AEMSim can add nonnegative violation
# slack when service slacks are enabled; that changes feasibility and adds a penalty to the
# objective, but does not change the physical meaning of these limits.
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
# AEMSim omits a joint-ramping row when the rate is zero/unknown, the initial MW is unknown,
# the service is ineligible, or the process timing excludes that interval.
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
# AEMSim adds their enablements into a unit total for each regulation service:
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
# ### Where to inspect these rows
#
# | Mathematical role | AEMSim container |
# | --- | --- |
# | Single-sided or whole-unit enabled capacity | `FCASCapacityVariable` |
# | Two-sided battery regulation capacity | `FCASSideCapacityVariable` |
# | Unit regulation total | `FCASUnitRegulationTarget` |
# | Sloped capacity rows, including contingency/regulation coupling | `FCASJointCapacityConstraint` |
# | Energy plus regulation against initial MW and AGC ramp | `FCASJointRampingConstraint` |
# | Shared battery regulation SCADA capability | `FCASBDURampingConstraint` |
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
# AEMSim builds feasibility rows but does not implement AEMO's complete post-dispatch availability
# calculation for every participant and service. `read_fcas_dispatch` reads published availability
# where the cached schema supplies it. Inspect violation slacks before interpreting an enabled
# target above the hard envelope.

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
# A regional FCAS price can contain several local/shared equation contributions. Let
# ``\mathcal G_{r,k}`` be the built generic constraints tagged as governing region ``r`` and
# service ``k``. For raw solver dual ``\mu_g`` on a per-unit RHS, AEMSim reports
#
# ```math
# \mathrm{ROP}_{r,k}=\frac{1}{S\Delta h}\sum_{g\in\mathcal G_{r,k}}\mu_g,
# ```
#
# where ``S`` is base power in MW. `compute_fcas_prices` performs the mapping and warns when a
# governing constraint has no recorded dual. It retains solver signs: a binding `>=` row in a
# minimisation problem typically has a positive dual; a binding `<=` row has a negative dual.
# A unit capability-row dual is not itself a regional FCAS price. AEMO's requirement mechanism
# is described in the [Constraint Formulation Guidelines, §5](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/congestion-information/2025/constraint-formulation-guidelines.pdf).
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
# Compare the unadjusted model price with `DISPATCHPRICE.<SERVICE>ROP`. `RRP` includes applicable
# administered adjustments, which AEMSim does not reproduce. See
# [Violations, tie-breaking and prices](@ref nemde-prices) for scaling and integer pricing.
#
# ## [Worked interval: Tasmania, 13 January 2025](@id fcas-requirement-reading)
#
# This walkthrough retains the original *FCAS in the NEM* interval: 16:30 AEST on 13 January
# 2025. The queries are runnable against a cache containing the bid, dispatch and historical
# constraint-definition tables above. The documentation build does not require that cache.
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
# The previously inspected Tungatinah offer had ``E_{\min}=1``, ``L=5`` and ``F=4`` MW,
# with energy target 2 MW and no lower regulation. Its lower-side limit is
# ``2-((5-1)/4)f_{\mathrm{LOWER6SEC}}\ge1``, giving 1 MW capability. Verify all five bid
# parameters and other enabled services before treating this as the full availability.
# Its 9 MW raise-regulation target reduced upper contingency headroom:
#
# | Service | Submitted upper coefficient | Upper-row capability at 2 MW energy and 9 MW raise regulation |
# | --- | --- | --- |
# | `RAISE6SEC` | ``(27-11)/9`` | 9 MW after applying the offered maximum |
# | `RAISE60SEC` | ``(27-6)/21`` | 16 MW |
# | `RAISE5MIN` | ``(26-2)/26`` | 16.25 MW |
#
# These are arithmetic reconstructions from previously inspected records, not AEMSim solve
# results generated during this documentation build. Compare them with `unit_outcomes`.
# Inspect requirement variants `F_T+NIL_MG_R6` and `F_T++NIL_MG_R6` across the surrounding hour.
# Original records included a row with RHS 137.5 MW and LHS about 129.65 MW at 16:30. **If its
# resolved sense is `>=`**, the deficit is about 7.85 MW. Establish the sense and coefficients
# from the exact invoked definition; missing definitions do not justify assuming every FCAS
# row is a lower bound. A very negative RHS can make an invoked variant nonbinding, rather
# than represent negative physical demand. Invocation and economic binding are different.
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
# ## [Replay coverage and references](@id fcas-references)
#
# AEMSim enforces all ten service curves, effective trapezium rows, contingency/regulation
# coupling, joint ramping and two-sided battery regulation when their inputs and timing apply.
# Complete generic definitions can represent mainland/local requirement combinations.
# FCAS cost recovery, live-SCADA RHS reconstruction, complete post-dispatch availability and
# daily/profiled energy eligibility are outside this formulation. `set_fcas_scaling_inputs!`
# currently attaches inputs to generators and storage; load scaling/status series need separate
# provision and are not attached by that setter.
#
# Official sources are [FCAS Model in NEMDE v3.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/dispatch/policy_and_process/fcas-model-in-nemde.pdf),
# [Guide to Frequency Control Ancillary Services v4.0](https://www.aemo.com.au/-/media/files/electricity/nem/security_and_reliability/ancillary_services/guide-to-frequency-control-ancillary-services.pdf)
# and the [Market Ancillary Service Specification](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/system-operations/ancillary-services/market-ancillary-service-specification-and-fcas-verification-tool).
