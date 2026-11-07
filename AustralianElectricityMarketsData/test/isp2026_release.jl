using AustralianElectricityMarketsData: TransientDownloadError

const AEMD = AustralianElectricityMarketsData

function _isp_test_release(dir, entries)
    archives = ISPArchive[]
    for (kind, filename, bytes) in entries
        path = joinpath(dir, filename)
        write(path, bytes)
        push!(
            archives,
            ISPArchive(
                kind, filename, filesize(path), AEMD._isp_sha256(path), "rev",
                "https://example.test/$filename"
            )
        )
    end
    return ISPRelease("test release", Date(2026, 9, 28), "https://example.test", archives)
end

@testset "_isp_sha256 matches a known vector" begin
    mktempdir() do dir
        path = joinpath(dir, "abc")
        write(path, "abc")
        @test AEMD._isp_sha256(path) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    end
end

@testset "ISP release record" begin
    @test length(ISP_RELEASE_2026.archives) == 5
    @test sort([a.kind for a in ISP_RELEASE_2026.archives]) ==
        [:hydro, :model, :solar, :timeslice, :wind]
    @test all(a -> occursin(r"^[0-9a-f]{64}$", a.sha256), ISP_RELEASE_2026.archives)
    @test all(a -> a.bytes > 0, ISP_RELEASE_2026.archives)
    @test length(unique([a.filename for a in ISP_RELEASE_2026.archives])) == 5
    @test isp_archives_dir(HiveConfiguration()) ==
        joinpath(homedir(), ".nemdb_cache", "ISP", "2026", "archives")
end

@testset "acquire_isp_archives matches a browser-named archive by hash" begin
    mktempdir() do root
        source = joinpath(root, "Downloads")
        mkpath(source)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        dest = joinpath(root, "cache", "ISP", "2026", "archives")
        release = _isp_test_release(source, [(:model, "2026-isp-model.zip", b"model bytes")])
        mv(
            joinpath(source, "2026-isp-model.zip"),
            joinpath(source, "2026 ISP Model (1).zip")
        )
        paths = acquire_isp_archives(
            config, source; release,
            download! = (url, path) -> error("unexpected download of $url")
        )
        @test paths[:model] == joinpath(dest, "2026-isp-model.zip")
        @test read(paths[:model]) == b"model bytes"
        @test isfile(joinpath(source, "2026 ISP Model (1).zip"))
        @test !isfile(joinpath(dest, "2026-isp-model.zip.part"))
    end
end

@testset "acquire_isp_archives reuses an archive already in the cache" begin
    mktempdir() do root
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        dest = joinpath(root, "cache", "ISP", "2026", "archives")
        mkpath(dest)
        release = _isp_test_release(dest, [(:wind, "2026-isp-wind-traces.zip", b"wind bytes")])
        source = joinpath(root, "Downloads")
        mkpath(source)
        paths = acquire_isp_archives(
            config, source; release,
            download! = (url, path) -> error("unexpected download of $url")
        )
        @test paths[:wind] == joinpath(dest, "2026-isp-wind-traces.zip")
        @test read(paths[:wind]) == b"wind bytes"
    end
end

@testset "acquire_isp_archives reports every missing archive in one error" begin
    mktempdir() do root
        source = joinpath(root, "Downloads")
        mkpath(source)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        dest = joinpath(root, "cache", "ISP", "2026", "archives")
        release = ISPRelease(
            "test release", Date(2026, 9, 28), "https://example.test",
            [
                ISPArchive(
                    :model, "2026-isp-model.zip", 11, repeat("0", 64), "rev-m",
                    "https://example.test/model"
                ),
                ISPArchive(
                    :wind, "2026-isp-wind-traces.zip", 10, repeat("1", 64), "rev-w",
                    "https://example.test/wind"
                ),
            ]
        )
        err = try
            acquire_isp_archives(
                config, source; release,
                download! = (url, path) -> throw(TransientDownloadError("HTTP 403 for $url"))
            )
        catch e
            e
        end
        @test err isa ISPReleaseError
        msg = sprint(showerror, err)
        @test occursin("2026-isp-model.zip", msg)
        @test occursin("https://example.test/model", msg)
        @test occursin("2026-isp-wind-traces.zip", msg)
        @test occursin(dest, msg)
        @test !isfile(joinpath(dest, "2026-isp-model.zip"))
        @test !isfile(joinpath(dest, "2026-isp-model.zip.part"))
    end
end

@testset "a canonical-named file with the wrong bytes is a release-list error" begin
    mktempdir() do root
        source = joinpath(root, "Downloads")
        mkpath(source)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        release = _isp_test_release(source, [(:model, "2026-isp-model.zip", b"expected")])
        write(joinpath(source, "2026-isp-model.zip"), b"tampered")
        err = try
            acquire_isp_archives(
                config, source; release,
                download! = (url, path) -> error("unexpected download of $url")
            )
        catch e
            e
        end
        @test err isa ISPReleaseError
        msg = sprint(showerror, err)
        @test occursin("2026-isp-model.zip", msg)
        @test occursin(release.archives[1].sha256, msg)
        @test read(joinpath(source, "2026-isp-model.zip")) == b"tampered"
    end
end

@testset "a same-size browser-named file with the wrong bytes is not accepted" begin
    mktempdir() do root
        source = joinpath(root, "Downloads")
        mkpath(source)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        dest = joinpath(root, "cache", "ISP", "2026", "archives")
        release = _isp_test_release(source, [(:model, "2026-isp-model.zip", b"expected")])
        rm(joinpath(source, "2026-isp-model.zip"))
        write(joinpath(source, "2026 ISP Model (1).zip"), b"tampered")
        err = try
            acquire_isp_archives(
                config, source; release,
                download! = (url, path) -> throw(TransientDownloadError("HTTP 403"))
            )
        catch e
            e
        end
        @test err isa ISPReleaseError
        @test read(joinpath(source, "2026 ISP Model (1).zip")) == b"tampered"
        @test !isfile(joinpath(dest, "2026-isp-model.zip"))
    end
end

@testset "a downloaded file that fails the release hash is collected and removed" begin
    mktempdir() do root
        source = joinpath(root, "Downloads")
        mkpath(source)
        config = HiveConfiguration(; hive_location = joinpath(root, "cache"))
        dest = joinpath(root, "cache", "ISP", "2026", "archives")
        release = _isp_test_release(source, [(:model, "2026-isp-model.zip", b"expected")])
        rm(joinpath(source, "2026-isp-model.zip"))
        err = try
            acquire_isp_archives(
                config, source; release,
                download! = (url, path) -> write(path, b"not the release")
            )
        catch e
            e
        end
        @test err isa ISPReleaseError
        @test occursin("do not match the release record", sprint(showerror, err))
        @test !isfile(joinpath(dest, "2026-isp-model.zip"))
        @test !isfile(joinpath(dest, "2026-isp-model.zip.part"))
    end
end

@testset "ISP archives require the local filesystem" begin
    config = HiveConfiguration(; hive_location = "bucket/prefix", filesystem = "s3")
    @test_throws ArgumentError acquire_isp_archives(config, mktempdir())
end
