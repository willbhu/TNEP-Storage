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
using Colors

SCENARIO_LABEL = ""  # set in main() from the simdir path

# ═══════════════════════════════════════════════════════════════════════════════
# FIXED FUEL COLORS
# ═══════════════════════════════════════════════════════════════════════════════
# Per meeting notes 8/12: pie chart and stacked plots must use the SAME color
# for the same resource. Plots.jl otherwise assigns colors by series ORDER, so
# a fuel that appears in a different position between charts gets a different
# color (this is why solar and coal looked swapped between the pie and stack).
# Mapping each fuel name to an explicit hex code fixes the color to the
# resource, not to its position.

const FUEL_COLORS = Dict(
    "nuclear"           => colorant"#7B68EE",   # purple
    "coal"              => colorant"#5A4632",   # dark brown
    "ng"                => colorant"#E4572E",   # orange-red
    "hydro"             => colorant"#2E86AB",   # blue
    "solar"             => colorant"#F4C430",   # yellow/gold
    "wind"              => colorant"#3BB273",   # green
    "wind_offshore"     => colorant"#1B998B",   # teal
    "storage_discharge" => colorant"#9B5DE5",   # violet
    "storage_charge"    => colorant"#C77DFF",   # light violet
)

const FALLBACK_COLOR = colorant"#999999"

# ═══════════════════════════════════════════════════════════════════════════════
# FIGURE CAPTIONS
# ═══════════════════════════════════════════════════════════════════════════════
# Each figure carries a short title above and an explanatory caption below, so
# it can be read on its own without surrounding text (research-paper style).

"""
    wrap_text(s, width) -> String

Hard-wrap a caption at `width` characters on word boundaries.
"""
function wrap_text(s::AbstractString, width::Int=110)
    words = split(s)
    lines = String[]
    cur = ""
    for w in words
        if isempty(cur)
            cur = w
        elseif length(cur) + 1 + length(w) <= width
            cur *= " " * w
        else
            push!(lines, cur); cur = w
        end
    end
    !isempty(cur) && push!(lines, cur)
    return join(lines, "\n")
end

"""
    with_caption(p, caption; height=0.14) -> Plot

Stack a plot above a text-only panel holding the figure caption.
"""
function with_caption(p, caption::AbstractString; height::Float64=0.14)
    try
        txt = wrap_text(caption)
        cappanel = plot(framestyle=:none, showaxis=false, grid=false,
                        ticks=nothing, legend=false)
        xlims!(cappanel, 0, 1); ylims!(cappanel, 0, 1)
        annotate!(cappanel, 0.02, 0.5, text(txt, 8, :left, :vcenter))
        return plot(p, cappanel,
                    layout = grid(2, 1, heights=[1 - height, height]),
                    size = (1000, 700))
    catch e
        @warn "Caption panel failed; saving figure without caption." exception=e
        return p
    end
end


"""
    fuel_color(name) -> Color

Look up the fixed color for a fuel type. Falls back to grey for anything
not in the map (so a new fuel never silently steals another's color).
Handles the "<fuel> (capacity ceiling)" labels used in the pre-solve plot.
"""
function fuel_color(name)
    s = string(name)
    # strip the "(capacity ceiling)" suffix used by the pre-solve stack
    s = replace(s, r"\s*\(capacity ceiling\)$" => "")
    return get(FUEL_COLORS, s, FALLBACK_COLOR)
end

"""
    colors_for(names) -> row vector of Colors

Build the `seriescolor` argument for a set of series, in order.
"""
colors_for(names) = reshape([fuel_color(n) for n in names], 1, length(names))


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

    # A pie is ONE series with N slices, so seriescolor (which is per-series)
    # collapses every slice to a single colour. Passing an ordered palette
    # assigns colours slice by slice instead.
    slice_colors = [fuel_color(l) for l in labels]
    pie_palette = try
        palette(slice_colors)
    catch
        @warn "Could not build pie palette from FUEL_COLORS; using default colours."
        :auto
    end
    p = pie(labels, values_,
            palette=pie_palette,
            size=(900, 600),
            title="Installed Capacity by Fuel Type — $SCENARIO_LABEL", titlefontsize=10,
            legend=:outertopright)

    total_gw = sum(values_) / 1000
    cap = "Installed generation capacity by fuel type for scenario $SCENARIO_LABEL, after " *
          "scenario scaling is applied to the 2022 baseline. Values are nameplate maximum " *
          "output (pmax), not energy produced; a large capacity share does not imply a large " *
          "generation share, since wind and solar operate well below nameplate most hours. " *
          "Total installed capacity is $(round(total_gw, digits=1)) GW."
    p = with_caption(p, cap)

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

    # STACKING ORDER (per meeting notes 7/29): static baseload at the BOTTOM.
    # Coal and nuclear run flat around the clock, so putting them at the base
    # of the stack gives a stable foundation and makes the variable renewable
    # layers above them readable. Order: nuclear -> coal -> other thermal ->
    # renewables on top.
    # Explicit stack order (per meeting notes 8/12): baseload at the bottom,
    # then dispatchable thermal, then variable renewables (solar before wind).
    # areaplot stacks the FIRST series at the bottom, so this list runs
    # bottom -> top: static baseload first, then dispatchable thermal, then
    # variable renewables with wind below and solar on top.
    STACK_ORDER = ["nuclear", "coal", "ng", "hydro", "wind", "wind_offshore", "solar"]
    order_rank(t) = something(findfirst(==(string(t)), STACK_ORDER), length(STACK_ORDER) + 1)
    active_nonrenewables = sort(active_nonrenewables, by = order_rank)
    active_renewables    = sort(active_renewables,    by = order_rank)

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
    # Baseload (nuclear, coal, then other thermal) at the BOTTOM of the stack,
    # variable renewables layered on top.
    gen_labels = vcat(["$(rt) (capacity ceiling)" for rt in active_nonrenewables],
                       active_renewables)
    gen_series = vcat(
        [nonrenewable_profiles[rt] for rt in active_nonrenewables],
        [renewable_profiles[rt] for rt in active_renewables]
    )
    gen_matrix = hcat(gen_series...)

    p = areaplot(hours, gen_matrix,
                 label=reshape(gen_labels, 1, length(gen_labels)),
                 seriescolor=colors_for(gen_labels),
                 title="Available Capacity vs. Load — $SCENARIO_LABEL, Day $rep_index", titlefontsize=10,
                 xlabel="Hour of representative day", ylabel="Power (MW)",
                 size=(1000, 600), left_margin=6Plots.mm, bottom_margin=5Plots.mm,
                 legend=:outertopright)

    plot!(p, hours, total_load,
          label="Total Load", linewidth=3, linecolor=:black, linestyle=:dash)

    cap = "Model input for scenario $SCENARIO_LABEL: available generation capacity against " *
          "system load over one representative day. Wind, solar and hydro layers show the " *
          "hourly resource profile actually available; thermal layers (nuclear, coal, gas) " *
          "show the nameplate ceiling rather than dispatch, since commitment is decided by " *
          "the optimizer. Baseload sits at the bottom of the stack, variable renewables above. " *
          "The dashed line is total system load. This figure precedes the solve and shows what " *
          "the optimizer has to work with, not what it chose."
    p = with_caption(p, cap, height=0.18)

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

    # STACKING ORDER (per meeting notes 7/29): static baseload at the BOTTOM.
    # Nuclear and coal run flat around the clock, so they form a stable base
    # for the stack; variable renewables layer on top where their shape is
    # readable against a steady foundation.
    # Explicit stack order (per meeting notes 8/12): baseload at the bottom,
    # then dispatchable thermal, then variable renewables with solar before
    # wind. Alphabetical sorting previously put wind before solar.
    # areaplot stacks the FIRST series at the bottom, so this list runs
    # bottom -> top: static baseload first, then dispatchable thermal, then
    # variable renewables with wind below and solar on top.
    STACK_ORDER = ["nuclear", "coal", "ng", "hydro", "wind", "wind_offshore", "solar"]
    order_rank(t) = something(findfirst(==(string(t)), STACK_ORDER), length(STACK_ORDER) + 1)
    active_types = sort(active_types, by = order_rank)

    BASE_POWER = 100.0

    # ── Storage (per meeting notes 8/12) ─────────────────────────────────────
    # The power balance the model enforces is:
    #     generation + storage_discharge - storage_charge = load + load_shed
    # Plotting only generation makes storage arbitrage LOOK like load shed:
    # surplus in off-peak hours (charging) reads as overbuild, and the evening
    # peak (discharging) reads as an unserved gap. Adding discharge as a layer
    # on top of generation, and charge as a NEGATIVE layer below the axis,
    # makes the stack close on the load line so any remaining gap is REAL
    # load shed.
    #
    # Column names vary by codebase version, so we search a few candidates.
    discharge_cols = ["discharge", "dis", "storage_discharge", "Discharge"]
    charge_cols    = ["charge", "ch", "storage_charge", "Charge"]

    find_col(cands) = findfirst(x -> x in df_col_names, cands)

    dis_idx = find_col(discharge_cols)
    ch_idx  = find_col(charge_cols)

    discharge_series = nothing
    charge_series    = nothing

    if dis_idx !== nothing
        colname = discharge_cols[dis_idx]
        g = combine(groupby(df, :Hour), Symbol(colname) => sum => :d)
        sort!(g, :Hour)
        if sum(g.d) > 0
            discharge_series = g.d .* BASE_POWER
        end
    end
    if ch_idx !== nothing
        colname = charge_cols[ch_idx]
        g = combine(groupby(df, :Hour), Symbol(colname) => sum => :c)
        sort!(g, :Hour)
        if sum(g.c) > 0
            charge_series = g.c .* BASE_POWER
        end
    end

    if dis_idx === nothing && ch_idx === nothing
        @warn "No storage columns found in energy.csv (looked for $(discharge_cols) / $(charge_cols)). " *
              "Any gap between the generation stack and the load line may be storage, not load shed."
    end

    # Build the stack: generation types, then storage discharge on top
    stack_series = [grouped[!, Symbol(gt)] .* BASE_POWER for gt in active_types]
    stack_labels = [string(gt) for gt in active_types]

    if discharge_series !== nothing
        push!(stack_series, discharge_series)
        push!(stack_labels, "storage_discharge")
    end

    dispatch_matrix = hcat(stack_series...)

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
                 label=reshape(string.(stack_labels), 1, length(stack_labels)),
                 seriescolor=colors_for(stack_labels),
                 title="Actual Dispatch — $SCENARIO_LABEL, Day $rep_index", titlefontsize=10,
                 xlabel="Hour of representative day", ylabel="Power (MW)",
                 size=(1000, 600), left_margin=6Plots.mm, bottom_margin=5Plots.mm,
                 legend=:outertopright)

    plot!(p, hours, total_load,
          label="Total Load", linewidth=3, linecolor=:black, linestyle=:dash)

    # Storage charging drawn BELOW the axis -- it's load the grid is serving,
    # so showing it as negative keeps the visual power balance honest.
    if charge_series !== nothing
        plot!(p, hours, -charge_series,
              seriestype=:line, fillrange=0, fillalpha=0.55,
              fillcolor=fuel_color("storage_charge"),
              linecolor=fuel_color("storage_charge"), linewidth=1,
              label="storage_charge (negative)")
    end

    peak_load = maximum(total_load)
    shed_note = "Generation plus storage discharge should meet the load line exactly; any " *
                "visible gap is unserved load."
    cap = "Solved dispatch for scenario $SCENARIO_LABEL over one representative day. Each layer " *
          "is actual generation from the optimizer (pg), with storage discharge stacked on top " *
          "and storage charging drawn below the axis as it is load the grid must serve. " *
          "Baseload runs flat at the bottom; variable renewables layer above. Peak load is " *
          "$(round(peak_load/1000, digits=1)) GW. " * shed_note
    p = with_caption(p, cap, height=0.18)

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