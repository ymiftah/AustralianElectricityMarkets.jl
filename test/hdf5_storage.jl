@testset "file-backed writes release native datatype handles" begin
    hdf5 = PowerSystems.IS.HDF5
    count_types() = hdf5.API.h5f_get_obj_count(hdf5.API.H5F_OBJ_ALL, hdf5.API.H5F_OBJ_DATATYPE)
    mktempdir() do folder
        path = joinpath(folder, "series.h5")
        data = ones(4)
        hdf5.h5open(path, "w") do file
            file["data"] = data
        end
        GC.gc(true)
        before = count_types()
        gc_enabled = GC.enable(false)
        try
            for _ in 1:20
                hdf5.h5open(path, "w") do file
                    file["data"] = data
                    @test read(file, "data") == data
                end
            end
            @test count_types() == before
        finally
            GC.enable(gc_enabled)
        end
    end
end
