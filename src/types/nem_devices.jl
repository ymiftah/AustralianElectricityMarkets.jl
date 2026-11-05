# NEM counterparts of the PowerSystems device types, differing only in `operation_cost`.

# Defines the field getters and setters of a NEM device type. `unit_getters` and `unit_setters`
# convert through the device base power as the PowerSystems accessors do.
function _define_accessors!(T, getters, unit_getters, setters, unit_setters)
    for f in getters
        @eval begin
            @doc $("Get [`$T`](@ref) `$f`.") function PSY.$(Symbol(:get_, f))(value::$T)
                return value.$f
            end
        end
    end
    for f in unit_getters
        @eval begin
            @doc $("Get [`$T`](@ref) `$f`.") function PSY.$(Symbol(:get_, f))(value::$T)
                return PSY.get_value(value, Val($(QuoteNode(f))), Val(:mva))
            end
        end
    end
    for f in setters
        @eval begin
            @doc $("Set [`$T`](@ref) `$f`.") function PSY.$(Symbol(:set_, f, :!))(value::$T, val)
                value.$f = val
                return value.$f
            end
        end
    end
    for f in unit_setters
        @eval begin
            @doc $("Set [`$T`](@ref) `$f`.") function PSY.$(Symbol(:set_, f, :!))(value::$T, val)
                value.$f = PSY.set_value(value, Val($(QuoteNode(f))), val, Val(:mva))
                return value.$f
            end
        end
    end
    return
end

"""
    NEMThermalGen(; <fields of PSY.ThermalStandard>)

A NEM counterpart of `PSY.ThermalStandard` (a thermal generator) whose `operation_cost` is a [`NEMOfferCost`](@ref). It has
the fields, constructors, getters and setters of `PSY.ThermalStandard`, with the same per-unit conversions.

# Fields
- `name`: `String`
- `available`: `Bool`
- `status`: `Bool`
- `bus`: `ACBus`
- `active_power`: `Float64`
- `reactive_power`: `Float64`
- `rating`: `Float64`
- `active_power_limits`: `MinMax`
- `reactive_power_limits`: `Union{Nothing, PSY.MinMax}`
- `ramp_limits`: `Union{Nothing, PSY.UpDown}`
- `operation_cost`: `NEMOfferCost`
- `base_power`: `Float64`
- `time_limits`: `Union{Nothing, PSY.UpDown}`
- `must_run`: `Bool`
- `prime_mover_type`: `PrimeMovers`
- `fuel`: `ThermalFuels`
- `services`: `Vector{Service}`
- `time_at_status`: `Float64`
- `dynamic_injector`: `Union{Nothing, DynamicInjection}`
- `ext`: `Dict{String, Any}`
- `internal`: `InfrastructureSystemsInternal`
"""
mutable struct NEMThermalGen <: PSY.ThermalGen
    name::String
    available::Bool
    status::Bool
    bus::ACBus
    active_power::Float64
    reactive_power::Float64
    rating::Float64
    active_power_limits::PSY.MinMax
    reactive_power_limits::Union{Nothing, PSY.MinMax}
    ramp_limits::Union{Nothing, PSY.UpDown}
    operation_cost::NEMOfferCost
    base_power::Float64
    time_limits::Union{Nothing, PSY.UpDown}
    must_run::Bool
    prime_mover_type::PrimeMovers
    fuel::ThermalFuels
    services::Vector{Service}
    time_at_status::Float64
    dynamic_injector::Union{Nothing, DynamicInjection}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function NEMThermalGen(name, available, status, bus, active_power, reactive_power, rating, active_power_limits, reactive_power_limits, ramp_limits, operation_cost, base_power, time_limits = nothing, must_run = false, prime_mover_type = PrimeMovers.OT, fuel = ThermalFuels.OTHER, services = Device[], time_at_status = PSY.INFINITE_TIME, dynamic_injector = nothing, ext = Dict{String, Any}())
    return NEMThermalGen(name, available, status, bus, active_power, reactive_power, rating, active_power_limits, reactive_power_limits, ramp_limits, operation_cost, base_power, time_limits, must_run, prime_mover_type, fuel, services, time_at_status, dynamic_injector, ext, IS.InfrastructureSystemsInternal())
end

function NEMThermalGen(; name, available, status, bus, active_power, reactive_power, rating, active_power_limits, reactive_power_limits, ramp_limits, operation_cost, base_power, time_limits = nothing, must_run = false, prime_mover_type = PrimeMovers.OT, fuel = ThermalFuels.OTHER, services = Device[], time_at_status = PSY.INFINITE_TIME, dynamic_injector = nothing, ext = Dict{String, Any}(), internal = IS.InfrastructureSystemsInternal())
    return NEMThermalGen(name, available, status, bus, active_power, reactive_power, rating, active_power_limits, reactive_power_limits, ramp_limits, operation_cost, base_power, time_limits, must_run, prime_mover_type, fuel, services, time_at_status, dynamic_injector, ext, internal)
end

_define_accessors!(
    NEMThermalGen,
    (:name, :available, :status, :bus, :operation_cost, :base_power, :time_limits, :must_run, :prime_mover_type, :fuel, :services, :time_at_status, :dynamic_injector, :ext, :internal),
    (:active_power, :reactive_power, :rating, :active_power_limits, :reactive_power_limits, :ramp_limits),
    (:available, :status, :bus, :operation_cost, :base_power, :time_limits, :must_run, :prime_mover_type, :fuel, :services, :time_at_status, :ext),
    (:active_power, :reactive_power, :rating, :active_power_limits, :reactive_power_limits, :ramp_limits),
)


"""
    NEMHydroGen(; <fields of PSY.HydroDispatch>)

A NEM counterpart of `PSY.HydroDispatch` (a dispatchable hydro generator) whose `operation_cost` is a [`NEMOfferCost`](@ref). It has
the fields, constructors, getters and setters of `PSY.HydroDispatch`, with the same per-unit conversions.

# Fields
- `name`: `String`
- `available`: `Bool`
- `bus`: `ACBus`
- `active_power`: `Float64`
- `reactive_power`: `Float64`
- `rating`: `Float64`
- `prime_mover_type`: `PrimeMovers`
- `active_power_limits`: `MinMax`
- `reactive_power_limits`: `Union{Nothing, PSY.MinMax}`
- `ramp_limits`: `Union{Nothing, PSY.UpDown}`
- `time_limits`: `Union{Nothing, PSY.UpDown}`
- `base_power`: `Float64`
- `status`: `Bool`
- `time_at_status`: `Float64`
- `operation_cost`: `NEMOfferCost`
- `services`: `Vector{Service}`
- `dynamic_injector`: `Union{Nothing, DynamicInjection}`
- `ext`: `Dict{String, Any}`
- `internal`: `InfrastructureSystemsInternal`
"""
mutable struct NEMHydroGen <: PSY.HydroGen
    name::String
    available::Bool
    bus::ACBus
    active_power::Float64
    reactive_power::Float64
    rating::Float64
    prime_mover_type::PrimeMovers
    active_power_limits::PSY.MinMax
    reactive_power_limits::Union{Nothing, PSY.MinMax}
    ramp_limits::Union{Nothing, PSY.UpDown}
    time_limits::Union{Nothing, PSY.UpDown}
    base_power::Float64
    status::Bool
    time_at_status::Float64
    operation_cost::NEMOfferCost
    services::Vector{Service}
    dynamic_injector::Union{Nothing, DynamicInjection}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function NEMHydroGen(name, available, bus, active_power, reactive_power, rating, prime_mover_type, active_power_limits, reactive_power_limits, ramp_limits, time_limits, base_power, status = false, time_at_status = PSY.INFINITE_TIME, operation_cost = NEMOfferCost(), services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}())
    return NEMHydroGen(name, available, bus, active_power, reactive_power, rating, prime_mover_type, active_power_limits, reactive_power_limits, ramp_limits, time_limits, base_power, status, time_at_status, operation_cost, services, dynamic_injector, ext, IS.InfrastructureSystemsInternal())
end

function NEMHydroGen(; name, available, bus, active_power, reactive_power, rating, prime_mover_type, active_power_limits, reactive_power_limits, ramp_limits, time_limits, base_power, status = false, time_at_status = PSY.INFINITE_TIME, operation_cost = NEMOfferCost(), services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}(), internal = IS.InfrastructureSystemsInternal())
    return NEMHydroGen(name, available, bus, active_power, reactive_power, rating, prime_mover_type, active_power_limits, reactive_power_limits, ramp_limits, time_limits, base_power, status, time_at_status, operation_cost, services, dynamic_injector, ext, internal)
end

_define_accessors!(
    NEMHydroGen,
    (:name, :available, :bus, :prime_mover_type, :time_limits, :base_power, :status, :time_at_status, :operation_cost, :services, :dynamic_injector, :ext, :internal),
    (:active_power, :reactive_power, :rating, :active_power_limits, :reactive_power_limits, :ramp_limits),
    (:available, :bus, :prime_mover_type, :time_limits, :base_power, :status, :time_at_status, :operation_cost, :services, :ext),
    (:active_power, :reactive_power, :rating, :active_power_limits, :reactive_power_limits, :ramp_limits),
)


"""
    NEMRenewableGen(; <fields of PSY.RenewableDispatch>)

A NEM counterpart of `PSY.RenewableDispatch` (a dispatchable renewable generator) whose `operation_cost` is a [`NEMOfferCost`](@ref). It has
the fields, constructors, getters and setters of `PSY.RenewableDispatch`, with the same per-unit conversions.

# Fields
- `name`: `String`
- `available`: `Bool`
- `bus`: `ACBus`
- `active_power`: `Float64`
- `reactive_power`: `Float64`
- `rating`: `Float64`
- `prime_mover_type`: `PrimeMovers`
- `reactive_power_limits`: `Union{Nothing, PSY.MinMax}`
- `power_factor`: `Float64`
- `operation_cost`: `NEMOfferCost`
- `base_power`: `Float64`
- `services`: `Vector{Service}`
- `dynamic_injector`: `Union{Nothing, DynamicInjection}`
- `ext`: `Dict{String, Any}`
- `internal`: `InfrastructureSystemsInternal`
"""
mutable struct NEMRenewableGen <: PSY.RenewableGen
    name::String
    available::Bool
    bus::ACBus
    active_power::Float64
    reactive_power::Float64
    rating::Float64
    prime_mover_type::PrimeMovers
    reactive_power_limits::Union{Nothing, PSY.MinMax}
    power_factor::Float64
    operation_cost::NEMOfferCost
    base_power::Float64
    services::Vector{Service}
    dynamic_injector::Union{Nothing, DynamicInjection}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function NEMRenewableGen(name, available, bus, active_power, reactive_power, rating, prime_mover_type, reactive_power_limits, power_factor, operation_cost, base_power, services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}())
    return NEMRenewableGen(name, available, bus, active_power, reactive_power, rating, prime_mover_type, reactive_power_limits, power_factor, operation_cost, base_power, services, dynamic_injector, ext, IS.InfrastructureSystemsInternal())
end

function NEMRenewableGen(; name, available, bus, active_power, reactive_power, rating, prime_mover_type, reactive_power_limits, power_factor, operation_cost, base_power, services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}(), internal = IS.InfrastructureSystemsInternal())
    return NEMRenewableGen(name, available, bus, active_power, reactive_power, rating, prime_mover_type, reactive_power_limits, power_factor, operation_cost, base_power, services, dynamic_injector, ext, internal)
end

_define_accessors!(
    NEMRenewableGen,
    (:name, :available, :bus, :prime_mover_type, :power_factor, :operation_cost, :base_power, :services, :dynamic_injector, :ext, :internal),
    (:active_power, :reactive_power, :rating, :reactive_power_limits),
    (:available, :bus, :prime_mover_type, :power_factor, :operation_cost, :base_power, :services, :ext),
    (:active_power, :reactive_power, :rating, :reactive_power_limits),
)


"""
    NEMStorage(; <fields of PSY.EnergyReservoirStorage>)

A NEM counterpart of `PSY.EnergyReservoirStorage` (an energy reservoir storage unit) whose `operation_cost` is a [`NEMOfferCost`](@ref). It has
the fields, constructors, getters and setters of `PSY.EnergyReservoirStorage`, with the same per-unit conversions.

# Fields
- `name`: `String`
- `available`: `Bool`
- `bus`: `ACBus`
- `prime_mover_type`: `PrimeMovers`
- `storage_technology_type`: `StorageTech`
- `storage_capacity`: `Float64`
- `storage_level_limits`: `MinMax`
- `initial_storage_capacity_level`: `Float64`
- `rating`: `Float64`
- `active_power`: `Float64`
- `input_active_power_limits`: `MinMax`
- `output_active_power_limits`: `MinMax`
- `efficiency`: `NamedTuple{(:in, :out), Tuple{Float64, Float64}}`
- `reactive_power`: `Float64`
- `reactive_power_limits`: `Union{Nothing, PSY.MinMax}`
- `base_power`: `Float64`
- `operation_cost`: `NEMOfferCost`
- `conversion_factor`: `Float64`
- `storage_target`: `Float64`
- `cycle_limits`: `Int`
- `services`: `Vector{Service}`
- `dynamic_injector`: `Union{Nothing, DynamicInjection}`
- `ext`: `Dict{String, Any}`
- `internal`: `InfrastructureSystemsInternal`
"""
mutable struct NEMStorage <: PSY.Storage
    name::String
    available::Bool
    bus::ACBus
    prime_mover_type::PrimeMovers
    storage_technology_type::StorageTech
    storage_capacity::Float64
    storage_level_limits::PSY.MinMax
    initial_storage_capacity_level::Float64
    rating::Float64
    active_power::Float64
    input_active_power_limits::PSY.MinMax
    output_active_power_limits::PSY.MinMax
    efficiency::NamedTuple{(:in, :out), Tuple{Float64, Float64}}
    reactive_power::Float64
    reactive_power_limits::Union{Nothing, PSY.MinMax}
    base_power::Float64
    operation_cost::NEMOfferCost
    conversion_factor::Float64
    storage_target::Float64
    cycle_limits::Int
    services::Vector{Service}
    dynamic_injector::Union{Nothing, DynamicInjection}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function NEMStorage(name, available, bus, prime_mover_type, storage_technology_type, storage_capacity, storage_level_limits, initial_storage_capacity_level, rating, active_power, input_active_power_limits, output_active_power_limits, efficiency, reactive_power, reactive_power_limits, base_power, operation_cost = NEMOfferCost(), conversion_factor = 1.0, storage_target = 0.0, cycle_limits = 1.0e4, services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}())
    return NEMStorage(name, available, bus, prime_mover_type, storage_technology_type, storage_capacity, storage_level_limits, initial_storage_capacity_level, rating, active_power, input_active_power_limits, output_active_power_limits, efficiency, reactive_power, reactive_power_limits, base_power, operation_cost, conversion_factor, storage_target, cycle_limits, services, dynamic_injector, ext, IS.InfrastructureSystemsInternal())
end

function NEMStorage(; name, available, bus, prime_mover_type, storage_technology_type, storage_capacity, storage_level_limits, initial_storage_capacity_level, rating, active_power, input_active_power_limits, output_active_power_limits, efficiency, reactive_power, reactive_power_limits, base_power, operation_cost = NEMOfferCost(), conversion_factor = 1.0, storage_target = 0.0, cycle_limits = 1.0e4, services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}(), internal = IS.InfrastructureSystemsInternal())
    return NEMStorage(name, available, bus, prime_mover_type, storage_technology_type, storage_capacity, storage_level_limits, initial_storage_capacity_level, rating, active_power, input_active_power_limits, output_active_power_limits, efficiency, reactive_power, reactive_power_limits, base_power, operation_cost, conversion_factor, storage_target, cycle_limits, services, dynamic_injector, ext, internal)
end

_define_accessors!(
    NEMStorage,
    (:name, :available, :bus, :prime_mover_type, :storage_technology_type, :storage_level_limits, :initial_storage_capacity_level, :efficiency, :base_power, :operation_cost, :conversion_factor, :storage_target, :cycle_limits, :services, :dynamic_injector, :ext, :internal),
    (:storage_capacity, :rating, :active_power, :input_active_power_limits, :output_active_power_limits, :reactive_power, :reactive_power_limits),
    (:available, :bus, :prime_mover_type, :storage_technology_type, :storage_level_limits, :initial_storage_capacity_level, :efficiency, :base_power, :operation_cost, :conversion_factor, :storage_target, :cycle_limits, :services, :ext),
    (:storage_capacity, :rating, :active_power, :input_active_power_limits, :output_active_power_limits, :reactive_power, :reactive_power_limits),
)


"""
    NEMLoad(; <fields of PSY.InterruptiblePowerLoad>)

A NEM counterpart of `PSY.InterruptiblePowerLoad` (a controllable load) whose `operation_cost` is a [`NEMOfferCost`](@ref). It has
the fields, constructors, getters and setters of `PSY.InterruptiblePowerLoad`, with the same per-unit conversions.

# Fields
- `name`: `String`
- `available`: `Bool`
- `bus`: `ACBus`
- `active_power`: `Float64`
- `reactive_power`: `Float64`
- `max_active_power`: `Float64`
- `max_reactive_power`: `Float64`
- `base_power`: `Float64`
- `operation_cost`: `NEMOfferCost`
- `conformity`: `LoadConformity`
- `services`: `Vector{Service}`
- `dynamic_injector`: `Union{Nothing, DynamicInjection}`
- `ext`: `Dict{String, Any}`
- `internal`: `InfrastructureSystemsInternal`
"""
mutable struct NEMLoad <: PSY.ControllableLoad
    name::String
    available::Bool
    bus::ACBus
    active_power::Float64
    reactive_power::Float64
    max_active_power::Float64
    max_reactive_power::Float64
    base_power::Float64
    operation_cost::NEMOfferCost
    conformity::LoadConformity
    services::Vector{Service}
    dynamic_injector::Union{Nothing, DynamicInjection}
    ext::Dict{String, Any}
    internal::IS.InfrastructureSystemsInternal
end

function NEMLoad(name, available, bus, active_power, reactive_power, max_active_power, max_reactive_power, base_power, operation_cost, conformity = LoadConformity.UNDEFINED, services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}())
    return NEMLoad(name, available, bus, active_power, reactive_power, max_active_power, max_reactive_power, base_power, operation_cost, conformity, services, dynamic_injector, ext, IS.InfrastructureSystemsInternal())
end

function NEMLoad(; name, available, bus, active_power, reactive_power, max_active_power, max_reactive_power, base_power, operation_cost, conformity = LoadConformity.UNDEFINED, services = Device[], dynamic_injector = nothing, ext = Dict{String, Any}(), internal = IS.InfrastructureSystemsInternal())
    return NEMLoad(name, available, bus, active_power, reactive_power, max_active_power, max_reactive_power, base_power, operation_cost, conformity, services, dynamic_injector, ext, internal)
end

_define_accessors!(
    NEMLoad,
    (:name, :available, :bus, :base_power, :operation_cost, :conformity, :services, :dynamic_injector, :ext, :internal),
    (:active_power, :reactive_power, :max_active_power, :max_reactive_power),
    (:available, :bus, :base_power, :operation_cost, :conformity, :services, :ext),
    (:active_power, :reactive_power, :max_active_power, :max_reactive_power),
)

"""
    PSY.get_max_reactive_power(d::NEMRenewableGen)

The upper reactive power limit of `d`, or `rating * sin(acos(power_factor))` when it has no
reactive power limits.
"""
function PSY.get_max_reactive_power(d::NEMRenewableGen)
    limits = PSY.get_reactive_power_limits(d)
    isnothing(limits) && return PSY.get_rating(d) * sin(acos(PSY.get_power_factor(d)))
    return limits.max
end
