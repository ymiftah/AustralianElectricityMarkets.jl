"""
    NEMFloatTimeSeriesParameter

Abstract supertype of the time-series parameters whose values are stored as `Float64` in every build mode
and written into constraint coefficients and row bounds.
"""
abstract type NEMFloatTimeSeriesParameter <: PSI.TimeSeriesParameter end

"Time-series parameter whose value is the coefficient of a variable in a constraint row; see `_add_coefficient_target!`."
abstract type NEMConstraintCoefficientParameter <: NEMFloatTimeSeriesParameter end

"Time-series parameter that frees (value 0) or bounds (nonzero) a constraint row; see `_add_bound_target!`."
abstract type NEMConstraintBoundParameter <: NEMFloatTimeSeriesParameter end

# Coefficient of `variable` in `constraint`, `scale * value * multiplier` at `(param_row, time_step)` / `(multiplier_row, time_step)`.
struct _CoefficientTarget
    constraint::JuMP.ConstraintRef
    variable::JuMP.VariableRef
    scale::Float64
    param_row::Int
    multiplier_row::Int
    time_step::Int
end

# Interval bounds `(active_lo, active_hi)` of `constraint`, free where `value * multiplier` is 0.
struct _BoundTarget
    constraint::JuMP.ConstraintRef
    active_lo::Float64
    active_hi::Float64
    param_row::Int
    multiplier_row::Int
    time_step::Int
end
