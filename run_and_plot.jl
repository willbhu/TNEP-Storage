"""
run_and_plot.jl

Runs the TEP+Storage model on a scenario, then automatically generates all
visual plots:
    1. Stacked pre-solve capacity-vs-load plot   (Julia: visualize_generation_mix.jl)
    2. Actual dispatch stacked plot              (Julia: visualize_generation_mix.jl)
    3. Integrated load geo plot                  (Python: plot_integrated_load.py)
    4. Investment geo plot                       (Python: plot_investments.py)

The stacked + dispatch plots come from visualize_generation_mix.jl (which
already produces both). The two geo plots are Python and are shelled out to.

USAGE (from project root, in Julia REPL):
    include("src_clean/main.jl")          # load model functions first
    include("run_and_plot.jl")
    run_and_plot("scenarios/B_med/2030")

    # or skip the solve if outputs already exist:
    run_and_plot("scenarios/B_med/2030"; solve=false)

CONFIG:
    Set PYTHON_EXE below to your Python interpreter path.
"""

# ── Python interpreter path (edit to match your machine) ─────────────────────
const PYTHON_EXE = raw"C:\Users\willi\AppData\Local\Python\pythoncore-3.14-64\python.exe"

# Paths to the Python plotting scripts (relative to project root)
const PY_INTEGRATED_LOAD = "viz/tamu/topology/plot_integrated_load.py"
const PY_INVESTMENTS      = "viz/tamu/topology/plot_investments.py"

# Rep-day index to plot (1 = first date in the scenario's `dates` list)
const PLOT_REP_INDEX = 1

"""
    run_and_plot(simdir; solve=true, rep_index=PLOT_REP_INDEX)

Solve the model (unless solve=false) and generate all four plots for `simdir`.
"""
function run_and_plot(simdir::String; solve::Bool=true, rep_index::Int=PLOT_REP_INDEX)

    # ── 1. Solve the model ────────────────────────────────────────────────────
    if solve
        println("\n" * "="^70)
        println("SOLVING MODEL: $simdir")
        println("="^70)
        flush(stdout)
        model, data = run_model(simdir)
    else
        println("\nSkipping solve (solve=false) -- using existing outputs in $simdir")
    end

    # ── 2. Stacked + dispatch plots (Julia) ───────────────────────────────────
    # visualize_generation_mix.jl produces capacity_mix_pie, daily_profile_stacked,
    # and actual_dispatch_stacked (if energy.csv exists).
    println("\n" * "="^70)
    println("GENERATING STACKED + DISPATCH PLOTS (Julia)")
    println("="^70)
    flush(stdout)
    try
        empty!(ARGS)
        push!(ARGS, simdir, string(rep_index))
        include("visualize_generation_mix.jl")
    catch e
        @warn "Stacked/dispatch plots failed" exception=e
    end

    # ── 3. Integrated load geo plot (Python) ──────────────────────────────────
    println("\n" * "="^70)
    println("GENERATING INTEGRATED LOAD GEO PLOT (Python)")
    println("="^70)
    flush(stdout)
    run_python(PY_INTEGRATED_LOAD, simdir, string(rep_index))

    # ── 4. Investment geo plot (Python) ───────────────────────────────────────
    println("\n" * "="^70)
    println("GENERATING INVESTMENT GEO PLOT (Python)")
    println("="^70)
    flush(stdout)
    run_python(PY_INVESTMENTS, simdir)

    # ── Summary ───────────────────────────────────────────────────────────────
    println("\n" * "="^70)
    println("DONE. Plots written to $simdir/visual/ :")
    println("  daily_profile_stacked.png")
    println("  actual_dispatch_stacked.png")
    println("  integrated_load_geo.html")
    println("  investments_geo.html")
    println("="^70)
    flush(stdout)

    return nothing
end

"""
    run_python(script, args...)

Shell out to a Python script, streaming its output. Warns (doesn't error) on
failure so one broken plot doesn't kill the rest.
"""
function run_python(script::String, args::String...)
    if !isfile(PYTHON_EXE)
        @warn "Python executable not found at $PYTHON_EXE -- skipping $script.\n" *
              "Edit PYTHON_EXE at the top of run_and_plot.jl."
        return
    end
    if !isfile(script)
        @warn "Plot script not found: $script -- skipping."
        return
    end
    cmd = `$PYTHON_EXE $script $(collect(args))`
    println("  running: $cmd")
    flush(stdout)
    try
        run(cmd)
    catch e
        @warn "Python plot failed: $script" exception=e
    end
end