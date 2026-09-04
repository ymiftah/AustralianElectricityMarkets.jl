@testset "read_plexos_xml" begin
    path = joinpath(mktempdir(), "fixture.xml")
    write_isp_fixture(path)
    frames = read_plexos_xml(path)

    @test frames isa Dict{String, DataFrame}
    @test nrow(frames["t_object"]) == 7
    @test nrow(frames["t_data"]) == 7
    @test nrow(frames["t_date_from"]) == 3
    @test nrow(frames["t_band"]) == 1

    # Records with differing field sets union into one frame, absent => missing.
    obj = frames["t_object"]
    @test Set(names(obj)) == Set(["object_id", "class_id", "name", "category_id"])
    @test obj[obj.name .== "GEN_PLAIN", :object_id] == ["6"]

    # Every column is string-typed; numeric casting happens in SQL, not here.
    @test eltype(frames["t_data"].value) <: Union{String, Missing}
end
