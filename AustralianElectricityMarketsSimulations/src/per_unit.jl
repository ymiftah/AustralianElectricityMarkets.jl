"""
    DISPATCH_INTERVAL_HOURS

Length of one NEM dispatch interval in hours, `1 / 12`.
"""
const DISPATCH_INTERVAL_HOURS = 1 / 12

"""
    mw_to_pu(mw, base_power) -> Float64
    mw_to_pu(container, mw) -> Float64

Converts a natural-MW quantity to per-unit of `base_power`.

# Arguments
- `mw::Float64`: quantity in MW.
- `base_power::Float64`: system base power in MVA.
- `container::PSI.OptimizationContainer`: supplies the base power via `PSI.get_base_power`
  instead of an explicit `base_power`.

# Returns
`Float64` in per-unit of the base power.
"""
function mw_to_pu(mw::Float64, base_power::Float64)
    return mw / base_power
end

function mw_to_pu(container::PSI.OptimizationContainer, mw::Float64)
    return mw_to_pu(mw, PSI.get_base_power(container))
end

"""
    pu_to_mw(pu, base_power) -> Float64
    pu_to_mw(container, pu) -> Float64

Converts a per-unit-of-`base_power` quantity to natural MW.

# Arguments
- `pu::Float64`: quantity in per-unit of the base power.
- `base_power::Float64`: system base power in MVA.
- `container::PSI.OptimizationContainer`: supplies the base power via `PSI.get_base_power`
  instead of an explicit `base_power`.

# Returns
`Float64` in MW.
"""
function pu_to_mw(pu::Float64, base_power::Float64)
    return pu * base_power
end

function pu_to_mw(container::PSI.OptimizationContainer, pu::Float64)
    return pu_to_mw(pu, PSI.get_base_power(container))
end

"""
    price_to_pu_coefficient(price_per_mwh, base_power) -> Float64
    price_to_pu_coefficient(container, price_per_mwh) -> Float64

Converts a `\$/MWh` energy price into an objective coefficient on a per-unit-of-`base_power`
dispatch variable for one [`DISPATCH_INTERVAL_HOURS`](@ref)-long dispatch interval.

# Arguments
- `price_per_mwh::Float64`: energy price in `\$/MWh`.
- `base_power::Float64`: system base power in MVA.
- `container::PSI.OptimizationContainer`: supplies the base power via `PSI.get_base_power`
  instead of an explicit `base_power`.

# Returns
`Float64` objective coefficient, in `\$` per per-unit of dispatch over one dispatch interval.
"""
function price_to_pu_coefficient(price_per_mwh::Float64, base_power::Float64)
    return price_per_mwh * base_power * DISPATCH_INTERVAL_HOURS
end

function price_to_pu_coefficient(container::PSI.OptimizationContainer, price_per_mwh::Float64)
    return price_to_pu_coefficient(price_per_mwh, PSI.get_base_power(container))
end

"""
    dimensionless_factor(factor) -> Float64

Returns `factor` unchanged. A dimensionless multiplier on an already-per-unit quantity — such as
a [`GenericConstraint`](@ref) term's `factor` — carries no MW units and must never be passed
through [`mw_to_pu`](@ref) or [`pu_to_mw`](@ref).

# Arguments
- `factor::Float64`: a dimensionless multiplier.

# Returns
`factor`, unchanged.
"""
function dimensionless_factor(factor::Float64)
    return factor
end
