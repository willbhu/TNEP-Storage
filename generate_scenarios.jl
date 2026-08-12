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

SCENARIOS (each varies a DIFFERENT dimension, so effects can be isolated):
    A_low  = EIA AEO reference case. Baseline load AND baseline generation.
    B_med  = HIGHER ORGANIC LOAD growth (industrial, electrification, oil & gas).
             Generation stays at the EIA reference. Isolates the load effect.
    C_fossil = SAME LOAD AS B, but a strongly FOSSIL-HEAVY GENERATION MIX:
             solar ~35% of EIA, wind ~50% of EIA, offshore wind ~25% of EIA,
             gas GROWS 15-40% above 2022 (new CCGT build) instead of retiring,
             coal held at 2022 levels through 2035. Renewables end at ~68% of
             capacity vs ~88% in A/B. Isolates the generation-mix effect.

    NOTE: data-center demand is NOT in these load ratios. Data centers are a
    separate NODAL layer applied by add_data_centers.jl, which creates
    <scenario>_dc twins. This keeps load growth and data-center growth as
    independent, comparable dimensions.

SOURCES:
    ERCOT 2025 LTDEF   https://www.ercot.com/files/docs/2025/04/08/ERCOT-2025-Long-Term-Load-Forecast-Report.pdf
    ERCOT RPG          https://www.ercot.com/files/docs/2025/04/29/Long-term-Load-Forecast-RPG.pdf
    EIA AEO 2023       https://www.eia.gov/outlooks/aeo/
    NREL ATB 2024      https://atb.nrel.gov/electricity/2024/

FIXED INVESTMENTS (fast runs):
    Set FIXED_INVESTMENT_DIR below to a folder containing pre-set
    line_investments.csv and storage_investments.csv. Every generated config
    then gets `current_investment_dir` pointing at it, which lets the model
    skip solving investments from scratch. Per Kevin: Upgrade_Lvl all 1.0 in
    line_investments.csv, Storage_Energy all 12.0 in storage_investments.csv.
    Set to `nothing` to disable and let the model solve investments normally.

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
REPRESENTATIVE_DATES = ["2016-08-11"]
# REPRESENTATIVE_DATES = [
#     "2016-01-27","2016-02-23","2016-03-06","2016-03-11","2016-03-22","2016-03-27",
#     "2016-04-03","2016-04-22","2016-05-10","2016-05-19","2016-06-21","2016-07-11",
#     "2016-08-11","2016-09-02","2016-09-10","2016-11-16","2016-12-03","2016-12-08"]

# ── Fixed investments (fast run) ──────────────────────────────────────────────
# Per Kevin: to run the model faster, supply pre-set investment files and point
# `current_investment_dir` at the folder containing them:
#     line_investments.csv     -- Upgrade_Lvl all set to 1.0
#     storage_investments.csv  -- Storage_Energy all set to 12.0
# Set FIXED_INVESTMENT_DIR to that folder to enable for ALL scenarios.
# Set to nothing to disable (model solves investments from scratch).
FIXED_INVESTMENT_DIR = "current_investment_dir"   # or `nothing` to disable

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

  (
    name = "A_low",
    description = "EIA AEO reference case — baseline load and generation",
    defaults = Dict(
      2030 => Dict("load"=>1.126, "solar"=>4.511, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
      2035 => Dict("load"=>1.214, "solar"=>5.799, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
      2040 => Dict("load"=>1.307, "solar"=>6.873, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
      2045 => Dict("load"=>1.408, "solar"=>8.039, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
    ),
    overrides = Dict(
      2030 => Dict(
        301 => Dict("load"=>1.23, "solar"=>4.511, "wind"=>2.22, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        302 => Dict("load"=>1.09, "solar"=>4.511, "wind"=>2.26, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        303 => Dict("load"=>1.04, "solar"=>4.511, "wind"=>2.1, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        304 => Dict("load"=>1.08, "solar"=>4.78, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        305 => Dict("load"=>1.15, "solar"=>4.69, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        306 => Dict("load"=>1.12, "solar"=>4.511, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        307 => Dict("load"=>1.09, "solar"=>4.511, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        308 => Dict("load"=>1.23, "solar"=>4.78, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
      ),
      2035 => Dict(
        301 => Dict("load"=>1.32, "solar"=>5.799, "wind"=>2.45, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        302 => Dict("load"=>1.18, "solar"=>5.799, "wind"=>2.49, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        303 => Dict("load"=>1.12, "solar"=>5.799, "wind"=>2.32, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        304 => Dict("load"=>1.17, "solar"=>6.15, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        305 => Dict("load"=>1.24, "solar"=>6.03, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        306 => Dict("load"=>1.2, "solar"=>5.799, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        307 => Dict("load"=>1.18, "solar"=>5.799, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        308 => Dict("load"=>1.32, "solar"=>6.15, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
      ),
      2040 => Dict(
        301 => Dict("load"=>1.42, "solar"=>6.873, "wind"=>2.49, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        302 => Dict("load"=>1.27, "solar"=>6.873, "wind"=>2.54, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        303 => Dict("load"=>1.2, "solar"=>6.873, "wind"=>2.35, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        304 => Dict("load"=>1.25, "solar"=>7.29, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        305 => Dict("load"=>1.33, "solar"=>7.15, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        306 => Dict("load"=>1.3, "solar"=>6.873, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        307 => Dict("load"=>1.27, "solar"=>6.873, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        308 => Dict("load"=>1.42, "solar"=>7.29, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
      ),
      2045 => Dict(
        301 => Dict("load"=>1.53, "solar"=>8.039, "wind"=>2.55, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        302 => Dict("load"=>1.36, "solar"=>8.039, "wind"=>2.6, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        303 => Dict("load"=>1.3, "solar"=>8.039, "wind"=>2.41, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        304 => Dict("load"=>1.35, "solar"=>8.52, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        305 => Dict("load"=>1.44, "solar"=>8.36, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        306 => Dict("load"=>1.4, "solar"=>8.039, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        307 => Dict("load"=>1.36, "solar"=>8.039, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        308 => Dict("load"=>1.53, "solar"=>8.52, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
      ),
    ),
  ),
  (
    name = "B_med",
    description = "Higher organic load growth (industrial + electrification), EIA-reference generation",
    defaults = Dict(
      2030 => Dict("load"=>1.22, "solar"=>4.511, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
      2035 => Dict("load"=>1.36, "solar"=>5.799, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
      2040 => Dict("load"=>1.5, "solar"=>6.873, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
      2045 => Dict("load"=>1.66, "solar"=>8.039, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
    ),
    overrides = Dict(
      2030 => Dict(
        301 => Dict("load"=>1.49, "solar"=>4.511, "wind"=>2.52, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        302 => Dict("load"=>1.12, "solar"=>4.511, "wind"=>2.62, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        303 => Dict("load"=>0.98, "solar"=>4.511, "wind"=>2.22, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        304 => Dict("load"=>1.1, "solar"=>5.19, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        305 => Dict("load"=>1.28, "solar"=>4.96, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        306 => Dict("load"=>1.2, "solar"=>4.511, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        307 => Dict("load"=>1.12, "solar"=>4.511, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
        308 => Dict("load"=>1.49, "solar"=>5.19, "wind"=>2.015, "wind_offshore"=>21.628, "ng"=>0.787, "coal"=>0.821, "nuclear"=>0.975),
      ),
      2035 => Dict(
        301 => Dict("load"=>1.66, "solar"=>5.799, "wind"=>2.78, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        302 => Dict("load"=>1.25, "solar"=>5.799, "wind"=>2.89, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        303 => Dict("load"=>1.09, "solar"=>5.799, "wind"=>2.45, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        304 => Dict("load"=>1.22, "solar"=>6.67, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        305 => Dict("load"=>1.43, "solar"=>6.38, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        306 => Dict("load"=>1.33, "solar"=>5.799, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        307 => Dict("load"=>1.25, "solar"=>5.799, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
        308 => Dict("load"=>1.66, "solar"=>6.67, "wind"=>2.226, "wind_offshore"=>50.632, "ng"=>0.73, "coal"=>0.821, "nuclear"=>0.902),
      ),
      2040 => Dict(
        301 => Dict("load"=>1.83, "solar"=>6.873, "wind"=>2.83, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        302 => Dict("load"=>1.38, "solar"=>6.873, "wind"=>2.94, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        303 => Dict("load"=>1.2, "solar"=>6.873, "wind"=>2.49, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        304 => Dict("load"=>1.35, "solar"=>7.9, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        305 => Dict("load"=>1.58, "solar"=>7.56, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        306 => Dict("load"=>1.47, "solar"=>6.873, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        307 => Dict("load"=>1.38, "solar"=>6.873, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
        308 => Dict("load"=>1.83, "solar"=>7.9, "wind"=>2.264, "wind_offshore"=>50.632, "ng"=>0.714, "coal"=>0.821, "nuclear"=>0.801),
      ),
      2045 => Dict(
        301 => Dict("load"=>2.03, "solar"=>8.039, "wind"=>2.9, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        302 => Dict("load"=>1.53, "solar"=>8.039, "wind"=>3.01, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        303 => Dict("load"=>1.33, "solar"=>8.039, "wind"=>2.55, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        304 => Dict("load"=>1.49, "solar"=>9.24, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        305 => Dict("load"=>1.74, "solar"=>8.84, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        306 => Dict("load"=>1.63, "solar"=>8.039, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        307 => Dict("load"=>1.53, "solar"=>8.039, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
        308 => Dict("load"=>2.03, "solar"=>9.24, "wind"=>2.318, "wind_offshore"=>50.632, "ng"=>0.718, "coal"=>0.821, "nuclear"=>0.801),
      ),
    ),
  ),
  (
    name = "C_fossil",
    description = "Same load as B, FOSSIL-HEAVY generation — solar 35% / wind 50% of EIA, gas grows, coal held",
    defaults = Dict(
      2030 => Dict("load"=>1.22, "solar"=>1.58, "wind"=>1.01, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
      2035 => Dict("load"=>1.36, "solar"=>2.03, "wind"=>1.11, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
      2040 => Dict("load"=>1.5, "solar"=>2.41, "wind"=>1.13, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
      2045 => Dict("load"=>1.66, "solar"=>2.81, "wind"=>1.16, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
    ),
    overrides = Dict(
      2030 => Dict(
        301 => Dict("load"=>1.49, "solar"=>1.58, "wind"=>1.26, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        302 => Dict("load"=>1.12, "solar"=>1.58, "wind"=>1.31, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        303 => Dict("load"=>0.98, "solar"=>1.58, "wind"=>1.11, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        304 => Dict("load"=>1.1, "solar"=>1.82, "wind"=>1.01, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        305 => Dict("load"=>1.28, "solar"=>1.74, "wind"=>1.01, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        306 => Dict("load"=>1.2, "solar"=>1.58, "wind"=>1.01, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        307 => Dict("load"=>1.12, "solar"=>1.58, "wind"=>1.01, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
        308 => Dict("load"=>1.49, "solar"=>1.82, "wind"=>1.01, "wind_offshore"=>5.41, "ng"=>1.15, "coal"=>1.0, "nuclear"=>0.975),
      ),
      2035 => Dict(
        301 => Dict("load"=>1.66, "solar"=>2.03, "wind"=>1.39, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        302 => Dict("load"=>1.25, "solar"=>2.03, "wind"=>1.44, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        303 => Dict("load"=>1.09, "solar"=>2.03, "wind"=>1.22, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        304 => Dict("load"=>1.22, "solar"=>2.33, "wind"=>1.11, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        305 => Dict("load"=>1.43, "solar"=>2.23, "wind"=>1.11, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        306 => Dict("load"=>1.33, "solar"=>2.03, "wind"=>1.11, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        307 => Dict("load"=>1.25, "solar"=>2.03, "wind"=>1.11, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
        308 => Dict("load"=>1.66, "solar"=>2.33, "wind"=>1.11, "wind_offshore"=>12.66, "ng"=>1.25, "coal"=>1.0, "nuclear"=>0.902),
      ),
      2040 => Dict(
        301 => Dict("load"=>1.83, "solar"=>2.41, "wind"=>1.41, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        302 => Dict("load"=>1.38, "solar"=>2.41, "wind"=>1.47, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        303 => Dict("load"=>1.2, "solar"=>2.41, "wind"=>1.24, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        304 => Dict("load"=>1.35, "solar"=>2.77, "wind"=>1.13, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        305 => Dict("load"=>1.58, "solar"=>2.65, "wind"=>1.13, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        306 => Dict("load"=>1.47, "solar"=>2.41, "wind"=>1.13, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        307 => Dict("load"=>1.38, "solar"=>2.41, "wind"=>1.13, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
        308 => Dict("load"=>1.83, "solar"=>2.77, "wind"=>1.13, "wind_offshore"=>12.66, "ng"=>1.32, "coal"=>0.95, "nuclear"=>0.801),
      ),
      2045 => Dict(
        301 => Dict("load"=>2.03, "solar"=>2.81, "wind"=>1.45, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        302 => Dict("load"=>1.53, "solar"=>2.81, "wind"=>1.51, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        303 => Dict("load"=>1.33, "solar"=>2.81, "wind"=>1.28, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        304 => Dict("load"=>1.49, "solar"=>3.23, "wind"=>1.16, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        305 => Dict("load"=>1.74, "solar"=>3.09, "wind"=>1.16, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        306 => Dict("load"=>1.63, "solar"=>2.81, "wind"=>1.16, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        307 => Dict("load"=>1.53, "solar"=>2.81, "wind"=>1.16, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
        308 => Dict("load"=>2.03, "solar"=>3.23, "wind"=>1.16, "wind_offshore"=>12.66, "ng"=>1.4, "coal"=>0.9, "nuclear"=>0.801),
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

# Validate the fixed-investment folder if one is configured
inv_dir_abs = nothing
if FIXED_INVESTMENT_DIR !== nothing
    if isdir(FIXED_INVESTMENT_DIR)
        needed = ["line_investments.csv", "storage_investments.csv"]
        missing_files = [f for f in needed if !isfile(joinpath(FIXED_INVESTMENT_DIR, f))]
        if isempty(missing_files)
            inv_dir_abs = abspath(FIXED_INVESTMENT_DIR)
            println("Fixed investments ENABLED -> $inv_dir_abs")
        else
            @warn "FIXED_INVESTMENT_DIR '$FIXED_INVESTMENT_DIR' is missing: $(join(missing_files, ", ")). Fixed investments DISABLED."
        end
    else
        @warn "FIXED_INVESTMENT_DIR '$FIXED_INVESTMENT_DIR' not found. Fixed investments DISABLED."
    end
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
        write_config(simdir, year, base_config; inv_dir = inv_dir_abs)
        println("   ✓ $year → $simdir")
        push!(generated, simdir)
        flush(stdout)
    end
end

println("\n=== Done: $(length(generated)) simdirs under $OUTPUT_DIR/ ===")
println("Each simdir has scenario_ratios_<year>.json (direct ratios) + config.toml")
println("update_decarbonization applies: final = ratio x CSV[2022_baseline]")
flush(stdout)