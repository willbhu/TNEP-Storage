"""
plot_investments.py

Geographical plot of TEP+Storage investment decisions from a solved model:
- Transmission line upgrades (line_investments.csv): colored red, thickness
  proportional to upgrade level
- Storage siting (storage_investments.csv): green circles sized by installed
  energy capacity (MWh)
- All transmission lines shown as thin gray background

USAGE:
    cd viz/tamu/topology
    python plot_investments.py examples/example_simdir

    Or from project root:
    python viz/tamu/topology/plot_investments.py examples/example_simdir

OUTPUT:
    simdir/investments_geo.html  -- interactive Plotly map
"""

import json
import sys
import os
import numpy as np
import pandas as pd
import plotly.graph_objects as go

# ── Args ──────────────────────────────────────────────────────────────────────
simdir = sys.argv[1]

# ── Resolve paths regardless of where script is run from ─────────────────────
candidates = [
    os.path.join(simdir, "data.json"),
    os.path.join("../../../", simdir, "data.json"),
    os.path.join(os.path.dirname(__file__), "../../../", simdir, "data.json"),
]
data_path = next((p for p in candidates if os.path.isfile(p)), None)
if data_path is None:
    print(f"ERROR: Could not find data.json for simdir='{simdir}'")
    sys.exit(1)

out_dir = os.path.dirname(data_path)
lines_csv_path   = os.path.join(out_dir, "output", "line_investments.csv")
storage_csv_path = os.path.join(out_dir, "output", "storage_investments.csv")

for p in [lines_csv_path, storage_csv_path]:
    if not os.path.isfile(p):
        print(f"ERROR: Could not find {p}")
        print("Run the model first: model, data = run_model(simdir)")
        sys.exit(1)

# ── Load data ─────────────────────────────────────────────────────────────────
with open(data_path, "r") as f:
    data = json.load(f)

lines_df   = pd.read_csv(lines_csv_path)
storage_df = pd.read_csv(storage_csv_path)

BASE_MW = 100.0  # per-unit to MW

# ── Summarize investments ─────────────────────────────────────────────────────
upgraded_lines   = lines_df[lines_df["Upgrade_Lvl"] > 0]
storage_deployed = storage_df[storage_df["Storage_Energy"] > 0]

print(f"Total lines:        {len(lines_df)}")
print(f"Upgraded lines:     {len(upgraded_lines)}")
print(f"Storage nodes:      {len(storage_deployed)}")
if len(storage_deployed) > 0:
    total_storage = (storage_deployed["Storage_Energy"] * BASE_MW).sum()
    print(f"Total storage:      {total_storage:.1f} MWh")
if len(upgraded_lines) > 0:
    print(f"Max upgrade level:  {upgraded_lines['Upgrade_Lvl'].max():.2f}")

# ── Scale helpers ─────────────────────────────────────────────────────────────
def scale_sizes(values, min_size=6, max_size=35):
    arr = np.array(values, dtype=float)
    if arr.max() == 0:
        return [min_size] * len(arr)
    return (min_size + (max_size - min_size) * arr / arr.max()).tolist()

def upgrade_width(level):
    """Map upgrade level to line width."""
    if level <= 0:
        return 0.3
    elif level < 1:
        return 1.5
    elif level < 2:
        return 3.0
    else:
        return 5.0

# ── Build figure ───────────────────────────────────────────────────────────────
fig = go.Figure()

# 1. All transmission lines (thin gray background)
for _, row in lines_df.iterrows():
    fig.add_trace(go.Scattergeo(
        lat=[row["Lat1"], row["Lat2"]],
        lon=[row["Lon1"], row["Lon2"]],
        mode="lines",
        showlegend=False,
        line=dict(color="lightgray", width=0.3),
        hoverinfo="skip"
    ))

# 2. Upgraded lines (red, thickness by upgrade level)
if len(upgraded_lines) > 0:
    # Group by upgrade level for cleaner legend
    for level in sorted(upgraded_lines["Upgrade_Lvl"].unique()):
        subset = upgraded_lines[upgraded_lines["Upgrade_Lvl"] == level]
        width  = upgrade_width(level)
        first  = True
        for _, row in subset.iterrows():
            fig.add_trace(go.Scattergeo(
                lat=[row["Lat1"], row["Lat2"]],
                lon=[row["Lon1"], row["Lon2"]],
                mode="lines",
                name=f"Line upgrade (level {level:.0f})" if first else None,
                showlegend=first,
                line=dict(color="red", width=width),
                hovertemplate=(
                    f"Branch {int(row['Branch_Index'])}<br>"
                    f"Upgrade level: {level:.1f}<br>"
                    f"Rate_A: {row['Rate_A']:.2f} p.u.<extra></extra>"
                )
            ))
            first = False
else:
    print("No line upgrades in this solution -- grid topology shown only.")

# 3. Storage deployments (green circles, sized by MWh)
if len(storage_deployed) > 0:
    storage_mwh = storage_deployed["Storage_Energy"] * BASE_MW
    sizes = scale_sizes(storage_mwh.tolist())
    fig.add_trace(go.Scattergeo(
        lat=storage_deployed["Lat"].tolist(),
        lon=storage_deployed["Lon"].tolist(),
        mode="markers",
        name="Storage deployed",
        marker=dict(
            size=sizes,
            color="green",
            opacity=0.85,
            line=dict(width=1, color="darkgreen"),
            colorscale="Greens",
        ),
        text=[
            f"{row['Node_Name']}<br>Storage: {row['Storage_Energy'] * BASE_MW:.1f} MWh"
            for _, row in storage_deployed.iterrows()
        ],
        hovertemplate="%{text}<extra></extra>"
    ))

    # Size legend entries
    max_mwh = storage_mwh.max()
    for pct, label in [(0.25, f"{max_mwh*0.25:.0f} MWh"),
                        (0.50, f"{max_mwh*0.50:.0f} MWh"),
                        (1.00, f"{max_mwh:.0f} MWh")]:
        sz = 6 + (35 - 6) * pct
        fig.add_trace(go.Scattergeo(
            lat=[None], lon=[None],
            mode="markers",
            name=label,
            marker=dict(size=sz, color="green", opacity=0.6,
                        line=dict(width=0.5, color="darkgreen")),
            showlegend=True,
            hoverinfo="skip"
        ))
else:
    print("No storage deployed in this solution.")

# ── Layout ─────────────────────────────────────────────────────────────────────
n_upgraded = len(upgraded_lines)
n_storage  = len(storage_deployed)
total_mwh  = (storage_deployed["Storage_Energy"] * BASE_MW).sum() if n_storage > 0 else 0

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
        text=(
            f"TEP+Storage Investment Decisions — {os.path.basename(simdir)}<br>"
            f"<sup>{n_upgraded} line upgrades | "
            f"{n_storage} storage nodes | "
            f"{total_mwh:.1f} MWh total storage</sup>"
        ),
        font=dict(size=18)
    ),
    legend=dict(
        x=0.78, font=dict(size=13), orientation="v",
        xanchor="left", yanchor="top",
        title=dict(text="<b>Investment / Size</b>", font=dict(size=12))
    ),
    margin=dict(l=0, r=0, t=70, b=0)
)

visual_dir = os.path.join(out_dir, "visual")
os.makedirs(visual_dir, exist_ok=True)
out_path = os.path.join(visual_dir, "investments_geo.html")
fig.write_html(out_path)
print(f"\nSaved to {out_path}")