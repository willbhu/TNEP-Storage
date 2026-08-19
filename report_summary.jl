"""
report_summary.jl

Reports the key solved parameters for a scenario -- costs, investments,
storage, and load shed -- pulled from the model's output files.

Per meeting notes 8/12:
  - "Report some parameters such as operational cost etc from summary.csv"
  - "Validate that no load shed appears"
  - "Want estimate how much storage is needed/actually used"

Reads from <simdir>/output/ :
    summary_data.csv        solver-reported costs and stats
    line_investments.csv    Upgrade_Lvl per branch
    storage_investments.csv Storage_Energy per node
    <date>/energy.csv       Charge / Discharge / Energy_Imbalance per node-hour

USAGE (from project root):
    using CSV, DataFrames
    include("report_summary.jl")

    report_summary("scenarios/B_med/2035")          # one scenario
    report_all()                                     # every solved scenario
    report_all(; csv_out="scenario_comparison.csv")  # + write comparison table
"""

using CSV
using DataFrames
using Printf
using Dates

const BASE_MW       = 100.0   # per-unit -> MW
const STORAGE_HOURS = 4.0     # reference duration for power-vs-energy comparison

# ── Helpers ───────────────────────────────────────────────────────────────────

fmt(x::Real) = @sprintf("%,.1f", x)  # placeholder; Julia has no %, so:
function commas(x::Real)
    s = @sprintf("%.0f", abs(x))
    parts = String[]
    while length(s) > 3
        pushfirst!(parts, s[end-2:end]); s = s[1:end-3]
    end
    pushfirst!(parts, s)
    (x < 0 ? "-" : "") * join(parts, ",")
end

"""
    summarize(simdir) -> NamedTuple

Gathers all reported metrics for one solved scenario directory.
Returns `nothing` if the scenario hasn't been solved.
"""
function summarize(simdir::String)
    outdir = joinpath(simdir, "output")
    isdir(outdir) || return nothing

    result = Dict{String,Any}("simdir" => simdir)

    # ── summary_data.csv : whatever the solver reported ──────────────────────
    sfile = joinpath(outdir, "summary_data.csv")
    summary_df = nothing
    if isfile(sfile)
        summary_df = CSV.read(sfile, DataFrame)
        result["summary_columns"] = names(summary_df)
        # Pull every numeric column's value (these files are typically 1 row)
        for col in names(summary_df)
            v = summary_df[1, col]
            v isa Number && (result[col] = v)
        end
    end

    # ── line_investments.csv ─────────────────────────────────────────────────
    lfile = joinpath(outdir, "line_investments.csv")
    if isfile(lfile)
        ldf = CSV.read(lfile, DataFrame)
        if "Upgrade_Lvl" in names(ldf)
            upgraded = ldf[ldf.Upgrade_Lvl .> 0, :]
            result["n_lines_total"]    = nrow(ldf)
            result["n_lines_upgraded"] = nrow(upgraded)
            result["total_upgrade_lvl"] = sum(ldf.Upgrade_Lvl)
            result["max_upgrade_lvl"]  = isempty(upgraded) ? 0.0 : maximum(upgraded.Upgrade_Lvl)
        end
    end

    # ── storage_investments.csv ──────────────────────────────────────────────
    stfile = joinpath(outdir, "storage_investments.csv")
    if isfile(stfile)
        sdf = CSV.read(stfile, DataFrame)
        if "Storage_Energy" in names(sdf)
            sited = sdf[sdf.Storage_Energy .> 0, :]
            result["n_storage_nodes"]  = nrow(sited)
            result["storage_installed_mwh"] = sum(sdf.Storage_Energy) * BASE_MW
        end
    end

    # ── energy.csv across all representative days ────────────────────────────
    rep_days = filter(d -> isdir(joinpath(outdir, d)), readdir(outdir))
    total_shed = 0.0
    total_discharge = 0.0
    total_charge = 0.0
    node_energy_need = Dict{Int,Float64}()
    node_power_need  = Dict{Int,Float64}()

    for day in rep_days
        efile = joinpath(outdir, day, "energy.csv")
        isfile(efile) || continue
        edf = CSV.read(efile, DataFrame)

        "Energy_Imbalance" in names(edf) && (total_shed += sum(edf.Energy_Imbalance) * BASE_MW)
        "Discharge" in names(edf) && (total_discharge += sum(edf.Discharge) * BASE_MW)
        "Charge"    in names(edf) && (total_charge    += sum(edf.Charge)    * BASE_MW)

        # Per-node SOC swing and peak discharge (worst case across days)
        if all(c -> c in names(edf), ["Node_Index", "Hour", "Charge", "Discharge"])
            sort!(edf, [:Node_Index, :Hour])
            for g in groupby(edf, :Node_Index)
                ch  = g.Charge    .* BASE_MW
                dis = g.Discharge .* BASE_MW
                (sum(ch) == 0 && sum(dis) == 0) && continue
                soc = cumsum(ch .- dis)
                swing = maximum(soc) - minimum(soc)
                n = g.Node_Index[1]
                node_energy_need[n] = max(get(node_energy_need, n, 0.0), swing)
                node_power_need[n]  = max(get(node_power_need,  n, 0.0), maximum(dis))
            end
        end
    end

    result["n_rep_days"]      = length(rep_days)
    result["load_shed_mwh"]   = total_shed
    result["discharge_mwh"]   = total_discharge
    result["charge_mwh"]      = total_charge

    # Required storage = sum over nodes of max(SOC swing, peak discharge x 4h)
    required = 0.0
    n_power_lim = 0; n_energy_lim = 0
    for n in keys(node_energy_need)
        e = node_energy_need[n]
        p = get(node_power_need, n, 0.0) * STORAGE_HOURS
        required += max(e, p)
        e >= p ? (n_energy_lim += 1) : (n_power_lim += 1)
    end
    result["storage_required_mwh"] = required
    result["n_storage_active"]     = length(node_energy_need)
    result["n_power_limited"]      = n_power_lim
    result["n_energy_limited"]     = n_energy_lim

    return (; (Symbol(k) => v for (k, v) in result)...), summary_df
end

# ── Pretty single-scenario report ────────────────────────────────────────────

"""
    report_summary(simdir; save=true)

Print the scenario report and (by default) also write it to
<simdir>/visual/report.txt so it persists alongside the figures.
"""
function report_summary(simdir::String; verbose::Bool=true, save::Bool=true)
    res = summarize(simdir)
    if res === nothing
        println("No output/ found in $simdir -- not solved yet.")
        return nothing
    end
    r, summary_df = res

    # Build the report into a buffer, then print it once and save it.
    buf = IOBuffer()
    P(args...) = println(buf, args...)

    P("=" ^ 70)
    P("SCENARIO REPORT — $simdir")
    P("=" ^ 70)
    P("Generated $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM"))")
    P()
    P("Solved results for one scenario of the PTDF-based transmission expansion")
    P("and storage planning model on the 2000-bus synthetic ERCOT system.")
    P("Costs and solver statistics are as reported in output/summary_data.csv.")
    P("Storage requirement is computed per node as max(state-of-charge swing over")
    P("the day, peak discharge x $(Int(STORAGE_HOURS))h) and summed; state of charge is")
    P("reconstructed by integrating charge minus discharge, as the solver does not")
    P("report it directly. Load shed is the sum of Energy_Imbalance across all")
    P("nodes and hours; zero indicates every scenario hour was fully served.")

    # Costs and anything else the solver reported
    if summary_df !== nothing
        P("\n── From summary_data.csv ──")
        for col in names(summary_df)
            v = summary_df[1, col]
            if v isa Number
                P("  $(rpad(col, 34)) $(commas(v))")
            else
                P("  $(rpad(col, 34)) $v")
            end
        end
    else
        P("\n(no summary_data.csv found)")
    end

    # Investments
    P("\n── Investments ──")
    haskey(r, :n_lines_upgraded) && P(
        "  Lines upgraded                     $(commas(r.n_lines_upgraded)) / $(commas(r.n_lines_total))")
    haskey(r, :max_upgrade_lvl) && P(
        "  Max upgrade level                  $(round(r.max_upgrade_lvl, digits=2))")
    haskey(r, :n_storage_nodes) && P(
        "  Storage nodes sited                $(commas(r.n_storage_nodes))")
    haskey(r, :storage_installed_mwh) && P(
        "  Storage installed                  $(commas(r.storage_installed_mwh)) MWh")

    # Storage utilization
    P("\n── Storage utilization ($(r.n_rep_days) rep day(s)) ──")
    P("  Total discharged                   $(commas(r.discharge_mwh)) MWh")
    P("  Total charged                      $(commas(r.charge_mwh)) MWh")
    P("  Required (max SOC swing vs P×$(Int(STORAGE_HOURS))h)  $(commas(r.storage_required_mwh)) MWh")
    P("  Nodes actively cycling             $(commas(r.n_storage_active))")
    P("    energy-limited                   $(commas(r.n_energy_limited))")
    P("    power-limited                    $(commas(r.n_power_limited))")
    if haskey(r, :storage_installed_mwh) && r.storage_installed_mwh > 0
        pct = 100 * r.storage_required_mwh / r.storage_installed_mwh
        P("  Utilization vs installed           $(round(pct, digits=1)) %")
    end

    # Validation
    P("\n── Validation ──")
    shed = r.load_shed_mwh
    if abs(shed) < 1e-6
        P("  Load shed                          0 MWh   ✓ none")
    else
        P("  Load shed                          $(commas(shed)) MWh   ⚠ NONZERO")
    end
    P("=" ^ 70)

    text = String(take!(buf))
    print(stdout, text)

    if save
        visual_dir = joinpath(simdir, "visual")
        mkpath(visual_dir)
        path = joinpath(visual_dir, "report.txt")
        open(path, "w") do io
            write(io, text)
        end
        println("Saved report to $path")
    end

    return r
end

# ── Compare every solved scenario ────────────────────────────────────────────

function report_all(; scen_root::String="scenarios", csv_out::Union{Nothing,String}=nothing)
    isdir(scen_root) || error("No $scen_root/ directory found.")

    rows = []
    for scen in sort(readdir(scen_root))
        (startswith(scen, "zonal_") || startswith(scen, "fast_run")) && continue
        spath = joinpath(scen_root, scen)
        isdir(spath) || continue
        for year in sort(readdir(spath))
            simdir = joinpath(spath, year)
            isdir(joinpath(simdir, "output")) || continue
            res = summarize(simdir)
            res === nothing && continue
            r, _ = res
            push!(rows, merge(
                Dict("Scenario" => scen, "Year" => year),
                Dict(String(k) => v for (k, v) in pairs(r) if v isa Number)
            ))
        end
    end

    if isempty(rows)
        println("No solved scenarios found under $scen_root/.")
        return nothing
    end

    df = DataFrame(rows)
    # Put identifying and headline columns first where present
    front = ["Scenario", "Year", "load_shed_mwh", "storage_required_mwh",
             "storage_installed_mwh", "n_lines_upgraded", "n_storage_nodes"]
    ordered = vcat([c for c in front if c in names(df)],
                   [c for c in names(df) if !(c in front)])
    df = df[:, ordered]

    println("\n" * "=" ^ 70)
    println("ALL SOLVED SCENARIOS")
    println("=" ^ 70)
    show(stdout, df; allrows=true, allcols=true)
    println()

    # Flag any scenario with load shed
    if "load_shed_mwh" in names(df)
        bad = df[abs.(df.load_shed_mwh) .> 1e-6, :]
        if isempty(bad)
            println("\n✓ No load shed in any solved scenario.")
        else
            println("\n⚠ Load shed present in:")
            for r in eachrow(bad)
                println("    $(r.Scenario)/$(r.Year): $(commas(r.load_shed_mwh)) MWh")
            end
        end
    end

    if csv_out !== nothing
        CSV.write(csv_out, df)
        println("\nWrote comparison table to $csv_out")
    end

    return df
end