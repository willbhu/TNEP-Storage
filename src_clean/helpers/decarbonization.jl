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

        # `target` is the FINAL ratio relative to the 2022 baseline.
        #
        # IMPORTANT: the generator data arriving here is already AT the 2022
        # baseline scale -- add_params_profiles loads raw capacities and does
        # not apply any decarbonization ratio. Applying the ratio is exactly
        # what this function is for. So the scale factor is simply `target`.
        #
        # (An earlier version divided by the CSV's own EIA ratio on the
        # assumption the data already carried it. It does not, so that
        # cancelled the scaling almost entirely -- solar came out at ~1x
        # instead of 8x, gas covered the whole load curve, and storage had
        # no surplus to arbitrage.)
        scale = final_ratio(gen_type, zone_id)

        gen["pmax"] *= scale
        gen["pmin"] *= scale
        if gen_type in renewable_types
            for (k, vals) in gen["profile"]
                gen["profile"][k] = map(x -> x * scale, vals)
            end
        end
    end

    # ── Scale load ────────────────────────────────────────────────────────────
    # Bus load arrives at the 2022 baseline scale, so the zone's target ratio
    # is applied directly (see the note on generator scaling above).
    for (bus_id, bus) in data["bus"]
        zone_id = get(bus, "zone_id", nothing)
        scale   = final_ratio("load", zone_id)
        for rep in keys(bus["load"])
            bus["load"][rep] *= scale
        end
    end

    # ── Data-center nodal load ────────────────────────────────────────────────
    # Written by add_data_centers.jl into the <scenario>_dc twin folders.
    # Data centers are modeled as NODAL growth: fixed-MW blocks of flat 24/7
    # load at specific buses, added ON TOP of the scaled zonal load. This is
    # inert for base scenarios (data_centers is absent/false in their config),
    # so only the _dc twins are affected.
    if get(toml_data, "data_centers", false) && haskey(toml_data, "data_center_load_file")
        dcf = toml_data["data_center_load_file"]
        if isfile(dcf)
            # UNITS: the sidecar stores MW, and this function runs BEFORE
            # convert_units, so bus["load"] is still on the MW scale here.
            # Adding per-unit values instead would be 100x too small.
            dc_json  = JSON.parsefile(dcf)
            dc_added = haskey(dc_json, "bus_added_mw") ? dc_json["bus_added_mw"] :
                       Dict(k => Float64(v) * 100 for (k,v) in dc_json["bus_added_pu"])
            n_buses  = 0
            total_mw = 0.0
            for (bid, add_mw) in dc_added
                haskey(data["bus"], bid) || continue
                add = Float64(add_mw)
                for (rep, prof) in data["bus"][bid]["load"]
                    data["bus"][bid]["load"][rep] = prof .+ add
                end
                n_buses  += 1
                total_mw += add
            end
            println("  Data centers: added $(round(total_mw, digits=0)) MW " *
                    "across $n_buses buses (flat 24/7)")
        else
            @warn "data_centers enabled but load file not found: $dcf"
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