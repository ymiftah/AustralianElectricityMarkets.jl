const _FCASOptionalSeries = Union{Nothing, Vector{Float64}}
const _FCASEnergyAvailability = Union{Nothing, Float64, NamedTuple{(:gen, :load), Tuple{Float64, Float64}}}

struct _FCASDeviceInputs
    process::Symbol
    initial_mw::Vector{Union{Nothing, Float64}}
    availability::Vector{_FCASEnergyAvailability}
    agc_status::Vector{Union{Nothing, Int}}
    uigf::_FCASOptionalSeries
    ramp_capabilities::Dict{BidType, _FCASOptionalSeries}
    agc_limits::Dict{BidType, Tuple{_FCASOptionalSeries, _FCASOptionalSeries}}
end

struct _FCASBidInputs
    trapeziums::Vector{FCASTrapezium}
    curves::Vector{PSY.PiecewiseStepData}
    enabled::Vector{Bool}
end

struct _FCASContributorInputs
    direction::Symbol
    telemetry::_FCASDeviceInputs
    incremental::Union{Nothing, _FCASBidInputs}
    decremental::Union{Nothing, _FCASBidInputs}
    enabled::Vector{Bool}
    ramp_caps::_FCASOptionalSeries
end

struct _FCASServiceInputs
    devices::Vector{PSY.Device}
    single_devices::Vector{PSY.Device}
    both_devices::Vector{PSY.Device}
    single_names::Vector{String}
    both_names::Vector{String}
    bids::Dict{String, _FCASContributorInputs}
end

struct _FCASBuildInputs
    devices::Dict{Base.UUID, _FCASDeviceInputs}
    services::Dict{String, _FCASServiceInputs}
end

const _FCAS_BUILD_INPUTS_KEY = :AustralianElectricityMarketsSimulations_fcas_inputs


"""
    _prepare_fcas_device_inputs(container, devices_template, device) -> _FCASDeviceInputs

Read a device's shared FCAS telemetry for the build horizon and apply dispatch-process timing
to initial MW and AGC status.

# Returns
Telemetry and initially empty maps for service-specific AGC inputs.
"""
function _prepare_fcas_device_inputs(container, devices_template, device)
    initial_time = PSI.get_initial_time(container)
    horizon = length(PSI.get_time_steps(container))
    process = _fcas_process(container, devices_template, device)
    initial_mw = get_initial_mw(device, initial_time, horizon)
    agc_status = get_fcas_agc_status(device, initial_time, horizon)
    telemetry(series, t) = (isnothing(series) || (process !== :dispatch && t > 1)) ? nothing : series[t]
    availability = if device isa PSY.Storage
        values = get_storage_energy_max_avail(device, initial_time, horizon)
        _FCASEnergyAvailability[_storage_energy_max_avail_at(values, t) for t in 1:horizon]
    else
        values = get_energy_availability(device, initial_time, horizon)
        _FCASEnergyAvailability[isnothing(values) ? nothing : values[t] for t in 1:horizon]
    end
    uigf = AustralianElectricityMarkets._read_optional_fcas_scaling_series(device, "fcas_uigf", initial_time, horizon)
    return _FCASDeviceInputs(
        process, Union{Nothing, Float64}[telemetry(initial_mw, t) for t in 1:horizon],
        availability, Union{Nothing, Int}[telemetry(agc_status, t) for t in 1:horizon], uigf,
        Dict{BidType, _FCASOptionalSeries}(),
        Dict{BidType, Tuple{_FCASOptionalSeries, _FCASOptionalSeries}}(),
    )
end


function _prepare_fcas_ramp_capability!(inputs::_FCASDeviceInputs, container, device, bid_type)
    return get!(inputs.ramp_capabilities, bid_type) do
        return get_fcas_agc_ramp_capability(
            device, bid_type, PSI.get_initial_time(container), length(PSI.get_time_steps(container));
            resolution = PSI.get_resolution(container),
        )
    end
end


"""
    _prepare_fcas_bid_inputs(container, device, bid_type, decremental, inputs) -> _FCASBidInputs

Read and scale one bid direction using shared device inputs. Its enablement mask is filled
by service preparation after both directions, where present, have been read.

# Returns
Scaled trapeziums, offer curves and a mask with one entry per build step.
"""
function _prepare_fcas_bid_inputs(container, device, bid_type, decremental, inputs::_FCASDeviceInputs)
    initial_time = PSI.get_initial_time(container)
    horizon = length(PSI.get_time_steps(container))
    is_regulation = _is_regulation_service(bid_type)
    agc_min, agc_max = if is_regulation
        get!(inputs.agc_limits, bid_type) do
            read(name) = AustralianElectricityMarkets._read_optional_fcas_scaling_series(device, name, initial_time, horizon)
            service = string(bid_type)
            return read("fcas_agc_enablement_min_$service"), read("fcas_agc_enablement_max_$service")
        end
    else
        nothing, nothing
    end
    ramp = is_regulation && inputs.process !== :predispatch ?
        _prepare_fcas_ramp_capability!(inputs, container, device, bid_type) : nothing
    trapeziums = AustralianElectricityMarkets._scale_fcas_trapezium_series(
        get_fcas_trapezium(device, bid_type, initial_time, horizon; decremental);
        agc_enablement_min = agc_min, agc_enablement_max = agc_max, agc_max_avail = ramp,
        uigf = inputs.uigf, is_regulation, agc_first_interval_only = inputs.process !== :dispatch,
    )
    curves = get_fcas_offer_curve(device, bid_type, initial_time, horizon; decremental)
    return _FCASBidInputs(trapeziums, curves, fill(false, horizon))
end


"""
    _prepare_fcas_service_inputs!(container, svc, devices, devices_template) -> _FCASServiceInputs

Prepare one service's bids, enablement and ramp limits for all construction stages. Shared
telemetry is read once per contributing device in the optimisation container.

# Returns
The service's prepared inputs, owned by this build's JuMP model.
"""
function _prepare_fcas_service_inputs!(container, svc, devices, devices_template)
    build = get!(PSI.get_jump_model(container).ext, _FCAS_BUILD_INPUTS_KEY) do
        return _FCASBuildInputs(Dict{Base.UUID, _FCASDeviceInputs}(), Dict{String, _FCASServiceInputs}())
    end
    build = build::_FCASBuildInputs
    bid_type = get_bid_type(svc)
    is_regulation = _is_regulation_service(bid_type)
    time_steps = PSI.get_time_steps(container)
    single_devices, both_devices = PSY.Device[], PSY.Device[]
    bids = Dict{String, _FCASContributorInputs}()
    for device in devices
        direction = _fcas_direction(device, bid_type)
        inputs = get!(build.devices, IS.get_uuid(device)) do
            return _prepare_fcas_device_inputs(container, devices_template, device)
        end
        incremental = direction !== :decremental ? _prepare_fcas_bid_inputs(container, device, bid_type, false, inputs) : nothing
        decremental = direction !== :incremental ? _prepare_fcas_bid_inputs(container, device, bid_type, true, inputs) : nothing
        if direction === :both
            push!(both_devices, device)
            for t in time_steps
                incremental.enabled[t], decremental.enabled[t] = _fcas_both_sides_enabled(
                    device, incremental.trapeziums[t], incremental.curves[t], decremental.trapeziums[t], decremental.curves[t],
                    inputs.agc_status[t], inputs.initial_mw[t], inputs.availability[t],
                )
            end
            enabled = incremental.enabled .| decremental.enabled
        else
            push!(single_devices, device)
            bid = direction === :decremental ? decremental : incremental
            for t in time_steps
                bid.enabled[t] = _fcas_enabled(
                    device, is_regulation, direction === :decremental, bid.trapeziums[t], bid.curves[t],
                    inputs.availability[t], inputs.initial_mw[t], inputs.agc_status[t],
                )
            end
            enabled = bid.enabled
        end
        ramp_caps = if is_regulation
            ramp = _prepare_fcas_ramp_capability!(inputs, container, device, _fcas_ramp_rate_service(device, bid_type))
            [
                (isnothing(ramp) || isnan(ramp[t]) || !_fcas_agc_ramp_applies(inputs.process, t)) ? 0.0 : ramp[t]
                    for t in time_steps
            ]
        else
            nothing
        end
        bids[PSY.get_name(device)] = _FCASContributorInputs(direction, inputs, incremental, decremental, enabled, ramp_caps)
    end
    prepared = _FCASServiceInputs(
        collect(PSY.Device, devices), single_devices, both_devices,
        PSY.get_name.(single_devices), PSY.get_name.(both_devices), bids,
    )
    build.services[PSY.get_name(svc)] = prepared
    return prepared
end


function _fcas_service_inputs(container, name)
    build = PSI.get_jump_model(container).ext[_FCAS_BUILD_INPUTS_KEY]::_FCASBuildInputs
    return build.services[name]
end
