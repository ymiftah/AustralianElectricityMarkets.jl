"MW of slack below which a constraint row counts as satisfied."
const _VIOLATION_TOLERANCE_MW = 1.0e-6


# Every elastic slack family, as `slack variable type => (family, direction)`. `direction` is
# `"up"` for a slack that relaxes a `<=` row and `"down"` for one that relaxes a `>=` row; the
# FCAS families whose rows have both senses refine it per key in `_violation_direction`.
const _VIOLATION_FAMILIES = (
    EnergyOfferSurplusSlack => ("energy_offer", "up"),
    EnergyOfferDeficitSlack => ("energy_offer", "down"),
    EnergyDecrementalOfferSurplusSlack => ("energy_offer", "up"),
    EnergyDecrementalOfferDeficitSlack => ("energy_offer", "down"),
    EnergyMaxAvailOutSlack => ("energy_max_avail", "up"),
    EnergyMaxAvailInSlack => ("energy_max_avail", "down"),
    EnergyMaxAvailSlack => ("energy_max_avail", "up"),
    EnergyUIGFSlack => ("energy_uigf", "up"),
    EnergyFixedLoadSurplusSlack => ("fixed_load", "up"),
    EnergyFixedLoadDeficitSlack => ("fixed_load", "down"),
    MNSPMaxAvailSlack => ("mnsp_max_avail", "up"),
    MNSPOfferSlack => ("mnsp_offer", "up"),
    MNSPRampUpSlack => ("mnsp_ramp", "up"),
    MNSPRampDownSlack => ("mnsp_ramp", "down"),
    MNSPFixedLoadSurplusSlack => ("mnsp_fixed_load", "up"),
    MNSPFixedLoadDeficitSlack => ("mnsp_fixed_load", "down"),
    UnitRampUpSlack => ("unit_ramp", "up"),
    UnitRampDownSlack => ("unit_ramp", "down"),
    InterconnectorFlowSurplusSlack => ("interconnector_flow", "up"),
    InterconnectorFlowDeficitSlack => ("interconnector_flow", "down"),
    FCASMaxAvailSlack => ("fcas_max_avail", "up"),
    FCASBDURampingSlack => ("fcas_bdu_ramping", "up"),
    FCASJointRampingSlack => ("fcas_joint_ramping", "up"),
    FCASJointCapacitySlack => ("fcas_enablement", "up"),
    GenericConstraintSlackUp => ("generic_constraint", "up"),
    GenericConstraintSlackDown => ("generic_constraint", "down"),
    PSI.SystemBalanceSlackUp => ("area_balance", "up"),
    PSI.SystemBalanceSlackDown => ("area_balance", "down"),
)


function _violation_direction(::PSY.System, ::Type, ::AbstractString, ::AbstractString, default::AbstractString)
    return default
end

function _violation_direction(::PSY.System, ::Type{<:AbstractMNSPSlack}, meta::AbstractString, ::AbstractString, default::AbstractString)
    return isempty(meta) ? default : "$(meta)_$default"
end

function _violation_direction(::PSY.System, ::Type{<:Union{MNSPMaxAvailSlack, MNSPOfferSlack}}, meta::AbstractString, ::AbstractString, default::AbstractString)
    return isempty(meta) ? default : meta
end

# Capacity keys end in `_lower` for the >= EnablementMin rows.
function _violation_direction(::PSY.System, ::Type{FCASJointCapacitySlack}, meta::AbstractString, ::AbstractString, ::AbstractString)
    return endswith(meta, "_lower") ? "down" : "up"
end

# Joint ramping uses the upper form for the device's upper regulation service.
function _violation_direction(sys::PSY.System, ::Type{FCASJointRampingSlack}, meta::AbstractString, name::AbstractString, ::AbstractString)
    service = PSY.get_component(FCASService, sys, meta)
    device = PSY.get_component(PSY.Device, sys, name)
    return get_bid_type(service) == fcas_upper_regulation_service(device) ? "up" : "down"
end


# The stamps at which `sys`'s generic constraint `name` is invoked.
function _invoked_stamps(sys::PSY.System, name::AbstractString)
    constraint = PSY.get_component(GenericConstraint, sys, name)
    data = PSY.get_data(IS.get_time_series(constraint, _constraint_key(constraint, :invoked, NEM_CONSTRAINT_SERIES.invoked)))
    return Set(t for (t, v) in zip(PSY.TimeSeries.timestamp(data), PSY.TimeSeries.values(data)) if v != 0.0)
end


"""
    read_constraint_violations(results, sys::PSY.System) -> DataFrame

Reads every elastic slack above tolerance of a PSI model, in every interval and every family of
the slack table. A generic constraint's slack counts only at the intervals where it is invoked.
Rows are sorted by `DateTime`, `family`, `name`, `variable` and `direction`.

The families are `"energy_offer"`, `"energy_max_avail"`, `"energy_uigf"`, `"fixed_load"`,
`"mnsp_max_avail"`, `"mnsp_offer"`, `"mnsp_ramp"`, `"mnsp_fixed_load"`, `"unit_ramp"`,
`"interconnector_flow"`, `"fcas_max_avail"`, `"fcas_bdu_ramping"`, `"fcas_joint_ramping"`,
`"fcas_enablement"`, `"generic_constraint"` and `"area_balance"`. `direction` is `"up"` for a slack
relaxing a `<=` row and `"down"` for one relaxing a `>=` row; for `"area_balance"`, an equality,
`"up"` is a deficit (demand left unserved) and `"down"` a surplus. The tie-break slacks are not listed.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model, or `PSI.SimulationProblemResults` of a
  simulation, whose realized values are read.
- `sys`: the `System` the model was built from.

# Returns
A `DataFrame` with `family`, `name`, `DateTime`, `MW`, `direction` and `variable` (the slack
variable's key as PSI encodes it in result files, e.g. `"UnitRampUpSlack__NEMHydroGen"`). The
unit ramp rows are those with `family == "unit_ramp"`.
"""
function read_constraint_violations(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System,
    )
    kinds = Dict(_VIOLATION_FAMILIES)
    rows = NamedTuple{
        (:family, :name, :DateTime, :MW, :direction, :variable),
        Tuple{String, String, DateTime, Float64, String, String},
    }[]
    slack_keys = [key for key in PSI.list_variable_keys(results) if haskey(kinds, PSI.IS.Optimization.get_entry_type(key))]
    frames = _read_variable_frames(results, slack_keys)
    invoked = Dict{String, Set{DateTime}}()
    for key in slack_keys
        type = PSI.IS.Optimization.get_entry_type(key)
        kind = kinds[type]
        for r in eachrow(frames[key])
            r.value > _VIOLATION_TOLERANCE_MW || continue
            kind[1] == "generic_constraint" && !(r.DateTime in get!(() -> _invoked_stamps(sys, r.name), invoked, r.name)) &&
                continue
            direction = _violation_direction(sys, type, key.meta, r.name, kind[2])
            push!(rows, (; family = kind[1], name = r.name, DateTime = r.DateTime, MW = r.value, direction, variable = PSI.IS.Optimization.encode_key_as_string(key)))
        end
    end
    out = DataFrame(rows)
    sort!(out, [:DateTime, :family, :name, :variable, :direction])
    return out
end
