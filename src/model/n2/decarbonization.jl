using TOML
using JSON
using CSV
using DataFrames
using Dates

function update_decarbonization(simdir, data)
    # Load config file
    config_file = joinpath(simdir, "config.toml")
    toml_data = TOML.parsefile(config_file)

    d_data_file = toml_data["decarbonization"]
    year = Symbol(toml_data["decarbonization_year"])
    year_int = toml_data["decarbonization_year"]

    renewable_types    = Set(toml_data["renewable_types"])
    nonrenewable_types = Set(toml_data["nonrenewable_types"])

    # Read decarbonization file
    decarbonization = CSV.read(d_data_file, DataFrame, delim=',')

    # ── Statewide ratios (same as before) ────────────────────────────────────
    # ratio = target_year_value / 2022_baseline_value
    ratios = Dict()
    for row in eachrow(decarbonization)
        type_key  = row[:Type]
        new_value = row[year]
        old_value = row[2]  # second column is the 2022 baseline
        ratios[type_key] = new_value / old_value
    end

    # ── Zonal multipliers (new) ───────────────────────────────────────────────
    # If a zone_multipliers_<year>.json file exists in the simdir, load it.
    # These multipliers are applied PER BUS on top of the statewide ratio.
    # Final effective multiplier for a bus = statewide_ratio * zonal_multiplier.
    # Written by generate_scenarios.jl alongside each scenario's decarbonization CSV.
    #
    # Source: ERCOT 2025 Long-Term Load Forecast
    #   https://www.ercot.com/gridinfo/load/forecast
    # Source: EIA Annual Energy Outlook
    #   https://www.eia.gov/outlooks/aeo/
    # Source: NREL Annual Technology Baseline 2024
    #   https://atb.nrel.gov/electricity/2024/

    zone_mult_path = joinpath(simdir, "zone_multipliers_$(year_int).json")
    zone_multipliers = Dict{Int, Dict{String, Float64}}()  # zone_id → fuel_type → multiplier

    if isfile(zone_mult_path)
        println("  Loading zonal multipliers from $zone_mult_path")
        zm_data = JSON.parsefile(zone_mult_path)
        for (zone_id_str, zone_info) in zm_data["zones"]
            zone_id = parse(Int, zone_id_str)
            zone_multipliers[zone_id] = Dict{String, Float64}(
                k => Float64(v) for (k, v) in zone_info["multipliers"]
            )
        end
        println("  Loaded zonal multipliers for $(length(zone_multipliers)) zones")
    else
        println("  No zone_multipliers_$(year_int).json found -- using statewide scaling only")
    end

    # ── Apply scaling to generators ───────────────────────────────────────────
    for (gen_id, gen) in data["gen"]
        gen_type = gen["gen_type"]

        if !(gen_type in keys(ratios))
            continue
        end

        statewide_ratio = ratios[gen_type]

        # Get zonal multiplier for this generator's bus zone (default 1.0)
        gen_bus   = gen["gen_bus"]
        bus_id    = string(gen_bus)
        zone_id   = get(data["bus"], bus_id, Dict()) |> b -> get(b, "zone_id", nothing)
        zonal_mult = 1.0
        if zone_id !== nothing && haskey(zone_multipliers, zone_id)
            zonal_mult = get(zone_multipliers[zone_id], gen_type, 1.0)
        end

        effective_ratio = statewide_ratio * zonal_mult

        # Scale pmax and pmin
        gen["pmax"] *= effective_ratio
        gen["pmin"] *= effective_ratio

        # Scale renewable time series profiles
        if gen_type in renewable_types
            for (key, values) in gen["profile"]
                gen["profile"][key] = map(x -> x * effective_ratio, values)
            end
        end
    end

    # ── Apply scaling to load ─────────────────────────────────────────────────
    statewide_load_ratio = ratios["load"]

    for (bus_id, bus) in data["bus"]
        zone_id    = get(bus, "zone_id", nothing)
        zonal_mult = 1.0
        if zone_id !== nothing && haskey(zone_multipliers, zone_id)
            zonal_mult = get(zone_multipliers[zone_id], "load", 1.0)
        end

        effective_load_ratio = statewide_load_ratio * zonal_mult

        for rep_index in keys(bus["load"])
            bus["load"][rep_index] *= effective_load_ratio
        end
    end

    return data
end


function edit_decarbonization()
    df = CSV.read("data/topology/tamu/decarbonization.csv", DataFrame)    

    # Find the row where the first column is "load"
    row_index = findfirst(df[!, 1] .== "load")

    # Modify the row starting from the second element
    if !isnothing(row_index)
        for j in 2:size(df, 2)
            df[row_index, j] = j == 2 ? df[row_index, j] : df[row_index, j - 1] * 1.03
        end
    end

    println(df)
    CSV.write("data/topology/tamu/decarbonization.csv", df)
end