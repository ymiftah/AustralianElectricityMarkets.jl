# Local diagnostic, excluded from CI. Uses supported PSY storage APIs without replacing readers.
# julia -O1 --project=AustralianElectricityMarketsSimulations/test \
#     AustralianElectricityMarketsSimulations/test/real_data/benchmark_store_reads.jl
using AustralianElectricityMarkets
using Dates
using PowerSystemCaseBuilder
import PowerSystems as PSY

function read_series(device, key, count)
    for _ in 1:count
        PSY.get_time_series(device, key; start_time = DateTime(2026), len = 1)
    end
    return
end

function read_bulk(sys, device, key, count)
    return PSY.open_time_series_store!(sys, "r") do
        read_series(device, key, count)
    end
end

function benchmark_store_reads()
    sys = PowerSystemCaseBuilder.build_system(PowerSystemCaseBuilder.PSISystems, "5_bus_hydro_ed_sys")
    PSY.clear_time_series!(sys)
    device = first(PSY.get_components(PSY.ThermalStandard, sys))
    curves = [PSY.PiecewiseStepData([0.0, 10.0], [10.0]) for _ in 1:60]
    key = PSY.add_time_series!(sys, device, single_series("probe", DateTime(2026), curves, Minute(5)))
    read_series(device, key, 1)
    read_bulk(sys, device, key, 1)
    println((; julia = string(VERSION), psy = string(Base.pkgversion(PSY)), optimization_level = Int(Base.JLOptions().opt_level)))
    for count in (100, 1000, 3000)
        GC.gc()
        plain = @timed read_series(device, key, count)
        GC.gc()
        bulk = @timed read_bulk(sys, device, key, count)
        println(
            (;
                count, plain_s = plain.time, bulk_s = bulk.time, plain_gc_s = plain.gctime,
                bulk_gc_s = bulk.gctime, plain_bytes = plain.bytes, bulk_bytes = bulk.bytes,
            )
        )
        flush(stdout)
    end
    return
end

if abspath(PROGRAM_FILE) == @__FILE__
    benchmark_store_reads()
end
