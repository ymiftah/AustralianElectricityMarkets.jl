# AustralianElectricityMarket.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://ymiftah.github.io/AustralianElectricityMarket.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://ymiftah.github.io/AustralianElectricityMarket.jl/dev)
[![Build Status](https://github.com/ymiftah/AustralianElectricityMarket.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/ymiftah/AustralianElectricityMarket.jl/actions/workflows/CI.yml?query=branch%3Amain)

A Julia package for interfacing with data from the Australian Energy Market Operator (AEMO) to simulate the operation of the Australian Electricity Market.

## Description

This package provides a set of tools to fetch, cache, and process data from AEMO's public data sources, particularly through the NEMDB database. It allows users to read various datasets, including interconnector data, regional demand, and generation unit details, and integrates with `PowerSystems.jl` for power system modeling and simulation.

## Installation

To install the package, open the Julia REPL and run:

```julia
using Pkg
Pkg.add("AustralianElectricityMarket")
```

## Usage

Here is a basic example of how to use the package to read demand data:

```julia
using AustralianElectricityMarket
using DuckDB
using DataFrames

# Establish a database connection
db = DBInterface.connect(DuckDB.DB)

# Fetch and read the demand data
demand_df = read_demand(db)

println(demand_df)
```

## Features

*   **Data Fetching:** Fetch data from AEMO's NEMWEB data source for specified time ranges.
*   **Data Caching:** Cache downloaded data locally for faster access.
*   **Data Processing:** Read and process various NEMDB tables, including:
    *   Interconnector data
    *   Regional demand
    *   Generation unit details
*   **PowerSystems.jl Integration:** Parse AEMO data into `PowerSystems.jl` models for simulation.
*   **Flexible Data Backend:** Uses `TidierDB.jl` to support different database backends (e.g., DuckDB).

## Data Sources

This package primarily interfaces with data from the [Australian Energy Market Operator (AEMO)](https://aemo.com.au/). It relies on the [NEMDB](https://github.com/opennem/nemdb) project for accessing and managing the underlying data.

## License

This project is licensed under the [MIT License](LICENSE).
