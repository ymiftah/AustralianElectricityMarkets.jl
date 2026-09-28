"""
    _fcas_bid_direction(device, bid_type) -> Symbol

`:incremental`, `:decremental`, `:both` or `:none`, describing which `"fcas_trapezium_<bid_type>
[_decremental]"` series `device` carries.
"""
function _fcas_bid_direction(device, bid_type::BidType)
    bid_type_str = string(bid_type)
    has_inc = PSY.has_time_series(device, PSY.Deterministic, "fcas_trapezium_$bid_type_str")
    has_dec = PSY.has_time_series(device, PSY.Deterministic, "fcas_trapezium_$(bid_type_str)_decremental")
    has_inc && has_dec && return :both
    has_inc && return :incremental
    has_dec && return :decremental
    return :none
end

"""
    check_fcas_services(sys, template)

Verifies every available [`FCASService`](@ref) that `template` models under
[`FCASMarket`](@ref) is buildable: each available contributing device's type is modeled by a
`PSI.DeviceModel` whose formulation dispatches energy (not `PSI.FixedOutput`), the device
carries exactly one direction of FCAS bid for that service's market, a decremental-only bid sits
only on a `PSY.Storage` device, and no device contributes to more than one such `FCASService` of
the same market.

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
            direction = _fcas_bid_direction(device, bid_type)
            if direction == :none
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" carries neither an " *
                        "incremental nor a decremental $(string(bid_type)) bid.",
                )
            elseif direction == :both
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" carries both an incremental " *
                        "and a decremental $(string(bid_type)) bid; bidirectional FCAS " *
                        "capacity is not modeled.",
                )
            elseif direction == :decremental && !(device isa PSY.Storage)
                push!(
                    problems,
                    "FCASService \"$svc_name\": device \"$dname\" ($(typeof(device))) has only " *
                        "a decremental $(string(bid_type)) bid; scheduled-load FCAS capacity " *
                        "is not modeled.",
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
