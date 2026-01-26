module RegionModel

using ..AustralianElectricityMarkets
using DataFrames, Chain, Statistics
using PowerSystems

export nem_system, set_demand!, set_renewable_pv!, set_renewable_wind!

const LOAD_SUFFIX = "_LOAD_BUS"
const GEN_SUFFIX = "_GEN_BUS"
const BASE_POWER = 100.0  # MVA

const MATCH_TYPE_TO_PRIMEMOVER = Dict(
    :RenewableDispatch => Set((PrimeMovers.WT, PrimeMovers.WS, PrimeMovers.PVe)),
    :ThermalStandard => Set(
        (
            PrimeMovers.BT,  # Turbines Used in a Binary Cycle (including those used for geothermal applications)
            PrimeMovers.CA,  # Combined-Cycle – Steam Part
            PrimeMovers.CC,  # Combined-Cycle - Aggregated Plant *augmentation of EIA
            PrimeMovers.CS,  # Combined-Cycle Single-Shaft Combustion turbine and steam turbine share a single generator
            PrimeMovers.CT,  # Combined-Cycle Combustion Turbine Part
            PrimeMovers.GT,  # Combustion (Gas) Turbine (including jet engine design)
            PrimeMovers.IC,  # Internal Combustion (diesel, piston, reciprocating) Engine
            PrimeMovers.OT,  # Other – Specify on SCHEDULE 9.
            PrimeMovers.ST,  # Steam Turbine (including nuclear, geothermal and solar steam; does not include combined-cycle turbine)
        )
    ),
    :HydroDispatch => Set(
        (
            PrimeMovers.HA,  # Hydrokinetic, Axial Flow Turbine
            PrimeMovers.HB,  # Hydrokinetic, Wave Buoy
            PrimeMovers.HK,  # Hydrokinetic, Other
            PrimeMovers.HY,  # Hydraulic Turbine (including turbines associated with delivery of water by pipeline)
        )
    ),
    :HydroEnergyReservoir => Set(
        (
            PrimeMovers.PS,  # Energy Storage, Reversible Hydraulic Turbine (Pumped Storage)
        )
    ),

    # PrimeMovers.ES  # Energy Storage, Other (Specify on Schedule 9, Comments)
    # PrimeMovers.FC,  # Fuel Cell
    # PrimeMovers.FW,  # Energy Storage, Flywheel
    # PrimeMovers.CE  # Energy Storage, Compressed Air
    # PrimeMovers.CP  # Energy Storage, Concentrated Solar Power
    # PrimeMovers.BA  # Energy Storage, Battery

)

"""
    get_bus_dataframe(db)

Generates a DataFrame of bus information.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing bus details.

# Example
```julia
db = aem_connect(duckdb())
bus_df = get_bus_dataframe(db)
println(bus_df)
```
"""
function get_bus_dataframe(db)
    interconnectors = read_interconnectors(db)
    regions = @chain interconnectors begin
        select(:REGIONFROM => :region)
        vcat(select(interconnectors, :REGIONTO => :region))
        unique
        sort!(:region)
    end

    # Get a reference bus"_LOAD_BUS"
    ref_bus = first(regions.region)
    gen_buses = @chain regions begin
        insertcols!(
            :voltage => 1,
            :angle => 0.0,
            :base_voltage => 130,
            :voltage_limits_min => 0.9,
            :voltage_limits_max => 1.1,
            :magnitude => 1.0,
        )
        transform!(
            :region =>
                ByRow(x -> x == ref_bus ? ACBusTypes.REF : ACBusTypes.PV) => :bustype,
            :region => ByRow(x -> x * GEN_SUFFIX) => :name,
        )
    end
    load_buses = @chain gen_buses begin
        transform(
            :bustype => ByRow(x -> ACBusTypes.PQ) => :bustype,
            :region => ByRow(x -> x * LOAD_SUFFIX) => :name,
        )
    end
    return @chain vcat(gen_buses, load_buses) begin
        insertcols!(_, :bus_id => 1:nrow(_))
    end
end

"""
    get_load_dataframe(db)

Generates a DataFrame of load information.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing load details.

# Example
```julia
db = aem_connect(duckdb())
load_df = get_load_dataframe(db)
println(load_df)
```
"""
function get_load_dataframe(db)
    buses = get_bus_dataframe(db)
    loads = @chain buses begin
        select!(:bus_id, :region, :name)
        subset!(:name => ByRow(contains(LOAD_SUFFIX)))
        transform!(:region => ByRow(x -> x * " Load") => :name)
        insertcols!(
            :base_power => BASE_POWER,
            :active_power => 0.1,
            :available => true,
            :max_active_power => 20,
        )
    end
    return loads
end

"""
    get_branch_dataframe(db)

Generates a DataFrame of branch information.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing branch details.

# Example
```julia
db = aem_connect(duckdb())
branch_df = get_branch_dataframe(db)
println(branch_df)
```
"""
function get_branch_dataframe(db)
    interconnectors = read_interconnectors(db)
    bus = select!(get_bus_dataframe(db), :bus_id, :name, :region)
    load_buses = subset(bus, :name => ByRow(contains(LOAD_SUFFIX)))
    gen_buses = subset(bus, :name => ByRow(contains(GEN_SUFFIX)))
    load_branches = @chain interconnectors begin
        select!(
            :INTERCONNECTORID => :name,
            :REGIONFROM => ByRow(x -> x * LOAD_SUFFIX) => :from,
            :REGIONTO => ByRow(x -> x * LOAD_SUFFIX) => :to,
            :MAXMWOUT => (x -> x / BASE_POWER) => :rate
        )
        leftjoin!(load_buses; on = :from => :name)
        rename!(:bus_id => :bus_from)
        leftjoin!(select(load_buses, Not(:region)); on = :to => :name)
        rename!(:bus_id => :bus_to)
        insertcols!(:r => 0.01, :x => 0.01, :b => 0)
        select(Not(:region))
    end

    # Add branches from Load buses to the Gen buses
    gen_branches = @chain gen_buses begin
        select!(:bus_id => :bus_from, :region, :name => :from)
        leftjoin!(select(load_buses, :bus_id => :bus_to, :region, :name => :to), on = :region)
        select!(
            [:from, :to] => ByRow((x, y) -> *(x, "-", y)) => :name,
            :from,
            :to,
            :bus_from,
            :bus_to,
        )
        insertcols!(:r => 0.01, :x => 0.01, :b => 0, :rate => 10.0)
    end
    return vcat(load_branches, gen_branches)
end

"""
    get_generators_dataframe(db)

Generates a DataFrame of generator information.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing generator details.

# Example
```julia
db = aem_connect(duckdb())
gen_df = get_generators_dataframe(db)
println(gen_df)
```
"""
function get_generators_dataframe(db)
    bus = select!(get_bus_dataframe(db), :bus_id, :name)
    nem_units = read_units(db)

    return @chain nem_units begin
        select!(
            :REGIONID => ByRow(x -> x * GEN_SUFFIX) => :bus_name,
            :REGIONID => :region,
            :DUID => :name,
            :REGISTEREDCAPACITY => :base_power,
            [:MINCAPACITY, :REGISTEREDCAPACITY] =>
                ByRow((m, r) -> r > 0 ? m / r : 0) => :min_active_power,
            [:MAXCAPACITY, :REGISTEREDCAPACITY] =>
                ByRow((m, r) -> r > 0 ? m / r : 0) => :max_active_power,
            [:MAXRATEOFCHANGEDOWN, :REGISTEREDCAPACITY] =>
                ByRow((m, r) -> r > 0 ? m / r : 0) => :max_ramp_up,
            [:MAXRATEOFCHANGEUP, :REGISTEREDCAPACITY] =>
                ByRow((m, r) -> r > 0 ? m / r : 0) => :max_ramp_down,
            :STATIONID => :station_id,
            :STATIONNAME => :station_name,
            :TECHNOLOGY => :technology,
            :FUELTYPE => :fuel_type,
            :POSTCODE => :postcode,
        )
        insertcols!(
            :rating => 1.0,
            :available => true,
            :active_power => 0.0,
            :reactive_power => 0.0,
            :output_point_0 => 0.0,
            :output_point_1 => 1.0,
            :max_reactive_power => 1.0,
            :reactive_power_limits_max => 1.0,
            :reactive_power_limits_min => -1.0,
            :heat_rate_avg_0 => 0.0,
            :heat_rate_incr_1 => 0.0,
        )
        leftjoin!(bus; on = :bus_name => :name)
        # Make hydro generators unavailable
        transform!(
            :min_active_power => ByRow(x -> coalesce(x, 0)) => :min_active_power,
            :max_ramp_up => ByRow(x -> coalesce(x, nothing)) => :max_ramp_up,
            :max_ramp_down => ByRow(x -> coalesce(x, nothing)) => :max_ramp_down,
        )
        dropmissing!(:technology)
        unique!(:name; keep = :first)
    end
end

"""
    get_batteries_dataframe(db)

Generates a DataFrame of Battery information.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing batteries details.

# Example
```julia
db = aem_connect(duckdb())
branch_df = get_batteries_dataframe(db)
println(branch_df)
```
"""
function get_batteries_dataframe(db)
    bus = select!(get_bus_dataframe(db), :bus_id, :name)
    units = read_units(db)
    dropmissing!(units, :TECHNOLOGY)
    subset!(units, :TECHNOLOGY => ByRow(==(PrimeMovers.BA)))
    batteries = select!(
        units,
        [
            :DUID => :name,
            :STATUS => ByRow(==("COMMISSIONED")) => :available,
            :REGIONID => ByRow(x -> x * GEN_SUFFIX) => :bus_name,
            :REGIONID => :region,
            :TECHNOLOGY => :prime_mover_type,
            :TECHNOLOGY => ByRow(x -> StorageTech.LIB) => :storage_technology_type,  # Find source
            :MAXSTORAGECAPACITY => :storage_capacity,
            [:STORAGEIMPORTEFFICIENCYFACTOR, :STORAGEEXPORTEFFICIENCYFACTOR] => ByRow(tuple) => :efficiency,
            :MAXCAPACITY => :base_power,
        ]
    )
    leftjoin!(batteries, bus; on = :bus_name => :name)
    insertcols!(
        batteries,
        :rating => 1.0,
        :active_power => 0.0,
        :reactive_power => 0.0,
        :max_reactive_power => 1.0,
        :reactive_power_limits => (-1.0, 1.0),
        :storage_level_limits => (0.0, 1.0),
        :initial_storage_capacity_level => 0.5,
    )
    dropmissing!(batteries)
    return batteries
end


"""
    get_interfaces_dataframe(db)

Generates a DataFrame of Interfaces information.

# Arguments
- `db`: The database connection.

# Returns
A `DataFrame` containing interfaces details.

# Example
```julia
db = aem_connect(duckdb())
branch_df = get_branch_dataframe(db)
println(branch_df)
```
"""
function get_interfaces_dataframe(db)
    interconnectors = read_interconnectors(db)
    select!(
        interconnectors,
        :INTERCONNECTORID => :name,
        :REGIONFROM => :from_area,
        :REGIONTO => :to_area,
        :MAXMWIN => :max_flow_from,
        :MAXMWOUT => :max_flow_to,
        :FROMREGIONLOSSSHARE => :from_region_loss_factor,
        :LOSSCONSTANT => :loss_constant,
        :LOSSFLOWCOEFFICIENT => :loss_flow_coefficient,
        :ICTYPE => :ic_type,
        # Make SNOWY interfaces unavailable by default, review status of this interconnector
        [:REGIONFROM, :REGIONTO] => ByRow((from_, to_) -> (from_ != "SNOWY1") && (to_ != "SNOWY1")) => :available
    )
    return interconnectors
end


"""
    nem_system(db)

Assembles a `PowerSystems.System` object from the database.

# Arguments
- `db`: The database connection.

# Returns
A `PowerSystems.System` object.

# Example
```julia
db = aem_connect(duckdb())
sys = nem_system(db)
println(sys)
```
"""
function nem_system(db; kwargs...)
    @info "parsing buses"
    bus_df = get_bus_dataframe(db)
    @info "parsing loads"
    loads_df = get_load_dataframe(db)
    @info "parsing branches"
    branch_df = get_branch_dataframe(db)
    @info "parsing generators"
    gen_df = get_generators_dataframe(db)
    @info "parsing batteries"
    batteries_df = get_batteries_dataframe(db)

    @info "parsing interconnectors/area interchanges / transmission interface"
    interfaces_df = get_interfaces_dataframe(db)

    sys = System(BASE_POWER; kwargs...)
    _add_buses!(sys, bus_df)
    _add_loads!(sys, loads_df)
    _add_generation!(sys, gen_df)
    _add_branches!(sys, branch_df)
    _add_batteries!(sys, batteries_df)
    _add_area_interfaces!(sys, interfaces_df)

    return sys
end

"""
    _add_buses!(sys, bus_df)

Adds buses to the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `bus_df`: A `DataFrame` of bus data.
"""
function _add_buses!(sys, bus_df)
    areas = (Area(; name = row[:region]) for row in eachrow(unique(bus_df, :region)))
    add_components!(sys, areas)
    buses = (
        ACBus(;
                number = row[:bus_id],
                name = row[:name],
                base_voltage = row[:base_voltage],
                bustype = row[:bustype],
                angle = row[:angle],
                magnitude = row[:magnitude],
                area = get_component(Area, sys, row[:region]),
                voltage_limits = (min = row[:voltage_limits_min], max = row[:voltage_limits_max]),
                available = true,
            ) for row in eachrow(bus_df)
    )
    return add_components!(sys, buses)
end

"""
    _add_branches!(sys, branch_df)

Adds branches to the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `branch_df`: A `DataFrame` of branch data.
"""
function _add_branches!(sys, branch_df)
    lines = (
        Line(;
                name = row[:name],
                available = true,
                active_power_flow = 0.0,
                reactive_power_flow = 0.0,
                arc = Arc(; from = get_bus(sys, row[:bus_from]), to = get_bus(sys, row[:bus_to])),
                r = row[:r], # Per-unit
                x = row[:x], # Per-unit
                b = (from = row[:b] / 2, to = row[:b] / 2), # Per-unit
                rating = row[:rate], # Line rating of 200 MVA / System base of 100 MVA
                angle_limits = (min = -0.7, max = 0.7),
            ) for row in eachrow(branch_df)
    )
    return add_components!(sys, lines)
end

"""
    _add_loads!(sys, loads_df)

Adds loads to the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `loads_df`: A `DataFrame` of load data.
"""
function _add_loads!(sys, loads_df)
    loads = (
        PowerLoad(;
                name = row[:name],
                available = row[:available],
                bus = get_bus(sys, row[:bus_id]),
                active_power = row[:active_power], # Per-unitized by device base_power
                reactive_power = 0.0, # Per-unitized by device base_power
                base_power = BASE_POWER, # MVA
                max_active_power = row[:max_active_power], # 10 MW per-unitized by device base_power
                max_reactive_power = row[:max_active_power],
            ) for row in eachrow(loads_df)
    )
    return add_components!(sys, loads)
end

"""
    _add_generation!(sys, gen_df)

Adds generation units to the system.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `gen_df`: A `DataFrame` of generator data.
"""
function _add_generation!(sys, gen_df)
    renewable = subset(
        gen_df, :technology => ByRow(in(MATCH_TYPE_TO_PRIMEMOVER[:RenewableDispatch]))
    )
    renewable_components = (
        RenewableDispatch(;
                name = row[:name],
                available = row[:available],
                bus = get_bus(sys, row[:bus_id]),
                active_power = row[:active_power],
                reactive_power = row[:reactive_power],
                rating = row[:rating], # MW per-unitized by device base_power
                prime_mover_type = row[:technology],
                reactive_power_limits = nothing,  # (min = row[:reactive_power_limits_min], max = row[:reactive_power_limits_max]), # 0 MVAR to 0.25 MVAR per-unitized by device base_power
                power_factor = 1.0,
                operation_cost = RenewableGenerationCost(;
                    # TODO find acceptable defaults issue #6
                    variable = CostCurve(
                        LinearCurve(rand(1.0:0.05:5.0), rand(1.0:0.1:10.0))
                    ),
                ),
                base_power = row[:base_power], # MVA
                ext = Dict(
                    "postcode" => row[:postcode],
                    "station_name" => row[:station_name],
                    "station_id" => row[:station_id],
                ),
            ) for row in eachrow(renewable)
    )
    add_components!(sys, renewable_components)

    hydro = subset(
        gen_df, :technology => ByRow(in(MATCH_TYPE_TO_PRIMEMOVER[:HydroDispatch]))
    )
    hydro_components = (
        HydroDispatch(;
                name = row[:name],
                available = row[:available],
                bus = get_bus(sys, row[:bus_id]),
                active_power = row[:active_power],
                reactive_power = row[:reactive_power],
                rating = row[:rating],
                prime_mover_type = row[:technology],
                active_power_limits = (min = row[:min_active_power], max = row[:max_active_power]),
                reactive_power_limits = nothing,
                ramp_limits = (
                    if isnothing(row[:max_ramp_up])
                        nothing
                else
                        (up = row[:max_ramp_up], down = row[:max_ramp_down])
                end
                ),
                time_limits = nothing,
                operation_cost = HydroGenerationCost(;
                    variable = CostCurve(
                        LinearCurve(
                            rand(0.0:0.05:1.0),
                            rand(0.1:0.05:1.0)
                        )
                    ), fixed = 0.0
                ),
                base_power = row[:base_power],
                ext = Dict(
                    "postcode" => row[:postcode],
                    "station_name" => row[:station_name],
                    "station_id" => row[:station_id],
                ),
            ) for row in eachrow(hydro)
    )
    add_components!(sys, hydro_components)

    thermal = subset(
        gen_df, :technology => ByRow(in(MATCH_TYPE_TO_PRIMEMOVER[:ThermalStandard]))
    )
    # look up affine costs from isp
    affine_heatrates = read_isp_thermal_costs_parameters(
        # TODO hardcoded for now, todo work on interface
        2025, "Step Change"
    )
    leftjoin!(thermal, affine_heatrates, on = :name => :unit; makeunique = true)

    #fill missing values with median price
    fill_missing(x) = all(ismissing.(x)) ? missing : median(skipmissing(x))
    thermal_with_costs = @chain thermal begin
        groupby(:technology)
        transform(
            :price_aud => fill_missing => :price_aud,
            :no_load_heat_input_GJ_per_h => fill_missing => :no_load_heat_input_GJ_per_h,
            :marginal_heat_rate_GJ_per_MWH => fill_missing => :marginal_heat_rate_GJ_per_MWH,
        )
    end

    thermal_components = (
        ThermalStandard(;
                name = row[:name],
                available = row[:available],
                status = true,
                bus = get_bus(sys, row[:bus_id]),
                active_power = row[:active_power],
                reactive_power = row[:reactive_power],
                rating = row[:rating], # MW per-unitized by device base_power
                active_power_limits = (min = row[:min_active_power], max = row[:max_active_power]), # 6 MW to 30 MW per-unitized by device base_power
                reactive_power_limits = nothing, # Per-unitized by device base_power
                ramp_limits = (
                    if isnothing(row[:max_ramp_up])
                        nothing # per-unitized by device base_power per minute
                else
                        (up = row[:max_ramp_up], down = row[:max_ramp_down]) # per-unitized by device base_power per minute
                end
                ), # per-unitized by device base_power per minute
                operation_cost = ThermalGenerationCost(;
                    # variable = CostCurve(
                    #     # LinearCurve(rand(10.0:50.0), rand(30.0:100.0))
                    # ),
                    variable = FuelCurve(;
                        value_curve = LinearCurve(
                            row[:marginal_heat_rate_GJ_per_MWH],
                            row[:no_load_heat_input_GJ_per_h]
                        ),
                        fuel_cost = row[:price_aud]
                    ),
                    fixed = 100.0,
                    start_up = 100.0,
                    shut_down = 100.0
                ),
                base_power = row[:base_power], # MVA
                time_limits = (up = 8.0, down = 8.0), # Hours
                must_run = false,
                prime_mover_type = row[:technology],
                fuel = row[:fuel_type],
                ext = Dict(
                    "postcode" => row[:postcode],
                    "station_name" => row[:station_name],
                    "station_id" => row[:station_id],
                ),
            ) for row in eachrow(thermal_with_costs)
    )
    add_components!(sys, thermal_components)

    return sys
end

function _add_batteries!(sys, batteries_df)
    battery_components = (
        EnergyReservoirStorage(;
                name = row[:name],
                available = row[:available],
                bus = get_bus(sys, row[:bus_id]),
                prime_mover_type = row[:prime_mover_type],
                storage_technology_type = row[:storage_technology_type],
                storage_capacity = row[:storage_capacity],
                storage_level_limits = row[:storage_level_limits],
                initial_storage_capacity_level = row[:initial_storage_capacity_level],
                rating = row[:rating],
                active_power = 0.0,
                reactive_power = 0,
                reactive_power_limits = (-1.0, 1.0),
                efficiency = row[:efficiency],
                base_power = row[:base_power],
                input_active_power_limits = (0.0, 1.0),
                output_active_power_limits = (0.0, 1.0),
            ) for row in eachrow(batteries_df)
    )
    return add_components!(sys, battery_components)
end

function _add_area_interfaces!(sys, interconnectors)
    interface_services = (
        TransmissionInterface(
                name = row[:name],
                available = row[:available],
                active_power_flow_limits = (; min = 0.0, max = max(row[:max_flow_from], row[:max_flow_to]) / BASE_POWER),
                violation_penalty = 1.0e5,
                direction_mapping = Dict(row[:name] => 1),
            ) for row in eachrow(interconnectors)
    )
    add_components!(sys, interface_services)

    area_interchanges = (
        AreaInterchange(;
                name = row[:name],
                available = row[:available],
                active_power_flow = 0.0,
                from_area = get_component(Area, sys, row[:from_area]),
                to_area = get_component(Area, sys, row[:to_area]),
                flow_limits = (row[:max_flow_from] / BASE_POWER, row[:max_flow_to] / BASE_POWER),
                # services=[get_component(TransmissionInterface, sys, row[:name])],
                ext = Dict(
                    "from_region_loss_factor" => row[:from_region_loss_factor],
                    "loss_constant" => row[:loss_constant],
                    "loss_flow_coefficient" => row[:loss_flow_coefficient],
                    "ic_type" => row[:ic_type],
                )
            ) for row in eachrow(interconnectors)
    )
    return add_components!(sys, area_interchanges)
end


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

end
