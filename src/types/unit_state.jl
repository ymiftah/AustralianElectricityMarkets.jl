"""
    NEMUnitState(initial_mw, dispatch_mode, time_in_mode = 0.0)

A NEM unit's state at the start of an interval, in natural units.

# Fields
- `initial_mw`: the output at the start of the interval, MW.
- `dispatch_mode`: the fast-start dispatch mode, from 0 to 4.
- `time_in_mode`: the minutes already spent in `dispatch_mode`, capped at the mode's length of the fast-start
  profile and zero in mode 0 or for a unit without a fast-start profile.
"""
struct NEMUnitState
    initial_mw::Float64
    dispatch_mode::Int
    time_in_mode::Float64
end

NEMUnitState(initial_mw::Real, dispatch_mode::Integer) = NEMUnitState(initial_mw, dispatch_mode, 0.0)
