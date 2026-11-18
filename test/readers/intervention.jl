# The mock hive carries the pricing run only. Each test copies the rows of one interval (00:10)
# into the physical run with changed values, so 00:05 keeps run 0 alone and 00:10 has both runs.
# A single read must then return run 1 at 00:10 and run 0 at 00:05.

const _PRICING_STAMP = DateTime(2025, 1, 1, 0, 5)
const _PHYSICAL_STAMP = DateTime(2025, 1, 1, 0, 10)
const _RUN_WINDOW = (_PRICING_STAMP, DateTime(2025, 1, 1, 0, 15))

_physical_copy(change) = "INSERT INTO input SELECT * REPLACE (1 AS INTERVENTION, $change) FROM input WHERE SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:10'"

# Asserts that `reader` over the window returns run 0 with intervention 0, and with intervention 1
# the physical values (`value + shift`) at 00:10 and the pricing values at 00:05, with the same keys.
function _check_runs(reader, base_db, db, ids, value, shift)
    cells(df) = Dict(Tuple(row[c] for c in [:SETTLEMENTDATE, ids...]) => row[value] for row in eachrow(df))
    pricing = cells(reader(base_db, _RUN_WINDOW; intervention = 0))
    @test !isempty(pricing)
    @test any(c -> c[1] == _PHYSICAL_STAMP, keys(pricing))
    @test cells(reader(db, _RUN_WINDOW; intervention = 0)) == pricing
    physical = cells(reader(db, _RUN_WINDOW; intervention = 1))
    @test Set(keys(physical)) == Set(keys(pricing))
    for (cell, v) in pricing
        expected = cell[1] == _PHYSICAL_STAMP ? v + shift : v
        @test physical[cell] ≈ expected
    end
    return
end

@testset "Intervention run is chosen per interval" begin
    base_db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR))

    @testset "DISPATCHLOAD" begin
        db = damaged_cache(AEM_TEST_HIVE_DIR, :DISPATCHLOAD, _physical_copy("TRY_CAST(INITIALMW AS DOUBLE) + 7.0 AS INITIALMW"))
        _check_runs(read_dispatch_limits, base_db, db, [:DUID], :INITIALMW, 7.0)
    end

    @testset "DISPATCHLOAD UIGF" begin
        db = damaged_cache(AEM_TEST_HIVE_DIR, :DISPATCHLOAD, _physical_copy("TRY_CAST(UIGF AS DOUBLE) + 6.0 AS UIGF"))
        _check_runs(read_uigf, base_db, db, [:DUID], :UIGF, 6.0)
    end

    @testset "read_demand charging rows follow the run of their interval" begin
        # Run 0 charges BW01 by 10 MW at 00:05 and run 1 charges it by 30 MW at 00:10. The run-0
        # charge at 00:05 must still count for intervention 1, which has no run-1 rows there.
        db = damaged_cache(
            AEM_TEST_HIVE_DIR, :DISPATCHLOAD,
            [
                "UPDATE input SET INITIALMW = -10.0 WHERE DUID = 'BW01' AND SETTLEMENTDATE = TIMESTAMP '2025-01-01 00:05'",
                _physical_copy("CASE WHEN DUID = 'BW01' THEN -30.0 ELSE TRY_CAST(INITIALMW AS DOUBLE) END AS INITIALMW"),
            ],
        )
        lossdemand(df) = Dict((row.SETTLEMENTDATE, row.REGIONID) => row.LOSSDEMAND for row in eachrow(df))
        base_loss = lossdemand(read_demand(base_db, _RUN_WINDOW; intervention = 0))
        # The LOSSDEMAND change against the pricing-run cache, where it differs.
        shifts(df) = Dict(k => v - base_loss[k] for (k, v) in lossdemand(df) if !isapprox(v, base_loss[k]))
        pricing = shifts(read_demand(db, _RUN_WINDOW; intervention = 0))
        physical = shifts(read_demand(db, _RUN_WINDOW; intervention = 1))
        @test collect(values(pricing)) ≈ [-10.0]
        @test all(k[1] == _PRICING_STAMP for k in keys(pricing))
        @test [v for (_, v) in sort(collect(physical))] ≈ [-10.0, -30.0]
    end

    @testset "DISPATCHREGIONSUM" begin
        # The solar UIGF is read by _read_regional_renewable_uigf, which is checked with the same cache.
        db = damaged_cache(
            AEM_TEST_HIVE_DIR, :DISPATCHREGIONSUM,
            _physical_copy("TRY_CAST(TOTALDEMAND AS DOUBLE) + 500.0 AS TOTALDEMAND, TRY_CAST(SS_SOLAR_UIGF AS DOUBLE) + 9.0 AS SS_SOLAR_UIGF"),
        )
        _check_runs(read_demand, base_db, db, [:REGIONID], :TOTALDEMAND, 500.0)
        regional_uigf(source, range; intervention) = AustralianElectricityMarkets.Readers._read_regional_renewable_uigf(
            source, range; resolution = Minute(5), intervention,
        )
        _check_runs(regional_uigf, base_db, db, [:REGIONID], :SS_SOLAR_UIGF, 9.0)
    end

    @testset "DISPATCHPRICE" begin
        # The run-1 copy changes RRP, ROP and the RAISEREG prices, so every price reader sees a difference.
        db = damaged_cache(
            AEM_TEST_HIVE_DIR, :DISPATCHPRICE,
            _physical_copy(
                "TRY_CAST(RRP AS DOUBLE) + 3.0 AS RRP, TRY_CAST(ROP AS DOUBLE) + 3.0 AS ROP, " *
                    "TRY_CAST(RAISEREGRRP AS DOUBLE) + 3.0 AS RAISEREGRRP, TRY_CAST(RAISEREGROP AS DOUBLE) + 3.0 AS RAISEREGROP",
            ),
        )
        _check_runs(read_prices, base_db, db, [:REGIONID], :RRP, 3.0)

        @testset "published prices and FCAS prices stay on run 0" begin
            # read_published_interval also reads the interconnector results, so this hive carries them.
            hive = joinpath(mktempdir(), "hive")
            cp(AEM_TEST_HIVE_DIR, hive)
            write_mock_interconnector_results(hive)
            published_base = aem_connect(HiveConfiguration(hive_location = hive))
            published_db = damaged_cache(
                hive, :DISPATCHPRICE,
                _physical_copy(
                    "TRY_CAST(RRP AS DOUBLE) + 3.0 AS RRP, TRY_CAST(ROP AS DOUBLE) + 3.0 AS ROP, " *
                        "TRY_CAST(RAISEREGRRP AS DOUBLE) + 3.0 AS RAISEREGRRP, TRY_CAST(RAISEREGROP AS DOUBLE) + 3.0 AS RAISEREGROP",
                ),
            )
            steps = _PRICING_STAMP:Minute(5):_PHYSICAL_STAMP
            published = read_published_interval(published_db, steps; intervention = 1)
            pricing = read_published_interval(published_base, steps)
            @test !isequal(read_prices(published_db, _RUN_WINDOW; intervention = 1), read_prices(published_base, _RUN_WINDOW))
            @test !isequal(read_fcas_prices(published_db, _RUN_WINDOW; intervention = 1), read_fcas_prices(published_base, _RUN_WINDOW))
            @test isequal(published.prices, pricing.prices)
            @test isequal(published.fcas_prices, pricing.fcas_prices)
        end
    end

    @testset "DISPATCHCONSTRAINT" begin
        db = damaged_cache(AEM_TEST_HIVE_DIR, :DISPATCHCONSTRAINT, _physical_copy("TRY_CAST(RHS AS DOUBLE) + 5.0 AS RHS"))
        _check_runs(read_invoked_constraints, base_db, db, [:GENCONID], :RHS, 5.0)
    end

    @testset "DISPATCH_FCAS_REQ" begin
        db = damaged_cache(
            AEM_TEST_HIVE_DIR, :DISPATCH_FCAS_REQ,
            _physical_copy("TRY_CAST(MARGINALVALUE AS DOUBLE) + 1.0 AS MARGINALVALUE"),
        )
        _check_runs(read_fcas_requirements, base_db, db, [:REGIONID, :BIDTYPE, :GENCONID], :MARGINALVALUE, 1.0)
    end

    @testset "DISPATCHINTERCONNECTORRES" begin
        # The mock writes these results without an INTERVENTION column, so the run column is added first.
        hive = joinpath(mktempdir(), "hive")
        cp(AEM_TEST_HIVE_DIR, hive)
        write_mock_interconnector_results(hive)
        interconnector_base = aem_connect(HiveConfiguration(hive_location = hive))
        @testset "a table without the column is read unfiltered" begin
            for intervention in (0, 1)
                @test isequal(
                    read_interconnector_limits(interconnector_base, _RUN_WINDOW; intervention),
                    read_interconnector_limits(interconnector_base, _RUN_WINDOW),
                )
            end
        end
        db = damaged_cache(
            hive, :DISPATCHINTERCONNECTORRES,
            [
                "ALTER TABLE input ADD COLUMN INTERVENTION INTEGER DEFAULT 0",
                _physical_copy("TRY_CAST(METEREDMWFLOW AS DOUBLE) + 4.0 AS METEREDMWFLOW"),
            ],
        )
        _check_runs(read_interconnector_limits, interconnector_base, db, [:INTERCONNECTORID], :METEREDMWFLOW, 4.0)
    end

    @testset "intervention must be 0 or 1" begin
        for intervention in (-1, 2)
            @test_throws ArgumentError read_prices(base_db, _RUN_WINDOW; intervention)
            @test_throws ArgumentError read_demand(base_db, _RUN_WINDOW; intervention)
        end
    end
end
