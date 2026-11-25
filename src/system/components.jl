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


const _GENERATOR_KINDS = Dict(
    primemover => kind for (kind, type) in (
            :renewable => :RenewableDispatch, :hydro => :HydroDispatch, :thermal => :ThermalStandard,
        ) for primemover in MATCH_TYPE_TO_PRIMEMOVER[type]
)


"""
    _map_unit_technology(units) -> DataFrame

Copy of a [`read_units`](@ref) DataFrame with `:TECHNOLOGY::PrimeMovers` and
`:FUELTYPE::ThermalFuels` columns derived from its raw `:CO2E_ENERGY_SOURCE` via
`AEMO_PM_MAPPING` and `AEMO_FUEL_MAPPING`; both are `missing` where the source is.
"""
function _map_unit_technology(units)
    return transform(
        units,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AustralianElectricityMarkets.AEMO_PM_MAPPING[x]) => :TECHNOLOGY,
        :CO2E_ENERGY_SOURCE => ByRow(x -> AustralianElectricityMarkets.AEMO_FUEL_MAPPING[x]) => :FUELTYPE,
    )
end


"""
    get_bus_dataframe(interconnectors)

Generates a DataFrame of bus information: a generator bus and a load bus for every region an
interconnector connects.

# Arguments
- `interconnectors`: A `DataFrame` of interconnector data, as returned by [`read_interconnectors`](@ref).

# Returns
A `DataFrame` containing bus details.

# Example
```julia
db = aem_connect()
date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2)
bus_df = get_bus_dataframe(read_interconnectors(db, date_range))
println(bus_df)
```
"""
function get_bus_dataframe(interconnectors)
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
    get_load_dataframe(bus_df)

Generates a DataFrame of load information.

# Arguments
- `bus_df`: A `DataFrame` of bus data, as returned by `get_bus_dataframe`.

# Returns
A `DataFrame` containing load details.

# Example
```julia
db = aem_connect()
date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2)
bus_df = get_bus_dataframe(read_interconnectors(db, date_range))
load_df = get_load_dataframe(bus_df)
println(load_df)
```
"""
function get_load_dataframe(bus_df)
    loads = @chain copy(bus_df) begin
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
    get_branch_dataframe(bus_df, interconnectors)

Generates a DataFrame of branch information.

# Arguments
- `bus_df`: A `DataFrame` of bus data, as returned by `get_bus_dataframe`.
- `interconnectors`: A `DataFrame` of interconnector data, as returned by `read_interconnectors`.

# Returns
A `DataFrame` containing branch details.

# Example
```julia
db = aem_connect()
date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2)
bus_df = get_bus_dataframe(read_interconnectors(db, date_range))
branch_df = get_branch_dataframe(bus_df, read_interconnectors(db, date_range))
println(branch_df)
```
"""
function get_branch_dataframe(bus_df, interconnectors)
    bus = select(bus_df, :bus_id, :name, :region)
    load_buses = subset(bus, :name => ByRow(contains(LOAD_SUFFIX)))
    gen_buses = subset(bus, :name => ByRow(contains(GEN_SUFFIX)))
    load_branches = @chain copy(interconnectors) begin
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
    get_generators_dataframe(bus_df, units)

Generates a DataFrame of generator information, one row per non-load unit with a technology. The
`kind` column is `:renewable`, `:hydro`, `:thermal` or `:other`, from the unit's prime mover, and
`ramp_limits` is `nothing` or an `(up, down)` tuple per-unitized by `base_power`.

# Arguments
- `bus_df`: A `DataFrame` of bus data, as returned by `get_bus_dataframe`.
- `units`: A `DataFrame` of unit data, as returned by `read_units` and mapped by `_map_unit_technology`.

# Returns
A `DataFrame` containing generator details.

# Example
```julia
db = aem_connect()
date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2)
bus_df = get_bus_dataframe(read_interconnectors(db, date_range))
gen_df = get_generators_dataframe(bus_df, _map_unit_technology(read_units(db, date_range)))
println(gen_df)
```
"""
function get_generators_dataframe(bus_df, units)
    bus = select(bus_df, :bus_id, :name)
    ramp(rate, capacity) = capacity > 0 ? rate / capacity : 0
    return @chain units begin
        # Scheduled loads (some have a GENUNITS row) are built by `get_scheduled_loads_dataframe`.
        subset(:DISPATCHTYPE => ByRow(!isequal("LOAD")))
        select(
            # A battery registered as separate generator and load units: its generator half has no storage data.
            [:TECHNOLOGY, :DISPATCHTYPE] =>
                ByRow((t, d) -> isequal(t, PrimeMovers.BA) && isequal(d, "GENERATOR")) => :legacy_battery,
            :TECHNOLOGY => ByRow(t -> get(_GENERATOR_KINDS, t, :other)) => :kind,
            :REGIONID => ByRow(x -> x * GEN_SUFFIX) => :bus_name,
            :REGIONID => :region,
            :DUID => :name,
            :REGISTEREDCAPACITY => :base_power,
            [:MINCAPACITY, :REGISTEREDCAPACITY] => ByRow(ramp) => :min_active_power,
            [:MAXCAPACITY, :REGISTEREDCAPACITY] => ByRow(ramp) => :max_active_power,
            [:MAXRATEOFCHANGEUP, :MAXRATEOFCHANGEDOWN, :REGISTEREDCAPACITY] =>
                ByRow((up, down, r) -> ismissing(up) ? nothing : (up = ramp(up, r), down = ramp(down, r))) => :ramp_limits,
            :STATIONID => :station_id,
            :STATIONNAME => :station_name,
            :TECHNOLOGY => :technology,
            :FUELTYPE => :fuel_type,
            :POSTCODE => :postcode,
        )
        insertcols!(:rating => 1.0, :available => true, :active_power => 0.0, :reactive_power => 0.0)
        leftjoin!(bus; on = :bus_name => :name)
        transform!(:min_active_power => ByRow(x -> coalesce(x, 0)) => :min_active_power)
        dropmissing!(:technology)
        unique!(:name; keep = :first)
    end
end


"""
    get_batteries_dataframe(bus_df, units)

Generates a DataFrame of Battery information.

# Arguments
- `bus_df`: A `DataFrame` of bus data, as returned by `get_bus_dataframe`.
- `units`: A `DataFrame` of unit data, as returned by `read_units` and mapped by `_map_unit_technology`.

# Returns
A `DataFrame` containing batteries details.

# Example
```julia
db = aem_connect()
date_range = DateTime(2025, 1, 1):Minute(5):DateTime(2025, 1, 2)
bus_df = get_bus_dataframe(read_interconnectors(db, date_range))
branch_df = get_batteries_dataframe(bus_df, _map_unit_technology(read_units(db, date_range)))
println(branch_df)
```
"""
function get_batteries_dataframe(bus_df, units)
    bus = select(bus_df, :bus_id, :name)
    # TODO make assumptions when technology or efficiency is missing ?
    batteries = @chain units begin
        dropmissing([:TECHNOLOGY, :STORAGEIMPORTEFFICIENCYFACTOR])
        subset(:TECHNOLOGY => ByRow(==(PrimeMovers.BA)))
        select(
            :DUID => :name,
            :STATUS => ByRow(==("COMMISSIONED")) => :available,
            :REGIONID => ByRow(x -> x * GEN_SUFFIX) => :bus_name,
            :REGIONID => :region,
            :TECHNOLOGY => :prime_mover_type,
            :TECHNOLOGY => ByRow(x -> StorageTech.LIB) => :storage_technology_type,  # Find source
            :MAXSTORAGECAPACITY => :storage_capacity,
            [:STORAGEIMPORTEFFICIENCYFACTOR, :STORAGEEXPORTEFFICIENCYFACTOR] => ByRow(tuple) => :efficiency,
            :MAXCAPACITY => :base_power,
        )
        leftjoin(bus; on = :bus_name => :name)
        insertcols!(
            :rating => 1.0,
            :active_power => 0.0,
            :reactive_power => 0.0,
            :storage_level_limits => (0.0, 1.0),
            :initial_storage_capacity_level => 0.5,
        )
        dropmissing!
    end
    unique!(batteries) # TODO verify where duplication happens
    return batteries
end


"""
    get_scheduled_loads_dataframe(bus_df, units)

Generates a DataFrame of loads (`DISPATCHTYPE = LOAD` units, scheduled pumps and the
non-scheduled ancillary-service and demand-response loads alike), each on its region's generator
bus. A non-scheduled load starts unavailable: it carries no energy bid, and
[`set_market_bids!`](@ref) makes it available only when it offers FCAS.

# Arguments
- `bus_df`: A `DataFrame` of bus data, as returned by `get_bus_dataframe`.
- `units`: A `DataFrame` of unit data, as returned by `read_units`.

# Returns
A `DataFrame` with `name`, `bus_id`, `region`, `base_power`, `max_active_power` (per-unit of
`base_power`), `available`, `scheduled` and `commissioned`.
"""
function get_scheduled_loads_dataframe(bus_df, units)
    bus = select(bus_df, :bus_id, :name)
    loads = @chain units begin
        subset(
            :DISPATCHTYPE => ByRow(isequal("LOAD")), :SCHEDULE_TYPE => ByRow(in(("SCHEDULED", "NON-SCHEDULED"))),
            :REGISTEREDCAPACITY => ByRow(x -> !ismissing(x) && x > 0),
        )
        select(
            :DUID => :name,
            :REGIONID => ByRow(x -> x * GEN_SUFFIX) => :bus_name,
            :REGIONID => :region,
            :REGISTEREDCAPACITY => (x -> Float64.(x)) => :base_power,
            [:MAXCAPACITY, :REGISTEREDCAPACITY] =>
                ByRow((m, r) -> ismissing(m) ? 1.0 : Float64(m / r)) => :max_active_power,
            [:STATUS, :SCHEDULE_TYPE] => ByRow((s, t) -> s == "COMMISSIONED" && t == "SCHEDULED") => :available,
            :SCHEDULE_TYPE => ByRow(==("SCHEDULED")) => :scheduled,
            :STATUS => ByRow(==("COMMISSIONED")) => :commissioned,
        )
        leftjoin(bus; on = :bus_name => :name)
        select(Not(:bus_name))
        unique(:name)
    end
    return loads
end


"""
    get_interfaces_dataframe(interconnectors)

Generates a DataFrame of Interfaces information. `kind` is the interconnector's
`InterconnectorKind`, `missing` for an unknown `ICTYPE`.

# Arguments
- `interconnectors`: A `DataFrame` of interconnector data, as returned by `read_interconnectors`.

# Returns
A `DataFrame` containing interfaces details.

# Example
```julia
db = aem_connect()
interfaces_df = get_interfaces_dataframe(read_interconnectors(db, date_range))
println(interfaces_df)
```
"""
function get_interfaces_dataframe(interconnectors)
    interconnectors = copy(interconnectors)
    select!(
        interconnectors,
        :INTERCONNECTORID => :name,
        :REGIONFROM => :from_area,
        :REGIONTO => :to_area,
        :MAXMWIN => :max_flow_from,
        :MAXMWOUT => :max_flow_to,
        :ICTYPE => ByRow(t -> get(_INTERCONNECTOR_KINDS, t, missing)) => :kind,
        # Make SNOWY interfaces unavailable by default, review status of this interconnector
        [:REGIONFROM, :REGIONTO] => ByRow((from_, to_) -> (from_ != "SNOWY1") && (to_ != "SNOWY1")) => :available
    )
    return interconnectors
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


_fill_missing_median(x) = all(ismissing.(x)) ? missing : median(skipmissing(x))


"""
    _fill_opex!(df, variable_opex_df, fixed_opex_df, pm_var_medians, pm_fix_medians)

Fills the OPEX columns of the generators `df` (with a `:kind` column) in place and returns it, taking for
each missing value the first available of:
1. the unit's own value (`:name => :unit`);
2. the prime-mover median (`:technology => :primemover`);
3. the median of its `kind` and `isp_technology` group;
4. the median of its `kind`.

The thermal heat-rate and fuel-price columns are filled by steps 3 and 4 only.
"""
function _fill_opex!(df, variable_opex_df, fixed_opex_df, pm_var_medians, pm_fix_medians)
    leftjoin!(df, variable_opex_df; on = :name => :unit)
    leftjoin!(df, select(fixed_opex_df, :unit, :fixed_opex_aud_kw_year); on = :name => :unit)
    leftjoin!(df, pm_var_medians; on = :technology => :primemover)
    leftjoin!(df, pm_fix_medians; on = :technology => :primemover)
    df.variable_opex_aud_mwh = coalesce.(df.variable_opex_aud_mwh, df.variable_opex_aud_mwh_pm)
    df.fixed_opex_aud_kw_year = coalesce.(df.fixed_opex_aud_kw_year, df.fixed_opex_aud_kw_year_pm)
    select!(df, Not([:variable_opex_aud_mwh_pm, :fixed_opex_aud_kw_year_pm]))
    median_cols = [
        :variable_opex_aud_mwh, :fixed_opex_aud_kw_year,
        :price_aud, :no_load_heat_input_GJ_per_h, :marginal_heat_rate_GJ_per_MWH,
    ]
    return @chain df begin
        groupby([:kind, :isp_technology])
        transform(median_cols .=> _fill_missing_median .=> median_cols)
        groupby(:kind)
        transform(median_cols .=> _fill_missing_median .=> median_cols)
    end
end


# Generator of a `kind` from a row of `get_generators_dataframe`, with a zero operation cost.
function _generator(::Val{:renewable}, row, bus)
    return RenewableDispatch(;
        name = row.name, available = row.available, bus, active_power = row.active_power,
        reactive_power = row.reactive_power, rating = row.rating, prime_mover_type = row.technology,
        reactive_power_limits = nothing, power_factor = 1.0,
        operation_cost = RenewableGenerationCost(nothing), base_power = row.base_power,
    )
end

function _generator(::Val{:hydro}, row, bus)
    return HydroDispatch(;
        name = row.name, available = row.available, bus, active_power = row.active_power,
        reactive_power = row.reactive_power, rating = row.rating, prime_mover_type = row.technology,
        active_power_limits = (min = row.min_active_power, max = row.max_active_power),
        reactive_power_limits = nothing, ramp_limits = row.ramp_limits, time_limits = nothing,
        operation_cost = HydroGenerationCost(nothing), base_power = row.base_power,
    )
end

function _generator(::Val{:thermal}, row, bus)
    return ThermalStandard(;
        name = row.name, available = row.available, status = true, bus, active_power = row.active_power,
        reactive_power = row.reactive_power, rating = row.rating,
        active_power_limits = (min = row.min_active_power, max = row.max_active_power),
        reactive_power_limits = nothing, ramp_limits = row.ramp_limits,
        operation_cost = ThermalGenerationCost(nothing), base_power = row.base_power,
        time_limits = (up = 8.0, down = 8.0), must_run = false, prime_mover_type = row.technology,
        fuel = row.fuel_type,
    )
end


"""
    _add_generation!(sys, gen_df; legacy_batteries = false)

Adds the renewable, hydro and thermal generators of `gen_df` to `sys` with zero operation costs,
each with its station attached as a [`NEMStation`](@ref) shared among the units of one station.
`_set_isp_generation_costs!` replaces those costs with the ISP operating costs.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `gen_df`: A `DataFrame` of generator data.
- `legacy_batteries`: also add the generator unit of each battery registered as separate generator
  and load units, as a `ThermalStandard` with the battery prime mover.

# Returns
`sys`.
"""
function _add_generation!(sys, gen_df; legacy_batteries::Bool = false)
    stations = Dict(
        String(r.station_id) => NEMStation(; station_id = String(r.station_id), station_name = r.station_name, postcode = r.postcode)
            for r in eachrow(unique(gen_df, :station_id))
    )
    for row in eachrow(gen_df)
        kind = legacy_batteries && row.legacy_battery ? :thermal : row.kind
        kind === :other && continue
        generator = _generator(Val(kind), row, get_bus(sys, row.bus_id))
        add_component!(sys, generator)
        add_supplemental_attribute!(sys, generator, stations[String(row.station_id)])
    end
    return sys
end


# Operation cost of a `kind` from a row of `_fill_opex!`'s output.
function _isp_operation_cost(::Val{:renewable}, row, variable, fixed)
    # ISP2025: wind and large-scale solar PV O&M are included in the fixed O&M costs, so the variable cost is 0.
    return RenewableGenerationCost(; variable = CostCurve(LinearCurve(variable, 0.0)), fixed)
end

function _isp_operation_cost(::Val{:hydro}, row, variable, fixed)
    return HydroGenerationCost(; variable = CostCurve(LinearCurve(variable)), fixed)
end

function _isp_operation_cost(::Val{:thermal}, row, variable, fixed)
    return ThermalGenerationCost(;
        variable = FuelCurve(;
            value_curve = LinearCurve(row.marginal_heat_rate_GJ_per_MWH, row.no_load_heat_input_GJ_per_h),
            fuel_cost = row.price_aud,
            vom_cost = LinearCurve(variable),
        ),
        fixed, start_up = 100.0, shut_down = 100.0,
    )
end


"""
    _set_isp_generation_costs!(sys, gen_df)

Replaces the operation cost of every renewable, hydro and thermal generator of `gen_df` in `sys`
with its ISP2025 operating cost: per-unit ISP variable and fixed O&M, filled by the
`_fill_opex!` cascade, and for thermal units the ISP affine heat-rate and fuel-price
parameters. Generators must already be in `sys`, as added by `_add_generation!`.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `gen_df`: A `DataFrame` of generator data, as returned by `get_generators_dataframe`.

# Returns
`sys`.
"""
function _set_isp_generation_costs!(sys, gen_df)
    primemover(x) = AustralianElectricityMarkets.PM_MAPPING[x]
    variable_opex_df = transform(read_isp_variable_opex(), :isp_technology => ByRow(primemover) => :primemover)
    fixed_opex_df = transform(read_isp_fixed_opex(), :isp_technology => ByRow(primemover) => :primemover)
    pm_var_medians = combine(
        groupby(variable_opex_df, :primemover),
        :variable_opex_aud_mwh => median ∘ skipmissing => :variable_opex_aud_mwh_pm,
    )
    pm_fix_medians = combine(
        groupby(fixed_opex_df, :primemover),
        :fixed_opex_aud_kw_year => median ∘ skipmissing => :fixed_opex_aud_kw_year_pm,
    )
    # TODO scenario and year are hardcoded, work on interface
    affine_heatrates = read_isp_thermal_costs_parameters(2025, "Step Change")

    costs = @chain gen_df begin
        subset(:kind => ByRow(!=(:other)))
        leftjoin(affine_heatrates; on = :name => :unit, makeunique = true)
        _fill_opex!(variable_opex_df, fixed_opex_df, pm_var_medians, pm_fix_medians)
    end
    for row in eachrow(costs)
        variable = coalesce(row.variable_opex_aud_mwh, 0.0)
        fixed = coalesce(row.fixed_opex_aud_kw_year, 0.0) * row.base_power * 1000.0 / 8760.0
        set_operation_cost!(get_component(Generator, sys, row.name), _isp_operation_cost(Val(row.kind), row, variable, fixed))
    end
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
            storage_capacity = row[:storage_capacity] / row[:base_power],
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


"""
    _add_scheduled_loads!(sys, scheduled_loads_df; nemde = false)

Adds each load as an `InterruptiblePowerLoad` with a zero `LoadCost`; [`set_market_bids!`](@ref) gives
a scheduled load its decremental offer, or marks it unavailable when it has no bid. A non-scheduled load
(`scheduled = false`) starts unavailable; it keeps the zero cost, and the dispatch limits
([`nem_system`](@ref)) fix its energy at zero. A regional build records `non_scheduled` and
`commissioned` on the load's `ext`; a NEMDE build records them on its [`NEMRegistration`](@ref).
Despite the name, this builds every `DISPATCHTYPE = LOAD` unit of the data frame.

# Arguments
- `sys`: The `PowerSystems.System` object.
- `scheduled_loads_df`: A `DataFrame` as returned by `get_scheduled_loads_dataframe`.
- `nemde`: Record the non-scheduled flags on the registration instead of `ext`.

# Returns
The result of `add_components!`.
"""
function _add_scheduled_loads!(sys, scheduled_loads_df; nemde::Bool = false)
    loads = (
        InterruptiblePowerLoad(;
            name = row[:name],
            available = row[:available],
            bus = get_bus(sys, row[:bus_id]),
            active_power = 0.0,
            reactive_power = 0.0,
            max_active_power = row[:max_active_power],
            max_reactive_power = 0.0,
            base_power = row[:base_power],
            operation_cost = LoadCost(; variable = CostCurve(LinearCurve(0.0)), fixed = 0.0),
            # A run build records both flags on the load's registration instead.
            ext = (!nemde && !row[:scheduled]) ?
                Dict{String, Any}("non_scheduled" => true, "commissioned" => row[:commissioned]) :
                Dict{String, Any}(),
        ) for row in eachrow(scheduled_loads_df)
    )
    return add_components!(sys, loads)
end


function _add_area_interfaces!(sys, interfaces_df)
    for row in eachrow(interfaces_df)
        ismissing(row.kind) && throw(ArgumentError("interconnector $(row.name) has no valid ICTYPE"))
        interchange = AreaInterchange(;
            name = row.name,
            available = row.available,
            active_power_flow = 0.0,
            from_area = get_component(Area, sys, row.from_area),
            to_area = get_component(Area, sys, row.to_area),
            flow_limits = (row.max_flow_from / BASE_POWER, row.max_flow_to / BASE_POWER),
        )
        add_component!(sys, interchange)
        add_supplemental_attribute!(sys, interchange, NEMInterconnectorRegistration(; kind = row.kind))
    end
    return
end

const _INTERCONNECTOR_KINDS = Dict("REGULATED" => InterconnectorKind.REGULATED, "MNSP" => InterconnectorKind.MNSP)
