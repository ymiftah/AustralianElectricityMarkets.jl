"""
    FastStartModeTimeSeriesParameter

Time-series parameter of the starting fast-start dispatch mode of each unit with a fast-start profile
(`has_fast_start_profile`), read from the `"fast_start_start_mode"` series of `NEM_FAST_START_SERIES`. A
model of a fast-start run ([`nem_dispatch_sequence`](@ref)) adds it, and its per-step update sets the unit's
fast-start rows for the interval.
"""
struct FastStartModeTimeSeriesParameter <: PSI.TimeSeriesParameter end


"""
    FastStartCommitmentTargetParameter

The affected value of the dispatch run's `PSI.FixValueFeedforward` in [`nem_dispatch_sequence`](@ref): the
`FixValueParameter` the feedforward adds carries the commitment run's energy targets, which set the fast-start
rows, and fixes no variable.
"""
struct FastStartCommitmentTargetParameter <: PSI.ParameterType end


"""
    FAST_START_COMMITMENT_NAME

The name of the commitment run's decision model in [`nem_dispatch_sequence`](@ref): `"fast_start_commitment"`.
"""
const FAST_START_COMMITMENT_NAME = "fast_start_commitment"


# The two runs of NEMDE's fast-start dispatch, as the `"fast_start_run"` setting of a model holds them.
const _FAST_START_RUNS = ("commitment", "dispatch")
