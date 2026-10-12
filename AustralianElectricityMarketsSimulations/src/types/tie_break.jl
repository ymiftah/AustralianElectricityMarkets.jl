# One energy band: its reference-node price, per-unit width and PSI block variable.
const _TieBand = @NamedTuple{price::Float64, width::Float64, var::JuMP.VariableRef, name::String, band::Int}
