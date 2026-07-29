using TOML
using JSON
using CSV
using DataFrames
using Dates

"""
    update_decarbonization(simdir, data)

Applies DIRECT FINAL RATIOS to generation and load, per zone.

    final_value = ratio x baseline_2022_value

The ratio is read from scenario_ratios_<year>.json in the simdir (written by
generate_scenarios.jl). The decarbonization CSV is used only to read the 2022
baseline value per fuel type. There is NO multiplication by an EIA ratio --
the JSON ratio IS the final scaling relative to 2022.

For each generator:
    - look up its bus's zone_id
    - look up ratio[zone][gen_type] from the JSON (falls back to defaults)
    - scale pmax, pmin, and (for renewables) the hourly profile by:
          ratio / (current_value / baseline_2022_value)
      i.e. rescale so the result equals ratio x 2022_baseline.

If no scenario_ratios JSON is found, falls back to the classic behaviour
(statewide CSV ratio, no zonal scaling) for backward compatibility.
"""
function update_decarbonization(simdir, data)
    config_file = joinpath(simdir, "config.toml")
    toml_data   = TOML.parsefile(config_file)

    d_data_file = toml_data["decarbonization"]
    year        = toml_data["decarbonization_year"]
    year_sym    = Symbol(year)

    renewable_types    = Set(toml_data["renewable_types"])
    nonrenewable_types = Set(toml_data["nonrenewable_types"])

    decarb = CSV.read(d_data_file, DataFrame, delim=',')

    # 2022 baseline value and the CSV's own year value, per fuel type
    baseline_2022 = Dict{String,Float64}()
    csv_year_val  = Dict{String,Float64}()
    for row in eachrow(decarb)
        fuel = row[:Type]
        baseline_2022[fuel] = row[2]              # 2022 column
        csv_year_val[fuel]  = row[year_sym]       # target-year column
    end

    # ── Load direct ratios from scenario_ratios_<year>.json ──────────────────
    ratios_path = joinpath(simdir, "scenario_ratios_$(year).json")
    zone_ratios = Dict{Int, Dict{String,Float64}}()   # zone_id → fuel → final ratio
    default_ratios = Dict{String,Float64}()
    use_direct = false

    if isfile(ratios_path)
        use_direct = true
        rj = JSON.parsefile(ratios_path)
        for (f, v) in rj["defaults"]
            default_ratios[f] = Float64(v)
        end
        for (zid_str, zinfo) in rj["zones"]
            zid = parse(Int, zid_str)
            zone_ratios[zid] = Dict{String,Float64}(k => Float64(v) for (k,v) in zinfo["ratios"])
        end
        println("  Applying DIRECT ratios from scenario_ratios_$(year).json")
    else
        println("  No scenario_ratios_$(year).json -- falling back to statewide CSV ratio")
    end

    # helper: final ratio (vs 2022) for a fuel in a zone
    function final_ratio(fuel, zone_id)
        if use_direct
            if zone_id !== nothing && haskey(zone_ratios, zone_id) && haskey(zone_ratios[zone_id], fuel)
                return zone_ratios[zone_id][fuel]
            elseif haskey(default_ratios, fuel)
                return default_ratios[fuel]
            end
        end
        # fallback: classic CSV ratio
        if haskey(csv_year_val, fuel) && haskey(baseline_2022, fuel) && baseline_2022[fuel] != 0
            return csv_year_val[fuel] / baseline_2022[fuel]
        end
        return 1.0
    end

    # ── Scale generators ──────────────────────────────────────────────────────
    for (gen_id, gen) in data["gen"]
        gen_type = gen["gen_type"]
        (haskey(baseline_2022, gen_type) || use_direct) || continue

        gen_bus = gen["gen_bus"]
        bus     = get(data["bus"], string(gen_bus), nothing)
        zone_id = bus === nothing ? nothing : get(bus, "zone_id", nothing)

        target = final_ratio(gen_type, zone_id)   # desired final vs 2022

        # The CSV year value already encodes the EIA ratio. To make the FINAL
        # equal target x 2022_baseline, we scale current pmax by:
        #   target / (csv_year_val/baseline_2022)   if the CSV had this fuel
        # If the fuel isn't in the CSV, we can't know its 2022 baseline, so we
        # apply `target` directly as a multiplier on current pmax.
        if haskey(csv_year_val, gen_type) && haskey(baseline_2022, gen_type) && baseline_2022[gen_type] != 0
            csv_ratio = csv_year_val[gen_type] / baseline_2022[gen_type]
            scale = csv_ratio == 0 ? target : target / csv_ratio
        else
            scale = target
        end

        gen["pmax"] *= scale
        gen["pmin"] *= scale
        if gen_type in renewable_types
            for (k, vals) in gen["profile"]
                gen["profile"][k] = map(x -> x * scale, vals)
            end
        end
    end

    # ── Scale load ────────────────────────────────────────────────────────────
    csv_load_ratio = (haskey(csv_year_val,"load") && baseline_2022["load"] != 0) ?
                     csv_year_val["load"] / baseline_2022["load"] : 1.0

    for (bus_id, bus) in data["bus"]
        zone_id = get(bus, "zone_id", nothing)
        target  = final_ratio("load", zone_id)
        scale   = csv_load_ratio == 0 ? target : target / csv_load_ratio
        for rep in keys(bus["load"])
            bus["load"][rep] *= scale
        end
    end

    return data
end


function edit_decarbonization()
    df = CSV.read("data/topology/tamu/decarbonization.csv", DataFrame)
    row_index = findfirst(df[!, 1] .== "load")
    if !isnothing(row_index)
        for j in 2:size(df, 2)
            df[row_index, j] = j == 2 ? df[row_index, j] : df[row_index, j - 1] * 1.03
        end
    end
    println(df)
    CSV.write("data/topology/tamu/decarbonization.csv", df)
end