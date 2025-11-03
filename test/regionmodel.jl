@testitem "Test RegionModel" begin
    import AustralianElectricityMarkets.RegionModel as RM
    using Dates
    using TidierDB
    using DataFrames: nrow
    using PowerSystems


    db = connect(duckdb())
    map(
        [
            :INTERCONNECTOR,
            :INTERCONNECTORCONSTRAINT,
            :DISPATCHREGIONSUM,
            :DUDETAIL,
            :DUDETAILSUMMARY,
            :STATION,
            :STATIONOPERATINGSTATUS,
            :GENUNITS,
            :DUALLOC,
        ]
    ) do table
        fetch_table_data(table, Date(2025, 1, 1):Date(2025, 1, 1))
        table = read_hive(db, table) |> x -> (
            @collect(
                @head(
                    x, 5
                )
            )
        )
        @test nrow(table) == 5
    end

    system = RM.get_system(db)

    areas = get_components(Area, system) |> collect .|> get_name |> sort!
    @test areas == ["NSW1", "QLD1", "SA1", "SNOWY1", "TAS1", "VIC1"]

end
