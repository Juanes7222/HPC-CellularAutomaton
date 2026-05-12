"""
report_profiling.py  —  Traffic Automaton Sequential Profiling Report
======================================================================

Reads:
  - data_profiling.csv
  - raw/N<size>/gprof_report.txt
  - raw/N<size>/perf_stat.txt
  - raw/N<size>/perf_record_report.txt
  - raw/N<size>/cachegrind_report.txt
  - raw/N<size>/massif_report.txt
  - raw/N<size>/timing_ms.txt
  - raw/N<size>/timing_vel.txt

Writes:
  - reporte_profiling.xlsx
  - profiling_report.html
  - profiling_table.tex
  - charts_profiling/*.png

Usage:
  python3 report_profiling.py [path/to/data_profiling.csv]
"""

from __future__ import annotations

import html
import math
import os
import re
import sys
import statistics
from typing import Any

import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.drawing.image import Image as XLImage
from openpyxl.utils import get_column_letter

CSV_PATH = (
    sys.argv[1]
    if len(sys.argv) > 1
    else "tests/benchmarks/machine1/results_profiling/data_profiling.csv"
)

OUT_DIR    = os.path.dirname(os.path.abspath(CSV_PATH))
RAW_DIR    = os.path.join(OUT_DIR, "raw")
CHARTS_DIR = os.path.join(OUT_DIR, "charts_profiling")
XLSX_PATH  = os.path.join(OUT_DIR, "reporte_profiling.xlsx")
HTML_PATH  = os.path.join(OUT_DIR, "profiling_report.html")
LATEX_PATH = os.path.join(OUT_DIR, "profiling_table.tex")

# ---------------------------------------------------------------------------
# Style constants
# ---------------------------------------------------------------------------
COLORS = {
    "navy":     "1F3557",
    "blue":     "2E75B6",
    "cyan":     "1F9EB7",
    "green":    "70AD47",
    "orange":   "ED7D31",
    "red":      "C00000",
    "purple":   "7030A0",
    "gray":     "808080",
    "light":    "DCE6F1",
    "lighter":  "F7FBFF",
    "alt":      "F4F8FC",
    "white":    "FFFFFF",
    "border":   "C9D6E2",
    "good_bg":  "E2F0D9",
    "good_fg":  "2F6B1E",
    "warn_bg":  "FFF2CC",
    "warn_fg":  "7F6000",
    "bad_bg":   "FCE4D6",
    "bad_fg":   "A61C00",
}

CHART_STYLE = {
    "figure.facecolor":   "white",
    "axes.facecolor":     "white",
    "axes.grid":          True,
    "grid.color":         "#E7EDF3",
    "grid.linestyle":     "--",
    "grid.alpha":         0.75,
    "axes.spines.top":    False,
    "axes.spines.right":  False,
    "axes.titleweight":   "bold",
    "axes.labelsize":     10,
    "axes.titlesize":     12,
    "legend.frameon":     False,
    "font.size":          10,
}
plt.rcParams.update(CHART_STYLE)

# ---------------------------------------------------------------------------
# Excel helpers
# ---------------------------------------------------------------------------
def _border() -> Border:
    s = Side(style="thin", color=COLORS["border"])
    return Border(left=s, right=s, top=s, bottom=s)

def _fill(key: str) -> PatternFill:
    return PatternFill("solid", fgColor=COLORS[key])

def _set_width(ws, col: int, width: float) -> None:
    ws.column_dimensions[get_column_letter(col)].width = width

def _title_row(ws, text: str, cols: int, row: int = 1) -> None:
    ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=cols)
    c = ws.cell(row=row, column=1, value=text)
    c.font = Font(name="Calibri", bold=True, size=14, color=COLORS["white"])
    c.fill = _fill("navy")
    c.alignment = Alignment(horizontal="center", vertical="center")
    c.border = _border()
    ws.row_dimensions[row].height = 24

def _hcell(cell, value: Any, bg: str = "blue") -> None:
    cell.value = value
    cell.font = Font(name="Calibri", bold=True, size=10, color=COLORS["white"])
    cell.fill = _fill(bg)
    cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    cell.border = _border()

def _dcell(cell, value: Any, fmt: str | None = None, bg: str = "white",
           bold: bool = False, align: str = "right", fg: str = "000000") -> None:
    cell.value = value
    cell.font = Font(name="Calibri", bold=bold, size=10, color=COLORS.get(fg, fg))
    cell.fill = _fill(bg if bg in COLORS else "white")
    cell.alignment = Alignment(horizontal=align, vertical="center", wrap_text=True)
    cell.border = _border()
    if fmt:
        cell.number_format = fmt

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------
def _canon(name: str) -> str:
    s = name.strip().lower().replace("%", "pct").replace("-", "_").replace(" ", "_")
    s = re.sub(r"[^a-z0-9_]", "", s)
    return re.sub(r"_+", "_", s).strip("_")

def _read(path: str) -> str:
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read()

def _sf(x: Any, default: float = math.nan) -> float:
    try:
        return math.nan if pd.isna(x) else float(x)
    except Exception:
        return default

def _si(x: Any, default: int = 0) -> int:
    try:
        return default if pd.isna(x) else int(float(x))
    except Exception:
        return default

def _fn(x: Any, d: int = 3) -> str:
    try:
        f = float(x)
        return "—" if math.isnan(f) else f"{f:,.{d}f}"
    except Exception:
        return "—"

def _fp(x: Any, d: int = 2) -> str:
    try:
        f = float(x)
        return "—" if math.isnan(f) else f"{f:.{d}f}%"
    except Exception:
        return "—"

def _fi(x: Any) -> str:
    try:
        f = float(x)
        return "—" if math.isnan(f) else f"{int(round(f)):,}"
    except Exception:
        return "—"

def _classify_ipc(v: float) -> str:
    if math.isnan(v): return "Sin dato"
    if v >= 2.5: return "Alto"
    if v >= 1.5: return "Medio"
    return "Bajo"

def _classify_miss(v: float) -> str:
    if math.isnan(v): return "Sin dato"
    if v < 1:   return "Excelente"
    if v < 5:   return "Bueno"
    if v < 15:  return "Moderado"
    return "Alto"

def theoretical_heap_mb(n: int) -> float:
    """Two int32 arrays (cells + next_cells) of length N."""
    return 2 * n * 4 / 1024 / 1024

def perf_extract(path: str, keyword: str) -> int:
    if not os.path.exists(path):
        return 0
    for line in _read(path).splitlines():
        if keyword.lower() in line.lower() and not line.lstrip().startswith("#"):
            m = re.match(r"^\s*([\d,]+)", line)
            if m:
                return int(m.group(1).replace(",", ""))
    return 0

def compute_ratio(num: int, den: int, decimals: int = 4) -> float:
    return round(num / den * 100, decimals) if den > 0 else 0.0

def save_figure(fig, name: str) -> str:
    path = os.path.join(CHARTS_DIR, name)
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path

def annotate_points(ax, xs, ys, d: int = 3, dy: int = 8):
    for x, y in zip(xs, ys):
        if pd.isna(y): continue
        ax.annotate(f"{y:.{d}f}", (x, y), textcoords="offset points",
                    xytext=(0, dy), ha="center", fontsize=8)

# ---------------------------------------------------------------------------
# Data loading and normalization
# ---------------------------------------------------------------------------
def normalize_dataframe(path: str) -> pd.DataFrame:
    df = pd.read_csv(path)
    df.columns = [_canon(c) for c in df.columns]

    rename_map = {"time_ms": "time_mean_ms"}
    df = df.rename(columns={c: rename_map.get(c, c) for c in df.columns})

    if "road_length" not in df.columns:
        raise ValueError("CSV inválido: falta la columna road_length")

    for col in df.columns:
        if col == "road_length":
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("Int64")
        else:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    df = df.sort_values("road_length").reset_index(drop=True)

    # Ensure expected columns exist
    for col in ("time_mean_ms", "time_std_ms", "avg_velocity",
                "throughput_mcells_s", "ipc", "peak_heap_mb"):
        if col not in df.columns:
            df[col] = math.nan

    df["theoretical_heap_mb"] = df["road_length"].apply(
        lambda n: theoretical_heap_mb(int(n)) if pd.notna(n) else math.nan
    )
    df["heap_ratio_pct"] = 100.0 * df["peak_heap_mb"] / df["theoretical_heap_mb"]
    df["timing_cv_pct"]  = 100.0 * df["time_std_ms"] / df["time_mean_ms"]

    return df

# ---------------------------------------------------------------------------
# Raw report parsers
# ---------------------------------------------------------------------------
def parse_timing_traffic(raw_dir: str) -> dict[str, Any]:
    """Reads timing_ms.txt and timing_vel.txt written by bench_profiling.sh."""
    ms_vals, vel_vals = [], []

    for line in _read(os.path.join(raw_dir, "timing_ms.txt")).splitlines():
        line = line.strip()
        if line:
            try: ms_vals.append(float(line))
            except ValueError: pass

    for line in _read(os.path.join(raw_dir, "timing_vel.txt")).splitlines():
        line = line.strip()
        if line:
            try: vel_vals.append(float(line))
            except ValueError: pass

    if not ms_vals:
        return {"values": [], "vel_values": [], "count": 0,
                "mean_ms": math.nan, "std_ms": math.nan,
                "min_ms": math.nan, "max_ms": math.nan,
                "median_ms": math.nan, "cv_pct": math.nan,
                "mean_vel": math.nan, "std_vel": math.nan}

    mean  = statistics.mean(ms_vals)
    std   = statistics.stdev(ms_vals) if len(ms_vals) > 1 else 0.0
    mean_vel = statistics.mean(vel_vals) if vel_vals else math.nan
    std_vel  = statistics.stdev(vel_vals) if len(vel_vals) > 1 else 0.0

    return {
        "values":    ms_vals,
        "vel_values": vel_vals,
        "count":     len(ms_vals),
        "mean_ms":   mean,
        "std_ms":    std,
        "min_ms":    min(ms_vals),
        "max_ms":    max(ms_vals),
        "median_ms": statistics.median(ms_vals),
        "cv_pct":    100.0 * std / mean if mean else math.nan,
        "mean_vel":  mean_vel,
        "std_vel":   std_vel,
    }

def parse_gprof_flat(path: str, top_k: int = 8) -> dict[str, Any]:
    text = _read(path)
    if not text:
        return {"sample_seconds": math.nan, "top": []}

    m = re.search(r"Each sample counts as\s+([\d.]+)\s+seconds", text)
    sample_seconds = float(m.group(1)) if m else math.nan

    in_flat, rows = False, []
    for line in text.splitlines():
        if line.strip().startswith("Flat profile"):
            in_flat = True; continue
        if in_flat and line.strip().startswith("%"): continue
        if in_flat and not line.strip(): continue
        if in_flat and line.startswith("\f"): break
        if not in_flat: continue
        parts = line.split()
        if len(parts) < 7: continue
        try:
            pct_time     = float(parts[0])
            cumulative   = float(parts[1])
            self_seconds = float(parts[2])
        except ValueError:
            continue
        calls = int(parts[3]) if parts[3].isdigit() else None
        name  = parts[-1]
        rows.append({"name": name, "pct_time": pct_time,
                     "cumulative_s": cumulative, "self_s": self_seconds,
                     "calls": calls})

    return {"sample_seconds": sample_seconds, "top": rows[:top_k]}

def parse_perf_record(path: str, top_k: int = 8) -> dict[str, Any]:
    text = _read(path)
    if not text:
        return {"samples": 0, "event_count": 0, "top": []}

    m = re.search(r"Samples:\s+(\d+)", text)
    samples = int(m.group(1)) if m else 0
    m = re.search(r"Event count \(approx\.\):\s+([\d,]+)", text)
    event_count = int(m.group(1).replace(",", "")) if m else 0

    rows = []
    for line in text.splitlines():
        if line.lstrip().startswith("#") or not line.strip(): continue
        m = re.match(r"^\s*([\d.]+)%\s+(\S+)\s+(\S+)\s+(\[[^\]]+\])\s+(.+?)\s*$", line)
        if m:
            rows.append({"overhead_pct": float(m.group(1)), "command": m.group(2),
                         "shared_object": m.group(3), "symbol": m.group(5)})

    return {"samples": samples, "event_count": event_count, "top": rows[:top_k]}

def parse_cachegrind(path: str, top_k: int = 8, top_lines: int = 6) -> dict[str, Any]:
    text = _read(path)
    if not text:
        return {"total_ir": 0, "top_functions": [], "hot_lines": []}

    total_ir = 0
    m = re.search(r"^\s*([\d,]+)\s+\(100\.0%\)\s+PROGRAM TOTALS", text, re.MULTILINE)
    if m:
        total_ir = int(m.group(1).replace(",", ""))

    top_functions, in_func = [], False
    for line in text.splitlines():
        if "-- Function:file summary" in line:
            in_func = True; continue
        if in_func and line.startswith("-- Annotated source file"): break
        if not in_func: continue
        m = re.match(r"^>\s*([\d,]+)\s+\(([\\d.]+)%.*?\)\s+(.+?)\s*$", line.strip())
        if not m:
            m = re.match(r"^\s*([\d,]+)\s+\(([\d.]+)%[^)]*\)\s+(.+?)\s*$", line.strip())
        if m:
            top_functions.append({"ir": int(m.group(1).replace(",", "")),
                                   "pct": float(m.group(2)), "name": m.group(3)})

    hot_lines = []
    for line in text.splitlines():
        m = re.match(r"^\s*([\d,]+)\s+\(([\d.]+)%\)\s+(.+?)\s*$", line)
        if not m: continue
        code = m.group(3).strip()
        if not code or code == "." or code.startswith("--") or code.startswith("Unannotated"):
            continue
        hot_lines.append({"ir": int(m.group(1).replace(",", "")),
                          "pct": float(m.group(2)), "code": code})

    hot_lines = sorted(hot_lines, key=lambda x: x["ir"], reverse=True)[:top_lines]
    return {"total_ir": total_ir,
            "top_functions": top_functions[:top_k],
            "hot_lines": hot_lines}

def parse_massif(path: str) -> dict[str, Any]:
    text = _read(path)
    empty = {"snapshots": 0, "peak_total_b": 0, "peak_useful_b": 0,
             "peak_extra_b": 0, "peak_stacks_b": 0,
             "peak_total_mb": math.nan, "peak_useful_pct": math.nan, "allocators": []}
    if not text:
        return empty

    m = re.search(r"Number of snapshots:\s+(\d+)", text)
    snapshots = int(m.group(1)) if m else 0

    rows = []
    for line in text.splitlines():
        m = re.match(r"^\s*(\d+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)\s+([\d,]+)\s*$", line)
        if m:
            rows.append({"total_b": int(m.group(3).replace(",", "")),
                         "useful_b": int(m.group(4).replace(",", "")),
                         "extra_b":  int(m.group(5).replace(",", "")),
                         "stacks_b": int(m.group(6).replace(",", ""))})

    if not rows:
        return {**empty, "snapshots": snapshots}

    peak = max(rows, key=lambda x: x["total_b"])
    peak_mb  = peak["total_b"] / 1024 / 1024
    peak_pct = 100.0 * peak["useful_b"] / peak["total_b"] if peak["total_b"] else math.nan

    return {"snapshots": snapshots,
            "peak_total_b":   peak["total_b"],
            "peak_useful_b":  peak["useful_b"],
            "peak_extra_b":   peak["extra_b"],
            "peak_stacks_b":  peak["stacks_b"],
            "peak_total_mb":  peak_mb,
            "peak_useful_pct": peak_pct,
            "allocators": []}

def collect_raw(df: pd.DataFrame) -> dict[int, dict[str, Any]]:
    results: dict[int, dict[str, Any]] = {}
    for n in df["road_length"].dropna().astype(int).tolist():
        d = os.path.join(RAW_DIR, f"N{n}")
        results[n] = {
            "timing":       parse_timing_traffic(d),
            "gprof":        parse_gprof_flat(os.path.join(d, "gprof_report.txt")),
            "perf_record":  parse_perf_record(os.path.join(d, "perf_record_report.txt")),
            "cachegrind":   parse_cachegrind(os.path.join(d, "cachegrind_report.txt")),
            "massif":       parse_massif(os.path.join(d, "massif_report.txt")),
            "perf_stat_txt": _read(os.path.join(d, "perf_stat.txt")),
        }
    return results

# ---------------------------------------------------------------------------
# Charts
# ---------------------------------------------------------------------------
def chart_performance(df: pd.DataFrame) -> str:
    sizes  = df["road_length"].astype(int).tolist()
    labels = [f"N={n:,}" for n in sizes]

    fig, axs = plt.subplots(2, 2, figsize=(13, 8))

    axs[0, 0].errorbar(sizes, df["time_mean_ms"], yerr=df["time_std_ms"],
                       marker="o", lw=2.4, capsize=4, color="#2E75B6")
    axs[0, 0].set_title("Tiempo medio de ejecución")
    axs[0, 0].set_ylabel("ms")

    if "throughput_mcells_s" in df.columns and df["throughput_mcells_s"].notna().any():
        axs[0, 1].plot(sizes, df["throughput_mcells_s"], marker="o", lw=2.4, color="#1F9EB7")
        annotate_points(axs[0, 1], sizes, df["throughput_mcells_s"], d=2)
    axs[0, 1].set_title("Throughput secuencial")
    axs[0, 1].set_ylabel("Mcells/s")

    axs[1, 0].plot(sizes, df["ipc"], marker="D", lw=2.4, color="#7030A0")
    axs[1, 0].axhline(1.0, color="#BBBBBB", lw=1, ls="--")
    axs[1, 0].axhline(2.0, color="#BBBBBB", lw=1, ls="--")
    annotate_points(axs[1, 0], sizes, df["ipc"])
    axs[1, 0].set_title("Eficiencia del pipeline (IPC)")
    axs[1, 0].set_ylabel("IPC")

    axs[1, 1].plot(sizes, df["peak_heap_mb"], marker="o", lw=2.4,
                   color="#70AD47", label="Massif (medido)")
    axs[1, 1].plot(sizes, df["theoretical_heap_mb"], marker="s", lw=2.0,
                   ls="--", color="#7F7F7F", label="Teórico (2×N×4 B)")
    axs[1, 1].set_title("Memoria pico heap")
    axs[1, 1].set_ylabel("MB")
    axs[1, 1].legend()

    for ax in axs.flat:
        ax.set_xlabel("N (road length)")
        ax.set_xticks(sizes)
        ax.set_xticklabels(labels, rotation=20, ha="right")

    fig.suptitle("Resumen de rendimiento y memoria — autómata secuencial",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save_figure(fig, "01_performance_summary.png")

def chart_velocity(df: pd.DataFrame) -> str:
    """avg_velocity vs road_length — unique to the traffic automaton."""
    sizes  = df["road_length"].astype(int).tolist()
    labels = [f"N={n:,}" for n in sizes]

    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.plot(sizes, df["avg_velocity"], marker="o", lw=2.4, color="#ED7D31")
    ax.fill_between(sizes, df["avg_velocity"], alpha=0.12, color="#ED7D31")
    annotate_points(ax, sizes, df["avg_velocity"], d=4)
    ax.set_title("Velocidad media asintótica vs tamaño de carretera (ρ=0.50)")
    ax.set_xlabel("N (road length)")
    ax.set_ylabel("v̄ (fracción de carros que avanzan)")
    ax.set_xticks(sizes)
    ax.set_xticklabels(labels, rotation=20, ha="right")
    ax.set_ylim(0, 1.05)
    ax.axhline(0.5, color="#BBBBBB", lw=1, ls="--")
    fig.tight_layout()
    return save_figure(fig, "02_avg_velocity.png")

def chart_miss_rates(df: pd.DataFrame) -> str:
    sizes  = df["road_length"].astype(int).tolist()
    labels = [f"N={n:,}" for n in sizes]
    fig, axs = plt.subplots(2, 2, figsize=(13, 8))

    charts = [
        ("cache_miss_pct",  "Cache misses globales", "#C00000"),
        ("l1_miss_pct",     "L1-D miss rate",        "#ED7D31"),
        ("dtlb_miss_pct",   "dTLB miss rate",        "#2F5597"),
        ("branch_miss_pct", "Branch miss rate",      "#9E480E"),
    ]
    for ax, (col, title, color) in zip(axs.flat, charts):
        if col in df.columns and df[col].notna().any():
            ax.plot(sizes, df[col], marker="o", lw=2.2, color=color)
            annotate_points(ax, sizes, df[col], d=2)
        ax.set_title(title)
        ax.set_ylabel("%")
        ax.set_xticks(sizes)
        ax.set_xticklabels(labels, rotation=20, ha="right")

    fig.suptitle("Tasas de fallo por nivel de jerarquía de memoria",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save_figure(fig, "03_miss_rates.png")

def chart_counters(df: pd.DataFrame) -> str:
    sizes  = df["road_length"].astype(int).tolist()
    labels = [f"N={n:,}" for n in sizes]
    fig, axs = plt.subplots(2, 2, figsize=(13, 8))

    if "instructions" in df.columns and df["instructions"].notna().any():
        axs[0, 0].plot(sizes, df["instructions"] / 1e9, marker="o", lw=2.3, color="#2E75B6")
        axs[0, 0].set_title("Instructions")
        axs[0, 0].set_ylabel("Billion")

    if "cycles" in df.columns and df["cycles"].notna().any():
        axs[0, 1].plot(sizes, df["cycles"] / 1e9, marker="o", lw=2.3, color="#7030A0")
        axs[0, 1].set_title("Cycles")
        axs[0, 1].set_ylabel("Billion")

    if "cache_refs" in df.columns and df["cache_refs"].notna().any():
        axs[1, 0].plot(sizes, df["cache_refs"] / 1e9, marker="o", lw=2.3, color="#C00000")
        axs[1, 0].set_title("Cache references")
        axs[1, 0].set_ylabel("Billion")

    if "llc_miss_pct" in df.columns and df["llc_miss_pct"].notna().any():
        axs[1, 1].plot(sizes, df["llc_miss_pct"], marker="o", lw=2.3, color="#70AD47")
        annotate_points(axs[1, 1], sizes, df["llc_miss_pct"], d=2)
        axs[1, 1].set_title("LLC miss rate (clave para predicción de speedup)")
        axs[1, 1].set_ylabel("%")

    for ax in axs.flat:
        ax.set_xlabel("N")
        ax.set_xticks(sizes)
        ax.set_xticklabels(labels, rotation=20, ha="right")

    fig.suptitle("Contadores de hardware — volumen de trabajo",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save_figure(fig, "04_counter_trends.png")

def _barh(ax, rows, label_key, value_key, title, color):
    if not rows:
        ax.text(0.5, 0.5, "Sin datos", ha="center", va="center", fontsize=11)
        ax.axis("off"); return
    rows = rows[:5]
    labels = [str(r[label_key])[:34] for r in rows][::-1]
    values = [float(r[value_key]) for r in rows][::-1]
    bars = ax.barh(labels, values, color=color)
    mx = max(values) if values else 1
    for bar, val in zip(bars, values):
        ax.text(bar.get_width() + mx * 0.02, bar.get_y() + bar.get_height() / 2,
                f"{val:.2f}", va="center", fontsize=8)
    ax.set_title(title)
    ax.set_xlabel("%")

def chart_hotspots(df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> str:
    largest_n = int(df["road_length"].max())
    gprof_rows = raw.get(largest_n, {}).get("gprof", {}).get("top", [])
    perf_rows  = raw.get(largest_n, {}).get("perf_record", {}).get("top", [])
    cache_rows = raw.get(largest_n, {}).get("cachegrind", {}).get("top_functions", [])

    fig, axs = plt.subplots(1, 3, figsize=(17, 5.6))
    _barh(axs[0], gprof_rows, "name",   "pct_time",     f"gprof (N={largest_n:,})",      "#C00000")
    _barh(axs[1], perf_rows,  "symbol", "overhead_pct", "perf record",                   "#2E75B6")
    _barh(axs[2], cache_rows, "name",   "pct",          "cachegrind instruction share",  "#70AD47")

    fig.suptitle("Hotspots del caso más grande — justificación del #pragma omp",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save_figure(fig, "05_hotspots.png")

def chart_timing_variability(df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> str:
    largest_n = int(df["road_length"].max())
    timing = raw.get(largest_n, {}).get("timing", {})
    values = timing.get("values", [])

    fig, axs = plt.subplots(1, 2, figsize=(12, 4.8))
    if values:
        xs = list(range(1, len(values) + 1))
        axs[0].plot(xs, values, marker="o", lw=2.1, color="#2E75B6")
        axs[0].axhline(statistics.mean(values), color="#C00000", lw=1.2, ls="--",
                       label=f"mean={statistics.mean(values):.3f} ms")
        axs[0].legend(fontsize=9)
        axs[0].set_title(f"Corridas de tiempo (N={largest_n:,})")
        axs[0].set_xlabel("Run"); axs[0].set_ylabel("ms")
        axs[1].boxplot(values, vert=True, patch_artist=True,
                       boxprops=dict(facecolor="#DCE6F1"))
        axs[1].scatter([1] * len(values), values, color="#2E75B6", alpha=0.75)
        axs[1].set_title("Dispersión temporal")
        axs[1].set_ylabel("ms")
        axs[1].set_xticks([1])
        axs[1].set_xticklabels([f"N={largest_n:,}"])
    else:
        for ax in axs:
            ax.text(0.5, 0.5, "Sin timing_ms.txt", ha="center", va="center", fontsize=12)
            ax.axis("off")

    fig.suptitle("Variabilidad de corridas — estabilidad experimental",
                 fontsize=14, fontweight="bold")
    fig.tight_layout()
    return save_figure(fig, "06_timing_variability.png")

def build_chart_pack(df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> list[str]:
    os.makedirs(CHARTS_DIR, exist_ok=True)
    paths = [
        chart_performance(df),
        chart_velocity(df),
        chart_miss_rates(df),
        chart_counters(df),
        chart_hotspots(df, raw),
        chart_timing_variability(df, raw),
    ]
    return [p for p in paths if p and os.path.exists(p)]

# ---------------------------------------------------------------------------
# Excel workbook
# ---------------------------------------------------------------------------
def _write_overview(wb: Workbook, df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> None:
    ws = wb.create_sheet("Overview")
    _title_row(ws, "Profiling Report — Traffic Automaton Sequential Implementation", 4)

    for col, w in enumerate([28, 22, 30, 60], 1):
        _set_width(ws, col, w)

    for col, label in enumerate(["Indicador", "Contexto", "Valor", "Interpretación"], 1):
        _hcell(ws.cell(3, col), label, "blue")
    ws.freeze_panes = "A4"

    largest_n = int(df["road_length"].max())
    last  = df[df["road_length"] == largest_n].iloc[0]
    timing = raw.get(largest_n, {}).get("timing", {})
    gprof_top = raw.get(largest_n, {}).get("gprof", {}).get("top", [])
    perf_top  = raw.get(largest_n, {}).get("perf_record", {}).get("top", [])
    cache_top = raw.get(largest_n, {}).get("cachegrind", {}).get("top_functions", [])
    massif    = raw.get(largest_n, {}).get("massif", {})

    rows_data = []
    if df["throughput_mcells_s"].notna().any():
        best = df.loc[df["throughput_mcells_s"].idxmax()]
        rows_data.append(("Mejor throughput", f"N={int(best['road_length']):,}",
                          f"{_fn(best['throughput_mcells_s'], 2)} Mcells/s",
                          "Relación N×steps / tiempo de medición."))
    if df["ipc"].notna().any():
        best = df.loc[df["ipc"].idxmax()]
        rows_data.append(("Mejor IPC", f"N={int(best['road_length']):,}",
                          f"{_fn(best['ipc'], 4)} ({_classify_ipc(_sf(best['ipc']))})",
                          "Fracción de instrucciones retiradas por ciclo."))
    if df["peak_heap_mb"].notna().any():
        best = df.loc[df["peak_heap_mb"].idxmax()]
        rows_data.append(("Mayor heap pico", f"N={int(best['road_length']):,}",
                          f"{_fn(best['peak_heap_mb'], 3)} MB",
                          "Debe ser ≈ teórico = 2×N×4 B."))
    if timing.get("count", 0):
        rows_data.append(("Variabilidad temporal", f"N={largest_n:,} ({timing['count']} runs)",
                          f"CV={_fp(timing['cv_pct'])} | rango={_fn(timing['min_ms'])}–{_fn(timing['max_ms'])} ms",
                          "CV < 5% indica condiciones experimentales estables."))
    if timing.get("mean_vel") is not None and not math.isnan(_sf(timing.get("mean_vel"))):
        rows_data.append(("Velocidad media (ρ=0.50)", f"N={largest_n:,}",
                          f"v̄={_fn(timing['mean_vel'], 4)} ± {_fn(timing['std_vel'], 4)}",
                          "Coherencia entre repeticiones valida que se alcanzó estado estacionario."))
    if gprof_top:
        rows_data.append(("Hotspot gprof", f"N={largest_n:,}",
                          f"{gprof_top[0]['name']} → {_fp(gprof_top[0]['pct_time'])}",
                          "Función dominante que justifica la región #pragma omp."))
    if perf_top:
        rows_data.append(("Hotspot perf record", f"N={largest_n:,}",
                          f"{perf_top[0]['symbol']} → {_fp(perf_top[0]['overhead_pct'])}",
                          "Confirmación por muestreo estadístico."))
    if cache_top:
        rows_data.append(("Hotspot cachegrind", f"N={largest_n:,}",
                          f"{cache_top[0]['name']} → {_fp(cache_top[0]['pct'])}",
                          "Distribución de instrucciones ejecutadas."))
    if massif:
        rows_data.append(("Massif peak", f"N={largest_n:,}",
                          f"{_fn(massif.get('peak_total_mb'), 3)} MB | heap útil={_fp(massif.get('peak_useful_pct'))}",
                          "Ausencia de fugas y overhead de allocator mínimo esperado."))
    if "llc_miss_pct" in df.columns and df["llc_miss_pct"].notna().any():
        row_max = df.loc[df["llc_miss_pct"].idxmax()]
        rows_data.append(("LLC miss rate máximo", f"N={int(row_max['road_length']):,}",
                          _fp(row_max["llc_miss_pct"]),
                          "A medida que N supera la LLC, el cuello de botella cambia de cómputo a ancho de banda."))

    r = 4
    for label, ctx, val, note in rows_data:
        bg = "alt" if r % 2 == 0 else "white"
        _dcell(ws.cell(r, 1), label, bg=bg, align="left", bold=True)
        _dcell(ws.cell(r, 2), ctx,   bg=bg, align="center")
        _dcell(ws.cell(r, 3), val,   bg=bg, align="center")
        _dcell(ws.cell(r, 4), note,  bg=bg, align="left")
        r += 1

    r += 1
    _title_row(ws, "Per-size quick view", 7, row=r)
    r += 1

    headers = ["N", "Time mean (ms)", "Std (ms)", "Throughput (Mcells/s)",
               "IPC", "LLC miss %", "Heap peak (MB)"]
    for i, h in enumerate(headers, 1):
        _hcell(ws.cell(r, i), h, "cyan")
    r += 1

    for _, row in df.iterrows():
        bg = "alt" if r % 2 == 0 else "white"
        vals = [
            int(row["road_length"]),
            _sf(row.get("time_mean_ms")),
            _sf(row.get("time_std_ms")),
            _sf(row.get("throughput_mcells_s")),
            _sf(row.get("ipc")),
            _sf(row.get("llc_miss_pct")),
            _sf(row.get("peak_heap_mb")),
        ]
        fmts = ["#,##0", "0.000", "0.000", "0.000000", "0.0000", "0.00", "0.000"]
        for ci, (v, f) in enumerate(zip(vals, fmts), 1):
            _dcell(ws.cell(r, ci), v, fmt=f, bg=bg, align="center" if ci == 1 else "right")
        r += 1

def _write_metrics(wb: Workbook, df: pd.DataFrame) -> None:
    ws = wb.create_sheet("Metrics")
    _title_row(ws, "All Metrics from data_profiling.csv", len(df.columns))
    ws.freeze_panes = "A3"
    for ci, col in enumerate(df.columns, 1):
        _hcell(ws.cell(2, ci), col, "blue")
        _set_width(ws, ci, max(12, min(22, len(col) + 2)))
    for ri, row in enumerate(df.itertuples(index=False), 3):
        bg = "alt" if ri % 2 == 0 else "white"
        for ci, col in enumerate(df.columns, 1):
            val = getattr(row, col)
            if col == "road_length":
                _dcell(ws.cell(ri, ci), _si(val), fmt="#,##0", bg=bg, align="center")
            elif not pd.isna(val):
                fmt = "0.00" if "pct" in col else ("#,##0" if any(k in col for k in ["instructions", "cycles", "refs", "misses"]) else "0.000")
                _dcell(ws.cell(ri, ci), float(val), fmt=fmt, bg=bg)
            else:
                _dcell(ws.cell(ri, ci), "—", bg=bg, align="center")

def _write_raw_summary(wb: Workbook, df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> None:
    ws = wb.create_sheet("Raw Summary")
    headers = ["N", "Timing runs", "Mean (ms)", "Std (ms)", "CV %",
               "Mean velocity", "gprof top fn", "gprof %",
               "perf top sym", "perf %", "cachegrind top", "cachegrind %",
               "cachegrind Ir", "massif peak MB", "massif useful %"]
    _title_row(ws, "Summaries parsed from raw reports", len(headers))
    ws.freeze_panes = "A3"
    widths = [10, 12, 14, 12, 10, 14, 30, 10, 32, 10, 34, 12, 18, 16, 14]
    for i, (h, w) in enumerate(zip(headers, widths), 1):
        _hcell(ws.cell(2, i), h, "blue")
        _set_width(ws, i, w)

    r = 3
    for n in df["road_length"].astype(int).tolist():
        entry   = raw.get(n, {})
        timing  = entry.get("timing", {})
        gprof   = entry.get("gprof", {}).get("top", [])
        perf    = entry.get("perf_record", {}).get("top", [])
        cache   = entry.get("cachegrind", {})
        massif  = entry.get("massif", {})
        cache_top = cache.get("top_functions", [])

        bg = "alt" if r % 2 == 0 else "white"
        values = [
            n, timing.get("count", 0), timing.get("mean_ms", math.nan),
            timing.get("std_ms", math.nan), timing.get("cv_pct", math.nan),
            timing.get("mean_vel", math.nan),
            gprof[0]["name"] if gprof else "—", gprof[0]["pct_time"] if gprof else math.nan,
            perf[0]["symbol"] if perf else "—", perf[0]["overhead_pct"] if perf else math.nan,
            cache_top[0]["name"] if cache_top else "—", cache_top[0]["pct"] if cache_top else math.nan,
            cache.get("total_ir", 0),
            massif.get("peak_total_mb", math.nan), massif.get("peak_useful_pct", math.nan),
        ]
        fmts = ["#,##0", "0", "0.000", "0.000", "0.00", "0.000000",
                None, "0.00", None, "0.00", None, "0.00", "#,##0", "0.000", "0.00"]
        for ci, (val, fmt) in enumerate(zip(values, fmts), 1):
            if isinstance(val, str):
                _dcell(ws.cell(r, ci), val, bg=bg, align="left")
            elif fmt:
                _dcell(ws.cell(r, ci), val, fmt=fmt, bg=bg, align="center" if ci <= 2 else "right")
            else:
                _dcell(ws.cell(r, ci), val, bg=bg)
        r += 1

def _write_hot_lines(wb: Workbook, df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> None:
    ws = wb.create_sheet("Hot Lines")
    _title_row(ws, "Top annotated source lines from cachegrind", 4)
    ws.freeze_panes = "A3"
    for i, (h, w) in enumerate(zip(["N", "Ir", "Share %", "Source line"], [10, 18, 12, 95]), 1):
        _hcell(ws.cell(2, i), h, "blue")
        _set_width(ws, i, w)

    r = 3
    for n in df["road_length"].astype(int).tolist():
        hot = raw.get(n, {}).get("cachegrind", {}).get("hot_lines", [])
        if not hot:
            bg = "alt" if r % 2 == 0 else "white"
            _dcell(ws.cell(r, 1), n, fmt="#,##0", bg=bg, align="center")
            for ci in (2, 3):
                _dcell(ws.cell(r, ci), "—", bg=bg, align="center")
            _dcell(ws.cell(r, 4), "Sin líneas anotadas (N > VALGRIND_MAX_N)", bg=bg, align="left")
            r += 1; continue
        for item in hot:
            bg = "alt" if r % 2 == 0 else "white"
            _dcell(ws.cell(r, 1), n,           fmt="#,##0", bg=bg, align="center")
            _dcell(ws.cell(r, 2), item["ir"],   fmt="#,##0", bg=bg)
            _dcell(ws.cell(r, 3), item["pct"],  fmt="0.00",  bg=bg)
            _dcell(ws.cell(r, 4), item["code"], bg=bg, align="left")
            r += 1

def _write_analysis_notes(wb: Workbook, df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> None:
    ws = wb.create_sheet("Analysis Notes")
    _title_row(ws, "Auto-generated interpretation notes", 3)
    for i, w in enumerate([28, 22, 84], 1):
        _set_width(ws, i, w)
    for i, h in enumerate(["Tema", "Contexto", "Comentario"], 1):
        _hcell(ws.cell(2, i), h, "blue")

    largest_n = int(df["road_length"].max())
    last  = df[df["road_length"] == largest_n].iloc[0]
    timing = raw.get(largest_n, {}).get("timing", {})
    gprof_top = raw.get(largest_n, {}).get("gprof", {}).get("top", [])
    perf_top  = raw.get(largest_n, {}).get("perf_record", {}).get("top", [])
    cache_top = raw.get(largest_n, {}).get("cachegrind", {}).get("top_functions", [])
    massif    = raw.get(largest_n, {}).get("massif", {})

    notes = [
        ("Modelo de acceso", "Autómata 1D",
         "El bucle principal accede a cells[] y next_cells[] de forma estrictamente secuencial. "
         "El patrón es ideal para el prefetcher de hardware: L1 miss rate esperada < 2%."),
        ("Working set", "Función de N",
         "El working set es 2×N×4 bytes. Para N=8k es 64 KB (cabe en L1), "
         "para N=2M es 16 MB (supera L3 → limitado por ancho de banda DRAM)."),
        ("Paralelizabilidad", "compute_next_generation",
         "Las iteraciones son completamente independientes (cells[] solo lectura, next_cells[] solo escritura). "
         "La ausencia de dependencias de datos hace el bucle apto para #pragma omp parallel for."),
        ("IPC", f"N={largest_n:,}",
         f"IPC={_fn(last.get('ipc'), 4)} → {_classify_ipc(_sf(last.get('ipc')))}. "
         "El kernel es aritméticamante simple (2 operaciones lógicas + 3 lecturas + 1 escritura por celda). "
         "IPC bajo indica que el pipeline espera por datos de memoria, no por operaciones aritméticas."),
        ("LLC miss rate", f"N={largest_n:,}",
         f"LLC miss={_fp(last.get('llc_miss_pct'))} → {_classify_miss(_sf(last.get('llc_miss_pct')))}. "
         "Para N donde el working set supera la LLC, este valor sube e indica que el speedup OpenMP "
         "estará limitado por el ancho de banda del bus de memoria, no por el número de núcleos."),
    ]

    if timing.get("count", 0):
        notes.append(("Estabilidad", f"N={largest_n:,}",
                      f"Media={_fn(timing.get('mean_ms'), 3)} ms, std={_fn(timing.get('std_ms'), 3)} ms, "
                      f"CV={_fp(timing.get('cv_pct'))}. CV < 5% es criterio de medición válida."))
    if timing.get("mean_vel") and not math.isnan(_sf(timing.get("mean_vel"))):
        notes.append(("Velocidad asintótica", "ρ=0.50",
                      f"v̄={_fn(timing['mean_vel'], 4)} ± {_fn(timing['std_vel'], 4)}. "
                      "El modelo predice v̄ ≈ 0.5 para ρ=0.5 en el punto de transición de fase. "
                      "Consistencia entre repeticiones confirma que el calentamiento alcanzó estado estacionario."))
    if gprof_top:
        notes.append(("gprof hotspot", f"N={largest_n:,}",
                      f"{gprof_top[0]['name']} concentra {_fp(gprof_top[0]['pct_time'])} del tiempo muestral. "
                      "Es la función objetivo para la directiva OpenMP."))
    if perf_top:
        notes.append(("perf record", f"N={largest_n:,}",
                      f"Símbolo más pesado: {perf_top[0]['symbol']} con {_fp(perf_top[0]['overhead_pct'])} de overhead."))
    if cache_top:
        notes.append(("cachegrind", f"N={largest_n:,}",
                      f"Por conteo de instrucciones: {cache_top[0]['name']} con {_fp(cache_top[0]['pct'])}. "
                      "Coherente con gprof: ambas herramientas señalan el mismo punto de calor."))
    if massif:
        notes.append(("Massif", f"N={largest_n:,}",
                      f"Peak heap={_fn(massif.get('peak_total_mb'), 3)} MB; útil={_fp(massif.get('peak_useful_pct'))}. "
                      "El teórico es {_fn(theoretical_heap_mb(largest_n), 3)} MB (2×N×4 B). "
                      "Ratio cercano a 100% confirma que no hay sobreasignación ni estructuras auxiliares."))

    r = 3
    for topic, ctx, note in notes:
        bg = "alt" if r % 2 == 0 else "white"
        _dcell(ws.cell(r, 1), topic, bg=bg, align="left", bold=True)
        _dcell(ws.cell(r, 2), ctx,   bg=bg, align="center")
        _dcell(ws.cell(r, 3), note,  bg=bg, align="left")
        r += 1

def _write_charts_sheet(wb: Workbook, chart_paths: list[str]) -> None:
    ws = wb.create_sheet("Charts")
    _title_row(ws, "Visual report", 20)
    anchors = ["A3", "L3", "A28", "L28", "A53", "L53"]
    for anchor, path in zip(anchors, chart_paths):
        if not os.path.exists(path): continue
        img = XLImage(path)
        img.width = 760; img.height = 430
        ws.add_image(img, anchor)

def build_workbook(df: pd.DataFrame, raw: dict[int, dict[str, Any]], chart_paths: list[str]) -> None:
    wb = Workbook()
    wb.remove(wb.active)
    _write_overview(wb, df, raw)
    _write_metrics(wb, df)
    _write_raw_summary(wb, df, raw)
    _write_hot_lines(wb, df, raw)
    _write_analysis_notes(wb, df, raw)
    _write_charts_sheet(wb, chart_paths)
    wb.save(XLSX_PATH)

# ---------------------------------------------------------------------------
# LaTeX table
# ---------------------------------------------------------------------------
def build_latex_table(df: pd.DataFrame) -> None:
    lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Caracterización de la implementación secuencial del autómata de tráfico ($\rho=0.50$)}",
        r"\label{tab:profiling_seq}",
        r"\begin{tabular}{rrrrrrrr}",
        r"\toprule",
        r"$N$ & $t_\mu$ (ms) & $t_\sigma$ (ms) & Mcells/s & IPC & "
        r"L1 miss \% & LLC miss \% & Heap (MB) \\",
        r"\midrule",
    ]
    for _, row in df.iterrows():
        lines.append(
            f"{int(row['road_length']):,} & "
            f"{_sf(row.get('time_mean_ms')):.3f} & "
            f"{_sf(row.get('time_std_ms')):.3f} & "
            f"{_sf(row.get('throughput_mcells_s')):.3f} & "
            f"{_sf(row.get('ipc')):.4f} & "
            f"{_sf(row.get('l1_miss_pct')):.2f} & "
            f"{_sf(row.get('llc_miss_pct')):.2f} & "
            f"{_sf(row.get('peak_heap_mb')):.3f} \\\\"
        )
    lines += [r"\bottomrule", r"\end{tabular}", r"\end{table}"]
    with open(LATEX_PATH, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

# ---------------------------------------------------------------------------
# HTML report
# ---------------------------------------------------------------------------
CSS = """
:root{--bg:#f4f7fb;--surface:#fff;--text:#1f2a36;--muted:#5d6b79;
      --border:#d8e1ea;--primary:#1f3557;--accent:#2e75b6;
      --shadow:0 10px 30px rgba(31,53,87,.08)}
*{box-sizing:border-box}
body{margin:0;font-family:"Inter","Segoe UI",Arial,sans-serif;color:var(--text);
     background:linear-gradient(180deg,#f8fbff 0%,var(--bg) 100%);line-height:1.55}
.container{width:min(1380px,94vw);margin:0 auto;padding:32px 0 48px}
.hero{background:linear-gradient(135deg,#1f3557,#2e75b6);color:#fff;border-radius:22px;
      padding:36px;box-shadow:var(--shadow);margin-bottom:26px}
.hero h1{margin:0 0 8px;font-size:2.1rem}
.hero p{margin:0;color:rgba(255,255,255,.88);max-width:82ch}
.badge{background:rgba(255,255,255,.14);border:1px solid rgba(255,255,255,.18);
       padding:6px 10px;border-radius:999px;font-size:.9rem;display:inline-block;margin:4px 4px 0 0}
.grid{display:grid;gap:18px}
.kpis{grid-template-columns:repeat(auto-fit,minmax(220px,1fr));margin-bottom:24px}
.two{grid-template-columns:repeat(auto-fit,minmax(420px,1fr));margin-bottom:24px}
.charts{grid-template-columns:repeat(auto-fit,minmax(480px,1fr))}
.card{background:var(--surface);border:1px solid var(--border);border-radius:18px;
      box-shadow:var(--shadow);padding:20px}
.kpi-label{font-size:.8rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin-bottom:8px}
.kpi-value{font-size:1.4rem;font-weight:700;color:var(--primary);margin-bottom:4px}
.kpi-note{color:var(--muted);font-size:.94rem}
h2,h3{margin-top:0;color:var(--primary)}
table{width:100%;border-collapse:collapse;font-size:.94rem}
th,td{padding:10px 12px;border-bottom:1px solid var(--border);text-align:left;vertical-align:top}
th{background:#f9fbfd;color:var(--primary)}
.chart-card img{width:100%;height:auto;border-radius:12px;display:block}
code{font-family:"JetBrains Mono","Consolas",monospace;white-space:pre-wrap}
.section{margin-top:26px}
"""

def build_html_report(df: pd.DataFrame, raw: dict[int, dict[str, Any]], chart_paths: list[str]) -> None:
    largest_n = int(df["road_length"].max())
    last = df[df["road_length"] == largest_n].iloc[0]
    timing    = raw.get(largest_n, {}).get("timing", {})
    gprof_top = raw.get(largest_n, {}).get("gprof", {}).get("top", [])
    perf_top  = raw.get(largest_n, {}).get("perf_record", {}).get("top", [])
    cache_top = raw.get(largest_n, {}).get("cachegrind", {}).get("top_functions", [])
    massif    = raw.get(largest_n, {}).get("massif", {})

    def kpi(label, value, note=""):
        return (f'<div class="card kpi"><div class="kpi-label">{html.escape(label)}</div>'
                f'<div class="kpi-value">{html.escape(value)}</div>'
                f'<div class="kpi-note">{html.escape(note)}</div></div>')

    def htable(title, rows, nk, vk):
        if not rows:
            return f'<div class="card"><h3>{html.escape(title)}</h3><p>Sin datos.</p></div>'
        body = "".join(
            f"<tr><td>{html.escape(str(r.get(nk,'—')))}</td>"
            f"<td>{_fp(r.get(vk))}</td></tr>" for r in rows[:8]
        )
        return (f'<div class="card"><h3>{html.escape(title)}</h3>'
                f"<table><thead><tr><th>Función / Símbolo</th><th>Share</th></tr></thead>"
                f"<tbody>{body}</tbody></table></div>")

    sizes_str = ", ".join(f"N={int(n):,}" for n in df["road_length"].tolist())
    cards_html = "".join([
        kpi("Largest N tested", f"N={largest_n:,}",
            f"time={_fn(last.get('time_mean_ms'))} ms | IPC={_fn(last.get('ipc'), 4)}"),
        kpi("Peak throughput", f"{_fn(df['throughput_mcells_s'].max() if 'throughput_mcells_s' in df.columns else math.nan, 2)} Mcells/s",
            "N×steps / wall_time"),
        kpi("Avg velocity (ρ=0.50)", f"{_fn(timing.get('mean_vel'), 4)}",
            f"σ={_fn(timing.get('std_vel'), 4)} | CV={_fp(timing.get('cv_pct'))}"),
        kpi("Peak heap", f"{_fn(massif.get('peak_total_mb'), 3)} MB",
            f"useful={_fp(massif.get('peak_useful_pct'))}"),
    ])

    rows_html = "".join(
        "<tr>" + "".join(
            f"<td>N={int(r['road_length']):,}</td>" if c == "road_length"
            else f"<td>{_fp(r[c])}</td>" if "pct" in c
            else f"<td>{_fn(r[c], 3)}</td>"
            for c in ["road_length", "time_mean_ms", "time_std_ms", "throughput_mcells_s",
                      "avg_velocity", "ipc", "l1_miss_pct", "llc_miss_pct", "peak_heap_mb"]
        ) + "</tr>"
        for _, r in df.iterrows()
    )
    trend_table = (
        "<table><thead><tr>"
        "<th>N</th><th>Time mean (ms)</th><th>Std (ms)</th><th>Mcells/s</th>"
        "<th>v̄</th><th>IPC</th><th>L1 miss%</th><th>LLC miss%</th><th>Heap (MB)</th>"
        "</tr></thead><tbody>" + rows_html + "</tbody></table>"
    )

    imgs_html = "".join(
        f'<figure class="card chart-card">'
        f'<img src="{html.escape(os.path.relpath(p, OUT_DIR).replace(os.sep, "/"))}" loading="lazy"></figure>'
        for p in chart_paths if os.path.exists(p)
    )

    doc = f"""<!DOCTYPE html><html lang="es"><head>
<meta charset="utf-8"><title>Traffic Automaton — Profiling Report</title>
<style>{CSS}</style></head><body><div class="container">
<section class="hero">
  <h1>Traffic Automaton — Sequential Profiling Report</h1>
  <p>Generado desde data_profiling.csv + reportes crudos de gprof, perf, cachegrind, massif.</p>
  <div>{' '.join(f'<span class="badge">{html.escape(s)}</span>' for s in [sizes_str, f"Density=0.50", f"N largest={largest_n:,}"])}</div>
</section>
<section class="grid kpis">{cards_html}</section>
<section class="section card"><h2>Tabla de tendencias</h2>{trend_table}</section>
<section class="section grid two">
  {htable("gprof — funciones dominantes", gprof_top, "name", "pct_time")}
  {htable("perf record — símbolos dominantes", perf_top, "symbol", "overhead_pct")}
  {htable("cachegrind — distribución Ir", cache_top, "name", "pct")}
</section>
<section class="section grid charts">{imgs_html}</section>
</div></body></html>"""

    with open(HTML_PATH, "w", encoding="utf-8") as f:
        f.write(doc)

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------
def print_summary(df: pd.DataFrame, raw: dict[int, dict[str, Any]]) -> None:
    largest_n = int(df["road_length"].max())
    last  = df[df["road_length"] == largest_n].iloc[0]
    timing    = raw.get(largest_n, {}).get("timing", {})
    gprof_top = raw.get(largest_n, {}).get("gprof", {}).get("top", [])
    perf_top  = raw.get(largest_n, {}).get("perf_record", {}).get("top", [])

    print("=" * 60)
    print("  Traffic Automaton — Profiling Report generated")
    print("=" * 60)
    print(f"CSV   : {CSV_PATH}")
    print(f"XLSX  : {XLSX_PATH}")
    print(f"HTML  : {HTML_PATH}")
    print(f"LaTeX : {LATEX_PATH}")
    print(f"Charts: {CHARTS_DIR}")
    print("-" * 60)
    print(f"Largest N       : {largest_n:,}")
    print(f"Time mean (ms)  : {_fn(last.get('time_mean_ms'))}")
    print(f"Throughput      : {_fn(last.get('throughput_mcells_s'), 3)} Mcells/s")
    print(f"Avg velocity    : {_fn(last.get('avg_velocity'), 4)}")
    print(f"IPC             : {_fn(last.get('ipc'), 4)} ({_classify_ipc(_sf(last.get('ipc')))})")
    print(f"L1 miss %       : {_fp(last.get('l1_miss_pct'))}")
    print(f"LLC miss %      : {_fp(last.get('llc_miss_pct'))}")
    print(f"Peak heap (MB)  : {_fn(last.get('peak_heap_mb'))}")
    if timing.get("count", 0):
        print(f"Timing CV %     : {_fp(timing.get('cv_pct'))}")
    if gprof_top:
        print(f"gprof hotspot   : {gprof_top[0]['name']} ({_fp(gprof_top[0]['pct_time'])})")
    if perf_top:
        print(f"perf hotspot    : {perf_top[0]['symbol']} ({_fp(perf_top[0]['overhead_pct'])})")
    print("=" * 60)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def main() -> None:
    os.makedirs(CHARTS_DIR, exist_ok=True)
    df  = normalize_dataframe(CSV_PATH)
    raw = collect_raw(df)
    chart_paths = build_chart_pack(df, raw)
    build_workbook(df, raw, chart_paths)
    build_html_report(df, raw, chart_paths)
    build_latex_table(df)
    print_summary(df, raw)

if __name__ == "__main__":
    main()