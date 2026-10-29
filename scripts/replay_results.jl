# Results post-processing for replay simulations: solved prices, dispatch, interconnector flows,
# FCAS prices and constraint violations, read through the realized results of a simulation or the
# solved results of a model. Included by the replay workflow and the simulation tests.

module ReplayResults

using AustralianElectricityMarkets: BidType, FCASService, GenericConstraint, fcas_upper_regulation_service,
    get_bid_type, get_fcas_requirements, get_region, get_service
using AustralianElectricityMarketsSimulations
using Chain
using DataFrames
using Dates
import PowerSimulations as PSI
import PowerSystems as PSY

export replication_results, compute_fcas_prices

# PSI ignores a failed dual LP and leaves the duals NaN, so check them before reporting prices.
function _check_prices_finite(prices::DataFrame)
    bad = prices[.!isfinite.(prices.ROP), :]
    isempty(bad) || error(
        "Interval $(minimum(bad.SETTLEMENTDATE)) has non-finite regional price duals; the dual pass failed.",
    )
    return
end


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


# The long-format (`DateTime`, `name`, `value`) frame of each of `keys`: solved values of a model,
# realized values of a simulation's decision problem.
function _read_variable_frames(results::PSI.OptimizationProblemResults, keys)
    return Dict(key => PSI.read_variable(results, key) for key in keys)
end
function _read_variable_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.VariableKey, DataFrame}()
    names = Dict(key => PSI.IS.Optimization.encode_key_as_string(key) for key in keys)
    vals = PSI.read_realized_variables(results, collect(values(names)))
    return Dict(key => vals[name] for (key, name) in names)
end


# The stamps at which `sys`'s generic constraint `name` is invoked.
function _invoked_stamps(sys::PSY.System, name::AbstractString)
    ts = PSY.get_time_series(PSY.SingleTimeSeries, PSY.get_component(GenericConstraint, sys, name), "invoked")
    data = PSY.get_data(ts)
    return Set(t for (t, v) in zip(PSY.TimeSeries.timestamp(data), PSY.TimeSeries.values(data)) if v != 0.0)
end


# `family`, `name`, `DateTime`, `MW`, `direction` and `variable` (the slack variable's key) of
# every slack above the tolerance, in every interval and every family of `_VIOLATION_FAMILIES`;
# a generic constraint's slack counts only where it is invoked.
function _constraint_violations(
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
            push!(rows, (; family = kind[1], name = r.name, DateTime = r.DateTime, MW = r.value, direction, variable = string(key)))
        end
    end
    return DataFrame(rows)
end


# `DUID`, `DateTime`, `MW` and `direction` of every non-zero unit ramp slack, from the
# `_constraint_violations` table.
function _ramp_violations(violations::DataFrame)
    ramp = violations[violations.family .== "unit_ramp", :]
    return DataFrame(DUID = ramp.name, DateTime = ramp.DateTime, MW = ramp.MW, direction = ramp.direction)
end


"MW of slack below which a constraint row counts as satisfied."
const _VIOLATION_TOLERANCE_MW = 1.0e-6


# Each dispatch variable's sign in net MW: generation (or discharge) minus charge.
const _DISPATCH_SIGNS = Dict(
    PSI.ActivePowerVariable => 1.0, PSI.ActivePowerOutVariable => 1.0, PSI.ActivePowerInVariable => -1.0,
)


function _read_balance_duals(results::PSI.OptimizationProblemResults)
    return PSI.read_dual(results, PSI.CopperPlateBalanceConstraint, PSY.Area)
end
function _read_balance_duals(results::PSI.SimulationProblemResults)
    return only(values(PSI.read_realized_duals(results, [PSI.ConstraintKey(PSI.CopperPlateBalanceConstraint, PSY.Area)])))
end


# Solved output tables over every interval of `results`: `prices`
# (`SETTLEMENTDATE`, `REGIONID`, `ROP`), `dispatch` (`DUID`, net `TOTALCLEARED`), `interconnectors`
# (`INTERCONNECTORID`, `MWFLOW`, `MWLOSSES`) and `fcas_prices` ([`compute_fcas_prices`](@ref)).
# With `:losses` in `parts`, the interchange flow and loss variables must be in `results`.
function _solved_tables(results, sys::PSY.System, parts)
    keys_of(T, C) = [
        k for k in PSI.list_variable_keys(results)
            if PSI.IS.Optimization.get_entry_type(k) === T && (isnothing(C) || PSI.IS.Optimization.get_component_type(k) === C)
    ]
    interchange_keys = [only(keys_of(T, PSY.AreaInterchange)) for T in (PSI.FlowActivePowerVariable, InterconnectorLossVariable) if !isempty(keys_of(T, PSY.AreaInterchange))]
    if :losses in parts && !isempty(PSY.get_components(PSY.get_available, PSY.AreaInterchange, sys)) && length(interchange_keys) != 2
        error("Losses are modeled but the results lack the AreaInterchange flow or loss variables.")
    end
    dispatch_keys = PSI.VariableKey[k for T in keys(_DISPATCH_SIGNS) for k in keys_of(T, nothing)]
    frames = _read_variable_frames(results, [dispatch_keys; interchange_keys])

    # A balance dual is per per-unit-interval; dividing gives $/MWh.
    scale = PSY.get_base_power(sys) * interval_hours(DISPATCH_INTERVAL)
    prices = @chain _read_balance_duals(results) begin
        select(:DateTime => :SETTLEMENTDATE, :name => :REGIONID, :value => ByRow(v -> v / scale) => :ROP)
    end
    signed = [transform(frames[k], :value => (v -> _DISPATCH_SIGNS[PSI.IS.Optimization.get_entry_type(k)] .* v) => :value) for k in dispatch_keys]
    dispatch = @chain reduce(vcat, signed; init = DataFrame(DateTime = DateTime[], name = String[], value = Float64[])) begin
        groupby([:DateTime, :name])
        combine(:value => sum => :TOTALCLEARED)
        rename(:DateTime => :SETTLEMENTDATE, :name => :DUID)
    end
    interconnectors = if length(interchange_keys) == 2
        flow, loss = (rename(frames[k], :value => c) for (k, c) in zip(interchange_keys, (:MWFLOW, :MWLOSSES)))
        @chain flow begin
            leftjoin(loss; on = [:DateTime, :name])
            rename(:DateTime => :SETTLEMENTDATE, :name => :INTERCONNECTORID)
        end
    else
        DataFrame(SETTLEMENTDATE = DateTime[], INTERCONNECTORID = String[], MWFLOW = Float64[], MWLOSSES = Union{Missing, Float64}[])
    end
    fcas_prices = compute_fcas_prices(results, sys; resolution = DISPATCH_INTERVAL)
    return (; prices, dispatch, interconnectors, fcas_prices)
end


"""
    replication_results(results, sys::PSY.System; parts = REPLICATION_PARTS) -> NamedTuple

Extracts solved dispatch, prices, interconnector flows and constraint violations from PSI
results using the system's attached component metadata.

# Arguments
- `results`: PSI optimisation or simulation problem results.
- `sys`: the system used by the model.
- `parts`: the [`REPLICATION_PARTS`](@ref) used by the model.

# Returns
A named tuple of `solved` tables, `constraint_violations` and `ramp_violations`.
Throws when required model outputs are missing or regional price duals are non-finite.
"""
function replication_results(results, sys::PSY.System; parts = REPLICATION_PARTS)
    check_replication_parts(parts)
    solved = _solved_tables(results, sys, parts)
    _check_prices_finite(solved.prices)
    constraint_violations = _constraint_violations(results, sys)
    return (; solved, constraint_violations, ramp_violations = _ramp_violations(constraint_violations))
end


# Each key's long-format frame (`DateTime`, `value`): solved values, or realized ones of a simulation.
_read_dual_frames(results::PSI.OptimizationProblemResults, keys) = Dict(key => PSI.read_dual(results, key) for key in keys)
# Opens the simulation store once for all `keys`, over the window `read_realized_duals` reads.
function _read_dual_frames(results::PSI.SimulationProblemResults, keys)
    isempty(keys) && return Dict{PSI.OptimizationContainerKey, DataFrame}()
    vals = PSI.read_realized_duals(results, collect(keys))
    return Dict(key => vals[PSI.IS.Optimization.encode_key_as_string(key)] for key in keys)
end


"""
    compute_fcas_prices(results, sys; resolution = nothing) -> DataFrame

Maps solved [`NEMConstraintLimit`](@ref) duals onto regional FCAS prices: each `(region, service)`
`ROP` is the sum of the duals of every built [`GenericConstraint`](@ref) whose
[`get_fcas_requirements`](@ref) names that pair, in `\$/MWh`. This mirrors the sum of
`DISPATCH_FCAS_REQ`'s `MARGINALVALUE` (see [`read_fcas_prices`](@ref)). Duals keep the solver's
sign (change in cost per unit increase of the right-hand side): non-negative for a binding `>=`
constraint, non-positive for `<=`. Warns when a constraint with requirements has no recorded dual.

# Arguments
- `results`: `PSI.OptimizationProblemResults` of a model, or `PSI.SimulationProblemResults` of a
  simulation (its realized duals), that recorded `NEMConstraintLimit` duals.
- `sys`: the `System` the model was built from.
- `resolution`: interval length converting per-interval duals to `\$/MWh`. Defaults to the
  resolution the results record, which a single-interval solve does not; required then.

# Returns
A `DataFrame` with `SETTLEMENTDATE`, `REGIONID`, `BIDTYPE` and `ROP`, like [`read_fcas_prices`](@ref).
"""
function compute_fcas_prices(
        results::Union{PSI.OptimizationProblemResults, PSI.SimulationProblemResults}, sys::PSY.System;
        resolution::Union{Nothing, Dates.Period} = nothing,
    )
    resolution = something(resolution, PSI.get_resolution(results), Some(nothing))
    isnothing(resolution) && throw(
        ArgumentError(
            "compute_fcas_prices: `results` do not record a resolution (a single-interval model), so pass `resolution` explicitly.",
        ),
    )
    dual_keys = Dict(
        k.meta => k for k in PSI.list_dual_keys(results) if PSI.IS.Optimization.get_entry_type(k) === NEMConstraintLimit
    )
    scale = PSY.get_base_power(sys) * interval_hours(resolution)
    prices = Dict{Tuple{String, BidType}, DataFrame}()
    constrained = [gc for gc in PSY.get_components(GenericConstraint, sys) if !isempty(get_fcas_requirements(gc))]
    unrecorded = [PSY.get_name(gc) for gc in constrained if !haskey(dual_keys, PSY.get_name(gc))]
    recorded = [gc for gc in constrained if haskey(dual_keys, PSY.get_name(gc))]
    duals = _read_dual_frames(results, [dual_keys[PSY.get_name(gc)] for gc in recorded])
    for gc in recorded
        dual = duals[dual_keys[PSY.get_name(gc)]]
        for req in get_fcas_requirements(gc)
            id = (get_region(req), get_service(req))
            term = DataFrame(; SETTLEMENTDATE = dual.DateTime, ROP = dual.value ./ scale)
            haskey(prices, id) ? (prices[id].ROP .+= term.ROP) : (prices[id] = term)
        end
    end
    isempty(unrecorded) || @warn(
        "compute_fcas_prices: $(length(unrecorded)) GenericConstraint(s) with FCAS requirements " *
            "have no NEMConstraintLimit dual and are left out: $(join(first(sort!(unrecorded), 5), ", "))" *
            (length(unrecorded) > 5 ? ", ..." : ".")
    )
    out = DataFrame(; SETTLEMENTDATE = DateTime[], REGIONID = String[], BIDTYPE = BidType[], ROP = Float64[])
    for ((region, service), df) in sort!(collect(prices); by = p -> (p[1][1], string(p[1][2])))
        append!(out, DataFrame(; SETTLEMENTDATE = df.SETTLEMENTDATE, REGIONID = region, BIDTYPE = service, ROP = df.ROP))
    end
    return out
end

end
