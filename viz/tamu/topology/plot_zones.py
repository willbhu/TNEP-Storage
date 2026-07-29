"""
plot_zones.py

Geographical plot of ERCOT weather zones on the Texas grid, colored by
zone ID. Each bus is shown as a dot colored by its zone_id, with
transmission lines drawn as background. This gives a spatial reference
for understanding which areas each zone covers, useful for reviewing
zonal multiplier assignments in generate_scenarios.jl.

Zone mapping (from power_system_data.json lat/lon analysis):
    301 → Far West    (Permian Basin, lon~-102)
    302 → West        (Lubbock/Wind Corridor, lon~-101)
    303 → West/North  (Abilene, lon~-100)
    304 → South       (Corpus Christi, lon~-97)
    305 → South Ctrl  (Waco/Austin, lon~-96.5)
    306 → South Ctrl  (San Antonio, lon~-98.6)
    307 → Coast       (Gulf Coast, lon~-96.5)
    308 → North Ctrl  (DFW, lon~-96.1)

USAGE:
    From project root:
        python viz/tamu/topology/plot_zones.py data/topology/tamu/texas/power_system_data.json

    From viz/tamu/topology/:
        python plot_zones.py ../../../data/topology/tamu/texas/power_system_data.json

OUTPUT:
    viz/tamu/topology/zones_geo.html  -- interactive Plotly map
"""

import json
import sys
import os
import numpy as np
import plotly.graph_objects as go

# ── Args ──────────────────────────────────────────────────────────────────────
if len(sys.argv) < 2:
    print("Usage: python plot_zones.py path/to/power_system_data.json")
    sys.exit(1)

ps_data_path = sys.argv[1]
if not os.path.isfile(ps_data_path):
    # Try resolving relative to project root
    alt = os.path.join(os.path.dirname(__file__), "../../../", ps_data_path)
    if os.path.isfile(alt):
        ps_data_path = alt
    else:
        print(f"ERROR: Could not find {ps_data_path}")
        sys.exit(1)

# ── Load data ─────────────────────────────────────────────────────────────────
print(f"Loading {ps_data_path} ...")
with open(ps_data_path, "r") as f:
    data = json.load(f)

# ── Zone metadata ─────────────────────────────────────────────────────────────
ZONE_NAMES = {
    301: "Far West (Permian Basin)",
    302: "West (Lubbock/Wind Corridor)",
    303: "West/North (Abilene)",
    304: "South (Corpus Christi)",
    305: "South Central (Waco/Austin)",
    306: "South Central (San Antonio)",
    307: "Coast (Gulf Coast)",
    308: "North Central (DFW)",
}

# Distinct colors for 8 zones
ZONE_COLORS = {
    301: "#E63946",   # red        -- Far West
    302: "#F4A261",   # orange     -- West
    303: "#E9C46A",   # yellow     -- West/North
    304: "#2A9D8F",   # teal       -- South
    305: "#457B9D",   # steel blue -- South Central (Waco/Austin)
    306: "#1D3557",   # navy       -- South Central (San Antonio)
    307: "#A8DADC",   # light blue -- Coast
    308: "#6A4C93",   # purple     -- North Central (DFW)
}

# ── Aggregate buses by zone ───────────────────────────────────────────────────
zone_buses = {z: {"lat": [], "lon": [], "names": []} for z in ZONE_NAMES}

for bus_id, bus in data["bus"].items():
    zone_id = bus.get("zone_id")
    if zone_id in zone_buses:
        zone_buses[zone_id]["lat"].append(bus["lat"])
        zone_buses[zone_id]["lon"].append(bus["lon"])
        zone_buses[zone_id]["names"].append(
            f"Bus {bus_id}<br>"
            f"Zone {zone_id}: {ZONE_NAMES.get(zone_id, 'unknown')}<br>"
            f"lat={bus['lat']:.3f}, lon={bus['lon']:.3f}"
        )

# ── Build figure ───────────────────────────────────────────────────────────────
fig = go.Figure()

# (Zone hull shading removed — colored dots on white background only)

# Transmission lines — ALL plain gray. Per meeting notes 7/15: coloring
# branches by zone is misleading (a line isn't "in" a zone the way a bus is).
# Zone identity is carried by the NODES (colored dots) and shaded hulls only.
for branch in data["branch"].values():
    f_bus = data["bus"][str(branch["f_bus"])]
    t_bus = data["bus"][str(branch["t_bus"])]
    fig.add_trace(go.Scattergeo(
        lat=[f_bus["lat"], t_bus["lat"]],
        lon=[f_bus["lon"], t_bus["lon"]],
        mode="lines",
        showlegend=False,
        line=dict(color="lightgray", width=0.4),
        hoverinfo="skip"
    ))

# One trace per zone so each gets its own legend entry + color
for zone_id in sorted(ZONE_NAMES.keys()):
    buses = zone_buses[zone_id]
    if not buses["lat"]:
        continue
    n_buses = len(buses["lat"])
    fig.add_trace(go.Scattergeo(
        lat=buses["lat"],
        lon=buses["lon"],
        mode="markers",
        name=f"Zone {zone_id}: {ZONE_NAMES[zone_id]} ({n_buses} buses)",
        marker=dict(
            size=7,
            color=ZONE_COLORS[zone_id],
            opacity=0.85,
            line=dict(width=0.4, color="white")
        ),
        text=buses["names"],
        hovertemplate="%{text}<extra></extra>"
    ))

# ── Print zone bus counts ─────────────────────────────────────────────────────
print("\nBus count per zone:")
for zone_id in sorted(ZONE_NAMES.keys()):
    n = len(zone_buses[zone_id]["lat"])
    print(f"  Zone {zone_id} ({ZONE_NAMES[zone_id]}): {n} buses")

# ── Layout ─────────────────────────────────────────────────────────────────────
fig.update_geos(
    scope="usa",
    resolution=50,
    lonaxis_range=[-105, -94],
    lataxis_range=[25.5, 36],
    showland=True, landcolor="white",
    showocean=True, oceancolor="white",
    showlakes=True, lakecolor="white",
    showrivers=False,
    showcountries=True, countrycolor="lightgray",
    showsubunits=True, subunitcolor="#cccccc", subunitwidth=1.5,
    showframe=False,
    showcoastlines=False,
    bgcolor="white",
)
fig.update_layout(paper_bgcolor="white", plot_bgcolor="white",
                  geo=dict(bgcolor="white"))

fig.update_layout(
    title=dict(
        text="ERCOT Weather Zones — 2000-Bus Synthetic Texas Grid<br>"
             "<sup>Each dot = one bus, colored by zone_id from power_system_data.json</sup>",
        font=dict(size=18)
    ),
    legend=dict(
        x=0.01, y=0.99,
        font=dict(size=11),
        orientation="v",
        xanchor="left", yanchor="top",
        bgcolor="rgba(255,255,255,0.85)",
        bordercolor="lightgray", borderwidth=1,
        title=dict(text="<b>Zone</b>", font=dict(size=12))
    ),
    margin=dict(l=0, r=0, t=70, b=0)
)

# ── Save ──────────────────────────────────────────────────────────────────────
out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "zones_geo.html")
fig.write_html(out_path)
print(f"\nSaved to {out_path}")