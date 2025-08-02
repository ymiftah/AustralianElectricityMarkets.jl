using AustralianElectricityMarket
using TidierDB
using Dates

db = connect(duckdb())

list_available_tables()
fetch_table_data(:DUDETAIL, Date(2025, 1, 1):Date(2025, 1, 1))
table = read_hive(db, :DUDETAIL);
table

gen_units = @chain table begin
    @head
    @collect
end

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
