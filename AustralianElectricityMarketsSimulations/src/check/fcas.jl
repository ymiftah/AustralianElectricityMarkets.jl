"""
    _fcas_ramp_series_positive(device, bid_type) -> Bool

Whether `device` carries a `"fcas_agc_ramp_rate_<bid_type>"` `PSY.SingleTimeSeries` with any
positive value.

# Returns
`Bool`.
"""
function _fcas_ramp_series_positive(device::PSY.Device, bid_type::BidType)
    name = "fcas_agc_ramp_rate_$(string(bid_type))"
    PSY.has_time_series(device, PSY.SingleTimeSeries, name) || return false
    return any(>(0.0), PSY.get_time_series_values(PSY.SingleTimeSeries, device, name))
end

"""
    check_fcas_services(sys, template)

Verifies every available [`FCASService`](@ref) that `template` models under
[`FCASMarket`](@ref) is buildable: each available contributing device's type is modeled by a
`PSI.DeviceModel` whose formulation dispatches energy (not `PSI.FixedOutput`), the device
carries exactly one direction of FCAS bid for that service's market (both directions only on a
`PSY.Storage` device's regulation market), a decremental-only bid sits only on a `PSY.Storage`
device, no device contributes to more than one such `FCASService` of the same market, and a
regulation contributor with a positive AGC ramp rate also carries an `"initial_mw"` series (AEMO
*FCAS Model in NEMDE* §6.1's joint ramping constraint needs both; a per-interval gap in
`"initial_mw"` is skipped silently at build instead of failing the check).

# Arguments
- `sys`: system to read services and components from.
- `template`: `PSI.ProblemTemplate` to check device coverage against.

# Returns
`nothing`. Throws `ArgumentError` naming every problem device otherwise.
"""
function check_fcas_services(sys::PSY.System, template::PSI.ProblemTemplate)
    device_models = collect(values(PSI.get_device_models(template)))
    fcas_market_services = Set(
        name for ((name, _), model) in PSI.get_service_models(template)
            if PSI.get_component_type(model) == FCASService && PSI.get_formulation(model) == FCASMarket
    )
    problems = String[]
    services_by_market = Dict{Tuple{String, BidType}, Vector{String}}()
    for svc in PSY.get_components(FCASService, sys)
        PSY.get_available(svc) || continue
        svc_name = PSY.get_name(svc)
        svc_name in fcas_market_services || continue
        bid_type = get_bid_type(svc)
        for device in PSY.get_contributing_devices(sys, svc)
            PSY.get_available(device) || continue
            dname = PSY.get_name(device)
            push!(get!(services_by_market, (dname, bid_type), String[]), svc_name)
            idx = findfirst(m -> device isa PSI.get_component_type(m), device_models)
            if isnothing(idx)
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" ($(typeof(device))) has no " *
                        "device model in this template.",
                )
            elseif PSI.get_formulation(device_models[idx]) <: PSI.FixedOutput
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" ($(typeof(device))) is modeled " *
                        "as $(PSI.get_formulation(device_models[idx])), which dispatches no energy " *
                        "for the FCAS joint capacity constraints.",
                )
            end
            direction = AustralianElectricityMarkets._fcas_bid_direction(device, bid_type)
            if direction == :none
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" carries neither an " *
                        "incremental nor a decremental $(string(bid_type)) bid.",
                )
            elseif direction == :both && !(device isa PSY.Storage && _is_regulation_service(bid_type))
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" carries both an incremental " *
                        "and a decremental $(string(bid_type)) bid; bidirectional FCAS " *
                        "capacity is modeled only for a `PSY.Storage` device's regulation " *
                        "markets.",
                )
            elseif direction == :decremental && !(device isa PSY.Storage)
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" ($(typeof(device))) has only " *
                        "a decremental $(string(bid_type)) bid; scheduled-load FCAS capacity " *
                        "is not modeled.",
                )
            end
            if _is_regulation_service(bid_type) && _fcas_ramp_series_positive(device, bid_type) &&
                    !PSY.has_time_series(device, PSY.SingleTimeSeries, "initial_mw")
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" ($(typeof(device))) carries a " *
                        "positive fcas_agc_ramp_rate_$(string(bid_type)) series but no " *
                        "\"initial_mw\" series; AEMO §6.1's joint ramping constraint needs both.",
                )
            end
        end
    end
    for ((dname, bid_type), svc_names) in services_by_market
        length(svc_names) > 1 && push!(
            problems,
            "device \"$dname\" contributes to $(length(svc_names)) $(string(bid_type)) " *
                "FCASServices ($(join(sort(svc_names), ", "))); a device can offer each FCAS " *
                "market through only one.",
        )
    end
    isempty(problems) || throw(
        ArgumentError(
            "template cannot build $(length(problems)) FCASService contributing device(s):\n  " *
                join(problems, "\n  "),
        ),
    )
    return
end
