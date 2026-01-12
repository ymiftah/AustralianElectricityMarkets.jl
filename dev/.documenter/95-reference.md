
# Reference {#reference}

## Contents {#Contents}
- [reference](95-reference#reference)
    - [Contents](95-reference#contents)
    - [Index](95-reference#index)


## Index {#Index}
- [`AustralianElectricityMarkets.HiveConfiguration`](#AustralianElectricityMarkets.HiveConfiguration)
- [`AustralianElectricityMarkets._add_demand_ts_to_components!`](#AustralianElectricityMarkets._add_demand_ts_to_components!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets._add_renewable_ts_to_components!`](#AustralianElectricityMarkets._add_renewable_ts_to_components!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets._as_timearray`](#AustralianElectricityMarkets._as_timearray-NTuple{4,%20Any})
- [`AustralianElectricityMarkets._filter_latest`](#AustralianElectricityMarkets._filter_latest-Tuple{Any,%20Any})
- [`AustralianElectricityMarkets._filter_latest`](#AustralianElectricityMarkets._filter_latest-Tuple{Any})
- [`AustralianElectricityMarkets._parse_hive_root`](#AustralianElectricityMarkets._parse_hive_root-Tuple{AustralianElectricityMarkets.HiveConfiguration})
- [`AustralianElectricityMarkets.read_demand`](#AustralianElectricityMarkets.read_demand-Tuple{Any})
- [`AustralianElectricityMarkets.read_hive`](#AustralianElectricityMarkets.read_hive-Tuple{DBInterface.Connection,%20Symbol})
- [`AustralianElectricityMarkets.read_interconnectors`](#AustralianElectricityMarkets.read_interconnectors-Tuple{Any})
- [`AustralianElectricityMarkets.read_units`](#AustralianElectricityMarkets.read_units-Tuple{Any})
- [`AustralianElectricityMarkets.set_demand!`](#AustralianElectricityMarkets.set_demand!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.set_market_bids!`](#AustralianElectricityMarkets.set_market_bids!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.set_renewable_pv!`](#AustralianElectricityMarkets.set_renewable_pv!-Tuple{Any,%20Any,%20Any})
- [`AustralianElectricityMarkets.set_renewable_wind!`](#AustralianElectricityMarkets.set_renewable_wind!-Tuple{Any,%20Any,%20Any})

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.HiveConfiguration' href='#AustralianElectricityMarkets.HiveConfiguration'><span class="jlbinding">AustralianElectricityMarkets.HiveConfiguration</span></a> <Badge type="info" class="jlObjectType jlType" text="Type" /></summary>



```julia
HiveConfiguration
```


Configuration for accessing data.

**Fields**
- `hive_location::String`: The directory where data is cached. Defaults to `~/.nemweb_cache`.
  
- `filesystem::String`: The filesystem to use for the cache. Defaults to `"local"`. Can be s3, gs.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/configurations.jl#L1-L9" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets._add_demand_ts_to_components!-Tuple{Any, Any, Any}' href='#AustralianElectricityMarkets._add_demand_ts_to_components!-Tuple{Any, Any, Any}'><span class="jlbinding">AustralianElectricityMarkets._add_demand_ts_to_components!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_add_demand_ts_to_components!(sys, ts, type)
```


Adds demand time series data to the system components.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `ts`: A `TimeArray` of demand data.
  
- `type`: The type of component to add the time series to.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L402-L411" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets._add_renewable_ts_to_components!-Tuple{Any, Any, Any}' href='#AustralianElectricityMarkets._add_renewable_ts_to_components!-Tuple{Any, Any, Any}'><span class="jlbinding">AustralianElectricityMarkets._add_renewable_ts_to_components!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_add_renewable_ts_to_components!(sys, ts, prime_mover)
```


Adds renewable generation time series data to the system components.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `ts`: A `TimeArray` of renewable generation data.
  
- `prime_mover`: The prime mover type of the renewable generator.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L433-L442" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets._as_timearray-NTuple{4, Any}' href='#AustralianElectricityMarkets._as_timearray-NTuple{4, Any}'><span class="jlbinding">AustralianElectricityMarkets._as_timearray</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_as_timearray(df, index, col, value)
```


Converts a DataFrame to a TimeArray.

**Arguments**
- `df`: The input `DataFrame`.
  
- `index`: The column to use as the timestamp.
  
- `col`: The column to use for the column names of the `TimeArray`.
  
- `value`: The column to use for the values of the `TimeArray`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L386-L396" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets._filter_latest-Tuple{Any, Any}' href='#AustralianElectricityMarkets._filter_latest-Tuple{Any, Any}'><span class="jlbinding">AustralianElectricityMarkets._filter_latest</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_filter_latest(table, key)
```


Helper function to filter for the most recent records in a table based on a given key.

**Arguments**
- `table`: The TidierDB table to filter.
  
- `key`: The column (as a Symbol) to use for determining the latest records.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L276-L284" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets._filter_latest-Tuple{Any}' href='#AustralianElectricityMarkets._filter_latest-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets._filter_latest</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_filter_latest(table, key=:archive_month)
```


Helper function to filter for the most recent records in a table.

**Arguments**
- `table`: The table to filter.
  
- `key`: The column to use for determining the latest records. Defaults to `:archive_month`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L263-L271" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets._parse_hive_root-Tuple{AustralianElectricityMarkets.HiveConfiguration}' href='#AustralianElectricityMarkets._parse_hive_root-Tuple{AustralianElectricityMarkets.HiveConfiguration}'><span class="jlbinding">AustralianElectricityMarkets._parse_hive_root</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
_parse_hive_root(config::PyHiveConfiguration)
```


Construct the correct path to the Hive dataset based on the specified filesystem.

**Arguments**
- `config::PyHiveConfiguration`: The configuration object containing filesystem and location details.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L32-L39" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.read_demand-Tuple{Any}' href='#AustralianElectricityMarkets.read_demand-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.read_demand</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
read_demand(db; resolution::Dates.Period=Dates.Minute(5))
```


Read and process regional demand data from the database.

**Arguments**
- `db`: The database connection.
  
- `resolution::Dates.Period`: The time resolution to which the data should be floored. Defaults to 5 minutes.
  

**Returns**

A `DataFrame` with demand and renewable availability data, aggregated by the specified resolution.

**Example**

```julia
db = connect(duckdb())
demand_df = read_demand(db; resolution=Dates.Hour(1))
println(demand_df)
```


Row │ SETTLEMENTDATE       REGIONID  TOTALDEMAND  DISPATCHABLEGENERATION  DISPATCHABLELOAD  NETINTERCHANGE  	   │ Dates.DateTime       String7   Float64      Float64                 Float64           Float64         ───────┼────────────────────────────────────────────────────────────────────────────────────────────────────── 	 1 │ 2024-01-01T00:05:00  NSW1          6574.92                 6721.88               0.0          146.96 	 2 │ 2024-01-01T00:05:00  QLD1          6228.31                 5713.21               0.0         -515.1 	 3 │ 2024-01-01T00:05:00  SA1           1293.98                 1116.68               0.0         -177.3 	 4 │ 2024-01-01T00:05:00  TAS1          1033.29                  580.29               0.0         -453.0 	 5 │ 2024-01-01T00:05:00  VIC1          3977.1                  5071.17               0.0         1094.07


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L84-L110" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.read_hive-Tuple{DBInterface.Connection, Symbol}' href='#AustralianElectricityMarkets.read_hive-Tuple{DBInterface.Connection, Symbol}'><span class="jlbinding">AustralianElectricityMarkets.read_hive</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
read_hive(db::TidierDB.DBInterface.Connection,table_name::Symbol; config::HiveConfiguration=CONFIG[])
```


Read a hive-partitioned parquet dataset into a TidierDB table.

**Arguments**
- `db::TidierDB.DBInterface.Connection`: The database connection to use.
  
- `table_name::Symbol`: The name of the table to read.
  
- `config::HiveConfiguration`: The configuration to use. Defaults to `CONFIG[]`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L7-L16" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.read_interconnectors-Tuple{Any}' href='#AustralianElectricityMarkets.read_interconnectors-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.read_interconnectors</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
read_interconnectors(db)
```


Reads and processes interconnector data from the database.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing the latest interconnector constraint data.

**Example**

```julia
db = connect(duckdb())
interconnectors_df = read_interconnectors(db)
println(interconnectors_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L50-L67" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.read_units-Tuple{Any}' href='#AustralianElectricityMarkets.read_units-Tuple{Any}'><span class="jlbinding">AustralianElectricityMarkets.read_units</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
read_units(db)
```


Gathers and processes unit data from the database.

**Arguments**
- `db`: The database connection.
  

**Returns**

A `DataFrame` containing detailed information about each generation unit.

**Example**

```julia
db = connect(duckdb())
units_df = read_units(db)
println(units_df)
```



<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L136-L153" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.set_demand!-Tuple{Any, Any, Any}' href='#AustralianElectricityMarkets.set_demand!-Tuple{Any, Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.set_demand!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
set_demand!(sys, db, date_range; kwargs...)
```


Adds load time series data to the system from the database.

This function reads demand data for a specified date range, processes it into a time series, and attaches it to the `PowerLoad` components in the system.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `db`: The database connection.
  
- `date_range`: A range of dates for which to fetch demand data.
  
- `kwargs`: Additional keyword arguments passed to `read_demand`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L295-L308" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.set_market_bids!-Tuple{Any, Any, Any}' href='#AustralianElectricityMarkets.set_market_bids!-Tuple{Any, Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.set_market_bids!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
set_renewable_pv!(sys, db, date_range; kwargs...)
```


Adds Market bids time series data to the system.

This function reads solar availability data for a specified date range from the database, processes it into a time series, and attaches it to the `RenewableDispatch` components representing PV generators.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `db`: The database connection.
  
- `date_range`: A range of dates for which to fetch the data.
  
- `kwargs`: Additional keyword arguments passed to `read_demand`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L462-L476" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.set_renewable_pv!-Tuple{Any, Any, Any}' href='#AustralianElectricityMarkets.set_renewable_pv!-Tuple{Any, Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.set_renewable_pv!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
set_renewable_pv!(sys, db, date_range; kwargs...)
```


Adds photovoltaic (PV) renewable generation time series data to the system.

This function reads solar availability data for a specified date range from the database, processes it into a time series, and attaches it to the `RenewableDispatch` components representing PV generators.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `db`: The database connection.
  
- `date_range`: A range of dates for which to fetch the data.
  
- `kwargs`: Additional keyword arguments passed to `read_demand`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L319-L333" target="_blank" rel="noreferrer">source</a></Badge>

</details>

<details class='jldocstring custom-block' open>
<summary><a id='AustralianElectricityMarkets.set_renewable_wind!-Tuple{Any, Any, Any}' href='#AustralianElectricityMarkets.set_renewable_wind!-Tuple{Any, Any, Any}'><span class="jlbinding">AustralianElectricityMarkets.set_renewable_wind!</span></a> <Badge type="info" class="jlObjectType jlMethod" text="Method" /></summary>



```julia
set_renewable_wind!(sys, db, date_range; kwargs...)
```


Adds wind turbine renewable generation time series data to the system.

This function reads wind availability data for a specified date range from the database, processes it into a time series, and attaches it to the `RenewableDispatch` components representing wind turbines.

**Arguments**
- `sys`: The `PowerSystems.System` object.
  
- `db`: The database connection.
  
- `date_range`: A range of dates for which to fetch the data.
  
- `kwargs`: Additional keyword arguments passed to `read_demand`.
  


<Badge type="info" class="source-link" text="source"><a href="https://github.com/ymiftah/AustralianElectricityMarkets.jl/blob/b719508839751c7b451881d8d5cb21880784d1f9/src/parser.jl#L346-L360" target="_blank" rel="noreferrer">source</a></Badge>

</details>

