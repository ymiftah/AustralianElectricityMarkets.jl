"""
    NEMUnitState(initial_mw, dispatch_mode)

A NEM unit's state at the start of an interval, in natural units.

# Fields
- `initial_mw`: the output at the start of the interval, MW.
- `dispatch_mode`: the fast-start dispatch mode, from 0 to 4.
"""
struct NEMUnitState
    initial_mw::Float64
    dispatch_mode::Int
end
