@testset "Single-interval replication pipeline" begin
    db = aem_connect(HiveConfiguration(hive_location = AEM_TEST_HIVE_DIR, filesystem = "file"))
    t = DateTime(2025, 1, 1, 0, 5, 0)

    @testset "published interval" begin
        published = read_published_interval(db, t)
        # Mock flows at 00:05 (i = 1): MWFLOW = 100 * k + i for IC1..IC6.
        flows = Dict(zip(published.interconnectors.INTERCONNECTORID, published.interconnectors.MWFLOW))
        @test flows == Dict("IC$k" => 100.0k + 1 for k in 1:6)
        @test "BW01" in published.dispatch.DUID
        @test eltype(published.dispatch.TOTALCLEARED) <: Union{Missing, Float64}
        @test !isempty(published.prices)
        @test all(==(t), published.fcas_prices.SETTLEMENTDATE)

        # The mock carries only the pricing run (and no INTERVENTION column on interconnector results).
        physical = read_published_interval(db, t; intervention = 1)
        @test all(isempty, (physical.dispatch, physical.prices, physical.fcas_prices))
    end

    @testset "replicate_interval builds, solves and compares" begin
        result = replicate_interval(db, t)
        @test result.model isa PSI.DecisionModel
        comparison = result.comparison
        published = read_published_interval(db, t)

        # One row per published key, so nothing is dropped silently.
        @test nrow(comparison.prices) == nrow(published.prices)
        @test nrow(comparison.dispatch) == nrow(published.dispatch)
        @test nrow(comparison.interconnectors) == nrow(published.interconnectors)
        @test nrow(comparison.fcas_prices) == nrow(published.fcas_prices)
        @test all(==(t), comparison.fcas_prices.SETTLEMENTDATE)

        @test issubset(Set(["NSW1", "QLD1", "SA1", "TAS1", "VIC1"]), Set(comparison.prices.REGIONID))
        @test all(isfinite, skipmissing(comparison.prices.ROP_solved))
        @test any(!ismissing, comparison.prices.ROP_solved)
        @test any(!ismissing, comparison.dispatch.TOTALCLEARED_solved)
        @test any(!ismissing, comparison.interconnectors.MWFLOW_solved)
        @test all(isfinite, skipmissing(comparison.interconnectors.MWLOSSES_solved))
        @test any(!ismissing, comparison.fcas_prices.ROP_solved)
        # The unavailable IC6 has no solved flow.
        @test ismissing(only(filter(:INTERCONNECTORID => ==("IC6"), comparison.interconnectors)).MWFLOW_solved)
    end

    @testset "interval_flow_limits is opt-in" begin
        has_limits(sys) = all(
            has_time_series(d, SingleTimeSeries, "from_to_flow_limit") ||
                has_time_series(d, DeterministicSingleTimeSeries, "from_to_flow_limit") for
                d in get_components(AreaInterchange, sys)
        )
        @test !has_limits(replication_system(db, t))
        @test has_limits(replication_system(db, t; interval_flow_limits = true))
    end

    @testset "MNSP offers reach a built model through the single-window path" begin
        # The mock offers Basslink-like links on IC2 (300 MW available) for the intervals up to 04:00.
        t_mnsp = t
        sys = replication_system(db, t_mnsp)
        ic2 = get_component(AreaInterchange, sys, "IC2")
        @test has_time_series(ic2, Deterministic, "mnsp_forward_max_avail")
        result = replicate_interval(sys, db, t_mnsp)
        @test PSI.has_container_key(
            PSI.get_optimization_container(result.model), MNSPLinkFlowVariable, PSY.AreaInterchange,
        )
        flow = only(filter(:INTERCONNECTORID => ==("IC2"), result.comparison.interconnectors)).MWFLOW_solved
        @test abs(flow) <= 300.0 + 1.0e-6
    end
end
