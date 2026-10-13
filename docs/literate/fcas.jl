# # [Inspect an FCAS interval](@id fcas-requirement-reading)
#
# This page reads the offers, requirements, enablement and prices of one dispatch interval
# from the cache. For what the quantities mean, see
# [FCAS capability and co-optimisation](@ref nemde-fcas); for the tables behind each reader,
# see [Where the data lives](@ref fcas-types-mapping).
#
# The example is the interval ending 16:30 on 13 January 2025 in Tasmania. It needs a cache
# holding the bid, dispatch and constraint tables for that month, and the earlier months in
# which the constraint definitions were published.
#
# ## Offers and outcomes of one unit
#
# ```julia
# using AustralianElectricityMarkets, Dates, DataFrames
#
# db = aem_connect()
# interval = DateTime(2025, 1, 13, 16, 30)
# window = interval:Minute(5):(interval + Minute(5))
#
# bids = read_fcas_bids(db, window, BidType.LOWER6SEC)
# unit_bid = subset(bids, :DUID => ByRow(==("TUNGATIN")))
#
# outcomes = read_fcas_dispatch(db, window; intervention = 0)
# unit_outcomes = subset(outcomes, :DUID => ByRow(==("TUNGATIN")))
# ```
#
# `unit_bid` holds the five trapezium parameters and the band quantities. `unit_outcomes`
# holds the unit's enablement in each service. To check an enablement against the trapezium,
# apply the joint capacity constraints of
# [Energy and FCAS together](@ref fcas-cooptimisation) at the unit's energy target, with its
# regulation enablement from the same row.
#
# ## Requirements and prices of a region
#
# ```julia
# requirements = read_fcas_requirements(db, window; intervention = 0)
# tas_requirements = subset(requirements, :REGIONID => ByRow(==("TAS1")))
# prices = read_fcas_prices(db, window; intervention = 0)
# ```
#
# `tas_requirements` lists every requirement that covers Tasmania, per service, with its
# marginal value. Several usually apply to one service. Their marginal values sum to the
# price in `prices`, as described in [FCAS prices](@ref fcas-pricing).
#
# ## The definition of a requirement
#
# A requirement's name and right-hand side do not say what it requires. Its sense and its
# terms do.
#
# ```julia
# invoked = read_invoked_constraints(db, window; intervention = 0)
# definitions = read_constraint_definitions(db, invoked)
# terms = read_constraint_terms(db, invoked, window)
# ```
#
# `definitions` gives the sense (`<=`, `>=` or `=`) and the penalty factor of each
# constraint in force. `terms` gives its coefficients. For a `>=` requirement with a
# right-hand side of 137.5 MW and a left-hand side of 129.65 MW, the shortfall is 7.85 MW.
# The same numbers under a `<=` sense would mean the constraint is slack.
#
# ## Who was enabled
#
# ```julia
# providers = subset(outcomes, :BIDTYPE => ByRow(==(BidType.RAISE6SEC)), :TARGET => ByRow(>(0)))
# units = read_units(db)  # join on DUID to keep the providers of one region
# ```
#
# The published enablement shows which units were used. The offers alone do not: a cheaper
# unit can be left out because it is stranded, or because its energy target leaves it no
# headroom.
