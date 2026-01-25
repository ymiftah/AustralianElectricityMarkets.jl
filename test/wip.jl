begin
    using AustralianElectricityMarkets
    using TidierDB
    using Dates
    using DataFrames
    import AustralianElectricityMarkets.RegionModel as RM
    using PowerSystems
    using Base.ScopedValues
end

db = aem_connect(duckdb())

x = RegionalNetworkConfiguration()

sys = nem_system(db, RegionalNetworkConfiguration())

df = @with AustralianElectricityMarkets.CONFIG => AustralianElectricityMarkets.HiveConfiguration(hive_location = ".", filesystem = AustralianElectricityMarkets.CONFIG[].filesystem) begin
    AustralianElectricityMarkets.populate(:GENUNITS, 2025, 7)
end
df |> typeof

system = RM.nem_system(db)

areas = get_components(Area, system) |> collect .|> get_name |> sort!
areas == ["NSW1", "QLD1", "SA1", "SNOWY1", "TAS1", "VIC1"]

system

fetch_table_data(:DUDETAIL, Date(2025, 1, 1):Date(2025, 1, 1))
table = read_hive(db, :DUDETAIL);
table |> x -> @head(x, 5) |> x -> @collect(x) #|> AustralianElectricityMarkets.DataFrames.nrow

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
