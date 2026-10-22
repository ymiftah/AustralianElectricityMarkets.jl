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
    check_fcas_services(sys, template; excluded_device_types = ())

Verifies every available [`FCASService`](@ref) that `template` models under
[`FCASMarket`](@ref) is buildable: each available contributing device's type is modeled by a
`PSI.DeviceModel` whose formulation dispatches energy (not `PSI.FixedOutput`), the device's FCAS
bid direction is one [`FCASMarket`](@ref) models (incremental on any device but a load, decremental
on a `PSY.Storage` device or a load, both only on a `PSY.Storage` device's regulation market), no device
contributes to more than one such `FCASService` of the same market, and a regulation contributor
with a positive AGC ramp rate also carries an `"initial_mw"` series, which AEMO *FCAS Model in
NEMDE* §6.1's joint ramping constraint needs. A per-interval gap in `"initial_mw"` is not checked.

# Arguments
- `sys`: system to read services and components from.
- `template`: `PSI.ProblemTemplate` to check device coverage against.
- `excluded_device_types`: device types deliberately omitted from the template; their contributors
  are not checked. The default checks every available contributor.

# Returns
`nothing`. Throws `ArgumentError` naming every problem device otherwise.
"""
function check_fcas_services(sys::PSY.System, template::PSI.ProblemTemplate; excluded_device_types = ())
    device_models = collect(values(PSI.get_device_models(template)))
    fcas_market_services = _modeled_fcas_services(template)
    problems = String[]
    services_by_market = Dict{Tuple{String, BidType}, Vector{String}}()
    for svc in PSY.get_components(FCASService, sys)
        PSY.get_available(svc) || continue
        svc_name = PSY.get_name(svc)
        svc_name in fcas_market_services || continue
        bid_type = get_bid_type(svc)
        for device in PSY.get_contributing_devices(sys, svc)
            PSY.get_available(device) || continue
            any(t -> device isa t, excluded_device_types) && continue
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
            direction = fcas_bid_direction(device, bid_type)
            problem = _fcas_direction_problem(device, bid_type, direction)
            isnothing(problem) || push!(problems, "FCASService \"$svc_name\": device \"$dname\" $problem.")
            if bid_type in FCAS_REGULATION_MARKETS && _fcas_ramp_series_positive(device, bid_type) &&
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
