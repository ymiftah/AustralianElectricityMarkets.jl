"""
    NEMUnitConstraint

Constraint type of the unit rows of an [`AbstractNEMDispatch`](@ref) formulation, one container per
device type and row. The key meta names the row, composed with the row's own container meta after a
`|`:

- `"offer_band|gen"` and `"offer_band|load"`: `dispatch == Σ bands + surplus - deficit` for one device and
  interval, over its [`EnergyOfferBandVariable`](@ref)s. Meta `"gen"` or `"load"` for the offer's side.
- `"max_avail"`, `"uigf"`, `"max_avail_out"` and `"max_avail_in"`: the energy availability rows, the
  dispatch less its surplus at most the live limit. `"max_avail_in"` is the charging side of a battery.
- `"fixed_load|upper"` and `"fixed_load|lower"`: AEMO's Energy Inflexible Offer rows (*Schedule of
  Constraint Violation Penalty Factors* v8.0, item 13, "Unit = X MW") holding a unit's net energy at its
  fixed loading.
"""
struct NEMUnitConstraint <: PSI.ConstraintType end
