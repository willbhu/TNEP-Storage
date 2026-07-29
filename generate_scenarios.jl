"""
generate_scenarios.jl

Generates future grid scenarios for TEP+Storage planning using DIRECT
FINAL RATIOS -- the number specified for each (scenario, zone, fuel, year)
IS the ratio applied to the 2022 baseline. No EIA-baseline multiplication,
no derived multipliers.

═══════════════════════════════════════════════════════════════════════════════
HOW THE SCALING WORKS (simple):
═══════════════════════════════════════════════════════════════════════════════

    final_capacity = ratio x baseline_2022_capacity

    where `ratio` is read directly from the tables below.
      ratio = 1.0  -> same as 2022
      ratio = 2.0  -> double the 2022 capacity/load
      ratio = 0.8  -> 80% of 2022 (retirement)

    Each scenario has:
      - a DEFAULT ratio per fuel per year (applied to all zones)
      - optional PER-ZONE OVERRIDES for key zones (Far West, DFW, etc.)

    The decarbonization CSV is used ONLY to read the 2022 baseline values.
    update_decarbonization applies these ratios directly (see decarbonization.jl).

ZONE MAP (from power_system_data.json):
    301 Far West (Permian Basin)  -- oil/gas industrial, high wind
    302 West (Lubbock)            -- wind corridor
    303 West/North (Abilene)      -- rural, slow growth
    304 South (Corpus Christi)    -- coastal industrial
    305 South Central (Waco/Austin)
    306 South Central (San Antonio)
    307 Coast (Gulf Coast)        -- offshore wind
    308 North Central (DFW)       -- data centers

SCENARIOS:
    A_low  = EIA AEO reference case (ratios ARE the EIA CSV projection)
    B_med  = ERCOT adjusted forecast (data centers at 49.8% discount)
    C_high = ERCOT TSP realistic-high (data centers, toned-down upper bound)

SOURCES:
    ERCOT 2025 LTDEF   https://www.ercot.com/files/docs/2025/04/08/ERCOT-2025-Long-Term-Load-Forecast-Report.pdf
    ERCOT RPG          https://www.ercot.com/files/docs/2025/04/29/Long-term-Load-Forecast-RPG.pdf
    EIA AEO 2023       https://www.eia.gov/outlooks/aeo/
    NREL ATB 2024      https://atb.nrel.gov/electricity/2024/

USAGE (from project root):
    using CSV, DataFrames, TOML, JSON
    include("generate_scenarios.jl")
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

# FAST TEST (1 day). Swap in the 18-day list below for real runs.
#REPRESENTATIVE_DATES = ["2016-08-11"]
REPRESENTATIVE_DATES = [
      "2016-01-27","2016-02-23","2016-03-06","2016-03-11","2016-03-22","2016-03-27",
      "2016-04-03","2016-04-22","2016-05-10","2016-05-19","2016-06-21","2016-07-11",
      "2016-08-11","2016-09-02","2016-09-10","2016-11-16","2016-12-03","2016-12-08"]

USE_FAST_RUN = false

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

FUELS = ["load", "solar", "wind", "wind_offshore", "ng", "coal", "nuclear"]

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO RATIOS  --  each number is the FINAL ratio vs 2022 baseline.
#
# Structure:
#   defaults[year][fuel]          -> ratio applied to ALL zones
#   overrides[year][zone][fuel]   -> replaces the default for that zone/fuel
# ═══════════════════════════════════════════════════════════════════════════════

const SCENARIOS = [

  # ───────────────────────────────────────────────────────────────────────────
  # SCENARIO A -- EIA AEO reference case.
  # Defaults ARE the EIA CSV projection. Zonal overrides give modest regional
  # variation in LOAD only (Far West + DFW above, rural below).
  # ───────────────────────────────────────────────────────────────────────────
  (
    name = "A_low",
    description = "EIA AEO reference case (base economic growth, no large data-center load)",
    defaults = Dict(
      2030 => Dict("load"=>1.13, "solar"=>4.51, "wind"=>2.02, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
      2035 => Dict("load"=>1.21, "solar"=>5.8, "wind"=>2.23, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
      2040 => Dict("load"=>1.31, "solar"=>6.87, "wind"=>2.26, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
      2045 => Dict("load"=>1.41, "solar"=>8.04, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
    ),
    overrides = Dict(
      2030 => Dict(
        301 => Dict("load"=>1.23, "solar"=>4.51, "wind"=>2.22, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        302 => Dict("load"=>1.09, "solar"=>4.51, "wind"=>2.26, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        303 => Dict("load"=>1.04, "solar"=>4.51, "wind"=>2.1, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        304 => Dict("load"=>1.08, "solar"=>4.78, "wind"=>2.02, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        305 => Dict("load"=>1.15, "solar"=>4.69, "wind"=>2.02, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        306 => Dict("load"=>1.12, "solar"=>4.51, "wind"=>2.02, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        307 => Dict("load"=>1.09, "solar"=>4.51, "wind"=>2.02, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
        308 => Dict("load"=>1.23, "solar"=>4.78, "wind"=>2.02, "wind_offshore"=>21.6, "ng"=>0.79, "coal"=>0.82, "nuclear"=>0.98),
      ),
      2035 => Dict(
        301 => Dict("load"=>1.32, "solar"=>5.8, "wind"=>2.45, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        302 => Dict("load"=>1.17, "solar"=>5.8, "wind"=>2.5, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        303 => Dict("load"=>1.11, "solar"=>5.8, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        304 => Dict("load"=>1.16, "solar"=>6.15, "wind"=>2.23, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        305 => Dict("load"=>1.23, "solar"=>6.03, "wind"=>2.23, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        306 => Dict("load"=>1.2, "solar"=>5.8, "wind"=>2.23, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        307 => Dict("load"=>1.17, "solar"=>5.8, "wind"=>2.23, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
        308 => Dict("load"=>1.32, "solar"=>6.15, "wind"=>2.23, "wind_offshore"=>50.6, "ng"=>0.73, "coal"=>0.82, "nuclear"=>0.9),
      ),
      2040 => Dict(
        301 => Dict("load"=>1.43, "solar"=>6.87, "wind"=>2.49, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        302 => Dict("load"=>1.27, "solar"=>6.87, "wind"=>2.53, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        303 => Dict("load"=>1.21, "solar"=>6.87, "wind"=>2.35, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        304 => Dict("load"=>1.26, "solar"=>7.28, "wind"=>2.26, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        305 => Dict("load"=>1.34, "solar"=>7.14, "wind"=>2.26, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        306 => Dict("load"=>1.3, "solar"=>6.87, "wind"=>2.26, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        307 => Dict("load"=>1.27, "solar"=>6.87, "wind"=>2.26, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
        308 => Dict("load"=>1.43, "solar"=>7.28, "wind"=>2.26, "wind_offshore"=>50.6, "ng"=>0.71, "coal"=>0.82, "nuclear"=>0.8),
      ),
      2045 => Dict(
        301 => Dict("load"=>1.53, "solar"=>8.04, "wind"=>2.55, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        302 => Dict("load"=>1.36, "solar"=>8.04, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        303 => Dict("load"=>1.3, "solar"=>8.04, "wind"=>2.41, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        304 => Dict("load"=>1.35, "solar"=>8.52, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        305 => Dict("load"=>1.44, "solar"=>8.36, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        306 => Dict("load"=>1.4, "solar"=>8.04, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        307 => Dict("load"=>1.36, "solar"=>8.04, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
        308 => Dict("load"=>1.53, "solar"=>8.52, "wind"=>2.32, "wind_offshore"=>50.6, "ng"=>0.72, "coal"=>0.82, "nuclear"=>0.8),
      ),
    ),
  ),

  # ───────────────────────────────────────────────────────────────────────────
  # SCENARIO B -- ERCOT adjusted forecast.
  # Statewide load ~1.80x by 2030 (ERCOT adjusted peak with data centers at
  # 49.8% discount). Moderate renewable buildout above EIA; faster coal/ng
  # retirement. Far West + DFW get the most load growth.
  # ───────────────────────────────────────────────────────────────────────────
  (
    name = "B_med",
    description = "ERCOT adjusted forecast (data centers at 49.8% discount, moderate renewables)",
    defaults = Dict(
      2030 => Dict("load"=>1.8, "solar"=>5.05, "wind"=>2.32, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
      2035 => Dict("load"=>2.06, "solar"=>6.5, "wind"=>2.56, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
      2040 => Dict("load"=>2.33, "solar"=>7.69, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
      2045 => Dict("load"=>2.6, "solar"=>9.0, "wind"=>2.67, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
    ),
    overrides = Dict(
      2030 => Dict(
        301 => Dict("load"=>2.2, "solar"=>5.05, "wind"=>2.9, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        302 => Dict("load"=>1.66, "solar"=>5.05, "wind"=>3.02, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        303 => Dict("load"=>1.44, "solar"=>5.05, "wind"=>2.55, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        304 => Dict("load"=>1.62, "solar"=>5.81, "wind"=>2.32, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        305 => Dict("load"=>1.89, "solar"=>5.56, "wind"=>2.32, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        306 => Dict("load"=>1.76, "solar"=>5.05, "wind"=>2.32, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        307 => Dict("load"=>1.66, "solar"=>5.05, "wind"=>2.32, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
        308 => Dict("load"=>2.2, "solar"=>5.81, "wind"=>2.32, "wind_offshore"=>21.6, "ng"=>0.73, "coal"=>0.66, "nuclear"=>0.98),
      ),
      2035 => Dict(
        301 => Dict("load"=>2.51, "solar"=>6.5, "wind"=>3.2, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        302 => Dict("load"=>1.9, "solar"=>6.5, "wind"=>3.33, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        303 => Dict("load"=>1.65, "solar"=>6.5, "wind"=>2.82, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        304 => Dict("load"=>1.85, "solar"=>7.47, "wind"=>2.56, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        305 => Dict("load"=>2.16, "solar"=>7.15, "wind"=>2.56, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        306 => Dict("load"=>2.02, "solar"=>6.5, "wind"=>2.56, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        307 => Dict("load"=>1.9, "solar"=>6.5, "wind"=>2.56, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
        308 => Dict("load"=>2.51, "solar"=>7.47, "wind"=>2.56, "wind_offshore"=>50.6, "ng"=>0.67, "coal"=>0.66, "nuclear"=>0.9),
      ),
      2040 => Dict(
        301 => Dict("load"=>2.84, "solar"=>7.69, "wind"=>3.25, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        302 => Dict("load"=>2.14, "solar"=>7.69, "wind"=>3.38, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        303 => Dict("load"=>1.86, "solar"=>7.69, "wind"=>2.86, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        304 => Dict("load"=>2.1, "solar"=>8.84, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        305 => Dict("load"=>2.45, "solar"=>8.46, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        306 => Dict("load"=>2.28, "solar"=>7.69, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        307 => Dict("load"=>2.14, "solar"=>7.69, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
        308 => Dict("load"=>2.84, "solar"=>8.84, "wind"=>2.6, "wind_offshore"=>50.6, "ng"=>0.65, "coal"=>0.66, "nuclear"=>0.8),
      ),
      2045 => Dict(
        301 => Dict("load"=>3.17, "solar"=>9.0, "wind"=>3.34, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        302 => Dict("load"=>2.39, "solar"=>9.0, "wind"=>3.47, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        303 => Dict("load"=>2.08, "solar"=>9.0, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        304 => Dict("load"=>2.34, "solar"=>10.35, "wind"=>2.67, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        305 => Dict("load"=>2.73, "solar"=>9.9, "wind"=>2.67, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        306 => Dict("load"=>2.55, "solar"=>9.0, "wind"=>2.67, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        307 => Dict("load"=>2.39, "solar"=>9.0, "wind"=>2.67, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
        308 => Dict("load"=>3.17, "solar"=>10.35, "wind"=>2.67, "wind_offshore"=>50.6, "ng"=>0.66, "coal"=>0.66, "nuclear"=>0.8),
      ),
    ),
  ),

  # ───────────────────────────────────────────────────────────────────────────
  # SCENARIO C -- ERCOT TSP realistic-high (toned-down upper bound).
  # Statewide load ~2.25x by 2030 rising to ~2.82x by 2045. Aggressive
  # renewable buildout to serve the higher load; fastest coal retirement.
  # Far West + DFW see the most aggressive load growth.
  # ───────────────────────────────────────────────────────────────────────────
  (
    name = "C_high",
    description = "ERCOT TSP realistic-high (toned-down upper bound, aggressive renewables)",
    defaults = Dict(
      2030 => Dict("load"=>2.25, "solar"=>5.5, "wind"=>2.63, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
      2035 => Dict("load"=>2.43, "solar"=>7.08, "wind"=>2.9, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
      2040 => Dict("load"=>2.61, "solar"=>8.38, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
      2045 => Dict("load"=>2.82, "solar"=>9.81, "wind"=>3.02, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
    ),
    overrides = Dict(
      2030 => Dict(
        301 => Dict("load"=>2.75, "solar"=>5.5, "wind"=>3.29, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        302 => Dict("load"=>2.07, "solar"=>5.5, "wind"=>3.42, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        303 => Dict("load"=>1.8, "solar"=>5.5, "wind"=>2.89, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        304 => Dict("load"=>2.02, "solar"=>6.32, "wind"=>2.63, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        305 => Dict("load"=>2.36, "solar"=>6.05, "wind"=>2.63, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        306 => Dict("load"=>2.21, "solar"=>5.5, "wind"=>2.63, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        307 => Dict("load"=>2.07, "solar"=>5.5, "wind"=>2.63, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
        308 => Dict("load"=>2.75, "solar"=>6.32, "wind"=>2.63, "wind_offshore"=>21.6, "ng"=>0.67, "coal"=>0.45, "nuclear"=>0.98),
      ),
      2035 => Dict(
        301 => Dict("load"=>2.96, "solar"=>7.08, "wind"=>3.62, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        302 => Dict("load"=>2.24, "solar"=>7.08, "wind"=>3.77, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        303 => Dict("load"=>1.94, "solar"=>7.08, "wind"=>3.19, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        304 => Dict("load"=>2.19, "solar"=>8.14, "wind"=>2.9, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        305 => Dict("load"=>2.55, "solar"=>7.79, "wind"=>2.9, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        306 => Dict("load"=>2.38, "solar"=>7.08, "wind"=>2.9, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        307 => Dict("load"=>2.24, "solar"=>7.08, "wind"=>2.9, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
        308 => Dict("load"=>2.96, "solar"=>8.14, "wind"=>2.9, "wind_offshore"=>50.6, "ng"=>0.62, "coal"=>0.45, "nuclear"=>0.9),
      ),
      2040 => Dict(
        301 => Dict("load"=>3.18, "solar"=>8.38, "wind"=>3.67, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        302 => Dict("load"=>2.4, "solar"=>8.38, "wind"=>3.82, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        303 => Dict("load"=>2.09, "solar"=>8.38, "wind"=>3.23, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        304 => Dict("load"=>2.35, "solar"=>9.64, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        305 => Dict("load"=>2.74, "solar"=>9.22, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        306 => Dict("load"=>2.56, "solar"=>8.38, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        307 => Dict("load"=>2.4, "solar"=>8.38, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
        308 => Dict("load"=>3.18, "solar"=>9.64, "wind"=>2.94, "wind_offshore"=>50.6, "ng"=>0.6, "coal"=>0.45, "nuclear"=>0.8),
      ),
      2045 => Dict(
        301 => Dict("load"=>3.44, "solar"=>9.81, "wind"=>3.77, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        302 => Dict("load"=>2.59, "solar"=>9.81, "wind"=>3.93, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        303 => Dict("load"=>2.26, "solar"=>9.81, "wind"=>3.32, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        304 => Dict("load"=>2.54, "solar"=>11.28, "wind"=>3.02, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        305 => Dict("load"=>2.96, "solar"=>10.79, "wind"=>3.02, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        306 => Dict("load"=>2.76, "solar"=>9.81, "wind"=>3.02, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        307 => Dict("load"=>2.59, "solar"=>9.81, "wind"=>3.02, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
        308 => Dict("load"=>3.44, "solar"=>11.28, "wind"=>3.02, "wind_offshore"=>50.6, "ng"=>0.61, "coal"=>0.45, "nuclear"=>0.8),
      ),
    ),
  ),
]

# ── Resolve the ratio for a (scenario, zone, fuel, year) ─────────────────────
# override if present, else default.

function ratio_for(scenario, zone_id::Int, fuel::String, year::Int)
    ov = get(get(scenario.overrides, year, Dict()), zone_id, Dict())
    if haskey(ov, fuel)
        return ov[fuel], true          # zonal override
    end
    return scenario.defaults[year][fuel], false   # scenario default
end

# ── Load bus → zone mapping ───────────────────────────────────────────────────

function load_zone_map(path::String)
    ps = JSON.parsefile(path)
    zmap = Dict{Int,Int}()
    for (bid, bus) in ps["bus"]
        zmap[parse(Int, bid)] = bus["zone_id"]
    end
    return zmap
end

# ── Write per-scenario per-year ratio JSON (read by update_decarbonization) ──
# Structure: { "defaults": {fuel: ratio}, "zones": {zone_id: {fuel: ratio}} }

function write_ratios_json(simdir::String, scenario, year::Int)
    defaults = scenario.defaults[year]
    zones_out = Dict{String,Any}()
    for zid in sort(collect(keys(ZONE_NAMES)))
        zone_ratios = Dict{String,Float64}()
        for fuel in FUELS
            r, _ = ratio_for(scenario, zid, fuel, year)
            zone_ratios[fuel] = r
        end
        zones_out[string(zid)] = Dict(
            "zone_name" => ZONE_NAMES[zid],
            "ratios" => zone_ratios,
        )
    end
    out = Dict(
        "year" => year,
        "scenario" => scenario.name,
        "method" => "direct final ratio vs 2022 baseline: final = ratio x CSV[2022]",
        "defaults" => defaults,
        "zones" => zones_out,
    )
    path = joinpath(simdir, "scenario_ratios_$(year).json")
    open(path, "w") do f
        JSON.print(f, out, 2)
    end
    return path
end

function write_config(simdir::String, year::Int, base_config::Dict; inv_dir=nothing)
    config = deepcopy(base_config)
    config["decarbonization"]      = abspath(BASELINE_DECARB_CSV)  # source of 2022 baseline
    config["decarbonization_year"] = year
    config["dates"]                = REPRESENTATIVE_DATES
    config["num_representatives"]  = length(REPRESENTATIVE_DATES)
    config["representative_prob"]  = fill(1.0/length(REPRESENTATIVE_DATES), length(REPRESENTATIVE_DATES))
    inv_dir !== nothing && (config["current_investment_dir"] = inv_dir)
    open(joinpath(simdir, "config.toml"), "w") do f
        TOML.print(f, config)
    end
end

# ── Fast-run investment files (optional) ─────────────────────────────────────

function write_fast_run(dir::String, ps_path::String)
    ps = JSON.parsefile(ps_path)
    mkpath(dir)
    lrows = []
    for i in 1:length(ps["branch"])
        b = ps["branch"][string(i)]
        fb, tb = ps["bus"][string(b["f_bus"])], ps["bus"][string(b["t_bus"])]
        push!(lrows, (Branch_Index=i, Lat1=fb["lat"], Lon1=fb["lon"],
                      Lat2=tb["lat"], Lon2=tb["lon"], Rate_A=b["rate_a"], Upgrade_Lvl=1.0))
    end
    CSV.write(joinpath(dir,"line_investments.csv"), DataFrame(lrows))
    srows = []
    for i in 1:length(ps["bus"])
        bus = ps["bus"][string(i)]
        push!(srows, (Node_Index=i, Node_Name=get(bus,"bus_name","BUS_$i"),
                      Lat=bus["lat"], Lon=bus["lon"], Storage_Energy=12.0))
    end
    CSV.write(joinpath(dir,"storage_investments.csv"), DataFrame(srows))
end

# ── Main ──────────────────────────────────────────────────────────────────────

println("=== Scenario Generator (direct final ratios) ===")
flush(stdout)

base_config = TOML.parsefile(BASELINE_CONFIG_TOML)
zone_map    = load_zone_map(POWER_SYSTEM_DATA)
println("Loaded config + zone map ($(length(zone_map)) buses, $(length(unique(values(zone_map)))) zones)")
flush(stdout)

if isdir(OUTPUT_DIR)
    existing = readdir(OUTPUT_DIR)
    if !isempty(existing)
        println("Clearing $(length(existing)) existing item(s) from $OUTPUT_DIR/ ...")
        for f in existing
            rm(joinpath(OUTPUT_DIR, f); recursive=true)
        end
    end
end
mkpath(OUTPUT_DIR)

FAST_RUN_DIR = joinpath(OUTPUT_DIR, "fast_run_investments")
if USE_FAST_RUN
    write_fast_run(FAST_RUN_DIR, POWER_SYSTEM_DATA)
    println("Wrote fast-run investment files.")
end

generated = String[]
for scenario in SCENARIOS
    println("\n── $(scenario.name): $(scenario.description)")
    flush(stdout)
    for year in PLANNING_YEARS
        simdir = joinpath(OUTPUT_DIR, scenario.name, string(year))
        mkpath(joinpath(simdir, "output"))
        mkpath(joinpath(simdir, "visual"))
        write_ratios_json(simdir, scenario, year)
        write_config(simdir, year, base_config; inv_dir = USE_FAST_RUN ? abspath(FAST_RUN_DIR) : nothing)
        println("   ✓ $year → $simdir")
        push!(generated, simdir)
        flush(stdout)
    end
end

println("\n=== Done: $(length(generated)) simdirs under $OUTPUT_DIR/ ===")
println("Each simdir has scenario_ratios_<year>.json (direct ratios) + config.toml")
println("update_decarbonization applies: final = ratio x CSV[2022_baseline]")
flush(stdout)