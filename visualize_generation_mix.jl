"""
visualize_generation_mix.jl

Three visualizations of the generation mix, using your existing data pipeline
and (where available) your solved model results.

1) Pie chart (capacity_mix_pie.png): total max capacity (pmax) by fuel type,
   statewide. Pre-solve, reflects decarbonization-scaled installed capacity.

2) Pre-solve capacity vs. load (daily_profile_stacked.png): renewables (real
   hourly profiles) + nonrenewable capacity ceiling (flat pmax, NOT real
   dispatch) stacked together as "total available capacity," with Total Load
   drawn as a SEPARATE line on the same baseline (not stacked on top -- doing
   so would visually misrepresent load shed that doesn't actually exist).

3) Actual dispatch (actual_dispatch_stacked.png): REAL solved dispatch by
   fuel type, statewide, for one representative day. Reads directly from
   simdir/output/<date>/energy.csv, which is written by export_energy_csv
   (export_model.jl) using value.(model[:pg]) AFTER the model has been
   solved. This plot is only generated if that file already exists --
   you must run the model (e.g. run_model(simdir)) first.

Usage:
    julia visualize_generation_mix.jl path/to/simdir [rep_index]

    simdir     - same simulation directory used by your ExpansionPlanner
                 (must contain config.toml)
    rep_index  - which representative day to plot (default: 1)

Output:
    Saves PNG files to the simdir's "visual" folder.
"""

using Plots
using JSON

SCENARIO_LABEL = ""  # set in main() from the simdir path
using CSV
using DataFrames

# Reuse your existing data pipeline functions: add_params_profiles, update_decarbonization,
# convert_units. Adjust these include paths to match where these are defined relative to
# this script (e.g. they may already live in ExpansionPlanner.jl or its helpers).
@isdefined(add_params_profiles)     || include("add_params_profiles.jl")
@isdefined(update_decarbonization)  || include("update_decarbonization.jl")

function compute_capacity_by_type(data)
    capacity = Dict{String, Float64}()
    for (gen_id, gen) in data["gen"]
        gtype = gen["gen_type"]
        pmax = get(gen, "pmax", 0.0)
        capacity[gtype] = get(capacity, gtype, 0.0) + pmax
    end
    return capacity
end

function plot_capacity_pie(data, output_path)
    capacity = compute_capacity_by_type(data)

    # Filter out zero/negligible entries for a cleaner chart
    labels = String[]
    values_ = Float64[]
    for (gtype, cap) in sort(collect(capacity), by=x->-x[2])
        if cap > 0
            push!(labels, gtype)
            push!(values_, cap)
        end
    end

    p = pie(labels, values_,
            title="[MODEL INPUT] Installed Capacity by Fuel Type — $SCENARIO_LABEL\n(pmax MW, scaled capacity fed into the model)",
            legend=:outertopright)
    savefig(p, output_path)
    println("Saved pie chart to $output_path")
    return p
end

function compute_daily_profiles(data, rep_index)
    num_h = data["param"]["num_hours"]
    rep_key = string(rep_index)

    # Aggregate load across all buses for this representative day
    total_load = zeros(Float64, num_h)
    for (bus_id, bus) in data["bus"]
        if haskey(bus["load"], rep_key)
            total_load .+= bus["load"][rep_key]
        end
    end

    renewable_types = data["param"]["renewable_types"]
    nonrenewable_types = data["param"]["nonrenewable_types"]

    # Renewables: real hourly profiles, summed by type
    renewable_profiles = Dict{String, Vector{Float64}}()
    for rtype in renewable_types
        renewable_profiles[rtype] = zeros(Float64, num_h)
    end
    for (gen_id, gen) in data["gen"]
        gtype = gen["gen_type"]
        if gtype in renewable_types && haskey(gen, "profile") && haskey(gen["profile"], rep_key)
            renewable_profiles[gtype] .+= gen["profile"][rep_key]
        end
    end

    # Nonrenewables: NO hourly profile exists pre-solve (dispatch is a decision
    # variable, not a fixed time series). As a pre-solve proxy, we sum pmax
    # across all generators of each nonrenewable type and represent it as a
    # flat capacity ceiling repeated across all hours. This is NOT actual
    # dispatch -- it shows "what's available," not "what's used."
    nonrenewable_capacity = Dict{String, Float64}()
    for rtype in nonrenewable_types
        nonrenewable_capacity[rtype] = 0.0
    end
    for (gen_id, gen) in data["gen"]
        gtype = gen["gen_type"]
        if gtype in nonrenewable_types
            nonrenewable_capacity[gtype] += get(gen, "pmax", 0.0)
        end
    end
    nonrenewable_profiles = Dict{String, Vector{Float64}}(
        rtype => fill(cap, num_h) for (rtype, cap) in nonrenewable_capacity
    )

    return total_load, renewable_profiles, nonrenewable_profiles
end

function plot_daily_stacked(data, rep_index, output_path)
    total_load, renewable_profiles, nonrenewable_profiles = compute_daily_profiles(data, rep_index)
    num_h = length(total_load)
    hours = 1:num_h

    # Active renewable types (nonzero generation that day)
    active_renewables = sort([rt for (rt, vals) in renewable_profiles if sum(vals) > 0])
    # Active nonrenewable types (nonzero installed capacity)
    active_nonrenewables = sort([rt for (rt, vals) in nonrenewable_profiles if sum(vals) > 0])

    if isempty(active_renewables) && isempty(active_nonrenewables)
        println("Warning: no nonzero generation found for rep_index=$rep_index")
    end

    # IMPORTANT: generation types are stacked among THEMSELVES (renewables +
    # nonrenewable capacity ceiling), forming a single "total available
    # capacity" area. Load is then drawn as a SEPARATE line on the same
    # baseline -- NOT stacked on top of generation. Stacking load on top of
    # generation visually implies a capacity shortfall (load shed) even when
    # none exists, since stacked-area charts offset each layer by the
    # cumulative height of everything below it. This version instead lets you
    # directly compare "how high is the load line" vs "how high is the total
    # generation area" -- the real pre-solve feasibility check.
    gen_labels = vcat(active_renewables,
                       ["$(rt) (capacity ceiling)" for rt in active_nonrenewables])
    gen_series = vcat(
        [renewable_profiles[rt] for rt in active_renewables],
        [nonrenewable_profiles[rt] for rt in active_nonrenewables]
    )
    gen_matrix = hcat(gen_series...)

    p = areaplot(hours, gen_matrix,
                 label=reshape(gen_labels, 1, length(gen_labels)),
                 title="[MODEL INPUT] Available Capacity vs. Load — $SCENARIO_LABEL, Rep. Day $rep_index\n(Pre-solve: renewable profiles + nonrenewable pmax ceiling vs scaled load)",
                 xlabel="Hour", ylabel="Power (MW)",
                 legend=:outertopright)

    plot!(p, hours, total_load,
          label="Total Load", linewidth=3, linecolor=:black, linestyle=:dash)

    savefig(p, output_path)
    println("Saved stacked profile plot to $output_path")
    return p
end

function plot_actual_dispatch(simdir, data, rep_index, output_path)
    # energy.csv is written by export_energy_csv (export_model.jl) AFTER solving.
    # It contains one row per (bus, hour), with one column per fuel type holding
    # REAL solved dispatch (value.(model[:pg])), not pmax or a static profile.
    datestring = data["param"]["dates"][rep_index]
    energy_csv_path = joinpath(simdir, "output", datestring, "energy.csv")

    if !isfile(energy_csv_path)
        error("No solved results found at $energy_csv_path. " *
              "Run the model and call export_results!(planner) first -- " *
              "this plot requires actual dispatch values, which only exist after solving.")
    end

    df = CSV.read(energy_csv_path, DataFrame)

    gen_types = vcat(data["param"]["renewable_types"], data["param"]["nonrenewable_types"])
    # Keep only fuel-type columns that actually exist in the CSV.
    # names(df) returns Strings in DataFrames.jl, so compare as strings explicitly
    # regardless of whether gen_types entries are String or Symbol.
    df_col_names = Set(string.(names(df)))
    gen_types = [gt for gt in gen_types if string(gt) in df_col_names]

    # Sum dispatch across all buses, grouped by Hour, for each fuel type
    grouped = combine(groupby(df, :Hour), [Symbol(gt) => sum => Symbol(gt) for gt in gen_types]...)
    sort!(grouped, :Hour)

    hours = grouped.Hour
    active_types = [gt for gt in gen_types if sum(grouped[!, Symbol(gt)]) > 0]

    if isempty(active_types)
        println("Warning: no nonzero dispatch found in $energy_csv_path")
    end

    BASE_POWER = 100.0
    dispatch_matrix = hcat([grouped[!, Symbol(gt)] .* BASE_POWER for gt in active_types]...)

    # Real load, same as before, pulled from the data pipeline (not from energy.csv)
    num_h = data["param"]["num_hours"]
    rep_key = string(rep_index)
    total_load = zeros(Float64, num_h)
    for (bus_id, bus) in data["bus"]
        if haskey(bus["load"], rep_key)
            total_load .+= bus["load"][rep_key]
        end
    end

    p = areaplot(hours, dispatch_matrix,
                 label=reshape(string.(active_types), 1, length(active_types)),
                 title="[SOLVED OUTPUT] Actual Dispatch — $SCENARIO_LABEL, Rep. Day $rep_index\n(Real pg from the solved model, energy.csv)",
                 xlabel="Hour", ylabel="Power (MW)",
                 legend=:outertopright)

    plot!(p, hours, total_load,
          label="Total Load", linewidth=3, linecolor=:black, linestyle=:dash)

    savefig(p, output_path)
    println("Saved actual dispatch plot to $output_path")
    return p
end

function main()
    if length(ARGS) < 1
        println("Usage: julia visualize_generation_mix.jl path/to/simdir [rep_index]")
        return
    end

    simdir = ARGS[1]
    rep_index = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 1

    # Scenario label from the simdir path, e.g. "B_med / 2030"
    _parts = splitpath(rstrip(simdir, ['/','\\']))
    scenario_label = length(_parts) >= 2 ? join(_parts[end-1:end], " / ") : basename(simdir)
    global SCENARIO_LABEL = scenario_label

    visual_dir = joinpath(simdir, "visual")
    mkpath(visual_dir)

    println("Running data pipeline (add_params_profiles, update_decarbonization, convert_units) ...")
    data = add_params_profiles(simdir)
    data = update_decarbonization(simdir, data)
    # NOTE: convert_units converts to per-unit (divides by base_power=100), which
    # makes the plots show values in p.u. rather than MW. For readability, the
    # capacity/load visuals here are generated BEFORE convert_units, i.e. in MW.
    # If you want to confirm the unit-converted values are sane too, call
    # convert_units(data) separately and re-run the plot functions on that result.

    println("Plotting capacity mix pie chart ...")
    plot_capacity_pie(data, joinpath(visual_dir, "capacity_mix_pie.png"))

    println("Plotting pre-solve capacity vs. load (renewable profiles + nonrenewable ceiling) for rep_index=$rep_index ...")
    plot_daily_stacked(data, rep_index, joinpath(visual_dir, "daily_profile_stacked.png"))

    println("Checking for solved dispatch results ...")
    datestring = data["param"]["dates"][rep_index]
    energy_csv_path = joinpath(simdir, "output", datestring, "energy.csv")
    if isfile(energy_csv_path)
        println("Found solved results -- plotting actual dispatch for rep_index=$rep_index ...")
        plot_actual_dispatch(simdir, data, rep_index, joinpath(visual_dir, "actual_dispatch_stacked.png"))
    else
        println("No solved results found at $energy_csv_path -- skipping actual dispatch plot.")
        println("Run the model (run_model(simdir) or planner workflow) first to generate this.")
    end

    println("Done.")
end

main()