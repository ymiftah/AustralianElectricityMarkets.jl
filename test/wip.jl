using AustralianElectricityMarket
using TidierDB

db = connect(duckdb())

list_available_tables()
table = read_hive(:DISPATCHREGIONSUM, db);

dispatch_load = @chain table begin
    @filter(year == 2024)
    @mutate(SETTLEMENTDATE = floor_date(SETTLEMENTDATE, "hour"))
    @group_by(SETTLEMENTDATE, REGIONID)
    @summarise(TOTALDEMAND = mean(TOTALDEMAND))
    @arrange(SETTLEMENTDATE, REGIONID)
    # @select(SETTLEMENTDATE, REGIONID, TOTALDEMAND)
    # @show_query
    @collect
end
