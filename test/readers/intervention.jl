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

    @testset "DISPATCHREGIONSUM" begin
        db = damaged_cache(AEM_TEST_HIVE_DIR, :DISPATCHREGIONSUM, _physical_copy("TRY_CAST(TOTALDEMAND AS DOUBLE) + 500.0 AS TOTALDEMAND"))
        _check_runs(read_demand, base_db, db, [:REGIONID], :TOTALDEMAND, 500.0)
    end

    @testset "DISPATCHPRICE" begin
        db = damaged_cache(AEM_TEST_HIVE_DIR, :DISPATCHPRICE, _physical_copy("TRY_CAST(RRP AS DOUBLE) + 3.0 AS RRP"))
        _check_runs(read_prices, base_db, db, [:REGIONID], :RRP, 3.0)
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
