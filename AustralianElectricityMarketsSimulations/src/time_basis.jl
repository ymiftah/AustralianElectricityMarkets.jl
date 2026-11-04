"""
    interval_hours(resolution::Dates.Period) -> Float64

The length of `resolution` in hours.

# Example
```julia
interval_hours(Minute(30))  # 0.5
```
"""
function interval_hours(resolution::Dates.Period)
    return Dates.value(Dates.Millisecond(resolution)) / 3_600_000
end

"""
    interval_cost_coefficient(price::Real, resolution::Dates.Period = DISPATCH_INTERVAL)

Converts a `\$/MWh` price into an objective coefficient for one interval of length `resolution`.

# Arguments
- `price`: a price in `\$/MWh`.
- `resolution`: the interval length; defaults to one NEM dispatch interval (5 minutes).

# Returns
The coefficient in `\$/MW` for a dispatch variable over one interval, as a `Float64`.

# Example
```julia
interval_cost_coefficient(300.0)              # 25.0
interval_cost_coefficient(300.0, Minute(30))  # 150.0
```
"""
function interval_cost_coefficient(price::Real, resolution::Dates.Period = DISPATCH_INTERVAL)
    return price * interval_hours(resolution)
end

"""
    trading_day_steps(day::Date) -> StepRange{DateTime}

The 288 interval-ending timestamps of the NEM trading day `day`, from 04:05 on `day` to 04:00 on the
next day, in market time.

# Arguments
- `day`: the trading day.

# Returns
A `StepRange{DateTime}` with step [`DISPATCH_INTERVAL`](@ref).

# Example
```julia
trading_day_steps(Date(2026, 1, 1))  # 2026-01-01T04:05 to 2026-01-02T04:00
```
"""
function trading_day_steps(day::Date)
    return (DateTime(day) + Hour(4) + Minute(5)):DISPATCH_INTERVAL:(DateTime(day + Day(1)) + Hour(4))
end

"""
    replay_chunks(steps::StepRange{DateTime}; chunk::Union{Symbol, Dates.Period} = :trading_day) -> Vector{StepRange{DateTime}}

Splits `steps` into consecutive chunks. Each chunk is one financial year and at most one trading day, so it
can be one `PSI.Simulation`.

# Arguments
- `steps`: the interval-ending timestamps to split.
- `chunk`: `:trading_day`, or a `Dates.Period` that is a positive multiple of [`DISPATCH_INTERVAL`](@ref); a
  chunk also starts every `chunk` after its own start.

# Returns
A `Vector` of `StepRange{DateTime}`, one per chunk, that partition `steps`. Throws `ArgumentError` for any
other `chunk`.
"""
function replay_chunks(steps::StepRange{DateTime}; chunk::Union{Symbol, Dates.Period} = :trading_day)
    _check_chunk(chunk)
    starts = DateTime[]
    for t in steps
        starts_trading_day = Time(t) == Time(4, 5)
        starts_financial_year = month(t) == 7 && day(t) == 1 && Time(t) == Time(0, 5)
        periodic = chunk isa Dates.Period && !isempty(starts) && t - last(starts) >= chunk
        (isempty(starts) || starts_trading_day || starts_financial_year || periodic) && push!(starts, t)
    end
    stops = [starts[2:end] .- DISPATCH_INTERVAL; last(steps)]
    return [a:DISPATCH_INTERVAL:b for (a, b) in zip(starts, stops)]
end

# `chunk` is `:trading_day` or a positive whole number of dispatch intervals.
function _check_chunk(chunk)
    chunk === :trading_day && return
    fixed = chunk isa Union{Dates.Week, Dates.Day, Dates.Hour, Dates.Minute, Dates.Second, Dates.Millisecond}
    ms = fixed ? Dates.value(Dates.Millisecond(chunk)) : 0
    (fixed && ms > 0 && ms % Dates.value(Dates.Millisecond(DISPATCH_INTERVAL)) == 0) || throw(
        ArgumentError("replay_chunks: chunk must be :trading_day or a positive multiple of $DISPATCH_INTERVAL, got $chunk."),
    )
    return
end
