"""
    AEMDB(db::DuckDB, config::HiveConfiguration)

    Thin wrapper with the connection and a configuration for the data location
"""
@kwdef struct AEMDB
    db::DuckDB.DB
    config::HiveConfiguration = HiveConfiguration()
end

aem_connect(db::TidierDB.SQLBackend) = AEMDB(db = TidierDB.connect(db))
aem_connect(db::TidierDB.SQLBackend, config::HiveConfiguration) = AEMDB(db = TidierDB.connect(db), config = config)
