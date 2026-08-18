"""
AEMO FCAS trapezium parameters for one device's offer into one FCAS market (from
`BIDPEROFFER_D`). This is per-(device, market) data, not a property of the shared regional
[`NEMFCASReserve`](@ref) — cramming it onto the shared `Reserve` would break PowerSystems'
existing service/device separation. Instead it is a plain `PowerSystems.DeviceParameter`
value struct, the same role `LinearCurve`/`PiecewiseStepData` play inside `CostCurve`.

The trapezoid *binding-check math* (`energy_upper_limit = enablement_max -
fcas_cleared/upper_slope`, etc.) is explicitly out of scope here — this only makes the raw
parameters retrievable, typed data; NEMDE co-optimization constraint math belongs to
PowerSimulations.jl.
"""
struct FCASTrapezium <: PSY.DeviceParameter
    enablement_min::Float64
    low_breakpoint::Float64
    high_breakpoint::Float64
    enablement_max::Float64
    max_avail::Float64
    "ROCUP, regulation FCAS only"
    ramp_up_rate::Union{Nothing, Float64}
    "ROCDOWN, regulation FCAS only"
    ramp_down_rate::Union{Nothing, Float64}
end

function FCASTrapezium(;
        enablement_min::Float64,
        low_breakpoint::Float64,
        high_breakpoint::Float64,
        enablement_max::Float64,
        max_avail::Float64,
        ramp_up_rate::Union{Nothing, Float64} = nothing,
        ramp_down_rate::Union{Nothing, Float64} = nothing,
    )
    return FCASTrapezium(
        enablement_min, low_breakpoint, high_breakpoint, enablement_max, max_avail,
        ramp_up_rate, ramp_down_rate,
    )
end

get_enablement_min(value::FCASTrapezium) = value.enablement_min
get_low_breakpoint(value::FCASTrapezium) = value.low_breakpoint
get_high_breakpoint(value::FCASTrapezium) = value.high_breakpoint
get_enablement_max(value::FCASTrapezium) = value.enablement_max
get_max_avail(value::FCASTrapezium) = value.max_avail
get_ramp_up_rate(value::FCASTrapezium) = value.ramp_up_rate
get_ramp_down_rate(value::FCASTrapezium) = value.ramp_down_rate

"""
One device's bid into one FCAS market for one interval: a 10-band offer curve
(`PRICEBAND1-10` × `BANDAVAIL1-10`, the same shape the energy bid path already builds via
`PowerSystems.make_market_bid_curve`) plus the trapezium parameters for that market.

`reserve_name` identifies the regional [`NEMFCASReserve`](@ref) this offer is for by name
— resolve via `PowerSystems.get_component(PowerSystems.Reserve, sys, reserve_name)` —
rather than holding a live component reference. PowerSystems' component-reference JSON
round-trip machinery (`PowerSystems/src/models/serialization.jl`, `_CONTAINS_SHOULD_ENCODE`)
only UUID-encodes a small, closed set of built-in field shapes on `Component`/`MarketBidCost`
specifically; a plain external `DeviceParameter` struct can't join that set without modifying
PowerSystems itself, so a name lookup is used instead — it needs no core changes and matches
how this repo already looks up other components (e.g. `get_component(Area, sys, row[:region])`
in `region_model.jl`).
"""
struct FCASOffer <: PSY.DeviceParameter
    reserve_name::String
    offer_curve::PSY.CostCurve{PSY.PiecewiseIncrementalCurve}
    trapezium::FCASTrapezium
end

get_reserve_name(value::FCASOffer) = value.reserve_name
get_offer_curve(value::FCASOffer) = value.offer_curve
get_trapezium(value::FCASOffer) = value.trapezium

"""
Like `PowerSystems.MarketBidCost`, but `ancillary_service_offers` carries priced
[`FCASOffer`](@ref)s (10-band curve + trapezium per FCAS market) instead of PSY's bare
`Vector{Service}` membership list. Energy-side fields (`no_load_cost`, `start_up`,
`shut_down`, offer curves) are forwarded to an inner `PowerSystems.MarketBidCost`.

Not directly usable as a built-in device's `operation_cost` today: confirmed directly that
PSY's auto-generated device structs type that field as a *closed* `Union` of specific
concrete cost types (e.g. `ThermalStandard.operation_cost::Union{ThermalGenerationCost,
MarketBidCost}`), not the abstract `OperationalCost`/`OfferCurveCost` supertype — so no
externally-defined subtype, including this one, can be assigned there without modifying
PowerSystems' generated structs. `set_fcas_offers!` in `parser.jl` therefore attaches
`FCASOffer`s via each device's `ext` dict instead of via `operation_cost` — see that
function's docstring for the full reasoning. This type is kept as a standalone, usable
building block (e.g. for a hand-rolled `Device` not subject to PSY's generated Union) even
though nothing in this repo currently plugs it into a built-in device.

PowerSystems' own docs prescribe `InfrastructureSystems.@forward` for a type "identical to
an existing type except for one attribute" (`add_new_types.md`, "Specialize an Existing
Type", `RoundRotorQuadratic` precedent) — but that macro works by `eval`-ing new methods
directly into the *target* function's owning module (here, `PowerSystems`) at the point
`@forward` runs. `RoundRotorQuadratic` gets away with this because it forwards to
`RoundRotorMachine`, another type defined inside PowerSystems itself, so the `eval` lands in
a module that is still open (mid-compilation) at that point. Forwarding from an external,
separately-precompiled package like this one into the already-closed `PowerSystems` module
hits Julia's incremental-compilation guard ("Evaluation into the closed module `PowerSystems`
breaks incremental compilation") — confirmed by actually precompiling this package with
`@forward` before writing the explicit methods below instead. Ordinary method definitions
(as used here) don't have this restriction; only `@forward`'s runtime-`eval` mechanism does.
This is additive — a new type plus new methods on it — not a modification of `MarketBidCost`,
so it is not type piracy either way.
"""
mutable struct NEMMarketBidCost <: PSY.OfferCurveCost
    base_cost::PSY.MarketBidCost
    ancillary_service_offers::Vector{FCASOffer}
end

function NEMMarketBidCost(;
        base_cost::PSY.MarketBidCost,
        ancillary_service_offers::Vector{FCASOffer} = FCASOffer[],
    )
    return NEMMarketBidCost(base_cost, ancillary_service_offers)
end

get_base_cost(value::NEMMarketBidCost) = value.base_cost

"""Get [`NEMMarketBidCost`](@ref) `no_load_cost`, from the inner `base_cost`."""
PSY.get_no_load_cost(value::NEMMarketBidCost) = PSY.get_no_load_cost(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `start_up`, from the inner `base_cost`."""
PSY.get_start_up(value::NEMMarketBidCost) = PSY.get_start_up(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `shut_down`, from the inner `base_cost`."""
PSY.get_shut_down(value::NEMMarketBidCost) = PSY.get_shut_down(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `incremental_offer_curves`, from the inner `base_cost`."""
PSY.get_incremental_offer_curves(value::NEMMarketBidCost) = PSY.get_incremental_offer_curves(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `decremental_offer_curves`, from the inner `base_cost`."""
PSY.get_decremental_offer_curves(value::NEMMarketBidCost) = PSY.get_decremental_offer_curves(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `incremental_initial_input`, from the inner `base_cost`."""
PSY.get_incremental_initial_input(value::NEMMarketBidCost) = PSY.get_incremental_initial_input(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `decremental_initial_input`, from the inner `base_cost`."""
PSY.get_decremental_initial_input(value::NEMMarketBidCost) = PSY.get_decremental_initial_input(value.base_cost)
"""Get [`NEMMarketBidCost`](@ref) `ancillary_service_offers`."""
PSY.get_ancillary_service_offers(value::NEMMarketBidCost) = value.ancillary_service_offers

"""Set [`NEMMarketBidCost`](@ref) `no_load_cost`, on the inner `base_cost`."""
PSY.set_no_load_cost!(value::NEMMarketBidCost, val) = PSY.set_no_load_cost!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `start_up`, on the inner `base_cost`."""
PSY.set_start_up!(value::NEMMarketBidCost, val) = PSY.set_start_up!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `shut_down`, on the inner `base_cost`."""
PSY.set_shut_down!(value::NEMMarketBidCost, val) = PSY.set_shut_down!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `incremental_offer_curves`, on the inner `base_cost`."""
PSY.set_incremental_offer_curves!(value::NEMMarketBidCost, val) = PSY.set_incremental_offer_curves!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `decremental_offer_curves`, on the inner `base_cost`."""
PSY.set_decremental_offer_curves!(value::NEMMarketBidCost, val) = PSY.set_decremental_offer_curves!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `incremental_initial_input`, on the inner `base_cost`."""
PSY.set_incremental_initial_input!(value::NEMMarketBidCost, val) = PSY.set_incremental_initial_input!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `decremental_initial_input`, on the inner `base_cost`."""
PSY.set_decremental_initial_input!(value::NEMMarketBidCost, val) = PSY.set_decremental_initial_input!(value.base_cost, val)
"""Set [`NEMMarketBidCost`](@ref) `ancillary_service_offers`."""
PSY.set_ancillary_service_offers!(value::NEMMarketBidCost, val::Vector{FCASOffer}) =
    value.ancillary_service_offers = val
