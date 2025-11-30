# AustralianElectricityMarkets.jl

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://ymiftah.github.io/AustralianElectricityMarkets.jl/stable)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://ymiftah.github.io/AustralianElectricityMarkets.jl/dev)
[![Build Status](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)

A Julia package for interfacing with the Australian Energy Market Operator (AEMO) data archive.

## Description

This package provides a set of tools to fetch, cache, and process data from AEMO's public data sources, particularly through the NEMWEB dataarchive. It allows users to read various datasets, and integrates with `PowerSystems.jl` for power system modeling and simulation.

## Installation

To install the package, open the Julia REPL and run:

```julia
using Pkg
Pkg.add("AustralianElectricityMarkets")
```

## Usage

Here is a basic example of how to use the package to read demand data:

```julia
using AustralianElectricityMarkets
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
*   **Data Processing:** Read and process various NEMDB tables, including:
    *   Interconnector data
    *   Regional demand
    *   Generation unit details
*   **PowerSystems.jl Integration:** Parse AEMO data into `PowerSystems.jl` models for simulation.

## Data Sources

This package primarily interfaces with data from the [Australian Energy Market Operator (AEMO)](https://aemo.com.au/). It relies on the [NEMWEB](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/data-nem/market-data-nemweb) data archives and data models.

## License

This project is licensed under the [MIT License](LICENSE).
