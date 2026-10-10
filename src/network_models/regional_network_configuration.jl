"""
    Each australian State (i.e. AEMO Region) is a combination of a load node and a generator node. The load nodes are connected.
    between states by interconnectors
"""
struct RegionalNetworkConfiguration <: NetworkConfiguration end


"""
    table_requirements(::RegionalNetworkConfiguration)


    :INTERCONNECTOR,
    :INTERCONNECTORCONSTRAINT,
    :DISPATCHREGIONSUM,
    :DUDETAIL,
    :DUDETAILSUMMARY,
    :STATION,
    :STATIONOPERATINGSTATUS,
    :GENUNITS,
    :DUALLOC,
    :BIDDAYOFFER_D,
    :BIDPEROFFER_D,
"""
AustralianElectricityMarkets.table_requirements(::RegionalNetworkConfiguration) = [
    :INTERCONNECTOR,
    :INTERCONNECTORCONSTRAINT,
    :DISPATCHREGIONSUM,
    :DUDETAIL,
    :DUDETAILSUMMARY,
    :STATION,
    :STATIONOPERATINGSTATUS,
    :GENUNITS,
    :DUALLOC,
    :BIDDAYOFFER_D,
    :BIDPEROFFER_D,
]

AustralianElectricityMarkets.nem_system(db, ::RegionalNetworkConfiguration; kwargs...) = nem_system(db; kwargs...)

export RegionalNetworkConfiguration
