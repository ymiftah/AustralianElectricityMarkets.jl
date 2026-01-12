


# AustralianElectricityMarkets.jl {#AustralianElectricityMarkets.jl}

[<img src="https://img.shields.io/badge/docs-stable-blue.svg" alt="Stable">
](https://ymiftah.github.io/AustralianElectricityMarkets.jl/stable) [<img src="https://img.shields.io/badge/docs-dev-blue.svg" alt="Dev">
](https://ymiftah.github.io/AustralianElectricityMarkets.jl/dev) [<img src="https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/CI.yml/badge.svg?branch=main" alt="Build Status">
](https://github.com/ymiftah/AustralianElectricityMarkets.jl/actions/workflows/CI.yml?query=branch%3Amain) [<img src="https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black" alt="code style: runic">
](https://github.com/fredrikekre/Runic.jl)

A Julia package for interfacing with the Australian Energy Market Operator (AEMO) data archive.

## Description {#Description}

This package provides a set of tools to fetch, cache, and process data from AEMO&#39;s public data sources, particularly through the NEMWEB data archive. It allows users to read various datasets, and integrates with `PowerSystems.jl` for power system modeling and simulation.

## Installation {#Installation}

To install the package, open the Julia REPL and run:

```julia
using Pkg
Pkg.add("AustralianElectricityMarkets")
```


## Usage {#Usage}

Here is a basic example of how to use the package to read demand data:

```julia
using AustralianElectricityMarkets
using TidierDB

# Establish a database connection
db = connect(duckdb());

# Download the data from the monthly archive, saving them locally
# in parquet files
# Only the data requirements for a RegionalNetworkconfiguration are downloaded.
date_range = Date(2025, 1, 1):Date(2025, 1, 2)
fetch_table_data(date_range, RegionalNetworkConfiguration())

demand_df = read_demand(db)
println(demand_df)
```


And parsing the data into `PowerSystems.jl`

```julia
# Instantiate a System
sys = nem_system(db, RegionalNetworkConfiguration())

println(demand_df)
```


## Features {#Features}
- **Data Fetching:** Fetch data from AEMO&#39;s NEMWEB data source for specified time ranges.
  
- **Data Processing:** Read and process various NEMDB tables, including:
  - Interconnector data
    
  - Regional demand
    
  - Generation unit details
    
  
- **PowerSystems.jl Integration:** Parse AEMO data into `PowerSystems.jl` models for simulation.
  

## Data Sources {#Data-Sources}

This package primarily interfaces with data from the [Australian Energy Market Operator (AEMO)](https://aemo.com.au/). It relies on the [NEMWEB](https://www.aemo.com.au/energy-systems/electricity/national-electricity-market-nem/data-nem/market-data-nemweb) data archives and data models.

## License {#License}

This project is licensed under the MIT License.

## Index {#Index}
- [`AustralianElectricityMarkets.HiveConfiguration`](#AustralianElectricityMarkets.HiveConfiguration)
- [`AustralianElectricityMarkets.RegionModel.RegionalNetworkConfiguration`](#AustralianElectricityMarkets.RegionModel.RegionalNetworkConfiguration)
- [`AustralianElectricityMarkets.RegionModel._add_branches!`](#AustralianElectricityMarkets.RegionModel._add_branches!-Tuple{Any,%20Any})
- [`AustralianElectricityMarkets.RegionModel._add_buses!`](#AustralianElectricityMarkets.RegionModel._add_buses!-Tuple{Any,%20Any})
- [`AustralianElectricityMarkets.RegionModel._add_generation!`](#AustralianElectricityMarkets.RegionModel._add_generation!-Tuple{Any,%20Any})
- [`AustralianElectricityMarkets.RegionModel._add_loads!`](#AustralianElectricityMarkets.RegionModel._add_loads!-Tuple{Any,%20Any})
- [`AustralianElectricityMarkets.RegionModel.get_branch_dataframe`](#AustralianElectricityMarkets.RegionModel.get_branch_dataframe-Tuple{Any})
- [`AustralianElectricityMarkets.RegionModel.get_bus_dataframe`](#AustralianElectricityMarkets.RegionModel.get_bus_dataframe-Tuple{Any})
- [`AustralianElectricityMarkets.RegionModel.get_generators_dataframe`](#AustralianElectricityMarkets.RegionModel.get_generators_dataframe-Tuple{Any})
- [`AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe`](#AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe-Tuple{Any})
- [`AustralianElectricityMarkets.RegionModel.get_load_dataframe`](#AustralianElectricityMarkets.RegionModel.get_load_dataframe-Tuple{Any})
- [`AustralianElectricityMarkets.RegionModel.nem_system`](#AustralianElectricityMarkets.RegionModel.nem_system-Tuple{Any})
- [`AustralianElectricityMarkets._add_demand_ts_to_components!`](#AustralianElectricityMarkets._add_demand_ts_to_components!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets._add_renewable_ts_to_components!`](#AustralianElectricityMarkets._add_renewable_ts_to_components!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets._as_timearray`](#AustralianElectricityMarkets._as_timearray-NTuple{4,%20Any})
- [`AustralianElectricityMarkets._filter_latest`](#AustralianElectricityMarkets._filter_latest-Tuple{Any})
- [`AustralianElectricityMarkets._filter_latest`](#AustralianElectricityMarkets._filter_latest-Tuple{Any,%20Any})
- [`AustralianElectricityMarkets._parse_hive_root`](#AustralianElectricityMarkets._parse_hive_root-Tuple{AustralianElectricityMarkets.HiveConfiguration})
- [`AustralianElectricityMarkets.read_demand`](#AustralianElectricityMarkets.read_demand-Tuple{Any})
- [`AustralianElectricityMarkets.read_hive`](#AustralianElectricityMarkets.read_hive-Tuple{DBInterface.Connection,%20Symbol})
- [`AustralianElectricityMarkets.read_interconnectors`](#AustralianElectricityMarkets.read_interconnectors-Tuple{Any})
- [`AustralianElectricityMarkets.read_units`](#AustralianElectricityMarkets.read_units-Tuple{Any})
- [`AustralianElectricityMarkets.set_demand!`](#AustralianElectricityMarkets.set_demand!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.set_market_bids!`](#AustralianElectricityMarkets.set_market_bids!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.set_renewable_pv!`](#AustralianElectricityMarkets.set_renewable_pv!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.set_renewable_wind!`](#AustralianElectricityMarkets.set_renewable_wind!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.table_requirements`](#AustralianElectricityMarkets.table_requirements-Tuple{RegionalNetworkConfiguration})

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.RegionalNetworkConfiguration' href='#AustralianElectricityMarkets.RegionModel.RegionalNetworkConfiguration'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.RegionalNetworkConfiguration</span></a> <Badge type="info" class="jlObjectType jlType" text="Type" /></summary>



```julia
Each australian State (i.e. AEMO Region) is a combination of a load node and a generator node. The load nodes are connected.
between states by interconnectors
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L603-L606" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel._add_branches!-Tuple{Any, Any}' href='#AustralianElectricityMarkets.RegionModel._add_branches!-Tuple{Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel._add_branches!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_add_branches!(sys, branch_df)
```


Adds branches to the system.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `branch_df`: A `DataFrame` of branch data.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L367-L375" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel._add_buses!-Tuple{Any, Any}' href='#AustralianElectricityMarkets.RegionModel._add_buses!-Tuple{Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel._add_buses!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_add_buses!(sys, bus_df)
```


Adds buses to the system.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `bus_df`: A `DataFrame` of bus data.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L339-L347" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel._add_generation!-Tuple{Any, Any}' href='#AustralianElectricityMarkets.RegionModel._add_generation!-Tuple{Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel._add_generation!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_add_generation!(sys, gen_df)
```


Adds generation units to the system.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `gen_df`: A `DataFrame` of generator data.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L419-L427" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel._add_loads!-Tuple{Any, Any}' href='#AustralianElectricityMarkets.RegionModel._add_loads!-Tuple{Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel._add_loads!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_add_loads!(sys, loads_df)
```


Adds loads to the system.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `loads_df`: A `DataFrame` of load data.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L394-L402" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.get_branch_dataframe-Tuple{Any}' href='#AustralianElectricityMarkets.RegionModel.get_branch_dataframe-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.get_branch_dataframe</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
get_branch_dataframe(db)
```


Generates a DataFrame of branch information.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing branch details.

**Example**

```julia
db = connect(duckdb())
branch_df = get_branch_dataframe(db)
println(branch_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L140-L157" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.get_bus_dataframe-Tuple{Any}' href='#AustralianElectricityMarkets.RegionModel.get_bus_dataframe-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.get_bus_dataframe</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
get_bus_dataframe(db)
```


Generates a DataFrame of bus information.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing bus details.

**Example**

```julia
db = connect(duckdb())
bus_df = get_bus_dataframe(db)
println(bus_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L51-L68" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.get_generators_dataframe-Tuple{Any}' href='#AustralianElectricityMarkets.RegionModel.get_generators_dataframe-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.get_generators_dataframe</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
get_generators_dataframe(db)
```


Generates a DataFrame of generator information.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing generator details.

**Example**

```julia
db = connect(duckdb())
gen_df = get_generators_dataframe(db)
println(gen_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L194-L211" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe-Tuple{Any}' href='#AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.get_interfaces_dataframe</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
get_interfaces_dataframe(db)
```


Generates a DataFrame of Interfaces information.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing interfaces details.

**Example**

```julia
db = connect(duckdb())
branch_df = get_branch_dataframe(db)
println(branch_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L262-L279" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.get_load_dataframe-Tuple{Any}' href='#AustralianElectricityMarkets.RegionModel.get_load_dataframe-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.get_load_dataframe</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
get_load_dataframe(db)
```


Generates a DataFrame of load information.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing load details.

**Example**

```julia
db = connect(duckdb())
load_df = get_load_dataframe(db)
println(load_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L106-L123" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.RegionModel.nem_system-Tuple{Any}' href='#AustralianElectricityMarkets.RegionModel.nem_system-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.RegionModel.nem_system</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
nem_system(db)
```


Assembles a `PowerSystems.System` object from the database.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `PowerSystems.System` object.

**Example**

```julia
db = connect(duckdb())
sys = nem_system(db)
println(sys)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L298-L315" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.table_requirements-Tuple{RegionalNetworkConfiguration}' href='#AustralianElectricityMarkets.table_requirements-Tuple{RegionalNetworkConfiguration}'><span class="jlbinding">AustralianElectricityMarkets.table_requirements</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
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
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/3dc64a37c94cf5fb943dcd9677aca566e394ee34/src/network_models/region_model.jl#L610-L623" target="_blank" rel="noreferrer">source</a></Badge>

</details>

