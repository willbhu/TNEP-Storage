"""
plot_storage_utilization.py

Storage utilization analysis + geospatial plot.

Per meeting notes 8/12:
  - "Want estimate how much storage is needed/actually used"
  - "Storage utilization plot, geospatial plot, max state of charge at a node
     size reference, consider power & energy rating, also plot rate or capacity,
     based on which is limiting, max(SOC, discharge * 4)"

═══════════════════════════════════════════════════════════════════════════════
METHODOLOGY
═══════════════════════════════════════════════════════════════════════════════
energy.csv has Charge and Discharge per node per hour, but NO state-of-charge
column. SOC is therefore reconstructed by integrating over the day, accounting
for round-trip efficiency:

    SOC(t) = cumsum( Charge(t) x eta_c  -  Discharge(t) / eta_d )

Charging adds only eta_c per MWh drawn from the grid; discharging removes more
than it delivers. A raw charge-minus-discharge sum ignores this and understates
how much energy the reservoir actually has to hold. Only the SWING (max - min)
matters for sizing, since the model's SOC has a free starting point.

TWO DISTINCT QUANTITIES -- do not conflate them:
    SIZING     max(SOC swing, peak discharge x 4h) -- how big the unit must be
    THROUGHPUT total MWh discharged -- how hard it is worked over the horizon
A node can be large but rarely used, or small but cycled constantly.

UTILIZATION is computed PER NODE against that node's own installed capacity,
then summarised as a median. A fleet-wide required/installed ratio hides the
fact that most nodes may sit idle while a few are saturated.

SIZING METRIC -- which rating binds?
    energy_need = max SOC swing over the day                (MWh)
    power_need  = max discharge in any hour x 4 hours       (MWh equivalent)

    required = max(energy_need, power_need)

A 4-hour duration is the standard reference for grid batteries: a unit rated
for P MW of discharge is typically built with 4P MWh of energy. Comparing the
two tells you which rating is actually limiting at that node:

    power-limited   -> the node needs a bigger inverter / discharge rate
    energy-limited  -> the node needs more MWh of storage

USAGE (from project root):
    python viz/tamu/topology/plot_storage_utilization.py scenarios/B_med/2035

OUTPUT:
    <simdir>/visual/storage_utilization_geo.html   interactive map
    <simdir>/visual/storage_utilization.csv        per-node table
    console summary: total installed vs total actually used
"""

import json
import os
import sys

import numpy as np
import pandas as pd
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


# ── Args / paths ──────────────────────────────────────────────────────────────
if len(sys.argv) < 2:
    print("Usage: python plot_storage_utilization.py <simdir>")
    sys.exit(1)

simdir = sys.argv[1]
_parts = os.path.normpath(simdir).split(os.sep)
scenario_label = " / ".join(_parts[-2:]) if len(_parts) >= 2 else os.path.basename(simdir)

BASE_MW        = 100.0  # per-unit -> MW
STORAGE_HOURS  = 4.0    # standard grid-battery duration for the power/energy comparison
ROUND_TRIP_EFF = 0.85   # round-trip efficiency; SOC gains eta_c per MWh charged
CHARGE_EFF     = ROUND_TRIP_EFF ** 0.5   # one-way charging efficiency
DISCHARGE_EFF  = ROUND_TRIP_EFF ** 0.5   # one-way discharging efficiency

out_dir    = simdir
output_dir = os.path.join(out_dir, "output")
visual_dir = os.path.join(out_dir, "visual")
os.makedirs(visual_dir, exist_ok=True)

if not os.path.isdir(output_dir):
    print(f"ERROR: no output/ folder in {simdir}. Solve the model first.")
    sys.exit(1)

# Representative-day subfolders (e.g. 2016-08-11)
rep_days = sorted(
    d for d in os.listdir(output_dir)
    if os.path.isdir(os.path.join(output_dir, d))
)
if not rep_days:
    print(f"ERROR: no representative-day folders under {output_dir}")
    sys.exit(1)

# ── Aggregate storage behaviour across all representative days ───────────────
# For each node we keep the WORST-CASE (max) requirement across days, since
# storage must be sized for the hardest day it has to serve.

node_meta   = {}   # node -> (name, lat, lon)
energy_need = {}   # node -> max SOC swing (MWh) across days  [sizing]
power_need  = {}   # node -> max discharge (MW) across days   [sizing]
cycled_mwh  = {}   # node -> total MWh discharged over all days [throughput]
total_shed  = 0.0

# Installed capacity per node, so utilization can be computed node by node
# rather than as an aggregate ratio (which hides nodes that sit idle).
installed_by_node = {}
_inv_path = os.path.join(output_dir, "storage_investments.csv")
if os.path.isfile(_inv_path):
    _inv = pd.read_csv(_inv_path)
    if {"Node_Index", "Storage_Energy"}.issubset(_inv.columns):
        installed_by_node = {
            int(r.Node_Index): float(r.Storage_Energy) * BASE_MW
            for r in _inv.itertuples()
        }

for day in rep_days:
    path = os.path.join(output_dir, day, "energy.csv")
    if not os.path.isfile(path):
        continue

    df = pd.read_csv(path)
    if "Energy_Imbalance" in df.columns:
        total_shed += float(df["Energy_Imbalance"].sum()) * BASE_MW

    df = df.sort_values(["Node_Index", "Hour"])

    for node, g in df.groupby("Node_Index"):
        charge    = g["Charge"].to_numpy(dtype=float) * BASE_MW
        discharge = g["Discharge"].to_numpy(dtype=float) * BASE_MW

        if charge.sum() == 0 and discharge.sum() == 0:
            continue   # storage idle at this node on this day

        # Reconstruct SOC by integration. Charging adds eta_c per MWh drawn from
        # the grid; discharging removes MWh/eta_d from the reservoir. Ignoring
        # efficiency (as a raw charge-minus-discharge sum does) understates the
        # energy the reservoir actually has to hold.
        soc = np.cumsum(charge * CHARGE_EFF - discharge / DISCHARGE_EFF)
        swing = float(soc.max() - soc.min())

        node_meta.setdefault(
            node,
            (g["Node_Name"].iloc[0], float(g["Lat"].iloc[0]), float(g["Lon"].iloc[0]))
        )
        energy_need[node] = max(energy_need.get(node, 0.0), swing)
        power_need[node]  = max(power_need.get(node, 0.0), float(discharge.max()))
        cycled_mwh[node]  = cycled_mwh.get(node, 0.0) + float(discharge.sum())

if not node_meta:
    print("No storage activity found in any representative day.")
    print("(Charge and Discharge are all zero -- the model didn't use storage.)")
    sys.exit(0)

# ── Build the per-node table ─────────────────────────────────────────────────
rows = []
for node, (name, lat, lon) in node_meta.items():
    e_need = energy_need.get(node, 0.0)                       # MWh from SOC swing
    p_need = power_need.get(node, 0.0)                        # MW peak discharge
    p_as_energy = p_need * STORAGE_HOURS                      # MWh equivalent at 4h
    required = max(e_need, p_as_energy)
    limiting = "energy" if e_need >= p_as_energy else "power"

    inst = installed_by_node.get(node, float("nan"))
    util_pct = (100.0 * required / inst) if inst and inst > 0 else float("nan")

    rows.append({
        "Node_Index":          node,
        "Node_Name":           name,
        "Lat":                 lat,
        "Lon":                 lon,
        "Energy_Need_MWh":     round(e_need, 1),
        "Peak_Discharge_MW":   round(p_need, 1),
        "Power_As_Energy_MWh": round(p_as_energy, 1),
        "Required_MWh":        round(required, 1),
        "Cycled_MWh":          round(cycled_mwh.get(node, 0.0), 1),
        "Installed_MWh":       round(inst, 1) if inst == inst else "",
        "Utilization_Pct":     round(util_pct, 1) if util_pct == util_pct else "",
        "Limiting_Factor":     limiting,
    })

util = pd.DataFrame(rows).sort_values("Required_MWh", ascending=False)
csv_path = os.path.join(visual_dir, "storage_utilization.csv")
util.to_csv(csv_path, index=False)

# ── Compare against what was actually installed ──────────────────────────────
installed_total = None
inv_path = os.path.join(output_dir, "storage_investments.csv")
if os.path.isfile(inv_path):
    inv = pd.read_csv(inv_path)
    if "Storage_Energy" in inv.columns:
        installed_total = float(inv["Storage_Energy"].sum()) * BASE_MW

used_total     = float(util["Required_MWh"].sum())
cycled_total   = float(util["Cycled_MWh"].sum())
n_active       = len(util)
n_power_lim    = int((util["Limiting_Factor"] == "power").sum())
n_energy_lim   = int((util["Limiting_Factor"] == "energy").sum())

n_installed = len(installed_by_node) if installed_by_node else 0
n_idle      = max(n_installed - n_active, 0)
util_series = pd.to_numeric(util["Utilization_Pct"], errors="coerce").dropna()

print("=" * 72)
print(f"STORAGE UTILIZATION — {scenario_label}")
print("=" * 72)
print(f"  Representative days analysed: {len(rep_days)}")
print(f"  Round-trip efficiency assumed: {ROUND_TRIP_EFF:.0%}")
print()
print("  CAPACITY")
if installed_total is not None:
    print(f"    Installed                {installed_total:>14,.0f} MWh  across {n_installed:,} nodes")
print(f"    Required (sizing)        {used_total:>14,.0f} MWh  sum of per-node max(SOC swing, P x {STORAGE_HOURS:.0f}h)")
if installed_total and installed_total > 0:
    print(f"    Fleet-wide ratio         {100 * used_total / installed_total:>13.1f} %  required / installed")
print()
print("  THROUGHPUT")
print(f"    Energy discharged        {cycled_total:>14,.0f} MWh  summed over all days and nodes")
if installed_total and installed_total > 0 and len(rep_days) > 0:
    cycles = cycled_total / installed_total / len(rep_days)
    print(f"    Equivalent full cycles   {cycles:>13.2f}    per representative day")
print()
print("  NODE-LEVEL")
print(f"    Active (any cycling)     {n_active:>14,}")
if n_installed:
    print(f"    Idle (never cycled)      {n_idle:>14,}  {100*n_idle/n_installed:.1f}% of nodes with storage")
if len(util_series):
    print(f"    Median node utilization  {util_series.median():>13.1f} %")
    print(f"    Max node utilization     {util_series.max():>13.1f} %")
print(f"    Power-limited            {n_power_lim:>14,}  would need a higher discharge rate")
print(f"    Energy-limited           {n_energy_lim:>14,}  would need more MWh")
print()
print("  VALIDATION")
print(f"    Load shed                {total_shed:>14,.1f} MWh", end="")
print("   ✓ none" if abs(total_shed) < 1e-6 else "   ⚠ NONZERO")
print("=" * 72)
print(f"\nTop 10 nodes by required storage:")
print(util.head(10)[["Node_Index", "Node_Name", "Required_MWh",
                     "Peak_Discharge_MW", "Limiting_Factor"]].to_string(index=False))

# ── Geospatial plot ──────────────────────────────────────────────────────────
def scale_sizes(vals, lo=5, hi=38):
    a = np.asarray(vals, dtype=float)
    if a.max() <= 0:
        return [lo] * len(a)
    return (lo + (hi - lo) * a / a.max()).tolist()

fig = go.Figure()

# Faint grid backdrop from the data.json topology, if available
data_json = os.path.join(simdir, "data.json")
if os.path.isfile(data_json):
    with open(data_json) as f:
        grid = json.load(f)
    for branch in grid.get("branch", {}).values():
        fb = grid["bus"][str(branch["f_bus"])]
        tb = grid["bus"][str(branch["t_bus"])]
        fig.add_trace(go.Scattergeo(
            lat=[fb["lat"], tb["lat"]], lon=[fb["lon"], tb["lon"]],
            mode="lines", showlegend=False,
            line=dict(color="#dddddd", width=0.3), hoverinfo="skip",
        ))

# One trace per limiting factor so the legend explains the colours
COLORS = {"energy": "#9B5DE5", "power": "#F4A261"}
LABELS = {
    "energy": "Energy-limited (needs more MWh)",
    "power":  "Power-limited (needs higher discharge rate)",
}

for factor in ["energy", "power"]:
    sub = util[util["Limiting_Factor"] == factor]
    if sub.empty:
        continue
    fig.add_trace(go.Scattergeo(
        lat=sub["Lat"], lon=sub["Lon"], mode="markers",
        name=LABELS[factor],
        marker=dict(
            size=scale_sizes(sub["Required_MWh"]),
            color=COLORS[factor], opacity=0.75,
            line=dict(width=0.5, color="white"),
        ),
        text=[
            f"{r.Node_Name} (bus {r.Node_Index})<br>"
            f"Required: {r.Required_MWh:,.0f} MWh<br>"
            f"Max SOC swing: {r.Energy_Need_MWh:,.0f} MWh<br>"
            f"Peak discharge: {r.Peak_Discharge_MW:,.0f} MW "
            f"({r.Power_As_Energy_MWh:,.0f} MWh at {STORAGE_HOURS:.0f}h)<br>"
            f"Cycled: {r.Cycled_MWh:,.0f} MWh<br>"
            f"Limiting: {r.Limiting_Factor}"
            for r in sub.itertuples()
        ],
        hovertemplate="%{text}<extra></extra>",
    ))

# Size legend
max_req = float(util["Required_MWh"].max())
for pct in (0.25, 0.5, 1.0):
    fig.add_trace(go.Scattergeo(
        lat=[None], lon=[None], mode="markers",
        name=f"{max_req * pct:,.0f} MWh",
        marker=dict(size=5 + (38 - 5) * pct, color="#888888", opacity=0.5,
                    line=dict(width=0.5, color="white")),
        showlegend=True, hoverinfo="skip",
    ))

fig.update_geos(
    scope="usa", resolution=50,
    lonaxis_range=[-105, -94], lataxis_range=[25.5, 36],
    showland=True, landcolor="white",
    showocean=True, oceancolor="white",
    showlakes=True, lakecolor="white",
    showcountries=True, countrycolor="lightgray",
    showsubunits=True, subunitcolor="#cccccc", subunitwidth=1.5,
    showframe=False, showcoastlines=False, bgcolor="white",
)
fig.update_layout(
    paper_bgcolor="white", plot_bgcolor="white",
    title=dict(
        text=(
            f"Storage Utilization — {scenario_label}<br>"
            f"<sup>Circle size = max(SOC swing, peak discharge × {STORAGE_HOURS:.0f}h). "
            f"{used_total:,.0f} MWh required across {n_active:,} nodes.</sup>"
        ),
        font=dict(size=17),
    ),
    legend=dict(x=0.72, y=0.98, font=dict(size=11),
                bgcolor="rgba(255,255,255,0.85)",
                bordercolor="lightgray", borderwidth=1,
                title=dict(text="<b>Limiting factor / size</b>", font=dict(size=11))),
    margin=dict(l=0, r=0, t=70, b=0),
)

add_caption(fig,
    f"Storage actually used at each node in the solved model for scenario {scenario_label}. "
    f"Circle size is the storage requirement, taken as max(state-of-charge swing over the day, "
    f"peak discharge x {STORAGE_HOURS:.0f} h) — the larger of the energy and power requirements. "
    f"State of charge is reconstructed by integrating charge minus discharge, since the solver "
    f"does not report it directly. Colour shows which rating binds: violet nodes are energy-"
    f"limited and would need more MWh, orange nodes are power-limited and would need a higher "
    f"discharge rate. Across {n_active:,} active nodes the total requirement is "
    f"{used_total:,.0f} MWh, against {installed_total:,.0f} MWh installed."
    if installed_total else
    f"Storage actually used at each node in the solved model for scenario {scenario_label}. "
    f"Circle size is max(SOC swing, peak discharge x {STORAGE_HOURS:.0f} h). Violet nodes are "
    f"energy-limited, orange nodes power-limited. Total requirement {used_total:,.0f} MWh "
    f"across {n_active:,} nodes.")

html_path = os.path.join(visual_dir, "storage_utilization_geo.html")
fig.write_html(html_path)
print(f"\nSaved map to   {html_path}")
print(f"Saved table to {csv_path}")