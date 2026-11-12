# Replay baseline tools: the snapshot comparison that gates every later change against the captured
# baseline, and the key-type count. Only the comparison logic is tested here; `capture.jl` and the
# real-data captures are run by hand.

include(joinpath(@__DIR__, "baseline", "snapshot.jl"))
include(joinpath(@__DIR__, "baseline", "compare.jl"))

const BT_T1 = DateTime(2025, 1, 1, 0, 5)
const BT_T2 = DateTime(2025, 1, 1, 0, 10)

@testset "identical snapshots have no mismatch" begin
    a = Dict("variable/x" => DataFrame(DateTime = [BT_T1, BT_T2], u = [1.0, 2.0]))
    @test isempty(compare_snapshots(a, deepcopy(a)))
end

@testset "variable differences gate at 1e-9" begin
    a = Dict("variable/x" => DataFrame(DateTime = [BT_T1, BT_T2], u = [1.0, 2.0]))
    b = deepcopy(a)
    b["variable/x"].u[2] += 2.0e-9
    @test only(compare_snapshots(a, b)).key == "variable/x"
    b = deepcopy(a)
    b["variable/x"].u[2] += 5.0e-10
    @test isempty(compare_snapshots(a, b))
end

@testset "keys present on one side only are mismatches unless allowed" begin
    a = Dict("variable/x" => DataFrame(DateTime = [BT_T1, BT_T2], u = [1.0, 2.0]))
    c = merge(a, Dict("variable/new" => a["variable/x"]))
    @test !isempty(compare_snapshots(a, c))
    @test isempty(compare_snapshots(a, c; allow_new = [r"new"]))
    @test !isempty(compare_snapshots(c, a))
    @test isempty(compare_snapshots(c, a; allow_missing = [r"new"]))
end

@testset "parameter differences are reported, not gating" begin
    a = Dict("variable/x" => DataFrame(DateTime = [BT_T1, BT_T2], u = [1.0, 2.0]))
    p = merge(a, Dict("parameter/p" => DataFrame(DateTime = [BT_T1], u = [1.0])))
    q = deepcopy(p)
    q["parameter/p"].u[1] = 9.0
    @test isempty(compare_snapshots(p, q))
    @test max_parameter_difference(p, q).max_abs == 8.0
end

@testset "stats compare the objective relatively" begin
    stats(obj) = Dict(
        "stats/optimizer" => DataFrame(
            DateTime = [BT_T1, BT_T2], objective_value = [obj, 2.0e6], timed_solve_time = [0.1, 0.2],
            termination_status = ["OPTIMAL", "OPTIMAL"],
        ),
    )
    a = stats(1.0e6)
    b = deepcopy(a)
    b["stats/optimizer"].objective_value[1] += 1.0e-4
    @test isempty(compare_snapshots(a, b))
    b["stats/optimizer"].objective_value[1] += 1.0e-2
    @test only(compare_snapshots(a, b)).kind == "stats"
    b = deepcopy(a)
    b["stats/optimizer"].timed_solve_time[1] = 9.0
    @test isempty(compare_snapshots(a, b))
end

@testset "mask_gc_slacks zeroes slacks at intervals where the constraint is not invoked" begin
    slack = "variable/GenericConstraintSlackUp__GenericConstraint__gc1"
    invoked = DataFrame(DateTime = [BT_T1, BT_T2], gc1 = [1.0, 0.0])
    a = Dict(slack => DataFrame(DateTime = [BT_T1, BT_T2], value = [3.0, 4.0]), "input/constraint_invoked" => invoked)
    b = deepcopy(a)
    b[slack].value[2] = 7.0
    @test !isempty(compare_snapshots(a, b))
    @test isempty(compare_snapshots(a, b; mask_gc_slacks = true))
    b[slack].value[1] = 8.0
    @test !isempty(compare_snapshots(a, b; mask_gc_slacks = true))
end
