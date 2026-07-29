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
        println(io, "SCENARIO RATIOS  —  $(uppercase(scenario.name))")
        println(io, "="^78)
        println(io, scenario.description)
        println(io)
        println(io, "Each number = FINAL ratio vs 2022 baseline capacity/load.")
        println(io, "  1.00 = same as 2022    2.00 = double    0.80 = 80% (retirement)")
        println(io, "* = zone-specific override; unmarked = scenario default.")
        println(io, "Sources: ERCOT 2025 LTDEF | EIA AEO 2023 | NREL ATB 2024")

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
        println(io, "SCENARIO RATIOS - $(scenario.name)")
        println(io, scenario.description)
        println(io, "Each number = final ratio vs 2022 baseline. * = zone override.")
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