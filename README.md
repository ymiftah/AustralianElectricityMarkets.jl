# AustralianElectricityMarkets.jl

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://ymiftah.github.io/AustralianElectricityMarkets.jl/stable)
[![Development documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://ymiftah.github.io/AustralianElectricityMarkets.jl/dev)
[![Test workflow status](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/Test.yml/badge.svg?branch=main)](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/Test.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/ymiftah/AustralianElectricityMarkets.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/ymiftah/AustralianElectricityMarkets.jl)
[![Docs workflow Status](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/Documentation.yml/badge.svg?branch=main)](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/Documentation.yml?query=branch%3Amain)
[![BestieTemplate](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/JuliaBesties/BestieTemplate.jl/main/docs/src/assets/badge.json)](https://github.com/JuliaBesties/BestieTemplate.jl)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)

A Julia package for interfacing with the Australian Energy Market Operator (AEMO) data archive.

## Description

This package provides a set of tools to fetch, cache, and process data from AEMO's public data sources, particularly through the NEMWEB data archive. It allows users to read various datasets, and integrates with `PowerSystems.jl` for power system modeling and simulation.

## Installation

To install the package, open the Julia REPL and run:

```julia
using Pkg
Pkg.add(["AustralianElectricityMarkets", "AustralianElectricityMarketsData"])
```

## Usage

Here is a basic example of how to use the package to read demand data:

```julia
using AustralianElectricityMarkets
using AustralianElectricityMarketsData: populate
using Dates

# Establish a database connection
db = aem_connect();

# Download the data from the monthly archive, saving them locally
# in parquet files
# Only the data requirements for a RegionalNetworkConfiguration are downloaded.
populate(
    db, Date(2025, 1, 1), Date(2025, 1, 2);
    tables = table_requirements(RegionalNetworkConfiguration()),
)

demand_df = read_demand(db)
println(demand_df)
```

And parsing the data into `PowerSystems.jl`

```julia
# Instantiate a System
sys = nem_system(db, RegionalNetworkConfiguration())

println(sys)
```

## Features

* **Data Fetching:** Fetch data from AEMO's NEMWEB data source for specified time ranges.
* **Data Processing:** Read and process various NEMDB tables, including:
  * Interconnector data
  * Regional demand
  * Generation unit details
* **PowerSystems.jl Integration:** Parse AEMO data into `PowerSystems.jl` models for simulation.

## Package organization

`AustralianElectricityMarketsData` populates the Hive cache.
`AustralianElectricityMarkets.Readers` reads cached market data and ISP inputs;
its public readers are also available directly from `AustralianElectricityMarkets`.
Both packages share connection and configuration types from
`AustralianElectricityMarketsCache`, without depending on each other.
`AustralianElectricityMarkets` creates and populates `PowerSystems.System`s from cached data.
`AustralianElectricityMarketsSimulations` consumes those systems and supplies typed PSI
formulations and simulation utilities without querying the cache. Top-level `scripts/`
coordinate historical replay and NEMDE comparisons. See the
[dispatch replay guide](docs/src/dispatch_replay.md) for the construction and PSI lifecycle.

The root source folders separate types and their methods (`types/`), external-data
readers (`readers/`), system construction and modification (`system/`), and attached
component data lookup (`accessors/`). Domain categories appear as filenames within
these folders.

## Continuous integration

Each package has its own GitHub Actions workflow with native `paths` filters:
`Test.yml` (AEM), `TestCache.yml`, `TestData.yml` and `TestSimulations.yml`.
Matching pull requests and pushes to `main` run that package's suite on Julia
1.11, 1.12 and `pre`. Filters include source consumers: Cache changes run all four
packages, AEM changes run AEM and Simulations, and Data changes run Data and AEM,
whose package-boundary tests exercise Data. Changes confined to a package's tests
run that package, except shared fixtures, which trigger the suites that use them. Repository
replay scripts and their integration tests also trigger the Simulations workflow.

Workspace dependency files, coverage configuration and test CI changes select all packages. Documentation
and other unrelated changes skip Julia tests. Tags test all packages.
Manual runs test the package belonging to the dispatched workflow.
Coverage is collected only on Julia 1.11, separately for each package.
Codecov carries forward the last uploaded coverage for packages whose workflows
were skipped. All four packages must upload coverage once to establish a baseline.

Test workflow customizations must be preserved when updating the Bestie template.

## Data Sources

This package primarily interfaces with data from the [Australian Energy Market Operator (AEMO)](https://aemo.com.au/). It relies on the [NEMWEB](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/data-nem/market-data-nemweb) data archives and data models.

## License

This project is licensed under the BSD-3 License.
