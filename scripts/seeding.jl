using AustralianElectricityMarketsSimulations
import PowerSystems as PSY

"""
    seed_initial_conditions!(sys, inputs::IntervalInputs)

Sets each device's `active_power` to its real `INITIALMW` from `inputs`, so the model's ramp
base matches what NEMDE actually started from for this interval rather than the `System`'s own
static default. A device present in `sys` with no matching entry in `inputs.initial_mw` is left
unchanged and reported once via a summary `@warn` - never silently, mirroring
`add_nem_constraints!`'s own skip-and-warn-once convention.
"""
function seed_initial_conditions!(sys::PSY.System, inputs::IntervalInputs)
    unmatched = String[]
    for dev in PSY.get_components(PSY.Device, sys)
        name = PSY.get_name(dev)
        if haskey(inputs.initial_mw, name)
            PSY.set_active_power!(dev, inputs.initial_mw[name])
        else
            push!(unmatched, name)
        end
    end
    isempty(unmatched) ||
        @warn "seed_initial_conditions!: no INITIALMW for $(length(unmatched)) device(s), left unchanged" unmatched
    return
end
