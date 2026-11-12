"""
    NEMUnitSlack

Non-negative elastic slack of a unit row under an [`AbstractNEMDispatch`](@ref) formulation, one
container per device type and variant. The key meta is the variant's name, `"<family>_<variant>"`:

- energy offer (`"energy_offer_..."`): `surplus`, `deficit`, `decremental_surplus` and `decremental_deficit`,
  the dispatch above or below the cleared incremental or decremental energy bands.
- energy limit (`"energy_limit_..."`): `max_avail`, `uigf`, `max_avail_out` and `max_avail_in`, the dispatch
  above a raw or forecast availability limit.
- fixed load (`"fixed_load_..."`): `surplus` and `deficit`, the net energy above or below a fixed loading.
- unit ramp (`"unit_ramp_..."`): `up` and `down`, the excess over a ramp rate's base.

Slacks are in system-base per-unit, except that results of the ramp variants read in the units of the
active power variable.
"""
struct NEMUnitSlack <: PSI.VariableType end

# The family tags: each parses the metas of its own variants.
struct EnergyOfferFamily end
struct EnergyLimitFamily end
struct FixedLoadFamily end
struct UnitRampFamily end

struct EnergyOfferSurplusVariant end
struct EnergyOfferDeficitVariant end
struct EnergyOfferDecrementalSurplusVariant end
struct EnergyOfferDecrementalDeficitVariant end

struct EnergyLimitMaxAvailVariant end
struct EnergyLimitUIGFVariant end
struct EnergyLimitMaxAvailOutVariant end
struct EnergyLimitMaxAvailInVariant end

struct FixedLoadSurplusVariant end
struct FixedLoadDeficitVariant end

struct UnitRampUpVariant end
struct UnitRampDownVariant end

const _EnergyOfferVariant = Union{
    EnergyOfferSurplusVariant, EnergyOfferDeficitVariant,
    EnergyOfferDecrementalSurplusVariant, EnergyOfferDecrementalDeficitVariant,
}
const _EnergyLimitVariant = Union{
    EnergyLimitMaxAvailVariant, EnergyLimitUIGFVariant,
    EnergyLimitMaxAvailOutVariant, EnergyLimitMaxAvailInVariant,
}
const _FixedLoadVariant = Union{FixedLoadSurplusVariant, FixedLoadDeficitVariant}
const _UnitRampVariant = Union{UnitRampUpVariant, UnitRampDownVariant}

# The variants whose slacks sit on the energy offer rows, in the order their variables are built.
const _ENERGY_OFFER_SLACK_VARIANTS = (
    EnergyOfferSurplusVariant(), EnergyOfferDeficitVariant(),
    EnergyOfferDecrementalSurplusVariant(), EnergyOfferDecrementalDeficitVariant(),
)

# The key meta of each variant, which is also the name a result file gives it.
_nem_unit_slack_meta(::EnergyOfferSurplusVariant) = "energy_offer_surplus"
_nem_unit_slack_meta(::EnergyOfferDeficitVariant) = "energy_offer_deficit"
_nem_unit_slack_meta(::EnergyOfferDecrementalSurplusVariant) = "energy_offer_decremental_surplus"
_nem_unit_slack_meta(::EnergyOfferDecrementalDeficitVariant) = "energy_offer_decremental_deficit"
_nem_unit_slack_meta(::EnergyLimitMaxAvailVariant) = "energy_limit_max_avail"
_nem_unit_slack_meta(::EnergyLimitUIGFVariant) = "energy_limit_uigf"
_nem_unit_slack_meta(::EnergyLimitMaxAvailOutVariant) = "energy_limit_max_avail_out"
_nem_unit_slack_meta(::EnergyLimitMaxAvailInVariant) = "energy_limit_max_avail_in"
_nem_unit_slack_meta(::FixedLoadSurplusVariant) = "fixed_load_surplus"
_nem_unit_slack_meta(::FixedLoadDeficitVariant) = "fixed_load_deficit"
_nem_unit_slack_meta(::UnitRampUpVariant) = "unit_ramp_up"
_nem_unit_slack_meta(::UnitRampDownVariant) = "unit_ramp_down"

# The JuMP base name each variant's variables keep from the slack type they replace.
_nem_unit_slack_label(::EnergyOfferSurplusVariant) = "EnergyOfferSurplusSlack"
_nem_unit_slack_label(::EnergyOfferDeficitVariant) = "EnergyOfferDeficitSlack"
_nem_unit_slack_label(::EnergyOfferDecrementalSurplusVariant) = "EnergyDecrementalOfferSurplusSlack"
_nem_unit_slack_label(::EnergyOfferDecrementalDeficitVariant) = "EnergyDecrementalOfferDeficitSlack"
_nem_unit_slack_label(::EnergyLimitMaxAvailVariant) = "EnergyMaxAvailSlack"
_nem_unit_slack_label(::EnergyLimitUIGFVariant) = "EnergyUIGFSlack"
_nem_unit_slack_label(::EnergyLimitMaxAvailOutVariant) = "EnergyMaxAvailOutSlack"
_nem_unit_slack_label(::EnergyLimitMaxAvailInVariant) = "EnergyMaxAvailInSlack"
_nem_unit_slack_label(::FixedLoadSurplusVariant) = "EnergyFixedLoadSurplusSlack"
_nem_unit_slack_label(::FixedLoadDeficitVariant) = "EnergyFixedLoadDeficitSlack"
_nem_unit_slack_label(::UnitRampUpVariant) = "UnitRampUpSlack"
_nem_unit_slack_label(::UnitRampDownVariant) = "UnitRampDownSlack"

# The family a unit slack meta names, from its prefix.
function _nem_unit_slack_family(meta::AbstractString)
    startswith(meta, "energy_offer_") && return EnergyOfferFamily()
    startswith(meta, "energy_limit_") && return EnergyLimitFamily()
    startswith(meta, "fixed_load_") && return FixedLoadFamily()
    startswith(meta, "unit_ramp_") && return UnitRampFamily()
    throw(ArgumentError("a NEMUnitSlack has no variant named \"$meta\""))
end

# The variant a unit slack meta names, within the family it belongs to.
_nem_unit_slack_variant(meta::AbstractString) = _nem_unit_slack_variant(_nem_unit_slack_family(meta), meta)
_nem_unit_slack_variant(::EnergyOfferFamily, meta::AbstractString) = _energy_offer_variant(meta)
_nem_unit_slack_variant(::EnergyLimitFamily, meta::AbstractString) = _energy_limit_variant(meta)
_nem_unit_slack_variant(::FixedLoadFamily, meta::AbstractString) = _fixed_load_variant(meta)
_nem_unit_slack_variant(::UnitRampFamily, meta::AbstractString) = _unit_ramp_variant(meta)

function _energy_offer_variant(meta::AbstractString)::_EnergyOfferVariant
    meta == "energy_offer_surplus" && return EnergyOfferSurplusVariant()
    meta == "energy_offer_deficit" && return EnergyOfferDeficitVariant()
    meta == "energy_offer_decremental_surplus" && return EnergyOfferDecrementalSurplusVariant()
    meta == "energy_offer_decremental_deficit" && return EnergyOfferDecrementalDeficitVariant()
    throw(ArgumentError("a NEMUnitSlack energy offer has no variant named \"$meta\""))
end

function _energy_limit_variant(meta::AbstractString)::_EnergyLimitVariant
    meta == "energy_limit_max_avail" && return EnergyLimitMaxAvailVariant()
    meta == "energy_limit_uigf" && return EnergyLimitUIGFVariant()
    meta == "energy_limit_max_avail_out" && return EnergyLimitMaxAvailOutVariant()
    meta == "energy_limit_max_avail_in" && return EnergyLimitMaxAvailInVariant()
    throw(ArgumentError("a NEMUnitSlack energy limit has no variant named \"$meta\""))
end

function _fixed_load_variant(meta::AbstractString)::_FixedLoadVariant
    meta == "fixed_load_surplus" && return FixedLoadSurplusVariant()
    meta == "fixed_load_deficit" && return FixedLoadDeficitVariant()
    throw(ArgumentError("a NEMUnitSlack fixed load has no variant named \"$meta\""))
end

function _unit_ramp_variant(meta::AbstractString)::_UnitRampVariant
    meta == "unit_ramp_up" && return UnitRampUpVariant()
    meta == "unit_ramp_down" && return UnitRampDownVariant()
    throw(ArgumentError("a NEMUnitSlack unit ramp has no variant named \"$meta\""))
end
