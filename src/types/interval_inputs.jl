"""
One dispatch interval's NEMDE inputs, read from the NEMWEB archive.

Every field is a historical measurement for `settlement_date`.
`settlement_date` is the **end** of the interval, matching NEMWEB convention.

# Fields
- `settlement_date`: interval end.
- `initial_mw`: `DUID -> INITIALMW`, the metered output at interval start (the ramp base).
- `demand`: `REGIONID -> TOTALDEMAND`.
- `uigf`: `DUID -> UIGF`, semi-scheduled weather forecast. Absent for scheduled units.
- `interconnector_flows`: `INTERCONNECTORID -> MWFLOW`, the flow NEMDE targeted for the interval
  (the metered flow at interval start is `METEREDMWFLOW`).
- `intervention`: 0 for the pricing run, 1 for the physical run.
"""
struct IntervalInputs
    settlement_date::DateTime
    initial_mw::Dict{String, Float64}
    demand::Dict{String, Float64}
    uigf::Dict{String, Float64}
    interconnector_flows::Dict{String, Float64}
    intervention::Int
end
