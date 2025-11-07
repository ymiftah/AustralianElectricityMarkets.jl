@testset "Test RegionModel" begin

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
            TidierDB.@collect(
                TidierDB.@head(
                    x, 5
                )
            )
        )
        @test nrow(table) == 5
    end

    system = nem_system(db, RegionalNetworkConfiguration())

    areas = get_components(Area, system) |> collect .|> get_name |> sort!
    @test areas == ["NSW1", "QLD1", "SA1", "SNOWY1", "TAS1", "VIC1"]

end
