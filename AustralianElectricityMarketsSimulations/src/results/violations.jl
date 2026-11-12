"MW of slack below which a constraint row counts as satisfied."
const _VIOLATION_TOLERANCE_MW = 1.0e-6


# Every elastic slack family, as `slack variable type => (family, direction)`. `direction` is
# `"up"` for a slack that relaxes a `<=` row and `"down"` for one that relaxes a `>=` row; the
# FCAS families whose rows have both senses refine it per key in `_violation_direction`.
const _VIOLATION_FAMILIES = (
    GenericConstraintSlackUp => ("generic_constraint", "up"),
    GenericConstraintSlackDown => ("generic_constraint", "down"),
    PSI.SystemBalanceSlackUp => ("area_balance", "up"),
    PSI.SystemBalanceSlackDown => ("area_balance", "down"),
)


# The family and default direction of each MNSP slack variant.
_mnsp_violation_family(::MNSPMaxAvailVariant) = ("mnsp_max_avail", "up")
_mnsp_violation_family(::MNSPOfferVariant) = ("mnsp_offer", "up")
_mnsp_violation_family(::MNSPRampUpVariant) = ("mnsp_ramp", "up")
_mnsp_violation_family(::MNSPRampDownVariant) = ("mnsp_ramp", "down")
_mnsp_violation_family(::MNSPFixedLoadSurplusVariant) = ("mnsp_fixed_load", "up")
_mnsp_violation_family(::MNSPFixedLoadDeficitVariant) = ("mnsp_fixed_load", "down")

# The family and default direction of each interconnector flow slack variant.
_interconnector_flow_family(::InterconnectorFlowSurplus) = ("interconnector_flow", "up")
_interconnector_flow_family(::InterconnectorFlowDeficit) = ("interconnector_flow", "down")

# The family and default direction of each FCAS slack variant.
_fcas_violation_family(::FCASJointCapacityVariant) = ("fcas_enablement", "up")
_fcas_violation_family(::FCASJointRampingVariant) = ("fcas_joint_ramping", "up")
_fcas_violation_family(::FCASMaxAvailVariant) = ("fcas_max_avail", "up")
_fcas_violation_family(::FCASBDURampingVariant) = ("fcas_bdu_ramping", "up")

# The family and default direction of each NEMUnitSlack variant.
_nem_unit_violation_family(::Union{EnergyOfferSurplusVariant, EnergyOfferDecrementalSurplusVariant}) = ("energy_offer", "up")
_nem_unit_violation_family(::Union{EnergyOfferDeficitVariant, EnergyOfferDecrementalDeficitVariant}) = ("energy_offer", "down")
_nem_unit_violation_family(::Union{EnergyLimitMaxAvailVariant, EnergyLimitMaxAvailOutVariant}) = ("energy_max_avail", "up")
_nem_unit_violation_family(::EnergyLimitMaxAvailInVariant) = ("energy_max_avail", "down")
_nem_unit_violation_family(::EnergyLimitUIGFVariant) = ("energy_uigf", "up")
_nem_unit_violation_family(::FixedLoadSurplusVariant) = ("fixed_load", "up")
_nem_unit_violation_family(::FixedLoadDeficitVariant) = ("fixed_load", "down")
_nem_unit_violation_family(::UnitRampUpVariant) = ("unit_ramp", "up")
_nem_unit_violation_family(::UnitRampDownVariant) = ("unit_ramp", "down")

# The family and default direction of a slack key, from its variant for `NEMUnitSlack`, `MNSPSlack`, `InterconnectorFlowSlack` and `FCASSlack`.
_violation_kind(::Dict, ::Type{NEMUnitSlack}, meta::AbstractString) = _nem_unit_violation_family(_nem_unit_slack_variant(meta))
_violation_kind(::Dict, ::Type{MNSPSlack}, meta::AbstractString) = _mnsp_violation_family(_mnsp_slack_variant(String(meta)))
_violation_kind(::Dict, ::Type{FCASSlack}, meta::AbstractString) = _fcas_violation_family(_fcas_slack_variant(meta))
_violation_kind(::Dict, ::Type{InterconnectorFlowSlack}, meta::AbstractString) =
    _interconnector_flow_family(_interconnector_flow_variant(meta))
_violation_kind(kinds::Dict, type::Type, ::AbstractString) = kinds[type]

function _violation_direction(::PSY.System, ::Type, ::AbstractString, ::AbstractString, default::AbstractString)
    return default
end

function _violation_direction(::PSY.System, ::Type{MNSPSlack}, meta::AbstractString, ::AbstractString, default::AbstractString)
    return _mnsp_slack_direction(_mnsp_slack_variant(String(meta)), String(meta), default)
end

# The link of a commercial limit, the link and default of a fixed-loading slack, and the default of a ramp.
_mnsp_slack_direction(::Union{MNSPMaxAvailVariant, MNSPOfferVariant}, meta::String, ::AbstractString) =
    _mnsp_link_prefix(_mnsp_slack_link(meta))
_mnsp_slack_direction(::_MNSPFixedLoadVariant, meta::String, default::AbstractString) =
    "$(_mnsp_link_prefix(_mnsp_slack_link(meta)))_$default"
_mnsp_slack_direction(::_MNSPRampVariant, ::String, default::AbstractString) = default

function _violation_direction(sys::PSY.System, ::Type{FCASSlack}, meta::AbstractString, name::AbstractString, default::AbstractString)
    return _fcas_slack_direction(_fcas_slack_variant(meta), sys, _fcas_slack_row_meta(meta), name, default)
end

# Capacity keys end in `_lower` for the >= EnablementMin rows.
function _fcas_slack_direction(::FCASJointCapacityVariant, ::PSY.System, row::AbstractString, ::AbstractString, ::AbstractString)
    return endswith(row, "_lower") ? "down" : "up"
end

# Joint ramping uses the upper form for the device's upper regulation service.
function _fcas_slack_direction(::FCASJointRampingVariant, sys::PSY.System, service::AbstractString, name::AbstractString, ::AbstractString)
    svc = PSY.get_component(FCASService, sys, service)
    device = PSY.get_component(PSY.Device, sys, name)
    return get_bid_type(svc) == fcas_upper_regulation_service(device) ? "up" : "down"
end

_fcas_slack_direction(::Union{FCASMaxAvailVariant, FCASBDURampingVariant}, ::PSY.System, ::AbstractString, ::AbstractString, default::AbstractString) = default


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
variable's key as PSI encodes it in result files, e.g. `"NEMUnitSlack__HydroDispatch__unit_ramp_up"`). The
unit ramp rows are those with `family == "unit_ramp"`.
"""
function read_constraint_violations(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System,
    )
    kinds = Dict(_VIOLATION_FAMILIES)
    is_slack(type) = type === NEMUnitSlack || type === MNSPSlack || type === InterconnectorFlowSlack || type === FCASSlack || haskey(kinds, type)
    rows = NamedTuple{
        (:family, :name, :DateTime, :MW, :direction, :variable),
        Tuple{String, String, DateTime, Float64, String, String},
    }[]
    slack_keys = [key for key in PSI.list_variable_keys(results) if is_slack(PSI.IS.Optimization.get_entry_type(key))]
    frames = _read_variable_frames(results, slack_keys)
    invoked = Dict{String, Set{DateTime}}()
    for key in slack_keys
        type = PSI.IS.Optimization.get_entry_type(key)
        kind = _violation_kind(kinds, type, key.meta)
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
