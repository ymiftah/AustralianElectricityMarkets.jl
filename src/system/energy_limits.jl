"""
    set_nem_energy_limits!(sys, db, date_range; intervention = 0)

Attaches separate energy `MAXAVAIL` and semi-scheduled `UIGF` series, in system-base per-unit,
to available non-storage dispatch devices. Validates complete, finite, non-negative inputs
and a stable effective schedule type before modifying `sys`.

# Arguments
- `sys`: the system after bids and FCAS participants have been attached.
- `db`: the market cache connection.
- `date_range`: five-minute dispatch intervals, including the exclusive stop timestamp.
- `intervention`: the dispatch run used for UIGF.

# Returns
`nothing`. Non-scheduled FCAS-only loads receive zero energy availability and are identified
as non-semi-scheduled. Missing required input raises `ArgumentError`.
"""
function set_nem_energy_limits!(sys, db, date_range; intervention::Integer = 0)
    step(date_range) == Minute(5) || throw(ArgumentError("energy limits require five-minute intervals"))
    grid = collect(date_range)[1:(end - 1)]
    isempty(grid) && throw(ArgumentError("energy limits require at least one interval"))
    rows = read_energy_limits(db, date_range; intervention)
    by_offer = Dict((r.DUID, r.DIRECTION, r.SETTLEMENTDATE) => r for r in eachrow(rows))
    staged = NamedTuple[]
    problems = String[]
    for device in _nem_dispatch_devices(sys)
        device isa PSY.Storage && continue
        name = get_name(device)
        availability = Float64[]
        forecast = Float64[]
        modes = String[]
        if _is_non_scheduled_load(device)
            availability = zeros(length(grid))
            push!(modes, "NON-SCHEDULED")
        else
            direction = device isa PSY.ControllableLoad ? "LOAD" : "GEN"
            for t in grid
                key = (name, direction, t)
                if !haskey(by_offer, key)
                    push!(problems, "$name $direction at $t: missing energy offer")
                    continue
                end
                row = by_offer[key]
                if ismissing(row.SCHEDULE_TYPE) || !(row.SCHEDULE_TYPE in ("SCHEDULED", "SEMI-SCHEDULED", "NON-SCHEDULED"))
                    push!(problems, "$name at $t: missing or invalid effective schedule type")
                    continue
                end
                push!(modes, row.SCHEDULE_TYPE)
                if ismissing(row.MAXAVAIL) || !isfinite(row.MAXAVAIL) || row.MAXAVAIL < 0
                    push!(problems, "$name at $t: missing or invalid energy MAXAVAIL")
                    continue
                end
                push!(availability, row.MAXAVAIL)
                if row.SCHEDULE_TYPE == "SEMI-SCHEDULED"
                    if ismissing(row.UIGF) || !isfinite(row.UIGF) || row.UIGF < 0
                        push!(problems, "$name at $t: missing or invalid UIGF")
                        continue
                    end
                    push!(forecast, row.UIGF)
                end
            end
        end
        length(unique(modes)) == 1 || push!(problems, "$name: schedule type changes or is missing in the requested range")
        push!(staged, (; device, availability, forecast, semi = "SEMI-SCHEDULED" in modes))
    end
    isempty(problems) || throw(ArgumentError("set_nem_energy_limits!: " * join(problems, "; ")))
    base = get_base_power(sys)
    for data in staged
        add_time_series!(sys, data.device, SingleTimeSeries(; name = "energy_max_avail", data = TimeArray(grid, data.availability ./ base)))
        if data.semi
            add_time_series!(sys, data.device, SingleTimeSeries(; name = "energy_uigf", data = TimeArray(grid, data.forecast ./ base)))
        end
        get_ext(data.device)["nem_semi_scheduled"] = data.semi
    end
    return
end
