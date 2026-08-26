# Zonal Scenario Generation for TNEP-Storage

This adds spatially resolved future-grid scenarios to the PTDF-based
transmission expansion and storage planning model in
[AI4OPT/TNEP-Storage](https://github.com/AI4OPT/TNEP-Storage).

The base model scales all future generation and load uniformly across Texas —
one multiplier per fuel type applied to every bus. This pipeline replaces that
with a ratio per **(zone, fuel, year)**, and models data-center demand
separately as nodal load at individual buses.

---

## What it produces

Running the pipeline gives you, for each scenario and planning year:

| Output | Description |
|---|---|
| `config.toml` | Model config pointing at the scenario's ratios |
| `scenario_ratios_<year>.json` | The scaling ratio for every zone and fuel |
| `output/` | Solved results — dispatch, flows, investments, costs |
| `visual/` | Six figures plus a text report |

Plus scenario-level scaling tables for review, and optional data-center
variants of any scenario.

---

## Requirements

**Julia** with the project environment from the base repo (`Project.toml`,
`Manifest.toml`). Additionally requires `Colors` for the figure palettes:

```julia
import Pkg
Pkg.activate(".")
Pkg.instantiate()
Pkg.add("Colors")
```

**Gurobi** with a valid license — the model is a MIP and will not solve
without it.

**Data** — the `tamu/` dataset from
[zenodo.org/records/4538590](https://zenodo.org/records/4538590), extracted
into the project root. The pipeline expects:

```
data/topology/tamu/decarbonization_1015.csv
data/topology/tamu/texas/power_system_data.json
examples/example_simdir/config.toml
```

---

## Installation

Place the files as follows:

```
TNEP-Storage/
├── generate_scenarios.jl          ← project root
├── export_zonal_tables.jl
├── add_data_centers.jl
├── run_and_plot.jl
├── report_summary.jl
├── visualize_generation_mix.jl
│
├── src_clean/helpers/
│   └── decarbonization.jl         ← REPLACES the existing file
│
└── current_investment_dir/        ← optional, see "Fixed investments"
    ├── line_investments.csv
    └── storage_investments.csv
```

---

## Quick start

From the project root, in Julia:

```julia
import Pkg
Pkg.activate(".")
using CSV, DataFrames, TOML, JSON

# 1. Build the scenarios
include("generate_scenarios.jl")

# 2. Export the scaling tables for review
include("export_zonal_tables.jl")

# 3. (Optional) Create data-center variants
include("add_data_centers.jl")
add_data_centers_to_all()

# 4. Load the model and solve one scenario, generating all figures
include("src_clean/main.jl")
include("run_and_plot.jl")
run_and_plot("scenarios/B_med/2030")
```

---

## How the scaling works

Every generator and every load bus is scaled by a single number:

```
future_capacity = ratio × 2022_baseline_capacity
```

- `1.00` — unchanged from 2022
- `2.00` — doubled
- `0.80` — 80% of 2022, i.e. 20% retired

The ratio is resolved per bus by looking up its `zone_id`:

1. If that zone has a specific value for the fuel, use it
2. Otherwise fall back to the scenario default

Both the defaults and the per-zone values live in the `SCENARIOS` constant at
the top of `generate_scenarios.jl`. The number written there is the number
applied — there is no derivation or compounding.

The decarbonization CSV is used only to read the 2022 baseline values.

---

## The scenarios

Each varies **one** dimension so its effect can be isolated.

| | `A_low` | `B_med` | `C_fossil` |
|---|---|---|---|
| Load 2030 → 2045 | 1.13 → 1.41 | 1.22 → 1.66 | 1.22 → 1.66 |
| Solar 2045 | 8.04× | 8.04× | 2.81× |
| Wind 2045 | 2.32× | 2.32× | 1.16× |
| Gas 2045 | 0.72× (retiring) | 0.72× | 1.40× (growing) |
| Coal 2045 | 0.82× | 0.82× | 0.90× (held) |
| Renewable share | 88% | 88% | 68% |
| Varies | *baseline* | **load** | **generation mix** |

This gives three clean comparisons:

- **A vs B** — same generation, different load → isolates load growth
- **B vs C** — same load, different generation → isolates the generation pathway
- **X vs X_dc** — same everything ± data centers → isolates data-center impact

Planning years are 2030, 2035, 2040 and 2045.

---

## Zones

The eight `zone_id` values in `power_system_data.json` map to ERCOT weather
zones, derived from bus latitude and longitude:

| ID | Zone | Character |
|---|---|---|
| 301 | Far West (Permian Basin) | Highest growth — oil & gas electrification |
| 302 | West (Lubbock) | Wind corridor, lower load density |
| 303 | West/North (Abilene) | Rural, below statewide average |
| 304 | South (Corpus Christi) | Coastal industrial |
| 305 | South Central (Waco/Austin) | Austin corridor growth |
| 306 | South Central (San Antonio) | Population |
| 307 | Coast (Gulf) | Industrial and port |
| 308 | North Central (DFW) | Metro population growth |

---

## Data centers

Data-center demand is modeled as **nodal** load — fixed-MW blocks at
individual buses — rather than folded into the zonal load ratios. A data
center connects at one substation, not across a region.

`add_data_centers.jl` reads existing scenarios and creates `<scenario>_dc`
twins:

```julia
include("add_data_centers.jl")
add_data_centers_to_all()
```

This produces `scenarios/B_med_dc/2030/` alongside `scenarios/B_med/2030/`,
identical except for the added load. Solve either with `run_and_plot`.

**Parameters** (all in `add_data_centers.jl`):

- 500 MW per center, flat 24/7
- 100 centers per scenario = 50 GW added
- Placed at the highest-load buses within hotspot zones, weighted
  DFW 40%, Austin 25%, Houston 12%, Abilene 12%, Far West 11%

**To verify the load actually reached the model** after solving both:

```julia
verify_data_centers("scenarios/B_med_dc/2030")
```

This compares peak load against the base scenario and reports the difference.
If it comes back zero, the hook at the end of `update_decarbonization` is
missing — the function prints the exact block to paste in.

**To inspect placement without creating twins:**

```julia
add_data_centers_to("scenarios/B_med/2030"; mode=:report)
```

Writes `data_center_placement.csv` with bus, zone, MW and coordinates.

---

## Fixed investments

Solving investment siting from scratch is slow. To speed up runs, supply
pre-set investment files and the model will use them instead of optimizing:

```
current_investment_dir/
├── line_investments.csv      (Upgrade_Lvl all 1.0)
└── storage_investments.csv   (Storage_Energy all 12.0)
```

Enabled by default via the constant near the top of `generate_scenarios.jl`:

```julia
FIXED_INVESTMENT_DIR = "current_investment_dir"   # or `nothing` to disable
```

**When fixed investments are on**, installed storage and line upgrades are
inputs rather than results — they are identical across every scenario, and the
investment map shows a uniformly upgraded grid. Storage *utilization* remains
a genuine result, since it measures how much of the fixed capacity each
scenario actually cycles.

Set to `nothing` and re-solve to get real siting decisions.

---

## Figures

Each solve writes figures and a report into `<simdir>/visual/`:

| File | Type | Shows |
|---|---|---|
| `capacity_mix_pie.png` | input | Installed capacity by fuel after scaling |
| `daily_profile_stacked.png` | input | Available capacity against load, pre-solve |
| `actual_dispatch_stacked.png` | solved | Dispatch with storage charge and discharge |
| `report.txt` | solved | Costs, investments, storage need, load shed |

Every figure carries a title and a caption stating what it shows and whether
it is model input or solved output.

`run_and_plot` also calls the geographic plotting scripts in
`viz/tamu/topology/`, which write interactive maps of demand, investment
siting and storage use into the same folder. Those are optional — each is
wrapped in try/catch, so the run continues if they are unavailable.

To regenerate figures without re-solving:

```julia
run_and_plot("scenarios/B_med/2030"; solve=false)
```

---

## Reading the results

```julia
include("report_summary.jl")

report_summary("scenarios/B_med/2030")           # one scenario
report_all(; csv_out="scenario_comparison.csv")  # every solved scenario
```

`report_all` writes a single table with one row per scenario and year, and
flags any scenario with nonzero load shed.

**Load shed is the validation check.** Zero means every hour was fully served.
Nonzero means the generation and transmission build cannot meet demand — a
result in its own right, not necessarily an error.

**Storage utilization** is computed from the solved dispatch. Since
`energy.csv` has no state-of-charge column, SOC is reconstructed by
integrating charge and discharge with an assumed 85% round-trip efficiency.
Each node's requirement is `max(SOC swing, peak discharge × 4h)` — the larger
of its energy and power needs — and nodes are labelled energy-limited or
power-limited accordingly.

---

## Running everything

```julia
for scen in ["A_low", "B_med", "C_fossil", "B_med_dc", "C_fossil_dc"]
    for year in [2030, 2035, 2040, 2045]
        simdir = "scenarios/$scen/$year"
        println("\n>>> $simdir")
        try
            run_and_plot(simdir)
        catch e
            println("FAILED: $simdir — $e")
        end
    end
end

report_all(; csv_out="scenario_comparison.csv")
```

By default `REPRESENTATIVE_DATES` in `generate_scenarios.jl` is set to a
single day for fast testing. The full 18-day set is commented directly above
it — uncomment for production runs, and expect solves to take substantially
longer.

---

## Modifying the scenarios

**Change a scaling ratio** — edit the `SCENARIOS` constant in
`generate_scenarios.jl`. Both `defaults` (per year) and `overrides` (per zone
per year) hold final ratios versus 2022.

**Add a scenario** — append a new named tuple to `SCENARIOS` with `name`,
`description`, `defaults` and `overrides`. If it should get data centers, add
an entry to `DC_COUNTS` in `add_data_centers.jl`.

**Change planning years** — edit `PLANNING_YEARS`, and make sure every year
appears in every scenario's `defaults` and `overrides`.

**Change representative days** — edit `REPRESENTATIVE_DATES`. Dates must exist
in the underlying profile data.

After any change, regenerate:

```julia
include("generate_scenarios.jl")
include("export_zonal_tables.jl")
```

Note that `generate_scenarios.jl` **clears the `scenarios/` directory**, which
deletes previously solved outputs. Run it before solving, not after.


## Sources

Load forecasts and zonal growth patterns:

- ERCOT, *2025 Long-Term Hourly Peak Demand and Energy Forecast*
  <https://www.ercot.com/files/docs/2025/04/08/ERCOT-2025-Long-Term-Load-Forecast-Report.pdf>
- ERCOT, *Permian Basin Reliability Plan Study*, July 2024
  <https://www.rtoinsider.com/wp-content/uploads/2025/01/ERCOT-PB-Plan-Jul-24.pdf>
- LCG Consulting, *2025 ERCOT Electricity Market Outlook*
  <https://www.energyonline.com/reports/2025_ERCOT_Outlook.pdf>

Generation mix:

- U.S. Energy Information Administration, *Annual Energy Outlook: Narrative*
  <https://www.eia.gov/outlooks/aeo/narrative/>
- U.S. Energy Information Administration, *Texas State Energy Profile Analysis*
  <https://www.eia.gov/states/TX/analysis>

Data-center geography:

- *The Texas Tribune*, "Texas regulation of data centers, electricity and
  water", June 8 2026
  <https://www.texastribune.org/2026/06/08/texas-regulation-data-centers-electricity-power-water/>

Underlying model:

- Wu, Haider & Van Hentenryck, *High-Resolution PTDF-Based Planning of Storage
  and Transmission Under High Renewables*, arXiv:2510.14696

---
