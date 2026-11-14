using Test
pushfirst!(LOAD_PATH, joinpath(@__DIR__, "Boundary"))
using PortfolioBoundary
@test Base.find_package("PowerSystemsInvestmentsPortfolios") === nothing
@test Base.get_extension(PortfolioBoundary, :PortfolioBoundaryPSIPExt) === nothing
@test_throws MethodError PortfolioBoundary.portfolio_type()
