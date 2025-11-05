function nem_system(db, network_configuration::T) where {T <: NetworkConfiguration}
    throw("Not implemented for $(typeof(network_configuration))")
end
