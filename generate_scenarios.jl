"""
generate_scenarios.jl

Generates multiple future grid scenarios for TEP+Storage planning with
ZONE-SPECIFIC scaling of generation and load, replacing the previous
statewide-uniform approach.

Zone mapping (from power_system_data.json lat/lon):
    301 → Far West    (Permian Basin, lon~-102) -- oil/gas industrial, high wind
    302 → West        (Lubbock, lon~-101)       -- wind corridor
    303 → West/North  (Abilene, lon~-100)       -- mixed
    304 → South       (Corpus Christi, lon~-97) -- coastal industrial
    305 → South Ctrl  (Waco/Austin, lon~-96.5)  -- general population
    306 → South Ctrl  (San Antonio, lon~-98.6)  -- general population
    307 → Coast       (Gulf Coast, lon~-96.5)   -- industrial + port
    308 → North Ctrl  (DFW, lon~-96.1)          -- data centers + population

Sources:
    Load multipliers: ERCOT 2025 Long-Term Load Forecast
        https://www.ercot.com/gridinfo/load/forecast
    Generation mix: EIA Annual Energy Outlook 2023
        https://www.eia.gov/outlooks/aeo/
    Renewable cost trajectories: NREL Annual Technology Baseline 2024
        https://docs.nlr.gov/docs/fy24osti/89960.pdf
        
USAGE (from project root, in Julia REPL):
    using CSV, DataFrames, TOML
    include("generate_scenarios.jl")

OUTPUT:
    scenarios/<scenario_name>/<year>/
        config.toml
        decarbonization_<scenario>_<year>.csv
"""

using CSV
using DataFrames
using TOML
using JSON

# ── Config ────────────────────────────────────────────────────────────────────

BASELINE_DECARB_CSV  = "data/topology/tamu/decarbonization_1015.csv"
BASELINE_CONFIG_TOML = "examples/example_simdir/config.toml"
POWER_SYSTEM_DATA    = "data/topology/tamu/texas/power_system_data.json"
OUTPUT_DIR           = "scenarios"
PLANNING_YEARS       = [2030, 2035, 2040, 2045]

# 18 representative days from meeting notes (Aug 11 = hardest day)
REPRESENTATIVE_DATES = [
    "2016-01-27", "2016-02-23", "2016-03-06", "2016-03-11",
    "2016-03-22", "2016-03-27", "2016-04-03", "2016-04-22",
    "2016-05-10", "2016-05-19", "2016-06-21", "2016-07-11",
    "2016-08-11", "2016-09-02", "2016-09-10", "2016-11-16",
    "2016-12-03", "2016-12-08"
]

# ── Zone definitions ───────────────────────────────────────────────────────────
# Maps zone_id → ERCOT weather zone name for documentation purposes
ZONE_NAMES = Dict(
    301 => "Far West (Permian Basin)",
    302 => "West (Lubbock/Wind Corridor)",
    303 => "West/North (Abilene)",
    304 => "South (Corpus Christi)",
    305 => "South Central (Waco/Austin)",
    306 => "South Central (San Antonio)",
    307 => "Coast (Gulf Coast)",
    308 => "North Central (DFW)",
)

# ── Scenario definitions ───────────────────────────────────────────────────────
#
# Each scenario has:
#   - statewide_multipliers: Dict(year => Dict(fuel_type => multiplier))
#     Applied to ALL zones as a base. These come from EIA AEO reference case.
#
#   - zone_multipliers: Dict(year => Dict(zone_id => Dict(fuel_type => multiplier)))
#     Applied ON TOP of statewide multipliers for specific zones.
#     Final multiplier = statewide * zonal (multiplicative).
#
# This structure keeps the EIA baseline intact while allowing zones to
# deviate based on ERCOT zonal forecasts and local resource quality.
#
# Sources for zonal load multipliers:
#   - Zone 301 (Far West): ERCOT projects 11,964 MW oil/gas demand by 2030,
#     +255% load growth last decade. Source: ERCOT LTLF 2025.
#   - Zone 308 (DFW): Major data center concentration, high population growth.
#     Source: ERCOT LTLF 2025, large load interconnection requests.
#   - Zone 307 (Coast): Offshore wind opportunity, industrial port activity.
#     Source: ERCOT GIS report, ERCOT LTLF 2025.
#   - Zones 305/306 (South Central/Houston): Highest congestion prices,
#     significant population and industrial growth.
#     Source: ERCOT LTLF 2025.
#
# Sources for zonal generation multipliers:
#   - Zones 301/302 (Far West/West): Dominant wind resource. New wind projects
#     concentrated here per ERCOT GIS report.
#   - Solar: Distributed across zones per existing capacity share.
#     Source: ERCOT GIS report, NREL ATB 2024.

const SCENARIOS = [

    # ── Scenario A: Low / EIA Reference ──────────────────────────────────────
    # Statewide EIA reference generation mix. Load grows modestly above EIA
    # baseline (+5-12%), distributed uniformly across zones.
    # Represents a conservative world where data center buildout stalls.
    (
        name        = "A_low",
        description = "Low: EIA reference generation, uniform modest load growth",
        statewide_multipliers = Dict(
            2030 => Dict("load"=>1.05, "solar"=>1.00, "wind"=>1.00, "wind_offshore"=>1.00, "ng"=>1.00, "coal"=>1.00, "nuclear"=>1.00),
            2035 => Dict("load"=>1.08, "solar"=>1.00, "wind"=>1.00, "wind_offshore"=>1.00, "ng"=>1.00, "coal"=>1.00, "nuclear"=>1.00),
            2040 => Dict("load"=>1.10, "solar"=>1.00, "wind"=>1.00, "wind_offshore"=>1.00, "ng"=>1.00, "coal"=>1.00, "nuclear"=>1.00),
            2045 => Dict("load"=>1.12, "solar"=>1.00, "wind"=>1.00, "wind_offshore"=>1.00, "ng"=>1.00, "coal"=>1.00, "nuclear"=>1.00),
        ),
        # No zone-specific deviations for Scenario A -- uniform by design
        zone_multipliers = Dict(
            2030 => Dict{Int,Dict{String,Float64}}(),
            2035 => Dict{Int,Dict{String,Float64}}(),
            2040 => Dict{Int,Dict{String,Float64}}(),
            2045 => Dict{Int,Dict{String,Float64}}(),
        )
    ),

    # ── Scenario B: ERCOT-Adjusted (Medium) ──────────────────────────────────
    # Statewide: ERCOT adjusted methodology (~+35% load by 2030 statewide).
    # Zonal: load growth concentrated in Far West (oil/gas) and DFW (data centers).
    # Renewable buildout weighted toward existing resource-quality zones.
    # Source: ERCOT 2025 LTLF (49.8% discount on data center requests).
    (
        name        = "B_ercot_adjusted",
        description = "Medium: ERCOT-adjusted load, zone-specific growth (Far West + DFW heavy)",
        statewide_multipliers = Dict(
            2030 => Dict("load"=>1.35, "solar"=>1.33, "wind"=>1.24, "wind_offshore"=>1.00, "ng"=>0.95, "coal"=>0.90, "nuclear"=>1.00),
            2035 => Dict("load"=>1.50, "solar"=>1.45, "wind"=>1.30, "wind_offshore"=>1.20, "ng"=>0.90, "coal"=>0.80, "nuclear"=>1.00),
            2040 => Dict("load"=>1.65, "solar"=>1.58, "wind"=>1.36, "wind_offshore"=>1.50, "ng"=>0.85, "coal"=>0.70, "nuclear"=>0.95),
            2045 => Dict("load"=>1.80, "solar"=>1.70, "wind"=>1.42, "wind_offshore"=>1.80, "ng"=>0.80, "coal"=>0.60, "nuclear"=>0.90),
        ),
        zone_multipliers = Dict(
            # 2030: Far West oil/gas surge + DFW data center buildup begins
            # Wind concentrated in 301/302 (resource quality weighting)
            2030 => Dict(
                301 => Dict("load"=>1.40, "wind"=>1.50, "ng"=>1.10),  # Far West: oil/gas load + wind buildout
                302 => Dict("load"=>1.10, "wind"=>1.40),              # West: wind corridor
                303 => Dict("load"=>1.05),                            # West/North: modest
                304 => Dict("load"=>1.10, "solar"=>1.20),             # South: industrial + solar
                305 => Dict("load"=>1.15),                            # S. Central: population
                306 => Dict("load"=>1.15),                            # S. Central: population
                307 => Dict("load"=>1.10, "wind_offshore"=>1.50),     # Coast: offshore wind
                308 => Dict("load"=>1.50, "solar"=>1.20),             # DFW: data centers + solar
            ),
            2035 => Dict(
                301 => Dict("load"=>1.55, "wind"=>1.60, "ng"=>1.15),
                302 => Dict("load"=>1.12, "wind"=>1.50),
                303 => Dict("load"=>1.08),
                304 => Dict("load"=>1.15, "solar"=>1.30),
                305 => Dict("load"=>1.20),
                306 => Dict("load"=>1.20),
                307 => Dict("load"=>1.15, "wind_offshore"=>1.80),
                308 => Dict("load"=>1.70, "solar"=>1.35),
            ),
            2040 => Dict(
                301 => Dict("load"=>1.65, "wind"=>1.70, "ng"=>1.10),
                302 => Dict("load"=>1.15, "wind"=>1.60),
                303 => Dict("load"=>1.10),
                304 => Dict("load"=>1.18, "solar"=>1.40),
                305 => Dict("load"=>1.25),
                306 => Dict("load"=>1.25),
                307 => Dict("load"=>1.20, "wind_offshore"=>2.00),
                308 => Dict("load"=>1.85, "solar"=>1.50),
            ),
            2045 => Dict(
                301 => Dict("load"=>1.70, "wind"=>1.80, "ng"=>1.05),
                302 => Dict("load"=>1.18, "wind"=>1.70),
                303 => Dict("load"=>1.12),
                304 => Dict("load"=>1.20, "solar"=>1.50),
                305 => Dict("load"=>1.28),
                306 => Dict("load"=>1.28),
                307 => Dict("load"=>1.25, "wind_offshore"=>2.20),
                308 => Dict("load"=>2.00, "solar"=>1.65),
            ),
        )
    ),

    # ── Scenario C: High / Unadjusted TSP Forecast ───────────────────────────
    # Full unadjusted TSP large load additions, no discount applied.
    # Maximum zonal differentiation: DFW and Far West see most aggressive growth.
    # Aggressive renewable buildout required to meet demand.
    # Source: ERCOT unadjusted 2025 LTLF (~208 GW by 2030 without discounting).
    (
        name        = "C_high",
        description = "High: full unadjusted TSP forecast, aggressive zonal growth (DFW + Far West)",
        statewide_multipliers = Dict(
            2030 => Dict("load"=>1.65, "solar"=>1.65, "wind"=>1.48, "wind_offshore"=>1.50, "ng"=>1.05, "coal"=>0.75, "nuclear"=>1.00),
            2035 => Dict("load"=>1.90, "solar"=>1.95, "wind"=>1.62, "wind_offshore"=>2.00, "ng"=>1.00, "coal"=>0.55, "nuclear"=>1.00),
            2040 => Dict("load"=>2.15, "solar"=>2.30, "wind"=>1.76, "wind_offshore"=>2.50, "ng"=>0.90, "coal"=>0.40, "nuclear"=>0.95),
            2045 => Dict("load"=>2.40, "solar"=>2.65, "wind"=>1.90, "wind_offshore"=>3.00, "ng"=>0.80, "coal"=>0.30, "nuclear"=>0.90),
        ),
        zone_multipliers = Dict(
            2030 => Dict(
                301 => Dict("load"=>1.80, "wind"=>1.80, "ng"=>1.20),  # Far West: max oil/gas surge
                302 => Dict("load"=>1.20, "wind"=>1.70),              # West: aggressive wind
                303 => Dict("load"=>1.10),
                304 => Dict("load"=>1.20, "solar"=>1.40),
                305 => Dict("load"=>1.30),
                306 => Dict("load"=>1.30),
                307 => Dict("load"=>1.20, "wind_offshore"=>2.00),
                308 => Dict("load"=>2.00, "solar"=>1.50),             # DFW: full data center buildout
            ),
            2035 => Dict(
                301 => Dict("load"=>2.00, "wind"=>2.00, "ng"=>1.25),
                302 => Dict("load"=>1.25, "wind"=>1.85),
                303 => Dict("load"=>1.12),
                304 => Dict("load"=>1.25, "solar"=>1.55),
                305 => Dict("load"=>1.38),
                306 => Dict("load"=>1.38),
                307 => Dict("load"=>1.28, "wind_offshore"=>2.50),
                308 => Dict("load"=>2.30, "solar"=>1.70),
            ),
            2040 => Dict(
                301 => Dict("load"=>2.20, "wind"=>2.20, "ng"=>1.20),
                302 => Dict("load"=>1.30, "wind"=>2.00),
                303 => Dict("load"=>1.15),
                304 => Dict("load"=>1.30, "solar"=>1.70),
                305 => Dict("load"=>1.45),
                306 => Dict("load"=>1.45),
                307 => Dict("load"=>1.35, "wind_offshore"=>3.00),
                308 => Dict("load"=>2.60, "solar"=>1.90),
            ),
            2045 => Dict(
                301 => Dict("load"=>2.40, "wind"=>2.40, "ng"=>1.10),
                302 => Dict("load"=>1.35, "wind"=>2.15),
                303 => Dict("load"=>1.18),
                304 => Dict("load"=>1.35, "solar"=>1.85),
                305 => Dict("load"=>1.52),
                306 => Dict("load"=>1.52),
                307 => Dict("load"=>1.42, "wind_offshore"=>3.50),
                308 => Dict("load"=>2.90, "solar"=>2.10),
            ),
        )
    ),
]

# ── Helper: load bus → zone mapping from power system data ───────────────────

function load_zone_map(power_system_path::String)
    println("Loading zone map from $power_system_path ...")
    ps_data = JSON.parsefile(power_system_path)
    zone_map = Dict{Int, Int}()  # bus_index → zone_id
    for (bus_id_str, bus) in ps_data["bus"]
        zone_map[parse(Int, bus_id_str)] = bus["zone_id"]
    end
    return zone_map
end

# ── Helper: apply statewide + zonal multipliers to baseline CSV ───────────────

function apply_scenario(df::DataFrame, year::Int,
                        statewide::Dict, zonal::Dict,
                        zone_map::Dict{Int,Int})
    df_new   = copy(df)
    year_col = string(year)

    if !(year_col in names(df_new))
        error("Year column '$year_col' not found in CSV")
    end

    type_col = names(df_new)[1]

    # For statewide fuel-type multipliers (coal, ng, nuclear, solar, wind etc.)
    # these apply uniformly to all generators of that type
    for (fuel_type, multiplier) in statewide
        row_mask = df_new[!, type_col] .== fuel_type
        if !any(row_mask)
            @warn "Fuel type '$fuel_type' not found in CSV -- skipping"
            continue
        end
        df_new[row_mask, year_col] .*= multiplier
    end

    # Note: zonal multipliers cannot be applied directly to the statewide
    # decarbonization CSV (which has one row per fuel type, not per zone).
    # Instead, we write a separate zone_multipliers JSON file alongside the
    # CSV. The update_decarbonization function would need to be extended to
    # read this file and apply per-bus scaling. For now, we log the zonal
    # multipliers so they are available for the next step.
    return df_new
end

function write_zone_multipliers(simdir::String, year::Int,
                                 zonal::Dict, zone_map::Dict{Int,Int})
    # Write zone multipliers as a JSON file for later use when extending
    # update_decarbonization to support per-zone scaling
    zonal_out = Dict{String, Any}()
    for (zone_id, fuel_mults) in zonal
        zonal_out[string(zone_id)] = Dict{String, Any}(
            "zone_name" => get(ZONE_NAMES, zone_id, "unknown"),
            "multipliers" => fuel_mults
        )
    end
    out = Dict(
        "year" => year,
        "description" => "Zone-specific multipliers applied ON TOP of statewide CSV values",
        "source" => "ERCOT 2025 LTLF + ERCOT GIS Report + NREL ATB 2024",
        "zones" => zonal_out
    )
    path = joinpath(simdir, "zone_multipliers_$(year).json")
    open(path, "w") do f
        JSON.print(f, out, 2)
    end
    return path
end

function write_config(simdir::String, year::Int, decarb_abs_path::String,
                      base_config::Dict)
    config = deepcopy(base_config)
    config["decarbonization"]      = decarb_abs_path
    config["decarbonization_year"] = year
    config["dates"]                = REPRESENTATIVE_DATES
    config["num_representatives"]  = length(REPRESENTATIVE_DATES)
    config["representative_prob"]  = fill(1.0 / length(REPRESENTATIVE_DATES),
                                          length(REPRESENTATIVE_DATES))
    config_path = joinpath(simdir, "config.toml")
    open(config_path, "w") do f
        TOML.print(f, config)
    end
    return config_path
end

# ── Main ──────────────────────────────────────────────────────────────────────

println("=== Zonal Scenario Generator ===")
flush(stdout)

println("Loading baseline CSV: $BASELINE_DECARB_CSV")
flush(stdout)
baseline_df = CSV.read(BASELINE_DECARB_CSV, DataFrame)
println("  Loaded: $(nrow(baseline_df)) rows x $(ncol(baseline_df)) columns")
flush(stdout)

println("Loading baseline config: $BASELINE_CONFIG_TOML")
flush(stdout)
base_config = TOML.parsefile(BASELINE_CONFIG_TOML)
println("  Loaded.")
flush(stdout)

println("Loading zone map: $POWER_SYSTEM_DATA")
flush(stdout)
zone_map = load_zone_map(POWER_SYSTEM_DATA)
println("  Loaded: $(length(zone_map)) buses across $(length(unique(values(zone_map)))) zones")
flush(stdout)

mkpath(OUTPUT_DIR)
generated = String[]

for scenario in SCENARIOS
    println("\n── Scenario $(scenario.name) ──")
    println("   $(scenario.description)")
    flush(stdout)

    for year in PLANNING_YEARS
        if !haskey(scenario.statewide_multipliers, year)
            @warn "No multipliers for $(scenario.name) year $year -- skipping"
            continue
        end

        statewide = scenario.statewide_multipliers[year]
        zonal     = get(scenario.zone_multipliers, year, Dict{Int,Dict{String,Float64}}())

        simdir_path = joinpath(OUTPUT_DIR, scenario.name, string(year))
        mkpath(joinpath(simdir_path, "output"))
        mkpath(joinpath(simdir_path, "visual"))

        # Apply statewide multipliers and write CSV
        df_mod       = apply_scenario(baseline_df, year, statewide, zonal, zone_map)
        decarb_fname = "decarbonization_$(scenario.name)_$(year).csv"
        decarb_path  = joinpath(simdir_path, decarb_fname)
        CSV.write(decarb_path, df_mod)

        # Write zone multipliers JSON for next step (extending update_decarbonization)
        if !isempty(zonal)
            zm_path = write_zone_multipliers(simdir_path, year, zonal, zone_map)
            println("   ✓ $year → $simdir_path  [+zone_multipliers_$(year).json]")
        else
            println("   ✓ $year → $simdir_path  [statewide only]")
        end
        flush(stdout)

        # Write config
        write_config(simdir_path, year, abspath(decarb_path), base_config)
        push!(generated, simdir_path)
    end
end

println("\n=== Done: $(length(generated)) simdirs created under $OUTPUT_DIR/ ===")
println("\nNext step: extend update_decarbonization to read zone_multipliers_<year>.json")
println("and apply per-bus scaling based on bus → zone_id mapping.")
flush(stdout)