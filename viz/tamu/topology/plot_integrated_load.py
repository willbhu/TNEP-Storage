"""
plot_integrated_load.py

Geographical plot of total load integrated over 24 hours per bus, for one
representative day. Circle size and color intensity reflect the total MWh
consumed at each bus over the day -- showing where demand is geographically
concentrated across the Texas grid.

USAGE:
    cd viz/tamu/topology
    python plot_integrated_load.py examples/example_simdir [rep_index]

    rep_index defaults to 1 (first representative day).
    For the full 18-day config, Aug 11 is rep_index=13.

OUTPUT:
    simdir/integrated_load_geo.html  -- interactive Plotly map
"""

import json
import sys
import os
import numpy as np
import plotly.graph_objects as go


# ── Figure caption ────────────────────────────────────────────────────────────
def add_caption(fig, text, bottom_margin=95):
    """Attach an explanatory caption beneath the plot area (paper style)."""
    fig.add_annotation(
        text=text, xref="paper", yref="paper",
        x=0, y=-0.06, xanchor="left", yanchor="top",
        showarrow=False, align="left",
        font=dict(size=11, color="#333333"),
    )
    m = fig.layout.margin
    fig.update_layout(margin=dict(l=m.l or 0, r=m.r or 0, t=m.t or 60, b=bottom_margin))
    return fig


# ── Args ──────────────────────────────────────────────────────────────────────
simdir    = sys.argv[1]
_parts = os.path.normpath(simdir).split(os.sep)
scenario_label = " / ".join(_parts[-2:]) if len(_parts) >= 2 else os.path.basename(simdir)
rep_index = int(sys.argv[2]) if len(sys.argv) > 2 else 1
rep_key   = str(rep_index)
BASE_MW   = 100.0  # data.json is in per-unit; multiply by 100 to get MW

# ── Resolve data path regardless of where script is run from ──────────────────
candidates = [
    os.path.join(simdir, "data.json"),
    os.path.join("../../../", simdir, "data.json"),
    os.path.join(os.path.dirname(__file__), "../../../", simdir, "data.json"),
]
data_path = next((p for p in candidates if os.path.isfile(p)), None)
if data_path is None:
    print(f"ERROR: Could not find data.json for simdir='{simdir}'")
    print("Run from your project root: python viz/tamu/topology/plot_integrated_load.py examples/example_simdir")
    sys.exit(1)

out_dir = os.path.dirname(data_path)

# ── Load data ─────────────────────────────────────────────────────────────────
with open(data_path, "r") as f:
    data = json.load(f)

date_label = data["param"]["dates"][rep_index - 1]

# ── Compute integrated load per bus (sum over 24 hours → MWh) ────────────────
bus_records = []
for bus_id, bus in data["bus"].items():
    load_profile = bus["load"].get(rep_key, [])
    # Sum across all hours: each value is p.u. power × 1 hour = p.u. energy
    # Multiply by BASE_MW to convert to MWh
    integrated_load_mwh = float(np.sum(load_profile)) * BASE_MW if len(load_profile) > 0 else 0.0

    bus_records.append({
        "bus_id":               bus_id,
        "lat":                  bus["lat"],
        "lon":                  bus["lon"],
        "integrated_load_mwh":  integrated_load_mwh,
    })

# Only plot buses with nonzero load
load_buses = [b for b in bus_records if b["integrated_load_mwh"] > 0]

# ── Scale marker sizes and colors ─────────────────────────────────────────────
load_values = np.array([b["integrated_load_mwh"] for b in load_buses])

def scale_sizes(values, min_size=4, max_size=35):
    arr = np.array(values, dtype=float)
    if arr.max() == 0:
        return [min_size] * len(arr)
    return (min_size + (max_size - min_size) * arr / arr.max()).tolist()

sizes = scale_sizes(load_values)

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
        line=dict(color="darkgray", width=1.5),
        hoverinfo="skip"
    ))

# ── Build figure ───────────────────────────────────────────────────────────────
fig = go.Figure()

# Transmission lines underneath
fig.add_traces(line_traces)

# Integrated load bubbles -- colored by intensity using a continuous colorscale
fig.add_trace(go.Scattergeo(
    lat=[b["lat"] for b in load_buses],
    lon=[b["lon"] for b in load_buses],
    mode="markers",
    name="Daily Load (MWh)",
    marker=dict(
        size=sizes,
        color=[b["integrated_load_mwh"] for b in load_buses],
        colorscale="Reds",
        colorbar=dict(
            title=dict(text="Daily Load (MWh)"),
            tickfont=dict(size=11),
            x=0.92
        ),
        opacity=0.75,
        line=dict(width=0.4, color="darkred"),
        cmin=float(load_values.min()),
        cmax=float(load_values.max()),
        showscale=True
    ),
    text=[
        f"Bus {b['bus_id']}<br>"
        f"Daily load: {b['integrated_load_mwh']:.1f} MWh"
        for b in load_buses
    ],
    hovertemplate="%{text}<extra></extra>"
))

fig.update_geos(
    lonaxis_range=[-105, -94],
    lataxis_range=[25.5, 36],
    showland=True, showocean=True,
    oceancolor="aliceblue", showlakes=True, lakecolor="aliceblue",
    showcountries=True, countrycolor="gray",
    showsubunits=True, subunitcolor="gray", subunitwidth=2
)

fig.update_layout(
    title=dict(
        text=f"24-Hour Integrated Load per Bus — {scenario_label} ({date_label})<br>"
             f"<sup>Scaled load fed INTO the model (from data.json). Size/color = total MWh over the day.</sup>",
        font=dict(size=18)
    ),
    margin=dict(l=0, r=0, t=60, b=0)
)

add_caption(fig,
    f"Total electricity consumed at each bus over the 24 hours of representative day "
    f"{date_label}, for scenario {scenario_label}. Circle size and colour both encode daily "
    f"energy in MWh. This is model input — the scaled load fed into the optimizer — and shows "
    f"where demand is geographically concentrated. Grey lines are transmission branches.")

visual_dir = os.path.join(out_dir, "visual")
os.makedirs(visual_dir, exist_ok=True)
out_path = os.path.join(visual_dir, "integrated_load_geo.html")
fig.write_html(out_path)
print(f"Saved to {out_path}")

# ── Print top 10 buses by load for a quick sanity check ──────────────────────
print("\nTop 10 buses by integrated daily load:")
top10 = sorted(load_buses, key=lambda b: b["integrated_load_mwh"], reverse=True)[:10]
for b in top10:
    print(f"  Bus {b['bus_id']:>4s}  {b['integrated_load_mwh']:>10.1f} MWh  "
          f"  lat={b['lat']:.3f}  lon={b['lon']:.3f}")