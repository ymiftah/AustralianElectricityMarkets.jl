@testset "mnsp_fixed_load maps a NULL loading to zeros and a published one to its value" begin
    AEM = AustralianElectricityMarkets
    @test AEM.mnsp_fixed_load(NaN) == (0.0, 0.0)
    @test AEM.mnsp_fixed_load(0.0) == (0.0, 1.0)
    @test AEM.mnsp_fixed_load(-120.0) == (-120.0, 1.0)
end

# A mock hive with the Basslink flow rows of the MNSP tests, so `set_mnsp_offers!` reads its metered flow.
function _mnsp_mock_hive()
    hive = joinpath(mktempdir(), "hive")
    create_mock_data(hive)
    rows = DataFrame(
        SETTLEMENTDATE = repeat([DateTime(2025, 1, 1, 11, 55), DateTime(2025, 1, 1, 12)], 2),
        INTERCONNECTORID = fill("IC2", 4), METEREDMWFLOW = [125.0, -75.0, -125.0, 75.0],
        INTERVENTION = [0, 0, 1, 1], MWFLOW = fill(999.0, 4), EXPORTLIMIT = fill(500.0, 4), IMPORTLIMIT = fill(-500.0, 4),
    )
    db = DuckDB.DB()
    DuckDB.register_data_frame(db, rows, "mnsp_flow")
    file = joinpath(hive, "DISPATCHINTERCONNECTORRES", "archive_month=2025-01", "mnsp.parquet")
    mkpath(dirname(file))
    DuckDB.execute(db, "COPY mnsp_flow TO '$file' (FORMAT PARQUET)")
    DuckDB.close(db)
    return hive
end

const _MNSP_WINDOW = DateTime(2025, 1, 1, 11, 55):Minute(5):DateTime(2025, 1, 1, 12, 5)

# The MNSP system of `db` with its offers attached, and the fixed-loading series written by the writer.
function _mnsp_fixed_load_system(db)
    sys = nem_system(db, RegionalNetworkConfiguration())
    set_mnsp_offers!(sys, db, _MNSP_WINDOW)
    AustralianElectricityMarkets._set_mnsp_fixed_loads!(sys)
    return sys
end

# Checks the four written series of each MNSP bid of `sys` against its raw `FIXEDLOAD` series, mapped by
# `mnsp_fixed_load`. Returns the numbers of bids with a published loading and with a NULL one (no series).
function _check_mnsp_fixed_loads(sys)
    AEM = AustralianElectricityMarkets
    counts = Dict(:published => 0, :null => 0)
    for ic in PowerSystems.get_components(PowerSystems.AreaInterchange, sys), dir in ("forward", "reverse")
        bid = AEM._mnsp_bid(ic, dir)
        isnothing(bid) && continue
        names = AEM.NEM_MNSP_FIXED_LOAD_SERIES
        value_name, invoked_name = getproperty(names, Symbol(dir, "_value")), getproperty(names, Symbol(dir, "_invoked"))
        written(name) = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, name; ignore_scaling_factors = true)
        if isnothing(bid.fixed_load)
            @test written(value_name) == zeros(length(written(value_name)))
            @test written(invoked_name) == zeros(length(written(invoked_name)))
            counts[:null] += 1
        else
            raw = collect(values(PowerSystems.get_time_series_array(ic, PowerSystems.IS.get_time_series(ic, bid.fixed_load))))
            @test written(value_name) == first.(AEM.mnsp_fixed_load.(raw))
            @test written(invoked_name) == last.(AEM.mnsp_fixed_load.(raw))
            counts[:published] += 1
        end
    end
    return counts
end

@testset "the writer gives a bid without a fixed loading zeros on its MAXAVAIL grid" begin
    db = aem_connect(HiveConfiguration(hive_location = _mnsp_mock_hive(), filesystem = "file"))
    sys = _mnsp_fixed_load_system(db)
    counts = _check_mnsp_fixed_loads(sys)
    @test counts[:null] == 2
    ic = PowerSystems.get_component(PowerSystems.AreaInterchange, sys, "IC2")
    @test PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, "forward_fixed_load_value"; ignore_scaling_factors = true) == [0.0, 0.0]
end

@testset "the writer maps a published fixed loading to its value and invocation flag" begin
    # FIXEDLOAD is 4 MW at 11:55 and NULL at 12:00 on both Basslink links.
    db = damaged_cache(_mnsp_mock_hive(), :MNSP_BIDOFFERPERIOD, "UPDATE input SET FIXEDLOAD = 4 WHERE PERIODID = 95")
    sys = _mnsp_fixed_load_system(db)
    counts = _check_mnsp_fixed_loads(sys)
    @test counts[:published] == 2
    ic = PowerSystems.get_component(PowerSystems.AreaInterchange, sys, "IC2")
    get(name) = PowerSystems.get_time_series_values(PowerSystems.SingleTimeSeries, ic, name; ignore_scaling_factors = true)
    @test get("forward_fixed_load_value") == [4.0, 0.0]
    @test get("forward_fixed_load_invoked_flag") == [1.0, 0.0]
    @test get("reverse_fixed_load_value") == [4.0, 0.0]
    @test get("reverse_fixed_load_invoked_flag") == [1.0, 0.0]
end
