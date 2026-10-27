@testset "fixed-load-only preflight needs no GENCONDATA" begin
    db = damaged_cache(
        AEM_TEST_REPLAY_HIVE_DIR, :DISPATCHCONSTRAINT,
        "UPDATE input SET CONSTRAINTID = '\$BW01'"
    )
    fixed_db = damaged_cache(
        db.config.hive_location, :BIDPEROFFER_D,
        "UPDATE input SET FIXEDLOAD = 1.0 WHERE DUID = 'BW01' AND BIDTYPE = 'ENERGY'"
    )
    rm(joinpath(fixed_db.config.hive_location, "GENCONDATA"); recursive = true)
    t = DateTime(2025, 1, 1, 0, 5)
    @test isnothing(ReplayWorkflow._preflight_inputs(fixed_db, t:Minute(5):(t + Minute(10))))
end
