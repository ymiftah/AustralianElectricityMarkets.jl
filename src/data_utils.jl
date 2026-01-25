"""
    AEMDB(db::DuckDB, config::HiveConfiguration)

    Thin wrapper with the connection and a configuration for the data location
"""
@kwdef struct AEMDB
    db::DuckDB.DBInterface.Connection
    config::HiveConfiguration = HiveConfiguration()
end

aem_connect(db::TidierDB.SQLBackend) = AEMDB(TidierDB.connect(db))
aem_connect(db::TidierDB.SQLBackend, config::HiveConfiguration) = AEMDB(db = TidierDB.connect(db), config = config)
