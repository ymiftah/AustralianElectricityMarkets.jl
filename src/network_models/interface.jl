abstract type NetworkConfiguration end

function table_requirements(::NetworkConfiguration)
    error("Not implemented")
end

function nem_system(db, network_configuration::T) where {T <: NetworkConfiguration}
    error("Not implemented for $(typeof(network_configuration))")
end
