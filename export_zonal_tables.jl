"""
export_zonal_tables.jl

Exports the scenario ratios as clean zone x year tables, one file per scenario.

Since ratios are now DIRECT (the number is the final ratio vs 2022 baseline),
the tables just show that number -- no EIA/multiplier/effective breakdown.

    ratio = 2.0  means the fuel's capacity (or load) is 2x its 2022 value.

USAGE (from project root):
    using CSV, DataFrames, TOML, JSON
    include("export_zonal_tables.jl")

OUTPUT:
    scenarios/zonal_scaling_tables/zonal_scaling_<scenario>.txt   (readable)
    scenarios/zonal_scaling_tables/zonal_scaling_<scenario>.csv   (spreadsheet)
"""

using CSV, DataFrames, Printf

if !@isdefined(SCENARIOS)
    include("generate_scenarios.jl")
end

TABLES_DIR = joinpath("scenarios", "zonal_scaling_tables")

function write_readable(scenario, path)
    open(path, "w") do io
        println(io, "="^78)
        println(io, "TABLE — SCENARIO SCALING RATIOS: $(uppercase(scenario.name))")
        println(io, "="^78)
        println(io, scenario.description)
        println(io)
        println(io, "Scaling ratios applied to each fuel type and load in each ERCOT weather")
        println(io, "zone of the 2000-bus synthetic Texas system, for planning years " *
                    join(string.(PLANNING_YEARS), ", ") * ".")
        println(io)
        println(io, "HOW TO READ:")
        println(io, "  Each value is the FINAL ratio relative to the 2022 baseline, i.e.")
        println(io, "      future_capacity = ratio x 2022_capacity")
        println(io, "  1.00 = unchanged from 2022   2.00 = doubled   0.80 = 20% retired")
        println(io, "  Values are applied per bus according to that bus's zone_id.")
        println(io, "  Rows marked * carry a zone-specific value; unmarked rows inherit the")
        println(io, "  scenario default shown in the first row of each block.")
        println(io)
        println(io, "Load ratios are derived from ERCOT long-term load forecasts; generation")
        println(io, "ratios from EIA Annual Energy Outlook projections adjusted per scenario.")
        println(io, "Data-center demand is NOT included here — it is modeled separately as")
        println(io, "nodal load in the corresponding _dc scenario variants.")

        for fuel in FUELS
            println(io)
            println(io, "-"^78)
            println(io, "  $(uppercase(fuel))")
            println(io, "-"^78)
            hdr = rpad("Zone", 34)
            for y in PLANNING_YEARS; hdr *= lpad(string(y), 10); end
            println(io, hdr)

            # default row
            line = rpad("SCENARIO DEFAULT (all zones)", 34)
            for y in PLANNING_YEARS
                line *= lpad(@sprintf("%.2f", scenario.defaults[y][fuel]), 10)
            end
            println(io, line)

            # zone rows
            for zid in sort(collect(keys(ZONE_NAMES)))
                label = "$zid $(ZONE_NAMES[zid])"
                line  = rpad(length(label)>33 ? label[1:33] : label, 34)
                for y in PLANNING_YEARS
                    r, isz = ratio_for(scenario, zid, fuel, y)
                    line *= lpad(@sprintf("%.2f", r) * (isz ? "*" : " "), 10)
                end
                println(io, line)
            end
        end
        println(io)
    end
    return path
end

function write_csv(scenario, path)
    open(path, "w") do io
        println(io, "TABLE - SCENARIO SCALING RATIOS: $(scenario.name)")
        println(io, scenario.description)
        println(io, "Each value = final ratio vs 2022 baseline: future = ratio x 2022 value.")
        println(io, "1.00 = unchanged, 2.00 = doubled, 0.80 = 20% retired.")
        println(io, "* marks a zone-specific value; unmarked rows use the scenario default.")
        println(io, "Applied per bus by zone_id. Data-center load excluded (see _dc variants).")
        println(io)
        for fuel in FUELS
            println(io, "### $(uppercase(fuel)) ###")
            println(io, "Zone," * join(string.(PLANNING_YEARS), ","))
            dvals = [@sprintf("%.3f", scenario.defaults[y][fuel]) for y in PLANNING_YEARS]
            println(io, "SCENARIO DEFAULT," * join(dvals, ","))
            for zid in sort(collect(keys(ZONE_NAMES)))
                vals = String[]
                for y in PLANNING_YEARS
                    r, isz = ratio_for(scenario, zid, fuel, y)
                    push!(vals, @sprintf("%.3f", r) * (isz ? "*" : ""))
                end
                println(io, "$zid $(ZONE_NAMES[zid])," * join(vals, ","))
            end
            println(io)
        end
    end
    return path
end

println("=== Exporting Scenario Ratio Tables ===")
if isdir(TABLES_DIR)
    old = readdir(TABLES_DIR)
    for f in old; rm(joinpath(TABLES_DIR, f)); end
    !isempty(old) && println("  Cleared $(length(old)) old file(s)")
end
mkpath(TABLES_DIR)
flush(stdout)

for scenario in SCENARIOS
    c = joinpath(TABLES_DIR, "zonal_scaling_$(scenario.name).csv")
    t = joinpath(TABLES_DIR, "zonal_scaling_$(scenario.name).txt")
    write_csv(scenario, c); write_readable(scenario, t)
    println("   ✓ $(basename(t))")
    flush(stdout)
end

println("\n=== Done: tables in $TABLES_DIR/ ===")
for scenario in SCENARIOS
    println()
    print(read(joinpath(TABLES_DIR, "zonal_scaling_$(scenario.name).txt"), String))
end
flush(stdout)