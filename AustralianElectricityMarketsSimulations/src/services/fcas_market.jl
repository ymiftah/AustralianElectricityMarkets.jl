# NEM FCAS market participation as a `PowerSimulations.jl` `Service`: one `FCASCapacityVariable`
# per (unit, market, t), coupled into energy headroom via NEMDE's trapezium and costed from the
# offer curve. Mirrors `nem_constraints.jl`'s `construct_service!`-pair pattern.

const _MS_PER_MINUTE = 60_000.0
const _MS_PER_HOUR = 3.6e6

"""
One NEM FCAS market (e.g. `"RAISE6SEC"`) as a `PowerSimulations.jl` `Service`. One component
per market, not per region: contributing devices are every unit carrying that market's
`"fcas_trapezium_<SERVICE>"` time series ([`set_fcas_bids!`](@ref)), drawn across every region.
Region-level FCAS price/requirement resolution is [`GenericConstraint`](@ref)'s job, not this
service's.
"""
mutable struct NEMFCASService <: PSY.Service
    name::String
    service::BidType
    available::Bool
    ext::Dict{String, Any}
    internal::PSY.IS.InfrastructureSystemsInternal
end

function NEMFCASService(;
        name::AbstractString,
        service::BidType,
        available::Bool = true,
        ext::Dict{String, Any} = Dict{String, Any}(),
        internal::PSY.IS.InfrastructureSystemsInternal = PSY.IS.InfrastructureSystemsInternal(),
    )
    return NEMFCASService(String(name), service, available, ext, internal)
end

PSY.get_available(value::NEMFCASService) = value.available
PSY.set_available!(value::NEMFCASService, val) = value.available = val
PSY.get_ext(value::NEMFCASService) = value.ext
PSY.set_ext!(value::NEMFCASService, val) = value.ext = val
AustralianElectricityMarkets.get_service(value::NEMFCASService) = value.service

"""
    add_fcas_services!(sys::PSY.System)

Registers one [`NEMFCASService`](@ref) per NEM FCAS market (`AustralianElectricityMarkets.FCAS_BID_TYPES`)
with at least one bidding device, contributing devices being exactly those carrying that
market's `"fcas_trapezium_<SERVICE>"` series ([`set_fcas_bids!`](@ref)). A market with no
bidding devices gets no service at all. Decremental (`"<SERVICE>_decremental"`) series are never
consulted - see [`NEMFCASMarket`](@ref)'s docstring.
"""
function add_fcas_services!(sys::PSY.System)
    for bid_type in AustralianElectricityMarkets.FCAS_BID_TYPES
        service_name = string(bid_type)
        series_name = "fcas_trapezium_$(service_name)"
        contributing_devices = [
            d for d in PSY.get_components(PSY.Device, sys)
                if PSY.has_time_series(d, PSY.Deterministic, series_name)
        ]
        isempty(contributing_devices) && continue
        PSY.add_service!(sys, NEMFCASService(; name = service_name, service = bid_type), contributing_devices)
    end
    return
end

"""
Formulation for [`NEMFCASService`](@ref): a unit's offered capacity into one NEM FCAS market.

**Decremental bidding is out of scope.** `EnergyReservoirStorage` units can carry a second
series per service, `"<SERVICE>_decremental"` (load-direction bidding, see
[`set_fcas_bids!`](@ref)); nothing in this file ever reads those series, so no decremental
`FCASCapacityVariable` is ever created, for `EnergyReservoirStorage` or anything else. A
decremental unit's incremental and decremental capacity would share one piece of physical
headroom, and expressing that coupling is a formulation decision deliberately deferred.

Stays a **direct** `PSI.AbstractServiceFormulation` subtype rather than joining
[`AbstractNEMConstraintFormulation`](@ref) — see `constraint_formulations.jl`'s module comment
for why.

Trapezium/offer-curve data is resolved via manual per-device timestamp lookups
([`_resolve_fcas_series`](@ref)/[`_fcas_series_row`](@ref)) rather than a
`PSI.TimeSeriesParameter`: that machinery's `get_multiplier_value` pattern assumes one scalar
value, but this data is a packed 7-tuple trapezium and a piecewise offer curve, not a scalar.
"""
struct NEMFCASMarket <: PSI.AbstractServiceFormulation end

"A unit's offered FCAS capacity into one market, per timestep - MW, per-unit of base power."
struct FCASCapacityVariable <: PSI.VariableType end

"Epigraph variable for one unit's convex FCAS offer-band cost at one timestep - `\$`, not per-unit."
struct FCASOfferCostVariable <: PSI.VariableType end

"`ActivePowerVariable >= enablement_min/base_power + LowerSlopeCoeff * FCASCapacityVariable`."
struct FCASLowerSlopeConstraint <: PSI.ConstraintType end
"`ActivePowerVariable <= enablement_max/base_power - UpperSlopeCoeff * FCASCapacityVariable`."
struct FCASUpperSlopeConstraint <: PSI.ConstraintType end
"Epigraph constraint tying `FCASOfferCostVariable` to one linear underestimator of the convex offer cost."
struct FCASOfferCostConstraint <: PSI.ConstraintType end

PSI.get_default_time_series_names(::Type{NEMFCASService}, ::Type{NEMFCASMarket}) =
    Dict{Type{<:PSI.TimeSeriesParameter}, String}()
PSI.get_default_attributes(::Type{NEMFCASService}, ::Type{NEMFCASMarket}) = Dict{String, Any}()

# --- direction helpers ---

"""
Mirrors PSI's `get_expression_type_for_reserve` trait (`thermal_generation.jl`/
`renewable_generation.jl`) for FCAS services, reimplemented here because `NEMFCASService` isn't
a `PSY.Reserve`: raise services reduce a unit's upward energy headroom
(`ActivePowerRangeExpressionUB`), lower services its downward headroom
(`ActivePowerRangeExpressionLB`). One method per (device type, direction) so a device type
needing a different expression (e.g. `EnergyReservoirStorage`'s `ActivePowerOutVariable`) could
override it - not implemented here, out of scope (decremental bidding, see [`NEMFCASMarket`](@ref)).
"""
get_fcas_expression_type(::Type{<:PSY.Device}, ::Val{:raise}) = PSI.ActivePowerRangeExpressionUB
get_fcas_expression_type(::Type{<:PSY.Device}, ::Val{:lower}) = PSI.ActivePowerRangeExpressionLB

"`service`'s direction, from its canonical `BidType` (`AustralianElectricityMarkets.is_raise_market`) rather than parsing its name."
_fcas_direction(service::NEMFCASService) =
    AustralianElectricityMarkets.is_raise_market(get_service(service)) ? Val(:raise) : Val(:lower)

"""
    _headroom_coupled_devices(container, contributing_devices, direction) -> Vector

`contributing_devices` modeled with both an `ActivePowerVariable` and the `direction`-matching
range-expression container ([`get_fcas_expression_type`](@ref)) - the devices a service can
actually couple `FCASCapacityVariable` into (shared energy headroom + trapezium slope
constraints). Shared by [`PSI.add_to_expression!`](@ref) and [`PSI.add_constraints!`](@ref) so
neither one couples a device the other doesn't.
"""
function _headroom_coupled_devices(container::PSI.OptimizationContainer, contributing_devices::AbstractVector, direction)
    return [
        d for d in contributing_devices
            if PSI.has_container_key(container, PSI.ActivePowerVariable, typeof(d)) &&
            PSI.has_container_key(container, get_fcas_expression_type(typeof(d), direction), typeof(d))
    ]
end

"""
    _headroom_coupling_gaps(container, contributing_devices, direction) -> (; no_energy_var, no_range_expr)

Counts of `contributing_devices` a service can't couple into energy headroom: `no_energy_var`
have no `ActivePowerVariable` at all (variable + cost only); `no_range_expr` have one but lack
the `direction`-matching range-expression container (variable + cost, no slope constraint).
Legitimate for a template that doesn't model every bidding device type, but worth one summary
warning rather than silent per-device skipping.
"""
function _headroom_coupling_gaps(container::PSI.OptimizationContainer, contributing_devices::AbstractVector, direction)
    no_energy_var = 0
    no_range_expr = 0
    for d in contributing_devices
        dtype = typeof(d)
        if !PSI.has_container_key(container, PSI.ActivePowerVariable, dtype)
            no_energy_var += 1
        elseif !PSI.has_container_key(container, get_fcas_expression_type(dtype, direction), dtype)
            no_range_expr += 1
        end
    end
    return (; no_energy_var, no_range_expr)
end

# --- absolute-timestamp series lookup (ported from the abandoned `nem-dispatch-replication`
# branch, commit 8bd35aa - the fix that actually indexes by timestamp, not 86e3e34's first draft,
# which never did) ---

"""
    _container_timestamps(container) -> Vector{DateTime}

`container`'s own dispatch timestamps, mirroring `PSI.get_timestamps(::PSI.OperationModel)`
(`operation_model_interface.jl`) but computable from just the `OptimizationContainer` -
`construct_service!` never receives the owning `DecisionModel`.
"""
function _container_timestamps(container::PSI.OptimizationContainer)
    start_time = PSI.get_initial_time(container)
    resolution = PSI.get_resolution(container)
    horizon_count = PSI.get_time_steps(container)[end]
    return collect(range(start_time; length = horizon_count, step = resolution))
end

"""
    _resolve_fcas_series(comp, series_name) -> NamedTuple

Resolves `comp`'s `series_name` `Deterministic` series once - hoist this out of a per-timestep
loop and pass the result to [`_fcas_series_row`](@ref) per timestep, instead of re-fetching and
re-decomposing the same series metadata on every call.
"""
function _resolve_fcas_series(comp::PSY.Device, series_name::AbstractString)
    ts_data = PSY.get_time_series(PSY.Deterministic, comp, series_name)
    resolution = PSY.get_resolution(ts_data)
    data = PSY.get_data(ts_data)
    series_start = first(keys(data))
    rows = first(values(data))
    return (;
        comp, series_name, series_start, rows, resolution,
        resolution_ms = Dates.value(Dates.Millisecond(resolution)),
    )
end

"""
    _fcas_series_row(resolved, timestamp) -> row

The row of a [`_resolve_fcas_series`](@ref)-resolved series at absolute `timestamp`, found by
matching against the series' own declared `series_start`/resolution - not by positional index. A
`timestamp` off the series' grid entirely, or between two of its points, is a real data problem:
throws rather than silently skipping or misaligning.
"""
function _fcas_series_row(resolved, timestamp::Dates.DateTime)
    offset_ms = Dates.value(Dates.Millisecond(timestamp - resolved.series_start))
    idx, rem = divrem(offset_ms, resolved.resolution_ms)
    if rem != 0 || idx < 0 || idx + 1 > length(resolved.rows)
        error(
            "$(resolved.series_name): no value for $(PSY.get_name(resolved.comp)) at model " *
                "timestep $(timestamp) (series starts $(resolved.series_start), resolution " *
                "$(resolved.resolution), $(length(resolved.rows)) rows)",
        )
    end
    return resolved.rows[idx + 1]
end

"""
Builds an [`FCASTrapezium`](@ref) from a `"fcas_trapezium_<SERVICE>"` packed row
(`NTuple{7,Float64}`: `enablement_min, low_breakpoint, high_breakpoint, enablement_max,
max_avail, ramp_up_rate, ramp_down_rate` - `set_fcas_bids!`'s docstring), mapping `NaN` ramp
rates (non-regulation markets) back to `nothing`.
"""
function _fcas_trapezium(row::NTuple{7, Float64})
    ramp_up = isnan(row[6]) ? nothing : row[6]
    ramp_down = isnan(row[7]) ? nothing : row[7]
    return FCASTrapezium(;
        enablement_min = row[1], low_breakpoint = row[2], high_breakpoint = row[3],
        enablement_max = row[4], max_avail = row[5],
        ramp_up_rate = ramp_up, ramp_down_rate = ramp_down,
    )
end

# --- Step 2: add_variable! ---

"""
    PSI.add_variable!(container, ::FCASCapacityVariable, service, contributing_devices, ::NEMFCASMarket)

One non-negative [`FCASCapacityVariable`](@ref) per `(unit, model timestep)` for `service`'s
market, upper-bounded by that unit's `"fcas_trapezium_<SERVICE>"` `max_avail` (natural MW,
converted to per-unit of `PSI.get_base_power(container)`) at the matching absolute timestamp -
[`_fcas_series_row`](@ref).
"""
function PSI.add_variable!(
        container::PSI.OptimizationContainer,
        ::FCASCapacityVariable,
        service::NEMFCASService,
        contributing_devices::AbstractVector,
        ::NEMFCASMarket,
    )
    service_name = PSY.get_name(service)
    series_name = "fcas_trapezium_$(service_name)"
    time_steps = PSI.get_time_steps(container)
    timestamps = _container_timestamps(container)
    base_power = PSI.get_base_power(container)
    device_names = PSY.get_name.(contributing_devices)
    variable = PSI.add_variable_container!(
        container, FCASCapacityVariable(), NEMFCASService, service_name, device_names, time_steps,
    )
    jm = PSI.get_jump_model(container)
    for d in contributing_devices
        dname = PSY.get_name(d)
        resolved = _resolve_fcas_series(d, series_name)
        for t in time_steps
            row = _fcas_series_row(resolved, timestamps[t])
            max_avail = row[5]
            variable[dname, t] = JuMP.@variable(
                jm, lower_bound = 0.0, upper_bound = max_avail / base_power,
                base_name = "FCASCapacityVariable_$(service_name)_{$(dname), $(t)}",
            )
        end
    end
    return
end

# --- Step 3: add_to_expression! into the device's own energy range expression ---

"""
    PSI.add_to_expression!(container, service, contributing_devices, ::NEMFCASMarket)

For each [`_headroom_coupled_devices`](@ref) device, adds `service`'s
[`FCASCapacityVariable`](@ref) into that device's `ActivePowerRangeExpressionUB` (raise
services, `+1.0`) or `ActivePowerRangeExpressionLB` (lower services, `-1.0`) -
[`get_fcas_expression_type`](@ref) - mirroring PSI's own reserve `add_to_expression!`
(`common/add_to_expression.jl`) sign convention. A device that isn't headroom-coupled still
carries an [`FCASCapacityVariable`](@ref) from Step 2, just uncoupled from energy dispatch - see
`construct_service!`'s summary warning.
"""
function PSI.add_to_expression!(
        container::PSI.OptimizationContainer,
        service::NEMFCASService,
        contributing_devices::AbstractVector,
        ::NEMFCASMarket,
    )
    service_name = PSY.get_name(service)
    direction = _fcas_direction(service)
    sign = direction === Val(:raise) ? 1.0 : -1.0
    fcas_var = PSI.get_variable(container, FCASCapacityVariable(), NEMFCASService, service_name)
    time_steps = PSI.get_time_steps(container)
    for d in _headroom_coupled_devices(container, contributing_devices, direction)
        dtype = typeof(d)
        expr_type = get_fcas_expression_type(dtype, direction)
        expr = PSI.get_expression(container, expr_type(), dtype)
        dname = PSY.get_name(d)
        for t in time_steps
            JuMP.add_to_expression!(expr[dname, t], sign, fcas_var[dname, t])
        end
    end
    return
end

# --- Step 4: trapezium slope constraints ---

"""
    _agc_ramp_mw(rate_mw_per_min, resolution) -> Union{Nothing, Float64}

Converts a telemetered AGC ramp rate (`ROCUP`/`ROCDOWN`, MW/**minute**) to MW deliverable
within one model dispatch interval of length `resolution` - `scale_trapezium`'s `agc_ramp_mw`.
**Do not confuse with `RAMPUPRATE`/energy ramp rates, which are MW/hour** -
`median(RAMPUPRATE / ROCUP) == 60.0` on real archive data; passing the raw MW/minute rate
straight through here would be a silent 60x error. `nothing` in, `nothing` out (non-regulation
markets carry no ROCUP/ROCDOWN).
"""
function _agc_ramp_mw(rate_mw_per_min::Union{Nothing, Float64}, resolution::Dates.Period)
    isnothing(rate_mw_per_min) && return nothing
    resolution_minutes = Dates.value(Dates.Millisecond(resolution)) / _MS_PER_MINUTE
    return rate_mw_per_min * resolution_minutes
end

"""
    PSI.add_constraints!(container, service, contributing_devices, ::NEMFCASMarket)

Couples each [`_headroom_coupled_devices`](@ref) device's `ActivePowerVariable` to `service`'s
[`FCASCapacityVariable`](@ref) via NEMDE's trapezium slopes
(`scale_trapezium`/`lower_slope_coeff`/`upper_slope_coeff`, `replication/preprocessing.jl`):
`ActivePowerVariable >= EnablementMin + LowerSlopeCoeff * FCASCapacityVariable` and
`ActivePowerVariable <= EnablementMax - UpperSlopeCoeff * FCASCapacityVariable`, both in
per-unit. For `RAISEREG`/`LOWERREG`, the telemetered AGC ramp rate (`ROCUP`/`ROCDOWN` - raise
uses `ROCUP`, lower uses `ROCDOWN`) additionally narrows the trapezium's plateau via
[`_agc_ramp_mw`](@ref); `uigf` is not wired up here (this package's UIGF ceiling is fused into a
`RenewableDispatch`'s own `max_active_power` series at `nem_system` parse time, not separately
retrievable per-unit from `construct_service!` - see the module docstring).
"""
function PSI.add_constraints!(
        container::PSI.OptimizationContainer,
        service::NEMFCASService,
        contributing_devices::AbstractVector,
        ::NEMFCASMarket,
    )
    service_name = PSY.get_name(service)
    series_name = "fcas_trapezium_$(service_name)"
    is_regulation = AustralianElectricityMarkets.is_regulation_market(get_service(service))
    is_raise = AustralianElectricityMarkets.is_raise_market(get_service(service))
    direction = _fcas_direction(service)
    fcas_var = PSI.get_variable(container, FCASCapacityVariable(), NEMFCASService, service_name)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    time_steps = PSI.get_time_steps(container)
    timestamps = _container_timestamps(container)
    jm = PSI.get_jump_model(container)

    modeled_devices = _headroom_coupled_devices(container, contributing_devices, direction)
    isempty(modeled_devices) && return
    device_names = PSY.get_name.(modeled_devices)
    lb_con = PSI.add_constraints_container!(
        container, FCASLowerSlopeConstraint(), NEMFCASService, device_names, time_steps; meta = service_name,
    )
    ub_con = PSI.add_constraints_container!(
        container, FCASUpperSlopeConstraint(), NEMFCASService, device_names, time_steps; meta = service_name,
    )
    for d in modeled_devices
        energy_var = PSI.get_variable(container, PSI.ActivePowerVariable(), typeof(d))
        dname = PSY.get_name(d)
        resolved = _resolve_fcas_series(d, series_name)
        for t in time_steps
            row = _fcas_series_row(resolved, timestamps[t])
            trap = _fcas_trapezium(row)
            ramp_mw_per_min = is_regulation ? (is_raise ? trap.ramp_up_rate : trap.ramp_down_rate) : nothing
            agc_ramp_mw = _agc_ramp_mw(ramp_mw_per_min, resolution)
            eff = scale_trapezium(trap; uigf = nothing, agc_ramp_mw = agc_ramp_mw, is_regulation = is_regulation)
            lsc = lower_slope_coeff(eff)
            usc = upper_slope_coeff(eff)
            lb_con[dname, t] = JuMP.@constraint(
                jm, energy_var[dname, t] >= eff.enablement_min / base_power + lsc * fcas_var[dname, t]
            )
            ub_con[dname, t] = JuMP.@constraint(
                jm, energy_var[dname, t] <= eff.enablement_max / base_power - usc * fcas_var[dname, t]
            )
        end
    end
    return
end

# --- Step 5: objective_function! - epigraph cost over `"fcas_curve_<SERVICE>"`'s packed
# PiecewiseStepData (`x_coords` cumulative MW, `y_coords[i]` price for band `i`). Offer bands are
# non-decreasing in price, so the accumulated cost is convex piecewise-linear - the epigraph is
# exact at the optimum, no SOS2/binary needed. ---

"""
    PSI.objective_function!(container, service, contributing_devices, model)

Adds one [`FCASOfferCostVariable`](@ref) per `(unit, t)`, lower-bounded by every band's affine
cost line from `"fcas_curve_<SERVICE>"` ([`_fcas_series_row`](@ref)), and sums it into the
objective. A contributing device without a `"fcas_curve_<SERVICE>"` series is skipped (offered
capacity with no priced curve costs nothing, rather than erroring - no NEM offer is ever
submitted without one, but a hand-built test system may omit it deliberately).
"""
function PSI.objective_function!(
        container::PSI.OptimizationContainer,
        service::NEMFCASService,
        contributing_devices::AbstractVector,
        model::PSI.ServiceModel{NEMFCASService, NEMFCASMarket},
    )
    service_name = PSY.get_name(service)
    curve_series_name = "fcas_curve_$(service_name)"
    fcas_var = PSI.get_variable(container, FCASCapacityVariable(), NEMFCASService, service_name)
    base_power = PSI.get_base_power(container)
    resolution = PSI.get_resolution(container)
    dt = Dates.value(Dates.Millisecond(resolution)) / _MS_PER_HOUR
    time_steps = PSI.get_time_steps(container)
    timestamps = _container_timestamps(container)
    jm = PSI.get_jump_model(container)

    priced_devices = [d for d in contributing_devices if PSY.has_time_series(d, PSY.Deterministic, curve_series_name)]
    isempty(priced_devices) && return
    device_names = PSY.get_name.(priced_devices)
    cost_var = PSI.add_variable_container!(
        container, FCASOfferCostVariable(), NEMFCASService, device_names, time_steps; meta = service_name,
    )
    cost_con = PSI.add_constraints_container!(
        container, FCASOfferCostConstraint(), NEMFCASService, device_names, time_steps; meta = service_name,
    )
    for d in priced_devices
        # `d` is in `contributing_devices`, so `fcas_var[dname, t]` always exists (Step 2 creates
        # one per contributing device/timestep, regardless of whether it's priced).
        dname = PSY.get_name(d)
        resolved = _resolve_fcas_series(d, curve_series_name)
        for t in time_steps
            curve = _fcas_series_row(resolved, timestamps[t])
            x = PSY.get_x_coords(curve)
            y = PSY.get_y_coords(curve)
            cvar = cost_var[dname, t] = JuMP.@variable(
                jm, lower_bound = 0.0, base_name = "FCASOfferCostVariable_$(service_name)_{$(dname), $(t)}",
            )
            cumulative_cost = 0.0
            for i in eachindex(y)
                intercept = (cumulative_cost - y[i] * x[i]) * dt
                slope = y[i] * dt * base_power
                cost_con[dname, t] = JuMP.@constraint(
                    jm, cvar >= intercept + slope * fcas_var[dname, t]
                )
                cumulative_cost += y[i] * (x[i + 1] - x[i])
            end
            PSI.add_to_objective_invariant_expression!(container, JuMP.AffExpr(0.0, cvar => 1.0))
        end
    end
    return
end

# The `PSI._modify_device_model!` no-op for `ServiceModel{NEMFCASService, NEMFCASMarket}` lives
# in `psi_compat.jl`, alongside the equivalent override for `TermConstraint` - see that file.

# --- construct_service! stage pair ---

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ArgumentConstructStage,
        model::PSI.ServiceModel{NEMFCASService, NEMFCASMarket},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    service = PSY.get_component(NEMFCASService, sys, name)
    contributing_devices = PSI.get_contributing_devices(model)
    isempty(contributing_devices) && return
    PSI.add_variable!(container, FCASCapacityVariable(), service, contributing_devices, NEMFCASMarket())
    return
end

function PSI.construct_service!(
        container::PSI.OptimizationContainer,
        sys::PSY.System,
        ::PSI.ModelConstructStage,
        model::PSI.ServiceModel{NEMFCASService, NEMFCASMarket},
        devices_template::Dict{Symbol, PSI.DeviceModel},
        incompatible_device_types::Set{<:DataType},
        network_model::PSI.NetworkModel,
    )
    name = PSI.get_service_name(model)
    service = PSY.get_component(NEMFCASService, sys, name)
    !PSY.get_available(service) && return
    contributing_devices = PSI.get_contributing_devices(model)
    isempty(contributing_devices) && return

    direction = _fcas_direction(service)
    gaps = _headroom_coupling_gaps(container, contributing_devices, direction)
    if gaps.no_energy_var > 0 || gaps.no_range_expr > 0
        @warn "NEMFCASMarket ($(name)): $(gaps.no_energy_var) contributing device(s) have no ActivePowerVariable (uncoupled, costed only), $(gaps.no_range_expr) have one but no matching range-expression container (no slope constraint)"
    end

    PSI.add_to_expression!(container, service, contributing_devices, NEMFCASMarket())
    PSI.add_constraints!(container, service, contributing_devices, NEMFCASMarket())
    PSI.objective_function!(container, service, contributing_devices, model)
    return
end
