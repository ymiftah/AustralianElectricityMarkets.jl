"""
    Each australian State (i.e. AEMO Region) is a combination of a load node and a generator node. The load nodes are connected.
    between states by interconnectors.
    Suitable for standard ED/UC studies with "standard" PSI templates.
"""
struct RegionalNetworkConfiguration <: NetworkConfiguration end
