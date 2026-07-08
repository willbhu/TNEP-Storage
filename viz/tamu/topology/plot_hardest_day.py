"""
plot_hardest_day.py

Geographical plot of load and generation on the hardest representative day
(Aug 11). Each bus is shown as a circle sized by its peak hourly load or
total generation on that day.

USAGE:
    cd viz/tamu/topology
    python plot_hardest_day.py examples/example_simdir [rep_index]

    rep_index defaults to 1 (first representative day).
    For the full 18-day config, Aug 11 is rep_index=13.

OUTPUT:
    simdir/hardest_day_geo.html  -- interactive Plotly map
"""

import json
import sys
import numpy as np
import plotly.graph_objects as go

# ── Args ──────────────────────────────────────────────────────────────────────
simdir    = sys.argv[1]
rep_index = int(sys.argv[2]) if len(sys.argv) > 2 else 1
rep_key   = str(rep_index)
BASE_MW   = 100.0  # data.json is in per-unit; multiply by 100 to get MW

# ── Load data ─────────────────────────────────────────────────────────────────
with open(f"../../../{simdir}/data.json", "r") as f:
    data = json.load(f)

date_label = data["param"]["dates"][rep_index - 1]
renewable_types    = set(data["param"]["renewable_types"])
nonrenewable_types = set(data["param"]["nonrenewable_types"])

# ── Aggregate per bus ─────────────────────────────────────────────────────────
bus_records = []
for bus_id, bus in data["bus"].items():

    lat = bus["lat"]
    lon = bus["lon"]

    # Peak hourly load on this rep day (p.u. → MW)
    load_profile = bus["load"].get(rep_key, [])
    peak_load_mw = float(np.max(load_profile)) * BASE_MW if len(load_profile) > 0 else 0.0

    # Total renewable generation capacity available at this bus (pmax, MW)
    renewable_gen_mw = 0.0
    for gen_type, gen_ids in bus["gen"].items():
        if gen_type in renewable_types:
            for gen_id in gen_ids:
                gen = data["gen"][str(gen_id)]
                # Use profile max if available, otherwise pmax
                profile = gen.get("profile", {}).get(rep_key, [])
                if len(profile) > 0:
                    renewable_gen_mw += float(np.max(profile)) * BASE_MW
                else:
                    renewable_gen_mw += gen.get("pmax", 0.0) * BASE_MW

    # Total nonrenewable capacity at this bus (pmax, MW — no profile pre-solve)
    nonrenewable_cap_mw = 0.0
    for gen_type, gen_ids in bus["gen"].items():
        if gen_type in nonrenewable_types:
            for gen_id in gen_ids:
                nonrenewable_cap_mw += data["gen"][str(gen_id)].get("pmax", 0.0) * BASE_MW

    bus_records.append({
        "bus_id":             bus_id,
        "lat":                lat,
        "lon":                lon,
        "peak_load_mw":       peak_load_mw,
        "renewable_gen_mw":   renewable_gen_mw,
        "nonrenewable_cap_mw": nonrenewable_cap_mw,
    })

# ── Split into sub-dataframes ─────────────────────────────────────────────────
load_buses         = [b for b in bus_records if b["peak_load_mw"] > 0]
renewable_buses    = [b for b in bus_records if b["renewable_gen_mw"] > 0]
nonrenewable_buses = [b for b in bus_records if b["nonrenewable_cap_mw"] > 0]

# ── Uniform scaling across ALL three layers ───────────────────────────────────
# Find the global max across all values so circles are directly comparable --
# a circle of the same size means the same MW regardless of which layer it's on.
all_values = (
    [b["peak_load_mw"]       for b in load_buses] +
    [b["renewable_gen_mw"]   for b in renewable_buses] +
    [b["nonrenewable_cap_mw"] for b in nonrenewable_buses]
)
global_max = max(all_values) if all_values else 1.0
MIN_SIZE, MAX_SIZE = 4, 30

def scale_sizes_uniform(values):
    """Scale values against the global max so all layers share the same scale."""
    arr = np.array(values, dtype=float)
    return (MIN_SIZE + (MAX_SIZE - MIN_SIZE) * arr / global_max).tolist()

# ── Legend size reference points (for annotation) ─────────────────────────────
# Show three reference circles: 25%, 50%, 100% of global max
legend_pcts   = [0.25, 0.50, 1.00]
legend_labels = [f"{int(p * global_max):,} MW" for p in legend_pcts]
legend_sizes  = [MIN_SIZE + (MAX_SIZE - MIN_SIZE) * p for p in legend_pcts]

# ── Build transmission lines ───────────────────────────────────────────────────
line_traces = []
for branch in data["branch"].values():
    f_bus = data["bus"][str(branch["f_bus"])]
    t_bus = data["bus"][str(branch["t_bus"])]
    line_traces.append(go.Scattergeo(
        lat=[f_bus["lat"], t_bus["lat"]],
        lon=[f_bus["lon"], t_bus["lon"]],
        mode="lines",
        showlegend=False,
        line=dict(color="black", width=0.3),
        hoverinfo="skip"
    ))

# ── Build figure ───────────────────────────────────────────────────────────────
fig = go.Figure()

# Transmission lines first (drawn underneath)
fig.add_traces(line_traces)

# Nonrenewable capacity (gray, uniformly scaled)
if nonrenewable_buses:
    sizes = scale_sizes_uniform([b["nonrenewable_cap_mw"] for b in nonrenewable_buses])
    fig.add_trace(go.Scattergeo(
        lat=[b["lat"] for b in nonrenewable_buses],
        lon=[b["lon"] for b in nonrenewable_buses],
        mode="markers",
        name="Nonrenewable (pmax)",
        marker=dict(size=sizes, color="gray", opacity=0.7,
                    line=dict(width=0.5, color="black")),
        text=[f"Bus {b['bus_id']}<br>Nonrenewable pmax: {b['nonrenewable_cap_mw']:.1f} MW"
              for b in nonrenewable_buses],
        hovertemplate="%{text}<extra></extra>"
    ))

# Renewable generation (green, uniformly scaled)
if renewable_buses:
    sizes = scale_sizes_uniform([b["renewable_gen_mw"] for b in renewable_buses])
    fig.add_trace(go.Scattergeo(
        lat=[b["lat"] for b in renewable_buses],
        lon=[b["lon"] for b in renewable_buses],
        mode="markers",
        name="Renewable (peak gen)",
        marker=dict(size=sizes, color="green", opacity=0.8,
                    line=dict(width=0.5, color="darkgreen")),
        text=[f"Bus {b['bus_id']}<br>Peak renewable gen: {b['renewable_gen_mw']:.1f} MW"
              for b in renewable_buses],
        hovertemplate="%{text}<extra></extra>"
    ))

# Load (red, uniformly scaled)
if load_buses:
    sizes = scale_sizes_uniform([b["peak_load_mw"] for b in load_buses])
    fig.add_trace(go.Scattergeo(
        lat=[b["lat"] for b in load_buses],
        lon=[b["lon"] for b in load_buses],
        mode="markers",
        name="Peak Load",
        marker=dict(size=sizes, color="red", opacity=0.6,
                    line=dict(width=0.5, color="darkred")),
        text=[f"Bus {b['bus_id']}<br>Peak load: {b['peak_load_mw']:.1f} MW"
              for b in load_buses],
        hovertemplate="%{text}<extra></extra>"
    ))

# ── Size legend annotation ────────────────────────────────────────────────────
# Add invisible scatter traces that act as legend entries for circle sizes
for size, label in zip(legend_sizes, legend_labels):
    fig.add_trace(go.Scattergeo(
        lat=[None], lon=[None],
        mode="markers",
        name=label,
        marker=dict(size=size, color="black", opacity=0.5,
                    line=dict(width=0.5, color="black")),
        showlegend=True,
        hoverinfo="skip"
    ))

fig.update_geos(
    lonaxis_range=[-105, -94],
    lataxis_range=[25.5, 36],
    showland=True, showocean=True,
    oceancolor="lightblue", showlakes=True, lakecolor="lightblue",
    showcountries=True, countrycolor="lightgray",
    showsubunits=True, subunitcolor="lightgray", subunitwidth=2
)

fig.update_layout(
    title=dict(text=f"Load & Generation — Hardest Day ({date_label})<br>"
                    f"<sup>Circle size proportional to MW (uniform scale across all layers, max = {global_max:,.0f} MW)</sup>",
               font=dict(size=18)),
    legend=dict(
        x=0.78, font=dict(size=13), orientation="v",
        xanchor="left", yanchor="top",
        title=dict(text="<b>Layer / Size Reference</b>", font=dict(size=13))
    ),
    margin=dict(l=0, r=0, t=60, b=0)
)

out_path = f"../../../{simdir}/hardest_day_geo.html"
fig.write_html(out_path)
print(f"Saved to {out_path}")