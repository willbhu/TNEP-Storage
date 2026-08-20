"""
add_data_centers.jl

Takes ALREADY-GENERATED scenarios and produces data-center variants of them,
WITHOUT touching generate_scenarios.jl, decarbonization.jl, or any base code.

Per meeting notes 7/29: "instead of changing all the files and code ... generate
the scenarios as usual, then have another script which can make those scenarios
again but just with data centers".

WHAT IT DOES
    For each source scenario simdir (e.g. scenarios/C_fossil/2030) it creates a
    twin (e.g. scenarios/C_fossil_dc/2030) that is identical except a nodal
    data-center load file is written alongside. A small companion patch to
    update_decarbonization (see DATA_CENTER_HOOK below) reads that file at
    solve time. If you prefer zero code changes, the script can instead BAKE
    the data-center load directly into a copy of the scenario's config +
    a precomputed data_center_load.json that your plotting / analysis reads.

    Two modes:
      mode = :sidecar  -> writes data_center_load.json into the _dc simdir.
                          Requires the 3-line hook in update_decarbonization
                          (printed at the end). Cleanest for actually solving.
      mode = :report   -> writes data_center_placement.csv only (no solve
                          integration) so you can SEE and PLOT where the data
                          centers go without changing any model code.

═══════════════════════════════════════════════════════════════════════════════
METHODOLOGY (nodal data centers)
═══════════════════════════════════════════════════════════════════════════════
Each data center = fixed 500 MW block of flat, 24/7 load added to ONE bus
(a data center connects at a single substation, not across a whole zone).

Placement: highest existing-load buses within hotspot zones, because data
centers cluster near existing demand and infrastructure.

Hotspot zone weights (from ERCOT interconnection-request geography):
    308 DFW / North TX      0.40   (86 planned centers -- most)
    305 Austin / Central    0.25   (56 planned)
    307 Houston / Coast     0.12   (major hub)
    303 Abilene / West-N    0.12   (part of 45 West)
    301 Far West / Permian  0.11   (part of 45 West; Abilene facility ~1200 MW)

Counts (ERCOT adjusted-vs-unadjusted split):
    A_low  : 0    (EIA reference -- no data-center boom)
    B_med  : 40   (~20 GW; ERCOT adjusts DC requests to ~49.8%)
    C_fossil : 80   (~40 GW; TSP unadjusted, full requests)

SOURCES
    Texas Tribune 2026 (86 North / 56 Central / 45 West):
      https://www.texastribune.org/2026/06/08/texas-regulation-data-centers-electricity-power-water/
    Newsweek/Houston Chronicle 2026 (top counties Ellis, Johnson, Dallas...):
      https://www.newsweek.com/map-where-texas-greatest-data-center-demands-12058983
    ENGIE 2026 (four hubs DFW/Austin/Houston/San Antonio; 606 centers):
      https://www.engieresources.com/market-insight/texas-data-centers-the-new-large-load-shaping-ercot/
    CleanSpark 2026 (300-600 MW project -> 500 MW central size):
      https://www.barchart.com/story/news/37036905/
    ERCOT 2025 LTDEF (DC requests adjusted to 49.8%):
      https://www.ercot.com/files/docs/2025/04/08/ERCOT-2025-Long-Term-Load-Forecast-Report.pdf

═══════════════════════════════════════════════════════════════════════════════
USAGE (from project root):
    using CSV, DataFrames, JSON, TOML
    include("add_data_centers.jl")

    # Make _dc twins of every scenario/year, with a sidecar load file:
    add_data_centers_to_all()

    # Or just one scenario, report-only (no model changes needed):
    add_data_centers_to("scenarios/C_fossil/2030"; mode=:report)
═══════════════════════════════════════════════════════════════════════════════
"""

using CSV
using DataFrames
using JSON
using TOML

# NOTE: names are prefixed DC_ to avoid colliding with globals that
# generate_scenarios.jl already defines (DC_POWER_SYSTEM, DC_ZONE_NAMES, ...),
# so both scripts can be included in the same Julia session.

DC_MW_PER_CENTER = 500.0
DC_BASE_POWER    = 100.0
DC_POWER_SYSTEM  = "data/topology/tamu/texas/power_system_data.json"
DC_SCEN_DIR      = "scenarios"

DC_HOTSPOT_WEIGHTS = Dict(
    308 => 0.40, 305 => 0.25, 307 => 0.12, 303 => 0.12, 301 => 0.11,
)

DC_COUNTS = Dict(
    "A_low" => 0, "B_med" => 50, "C_fossil" => 50,
)

DC_ZONE_NAMES = Dict(
    301 => "Far West (Permian Basin)", 302 => "West (Lubbock)",
    303 => "West/North (Abilene)", 304 => "South (Corpus Christi)",
    305 => "South Central (Waco/Austin)", 306 => "South Central (San Antonio)",
    307 => "Coast (Gulf Coast)", 308 => "North Central (DFW)",
)

# ── Load zone map + per-bus baseline load from power_system_data.json ─────────

function load_grid_info()
    ps = JSON.parsefile(DC_POWER_SYSTEM)
    zone_map = Dict{Int,Int}()
    bus_load = Dict{Int,Float64}()   # baseline Pd per bus (proxy for "big load bus")
    bus_ll   = Dict{Int,Tuple{Float64,Float64}}()
    for (bid_str, bus) in ps["bus"]
        bid = parse(Int, bid_str)
        zone_map[bid] = bus["zone_id"]
        bus_load[bid] = get(bus, "Pd", 0.0)
        bus_ll[bid]   = (bus["lat"], bus["lon"])
    end
    return zone_map, bus_load, bus_ll
end

# ── Decide placement: bus_id => added_MW ─────────────────────────────────────

function plan_placement(scenario_name::String, zone_map, bus_load)
    count = get(DC_COUNTS, scenario_name, 0)
    placement = Dict{Int,Float64}()
    count == 0 && return placement

    for (zone_id, weight) in DC_HOTSPOT_WEIGHTS
        n = round(Int, count * weight)
        n == 0 && continue
        zbuses = [(b, bus_load[b]) for b in keys(bus_load) if get(zone_map, b, -1) == zone_id]
        isempty(zbuses) && continue
        sort!(zbuses, by = x -> x[2], rev = true)
        for i in 1:n
            b = zbuses[mod1(i, length(zbuses))][1]
            placement[b] = get(placement, b, 0.0) + DC_MW_PER_CENTER
        end
    end
    return placement
end

# ── Extract scenario name from a simdir path ─────────────────────────────────
# scenarios/C_fossil/2030 -> "C_fossil"

function scenario_of(simdir::String)
    parts = splitpath(rstrip(simdir, ['/','\\']))
    length(parts) >= 2 ? parts[end-1] : basename(simdir)
end

# ── Make a data-center twin of one scenario simdir ───────────────────────────

function add_data_centers_to(simdir::String; mode::Symbol = :sidecar)
    scen = scenario_of(simdir)
    year = basename(rstrip(simdir, ['/','\\']))
    zone_map, bus_load, bus_ll = load_grid_info()
    placement = plan_placement(scen, zone_map, bus_load)

    # Report table (always written -- lets you plot/see placement)
    rows = []
    for (bid, mw) in sort(collect(placement); by = x -> x[1])
        lat, lon = bus_ll[bid]
        push!(rows, (Bus=bid, Zone=zone_map[bid],
                     Zone_Name=get(DC_ZONE_NAMES, zone_map[bid], "?"),
                     Added_MW=mw, N_Centers=round(Int, mw/DC_MW_PER_CENTER),
                     Lat=lat, Lon=lon))
    end
    df = DataFrame(rows)

    if mode == :report
        # Just write the placement CSV next to the source scenario
        out = joinpath(simdir, "data_center_placement.csv")
        CSV.write(out, df)
        total = isempty(df) ? 0.0 : sum(df.Added_MW)
        println("  [$scen/$year] report: $(nrow(df)) buses, $(round(total)) MW → $out")
        return out
    end

    # mode == :sidecar : create a _dc twin simdir
    dc_scen_dir = joinpath(DC_SCEN_DIR, scen * "_dc", year)
    mkpath(joinpath(dc_scen_dir, "output"))
    mkpath(joinpath(dc_scen_dir, "visual"))

    # Copy the source scenario's key files
    for f in ["config.toml", "scenario_ratios_$(year).json"]
        src = joinpath(simdir, f)
        isfile(src) && cp(src, joinpath(dc_scen_dir, f); force = true)
    end

    # Patch the copied config to flag data centers + point at the load file
    cfg_path = joinpath(dc_scen_dir, "config.toml")
    if isfile(cfg_path)
        cfg = TOML.parsefile(cfg_path)
        cfg["data_centers"] = true
        cfg["data_center_load_file"] = abspath(joinpath(dc_scen_dir, "data_center_load.json"))
        open(cfg_path, "w") do io; TOML.print(io, cfg); end
    end

    # Write the sidecar load file: bus_id => added per-unit load (flat)
    load_pu = Dict(string(bid) => mw / DC_BASE_POWER for (bid, mw) in placement)
    open(joinpath(dc_scen_dir, "data_center_load.json"), "w") do io
        JSON.print(io, Dict(
            "scenario" => scen,
            "year" => year,
            "mw_per_center" => DC_MW_PER_CENTER,
            "total_mw" => isempty(placement) ? 0.0 : sum(values(placement)),
            "note" => "flat 24/7 load added per bus, in per-unit (MW/100)",
            "bus_added_pu" => load_pu,
        ), 2)
    end
    CSV.write(joinpath(dc_scen_dir, "data_center_placement.csv"), df)

    total = isempty(placement) ? 0.0 : sum(values(placement))
    println("  [$scen/$year] → $dc_scen_dir  ($(length(placement)) buses, $(round(total)) MW)")
    return dc_scen_dir
end

# ── Do all scenarios / years ──────────────────────────────────────────────────

function add_data_centers_to_all(; mode::Symbol = :sidecar)
    println("=== Adding data centers to scenarios (mode=$mode) ===")
    isdir(DC_SCEN_DIR) || error("No $DC_SCEN_DIR/ directory. Run generate_scenarios.jl first.")

    made = String[]
    for scen in readdir(DC_SCEN_DIR)
        # skip helper dirs and already-made _dc twins
        (startswith(scen, "zonal_") || startswith(scen, "fast_run") || endswith(scen, "_dc")) && continue
        scen_path = joinpath(DC_SCEN_DIR, scen)
        isdir(scen_path) || continue
        for year in readdir(scen_path)
            simdir = joinpath(scen_path, year)
            isdir(joinpath(simdir)) || continue
            isfile(joinpath(simdir, "config.toml")) || continue
            push!(made, add_data_centers_to(simdir; mode = mode))
        end
    end

    println("\n=== Done: processed $(length(made)) scenario/year dirs ===")
    if mode == :sidecar
        println("\nData-center twins created as <scenario>_dc/<year>/.")
        println("They carry data_center_load.json + a patched config.toml.")
        println("\nTo actually apply the load at solve time, add this hook to the END")
        println("of update_decarbonization (just before `return data`):\n")
        println(DATA_CENTER_HOOK)
    end
    return made
end

# ── The optional 3-line hook (only needed for mode=:sidecar solving) ─────────

const DATA_CENTER_HOOK = raw"""
    # --- data-center nodal load (added by add_data_centers.jl sidecar) ---
    if get(toml_data, "data_centers", false) && haskey(toml_data, "data_center_load_file")
        dcf = toml_data["data_center_load_file"]
        if isfile(dcf)
            dc = JSON.parsefile(dcf)["bus_added_pu"]
            for (bid, add_pu) in dc
                haskey(data["bus"], bid) || continue
                for (rep, prof) in data["bus"][bid]["load"]
                    data["bus"][bid]["load"][rep] = prof .+ Float64(add_pu)
                end
            end
        end
    end
"""
