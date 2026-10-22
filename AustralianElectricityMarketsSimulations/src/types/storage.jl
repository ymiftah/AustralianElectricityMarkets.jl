"""
    StorageInputDevicePower

Initial condition type for a [`AbstractNEMDispatch`](@ref) battery's charging-side power,
paired with `PowerSimulations.DevicePower` (the discharging side) so
[`NEMLookaheadDispatch`](@ref) can measure interval 1's net ramp against the initial-conditions
sub-model's solved `Out - In`.
"""
struct StorageInputDevicePower <: PSI.InitialConditionType end
