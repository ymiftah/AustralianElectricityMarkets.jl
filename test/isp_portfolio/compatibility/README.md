# Investment portfolio compatibility gate

This isolated Julia 1.13.3 environment tests PSIP data interfaces alongside the existing
operational package set. Its manifest pins all resolved dependencies. PSIP is revision
`c1150d6eadaa3d28f36575e7232d8d77dc722cca`, PSINV is revision
`7874984b6fa53e0463931c8e769c0e356df71910`, PowerSystems is 5.12.4,
InfrastructureSystems is 3.6.3, and the PowerSimulations fork is revision
`fc30a298afb314d563488db852387e145ec97f9a`. The PSINV import is a package-loading
check, not an optimisation solve or proof of formulation support.

Set `TMPDIR` to a disk-backed directory before running. From the repository root:

```sh
julia --startup-file=no --project=test/isp_portfolio/compatibility -e 'using Pkg; Pkg.instantiate()'
JULIA_LOAD_PATH='@:@stdlib' julia --startup-file=no --project=test/isp_portfolio/compatibility test/isp_portfolio/compatibility/check.jl
JULIA_LOAD_PATH='@:@stdlib' julia --startup-file=no --project=test/isp_portfolio/compatibility/Boundary test/isp_portfolio/compatibility/absent.jl
```

The miniature `PortfolioBoundary` package tests Julia's extension mechanism independently
of AEM. It is not an implementation of AEM's future extension. The main check covers
registered regions, technologies and requirements, a technology requirement association,
an existing PSY device, time-series retrieval and a JSON/HDF5 serialization round trip.
