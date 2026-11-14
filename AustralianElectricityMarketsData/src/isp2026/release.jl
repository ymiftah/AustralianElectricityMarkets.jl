# ── Built-in ISP release records ─────────────────────────────────────────────

"""
    ISPArchive

One archive published in an ISP release.

# Fields
- `kind::Symbol`: archive role, one of `:model`, `:hydro`, `:solar`, `:timeslice`, `:wind`.
- `filename::String`: canonical filename the archive is stored under.
- `bytes::Int`: exact archive size in bytes, used to skip SHA-256 work on unrelated files.
- `sha256::String`: lowercase hex SHA-256 of the published archive.
- `revision::String`: AEMO media revision token.
- `url::String`: the AEMO download URL.
"""
struct ISPArchive
    kind::Symbol
    filename::String
    bytes::Int
    sha256::String
    revision::String
    url::String
end

"""
    ISPRelease

A published ISP release: its archives and the page they were published on.

# Fields
- `name::String`: release name, e.g. `"2026 ISP"`.
- `page_date::Date`: publication date recorded in the source provenance.
- `source_page::String`: the AEMO publication page.
- `archives::Vector{ISPArchive}`: every archive in the release.
"""
struct ISPRelease
    name::String
    page_date::Date
    source_page::String
    archives::Vector{ISPArchive}
end

"""
    ISP_RELEASE_2026

The 2026 ISP release of 28 September 2026: five archives with their AEMO revision and SHA-256.
"""
const ISP_RELEASE_2026 = ISPRelease(
    "2026 ISP",
    Date(2026, 9, 28),
    "https://www.aemo.com.au/energy-systems/major-publications/integrated-system-plan-isp/2026-integrated-system-plan-isp",
    ISPArchive[
        ISPArchive(
            :model, "2026-isp-model.zip", 116917347,
            "d25ad3905dd6e8bffcdd53f323d6caccd4d188f2e10c600d5a97a35d9616e6f2",
            "6318fbe584ac478ebf78dd17c0410f22",
            "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-model.zip?rev=6318fbe584ac478ebf78dd17c0410f22&sc_lang=en",
        ),
        ISPArchive(
            :hydro, "2026-isp-hydro-traces.zip", 4976828,
            "e66ce0f94dd13a7414d6defa5b5405b479bae86c4db82d5323e9591f66e2dc5c",
            "b5dd6d5175714796b2c58e990ffeae45",
            "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-hydro-traces.zip?rev=b5dd6d5175714796b2c58e990ffeae45&sc_lang=en",
        ),
        ISPArchive(
            :solar, "2026-isp-solar-traces.zip", 103470007,
            "ce364d7c6eddfebaf23a56569732fb90bdb93f051007df79d3d6dda6d50fb689",
            "f5b2277e92ef46d8a98a79a0f162f723",
            "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-solar-traces.zip?rev=f5b2277e92ef46d8a98a79a0f162f723&sc_lang=en",
        ),
        ISPArchive(
            :timeslice, "2026-isp-timeslice-traces.zip", 12204,
            "66c21860a84de67f7164b4010e0fdb04df6bd03746878264e3c514358d40c3bd",
            "44f5e2f556df4a75a0d682618fa55d0a",
            "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-timeslice-traces.zip?rev=44f5e2f556df4a75a0d682618fa55d0a&sc_lang=en",
        ),
        ISPArchive(
            :wind, "2026-isp-wind-traces.zip", 159258886,
            "7a14094b68437356c20da1048714b62c1a082b030573531e690b3bf6df22d844",
            "356445951be944b0882122ac23aa745e",
            "https://www.aemo.com.au/-/media/files/major-publications/isp/2026/isp-model/2026-isp-wind-traces.zip?rev=356445951be944b0882122ac23aa745e&sc_lang=en",
        ),
    ],
)
