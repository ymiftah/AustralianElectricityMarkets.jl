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

Verifies every [`FCASService`](@ref) in `sys` is buildable under `template`: each contributing
device's type is modeled by some `PSI.DeviceModel`, and the device carries exactly one direction
of FCAS bid for that service's market, and a decremental-only bid only on a `PSY.Storage`
device.

# Arguments
- `sys`: system to read services and components from.
- `template`: `PSI.ProblemTemplate` to check device coverage against.

# Returns
`nothing`. Throws `ArgumentError` naming every problem device otherwise.
"""
function check_fcas_services(sys::PSY.System, template::PSI.ProblemTemplate)
    modeled_types = _modeled_device_types(template)
    problems = String[]
    for svc in PSY.get_components(FCASService, sys)
        PSY.get_available(svc) || continue
        bid_type = get_bid_type(svc)
        svc_name = PSY.get_name(svc)
        for device in PSY.get_contributing_devices(sys, svc)
            dname = PSY.get_name(device)
            _type_modeled(device, modeled_types) || push!(
                problems,
                "FCASService \"$svc_name\": device \"$dname\" ($(typeof(device))) has no " *
                    "device model in this template.",
            )
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
    isempty(problems) && return nothing
    throw(
        ArgumentError(
            "template cannot build $(length(problems)) FCASService contributing device(s):\n  " *
                join(problems, "\n  "),
        ),
    )
end
