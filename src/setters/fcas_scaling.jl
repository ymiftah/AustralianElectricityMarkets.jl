"""
    _fcas_scaling_devices(sys)

Every available `Generator` and `EnergyReservoirStorage` in `sys` - the device population
[`set_fcas_bids!`](@ref) attaches FCAS bid series to, and so the population
[`set_fcas_scaling_inputs!`](@ref) mirrors.

# Returns
A `Vector{Device}`.
"""
function _fcas_scaling_devices(sys)
    devices = Device[]
    append!(devices, collect(get_components(get_available, Generator, sys)))
    append!(devices, collect(get_components(get_available, EnergyReservoirStorage, sys)))
    return devices
end

"""
    _attach_fcas_scaling_series!(sys, device, by_time, full_grid, col, name, base_power; scale = 1.0)

Attaches a `SingleTimeSeries` named `name` to `device`, per-unitised by `base_power` and
`scale`, from `by_time[t][col]` at every `t` in `full_grid`. No-op (and leaves `device`
untouched) if `device` has no row in `by_time` for every `t`, or if any of those rows has a
`missing` value for `col` - AEMO's *FCAS Model in NEMDE* §4.1/§4.2 "zero or absent" rule
means an incomplete scaling input series is the same as no scaling.

# Returns
`nothing`.
"""
function _attach_fcas_scaling_series!(
        sys, device, by_time, full_grid::Vector, col::Symbol, name::AbstractString,
        base_power::Float64; scale::Float64 = 1.0,
    )
    values = Float64[]
    for t in full_grid
        row = get(by_time, t, nothing)
        (isnothing(row) || ismissing(row[col])) && return nothing
        push!(values, row[col] * scale / base_power)
    end
    add_time_series!(
        sys, device, SingleTimeSeries(; name = name, data = TimeArray(full_grid, values)),
    )
    return nothing
end

"""
    set_fcas_scaling_inputs!(sys, db, date_range; kwargs...)

Attaches per-device, per-interval [`FCASTrapezium`](@ref) scaling inputs (AEMO *FCAS Model in
NEMDE* §4) and the §5 AGC-status pre-condition input to every available `Generator` and
`EnergyReservoirStorage` in `sys`, read from [`read_fcas_scaling_inputs`](@ref)/[`read_uigf`](@ref):

- `"fcas_agc_enablement_min_RAISEREG"`/`"fcas_agc_enablement_max_RAISEREG"` from
  `RAISEREGENABLEMENTMIN`/`RAISEREGENABLEMENTMAX` (§4.1);
- `"fcas_agc_enablement_min_LOWERREG"`/`"fcas_agc_enablement_max_LOWERREG"` from
  `LOWERREGENABLEMENTMIN`/`LOWERREGENABLEMENTMAX` (§4.1);
- `"fcas_agc_max_avail_RAISEREG"`/`"fcas_agc_max_avail_LOWERREG"` from `RAMPUPRATE`/
  `RAMPDOWNRATE` (MW/h), multiplied by the interval length in hours taken from `date_range`'s
  step (§4.2);
- `"fcas_agc_status"` from `AGCSTATUS` (§5: `1` while the unit is under AGC control, `0`
  otherwise), not per-unitized;
- `"fcas_uigf"` from `UIGF`, for semi-scheduled units only (§4.3).

Every series but `"fcas_agc_status"` is per-unit of `sys`'s system base, read back by
[`get_scaled_fcas_trapezium`](@ref); `"fcas_agc_status"` carries AGCSTATUS's raw `0`/`1` value,
read back by [`get_fcas_agc_status`](@ref). A device with an incomplete series over
`date_range` (a missing interval, or a `missing` source value at some interval) is left
without that series rather than partially attached - reading it back then finds the series
absent, which AEMO's §4.1/§4.2 "zero or absent" rule already treats as no scaling on that leg,
and [`get_fcas_agc_status`](@ref)'s caller treats as AGC status unknown.

# Arguments
- `sys`: the `System` to add to.
- `db`: an `AEMDB` connection.
- `date_range`: the dispatch intervals to replay.
- `kwargs`: passed to [`read_fcas_scaling_inputs`](@ref)/[`read_uigf`](@ref) (e.g.
  `intervention`).

# Returns
`nothing`.
"""
function set_fcas_scaling_inputs!(sys, db, date_range; kwargs...)
    base_power = get_base_power(sys)
    full_grid = collect(date_range)[1:(end - 1)]
    interval_hours = Dates.value(Millisecond(step(date_range))) / (1000 * 60 * 60)

    scaling_rows = read_fcas_scaling_inputs(db, date_range; kwargs...)
    by_duid = DataFrames.isempty(scaling_rows) ? nothing : groupby(scaling_rows, :DUID)
    uigf_rows = read_uigf(db, date_range; kwargs...)
    uigf_by_duid = DataFrames.isempty(uigf_rows) ? nothing : groupby(uigf_rows, :DUID)

    for device in _fcas_scaling_devices(sys)
        duid = get_name(device)

        if !isnothing(by_duid) && haskey(by_duid, (duid,))
            by_time = Dict(zip(by_duid[(duid,)].SETTLEMENTDATE, eachrow(by_duid[(duid,)])))
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAISEREGENABLEMENTMIN,
                "fcas_agc_enablement_min_RAISEREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAISEREGENABLEMENTMAX,
                "fcas_agc_enablement_max_RAISEREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :LOWERREGENABLEMENTMIN,
                "fcas_agc_enablement_min_LOWERREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :LOWERREGENABLEMENTMAX,
                "fcas_agc_enablement_max_LOWERREG", base_power,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAMPUPRATE,
                "fcas_agc_max_avail_RAISEREG", base_power; scale = interval_hours,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :RAMPDOWNRATE,
                "fcas_agc_max_avail_LOWERREG", base_power; scale = interval_hours,
            )
            _attach_fcas_scaling_series!(
                sys, device, by_time, full_grid, :AGCSTATUS, "fcas_agc_status", 1.0,
            )
        end

        if !isnothing(uigf_by_duid) && haskey(uigf_by_duid, (duid,))
            by_time = Dict(zip(uigf_by_duid[(duid,)].SETTLEMENTDATE, eachrow(uigf_by_duid[(duid,)])))
            _attach_fcas_scaling_series!(sys, device, by_time, full_grid, :UIGF, "fcas_uigf", base_power)
        end
    end
    return
end
