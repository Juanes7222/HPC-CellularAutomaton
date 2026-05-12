"""
report.py  --  Traffic Automaton benchmark report generator.

Reads CSVs produced by benchmark.sh and writes:
  - An Excel workbook (reporte_traffic.xlsx) with five analytical sheets
  - PNG table images for each sheet (for document embedding)
  - Comparison charts (time, speedup, scaling)

Expected CSV columns:
  suite, impl, parallelism, road_length, density, repetition,
  wall_time_ms, avg_velocity, throughput_mcells_s

Sheets:
  1. Serial         seq_std vs seq_opt (if present)
  2. OpenMP         seq_std vs omp(2,4,6,8)
  3. Escalabilidad  Speedup + efficiency vs p for each road_length
  4. Correlacion    threads(p) vs processes(p) at same p and N (if MPI/fork present)
  5. Comparacion    Best representative of each strategy

Usage:
    python3 report.py [results_dir]
    Default: results_dir = results/
"""

from __future__ import annotations

import io
import math
import os
import sys
from dataclasses import dataclass

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.table as mpl_table
import pandas as pd
import numpy as np
from openpyxl import Workbook
from openpyxl.drawing.image import Image as XLImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
RESULTS_DIR = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else "results"
OUTPUT_PATH = os.path.join(RESULTS_DIR, "reporte_traffic.xlsx")
CHARTS_DIR  = os.path.join(RESULTS_DIR, "charts")
TABLES_DIR  = os.path.join(RESULTS_DIR, "tables")

SUITE_FILES = {
    "serial": "data_serial.csv",
    "omp":    "data_omp.csv",
    "mpi":    "data_mpi.csv",   # optional
}

IMPL_COLORS: dict[str, str] = {
    "seq_std":  "#2E75B6",
    "seq_opt":  "#C00000",
    "omp_1":    "#BBBBBB",
    "omp_2":    "#70AD47",
    "omp_4":    "#ED7D31",
    "omp_6":    "#4472C4",
    "omp_8":    "#7030A0",
    "mpi_2":    "#BBBBBB",
    "mpi_4":    "#5CB85C",
    "mpi_6":    "#337AB7",
    "mpi_8":    "#F0AD4E",
}

C = {
    "dark":      "1F3557",
    "mid":       "2E75B6",
    "light":     "DCE6F1",
    "alt":       "F4F8FC",
    "green_bg":  "E2F0D9",
    "green_fg":  "2F6B1E",
    "summary_bg":"EBF3FB",
    "summary_fg":"1F4E79",
    "impl_hdr":  "1F4E79",
    "sep":       "D9E1F2",
    "corr_t_bg": "E2EFDA",
    "corr_p_bg": "FCE4D6",
}

CHART_STYLE = {
    "figure.facecolor":  "white",
    "axes.facecolor":    "white",
    "axes.grid":         True,
    "grid.color":        "#E7EDF3",
    "grid.linestyle":    "--",
    "grid.alpha":        0.75,
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "axes.titleweight":  "bold",
    "axes.labelsize":    10,
    "axes.titlesize":    11,
    "legend.frameon":    False,
    "font.size":         10,
}
FONT_NAME = "Calibri"


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------
AllReps = dict["Impl", dict[int, list[tuple[int, float, float, float]]]]
# value tuple: (repetition, wall_time_ms, avg_velocity, throughput_mcells_s)


@dataclass(frozen=True)
class Impl:
    name:        str   # seq_std | seq_opt | omp | mpi
    parallelism: int   # 0 for serial, N threads/procs otherwise

    @property
    def label(self) -> str:
        labels = {
            "seq_std": "Secuencial estándar",
            "seq_opt": "Secuencial optimizado (-O3 full)",
        }
        if self.name in labels:
            return labels[self.name]
        if self.name == "omp":
            return f"OpenMP ({self.parallelism} hilos)"
        if self.name == "mpi":
            return f"MPI ({self.parallelism} procesos)"
        return f"{self.name} ({self.parallelism})"

    @property
    def short_label(self) -> str:
        return self.name if self.parallelism == 0 else f"{self.name}_{self.parallelism}"

    @property
    def color(self) -> str:
        return IMPL_COLORS.get(self.short_label, "#888888")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _size_label(n: int) -> str:
    if n >= 1_000_000 and n % 1_000_000 == 0:
        return f"{n // 1_000_000}M"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000 and n % 1_000 == 0:
        return f"{n // 1_000}K"
    return str(n)

def _fn(x, d=3):
    try:
        f = float(x)
        return "—" if math.isnan(f) else f"{f:,.{d}f}"
    except Exception:
        return "—"

def _fp(x, d=2):
    try:
        f = float(x)
        return "—" if math.isnan(f) else f"{f:.{d}f}%"
    except Exception:
        return "—"

def _mean(vals):
    return sum(vals) / len(vals) if vals else math.nan

def _std(vals):
    if len(vals) < 2: return 0.0
    m = _mean(vals)
    return math.sqrt(sum((v - m) ** 2 for v in vals) / len(vals))

def _cv(vals):
    m = _mean(vals)
    return 100 * _std(vals) / m if m else math.nan


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------
def load_csv(suite: str) -> pd.DataFrame | None:
    path = os.path.join(RESULTS_DIR, SUITE_FILES[suite])
    if not os.path.exists(path):
        print(f"  [--]  {path} not found (skipping)")
        return None
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    df["impl"]               = df["impl"].str.strip()
    df["parallelism"]        = df["parallelism"].astype(int)
    df["road_length"]        = df["road_length"].astype(int)
    df["repetition"]         = df["repetition"].astype(int)
    df["wall_time_ms"]       = df["wall_time_ms"].astype(float)
    df["avg_velocity"]       = df.get("avg_velocity", pd.Series(math.nan, index=df.index)).astype(float)
    df["throughput_mcells_s"]= df.get("throughput_mcells_s", pd.Series(math.nan, index=df.index)).astype(float)
    print(f"  [OK]  {path}  ({len(df)} rows)")
    return df


def build_all_reps(frames: list[pd.DataFrame]) -> AllReps:
    combined = pd.concat(frames, ignore_index=True)
    result: AllReps = {}
    for (name, par), grp in combined.groupby(["impl", "parallelism"]):
        impl = Impl(name=str(name), parallelism=int(str(par)))
        result[impl] = {}
        for size, sub in grp.groupby("road_length"):
            result[impl][int(str(size))] = sorted(
                [(int(r), float(t), float(v), float(tp))
                 for r, t, v, tp in zip(
                     sub["repetition"], sub["wall_time_ms"],
                     sub["avg_velocity"], sub["throughput_mcells_s"])],
                key=lambda x: x[0],
            )
    return result


def compute_avgs(all_reps: AllReps) -> dict[Impl, dict[int, float]]:
    return {
        impl: {s: _mean([t for _, t, _, _ in pairs])
               for s, pairs in sizes.items()}
        for impl, sizes in all_reps.items()
    }


def compute_avg_vel(all_reps: AllReps) -> dict[Impl, dict[int, float]]:
    return {
        impl: {s: _mean([v for _, _, v, _ in pairs])
               for s, pairs in sizes.items()}
        for impl, sizes in all_reps.items()
    }


def compute_avg_tp(all_reps: AllReps) -> dict[Impl, dict[int, float]]:
    return {
        impl: {s: _mean([tp for _, _, _, tp in pairs])
               for s, pairs in sizes.items()}
        for impl, sizes in all_reps.items()
    }


def best_parallel(avg_data, sizes, impl_name, ref) -> "Impl | None":
    ref_avgs = avg_data.get(ref, {})
    if not ref_avgs: return None
    best_impl, best_sp = None, 0.0
    for impl, times in avg_data.items():
        if impl.name != impl_name: continue
        sp_vals = [ref_avgs[s] / times[s] for s in sizes
                   if s in times and s in ref_avgs and times[s] > 0]
        if sp_vals:
            sp = _mean(sp_vals)
            if sp > best_sp:
                best_sp, best_impl = sp, impl
    return best_impl


# ---------------------------------------------------------------------------
# Excel styling helpers
# ---------------------------------------------------------------------------
def _thin_border() -> Border:
    s = Side(style="thin", color="BDD7EE")
    return Border(left=s, right=s, top=s, bottom=s)

def _thick_border() -> Border:
    thick = Side(style="medium", color="1F4E79")
    thin  = Side(style="thin",   color="BDD7EE")
    return Border(left=thick, right=thick, top=thin, bottom=thick)

def _hdr(cell, value, bg=C["mid"], fg="FFFFFF", size=10, bold=True, align="center"):
    cell.value     = value
    cell.font      = Font(name=FONT_NAME, bold=bold, size=size, color=fg)
    cell.fill      = PatternFill("solid", fgColor=bg)
    cell.alignment = Alignment(horizontal=align, vertical="center", wrap_text=True)
    cell.border    = _thin_border()

def _dat(cell, value, fmt=None, bg="FFFFFF", fg="000000", bold=False, align="right"):
    cell.value     = value
    cell.font      = Font(name=FONT_NAME, bold=bold, size=10, color=fg)
    cell.fill      = PatternFill("solid", fgColor=bg)
    cell.alignment = Alignment(horizontal=align, vertical="center")
    cell.border    = _thin_border()
    if fmt: cell.number_format = fmt

def _sdat(cell, value, fmt=None, bold=False):
    _dat(cell, value, fmt=fmt, bg=C["summary_bg"], fg=C["summary_fg"], bold=bold)

def _set_w(ws, col, w):
    ws.column_dimensions[get_column_letter(col)].width = w

def _title_row(ws, text, cols, row=1):
    ws.merge_cells(start_row=row, start_column=1, end_row=row, end_column=cols)
    c = ws.cell(row=row, column=1, value=text)
    c.font      = Font(name=FONT_NAME, bold=True, size=13, color="FFFFFF")
    c.fill      = PatternFill("solid", fgColor=C["dark"])
    c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
    ws.row_dimensions[row].height = 26


# ---------------------------------------------------------------------------
# Chart helpers
# ---------------------------------------------------------------------------
def _save_fig(fig, name: str) -> str:
    os.makedirs(CHARTS_DIR, exist_ok=True)
    path = os.path.join(CHARTS_DIR, name)
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path

def _plot_lines(ax, impls, avg_data, sizes, ylabel, log_scale=False):
    for impl in impls:
        times = avg_data.get(impl, {})
        xs = [s for s in sizes if s in times]
        ys = [times[s] for s in xs]
        if not xs: continue
        ax.plot(xs, ys, marker="o", lw=2.2, color=impl.color, label=impl.short_label)
    if log_scale:
        ax.set_yscale("log")
    ax.set_xticks(sizes)
    ax.set_xticklabels([_size_label(s) for s in sizes], rotation=20, ha="right")
    ax.set_ylabel(ylabel)
    ax.set_xlabel("N (road length)")
    ax.legend(fontsize=8, loc="upper left")

def chart_time(impls, avg_data, sizes, title, fname) -> str:
    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(9, 5))
        _plot_lines(ax, impls, avg_data, sizes, "Tiempo promedio (ms)", log_scale=True)
        ax.set_title(title, fontsize=12, fontweight="bold", pad=8)
        fig.tight_layout()
    return _save_fig(fig, fname)

def chart_speedup(impls, avg_data, ref, sizes, title, fname) -> str:
    ref_avgs = avg_data.get(ref, {})
    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(9, 5))
        ax.axhline(1, color="#AAAAAA", lw=1.2, ls="--", label=f"ref: {ref.short_label}")
        for impl in impls:
            if impl == ref or impl not in avg_data: continue
            data = {s: ref_avgs[s] / avg_data[impl][s]
                    for s in sizes if s in avg_data[impl] and s in ref_avgs
                    and avg_data[impl][s] > 0}
            if not data: continue
            xs = sorted(data)
            ax.plot(xs, [data[x] for x in xs], marker="o", lw=2.2,
                    color=impl.color, label=impl.short_label)
        ax.set_xticks(sizes)
        ax.set_xticklabels([_size_label(s) for s in sizes], rotation=20, ha="right")
        ax.set_ylabel("Speedup")
        ax.set_xlabel("N (road length)")
        ax.set_title(title, fontsize=12, fontweight="bold", pad=8)
        ax.legend(fontsize=8, loc="upper left")
        fig.tight_layout()
    return _save_fig(fig, fname)

def chart_scaling(par_counts, avg_data, ref, sizes, title, fname) -> str:
    """Speedup and efficiency vs p — one subplot per road_length (up to 6)."""
    ref_avgs = avg_data.get(ref, {})
    plot_sizes = sizes[:6]

    with plt.rc_context(CHART_STYLE):
        ncols = min(3, len(plot_sizes))
        nrows = math.ceil(len(plot_sizes) / ncols)
        fig, axs = plt.subplots(nrows, ncols, figsize=(5 * ncols, 4 * nrows),
                                squeeze=False)

        for idx, size in enumerate(plot_sizes):
            ax = axs[idx // ncols][idx % ncols]
            ref_t = ref_avgs.get(size)
            if not ref_t:
                ax.set_title(f"N={_size_label(size)}")
                ax.text(0.5, 0.5, "Sin ref", ha="center", va="center")
                continue

            sp_omp, eff_omp = [], []
            sp_mpi, eff_mpi = [], []
            for p in par_counts:
                for impl_name, sp_list, eff_list in [
                    ("omp", sp_omp, eff_omp), ("mpi", sp_mpi, eff_mpi)
                ]:
                    impl = Impl(impl_name, p)
                    t = avg_data.get(impl, {}).get(size)
                    if t and t > 0:
                        sp = ref_t / t
                        sp_list.append(sp)
                        eff_list.append(sp / p * 100)
                    else:
                        sp_list.append(None)
                        eff_list.append(None)

            valid_p = par_counts
            ax2 = ax.twinx()
            ax2.spines["right"].set_visible(True)

            if any(v is not None for v in sp_omp):
                ys = [v if v is not None else float("nan") for v in sp_omp]
                ax.plot(valid_p, ys, "o-", color="#2E75B6", lw=2, label="SpUp OMP")
                ys_e = [v if v is not None else float("nan") for v in eff_omp]
                ax2.plot(valid_p, ys_e, "s--", color="#70AD47", lw=1.5, label="Eff OMP")

            if any(v is not None for v in sp_mpi):
                ys = [v if v is not None else float("nan") for v in sp_mpi]
                ax.plot(valid_p, ys, "^-", color="#C00000", lw=2, label="SpUp MPI")
                ys_e = [v if v is not None else float("nan") for v in eff_mpi]
                ax2.plot(valid_p, ys_e, "v--", color="#ED7D31", lw=1.5, label="Eff MPI")

            ax.plot(valid_p, valid_p, "k--", lw=1, alpha=0.4, label="Ideal")
            ax.set_title(f"N={_size_label(size)}", fontsize=10)
            ax.set_xlabel("p"); ax.set_ylabel("Speedup"); ax2.set_ylabel("Eficiencia (%)")
            ax.set_xticks(valid_p)
            h1, l1 = ax.get_legend_handles_labels()
            h2, l2 = ax2.get_legend_handles_labels()
            ax.legend(h1 + h2, l1 + l2, fontsize=7, loc="upper left")

        # Hide unused subplots
        for idx in range(len(plot_sizes), nrows * ncols):
            axs[idx // ncols][idx % ncols].set_visible(False)

        fig.suptitle(title, fontsize=12, fontweight="bold")
        fig.tight_layout()
    return _save_fig(fig, fname)

def chart_velocity(impls, avg_vel, sizes, title, fname) -> str:
    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(9, 4.5))
        for impl in impls:
            vels = avg_vel.get(impl, {})
            xs = [s for s in sizes if s in vels]
            ys = [vels[s] for s in xs]
            if xs:
                ax.plot(xs, ys, marker="o", lw=2, color=impl.color, label=impl.short_label)
        ax.axhline(0.5, color="#BBBBBB", lw=1, ls="--", label="v̄=0.5 (ρ=0.5)")
        ax.set_ylim(0, 1.05)
        ax.set_xticks(sizes)
        ax.set_xticklabels([_size_label(s) for s in sizes], rotation=20, ha="right")
        ax.set_ylabel("v̄ (velocidad media)")
        ax.set_xlabel("N (road length)")
        ax.set_title(title, fontsize=12, fontweight="bold", pad=8)
        ax.legend(fontsize=8)
        fig.tight_layout()
    return _save_fig(fig, fname)


# ---------------------------------------------------------------------------
# PNG table images
# ---------------------------------------------------------------------------
def _save_table_image(table_data: list[list], col_headers: list[str],
                      row_headers: list[str], title: str, fname: str,
                      col_colors: list[str] | None = None) -> str:
    """Render a DataFrame-style table as a PNG image for document embedding."""
    os.makedirs(TABLES_DIR, exist_ok=True)
    path = os.path.join(TABLES_DIR, fname)

    n_rows = len(table_data)
    n_cols = len(col_headers)
    fig_w  = max(10, n_cols * 1.6)
    fig_h  = max(2.5, (n_rows + 2) * 0.35)

    fig, ax = plt.subplots(figsize=(fig_w, fig_h))
    ax.axis("off")

    # Header + row-label column
    all_cols    = [""] + col_headers
    all_data    = [[row_headers[i]] + list(table_data[i]) for i in range(n_rows)]

    tbl = ax.table(
        cellText=all_data,
        colLabels=all_cols,
        cellLoc="center",
        loc="center",
    )
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(8.5)
    tbl.scale(1, 1.35)

    # Style header row
    for ci in range(n_cols + 1):
        cell = tbl[0, ci]
        cell.set_facecolor("#1F3557")
        cell.set_text_props(color="white", fontweight="bold")

    # Style row headers
    for ri in range(1, n_rows + 1):
        tbl[ri, 0].set_facecolor("#2E75B6")
        tbl[ri, 0].set_text_props(color="white", fontweight="bold")

    # Alternating rows + optional column colors
    row_bg = ["#F4F8FC", "#FFFFFF"]
    for ri in range(1, n_rows + 1):
        for ci in range(1, n_cols + 1):
            cell = tbl[ri, ci]
            base_bg = row_bg[(ri - 1) % 2]
            if col_colors and ci - 1 < len(col_colors):
                cell.set_facecolor(col_colors[ci - 1])
            else:
                cell.set_facecolor(base_bg)

    ax.set_title(title, fontsize=11, fontweight="bold",
                 pad=10, color="#1F3557")
    fig.tight_layout()
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path


def build_speedup_table_image(impls: list[Impl],
                               avg_data: dict[Impl, dict[int, float]],
                               ref: Impl, sizes: list[int],
                               title: str, fname: str) -> str:
    ref_avgs = avg_data.get(ref, {})
    col_headers = []
    for s in sizes:
        col_headers += [f"{_size_label(s)}\nAvg(ms)", f"{_size_label(s)}\nSpeedup"]
    col_headers.append("SpUp\nProm.")

    row_headers, table_data = [], []
    for impl in impls:
        row_headers.append(impl.short_label)
        times  = avg_data.get(impl, {})
        sp_refs = []
        row    = []
        for s in sizes:
            avg_t   = times.get(s)
            ref_avg = ref_avgs.get(s)
            row.append(_fn(avg_t) if avg_t is not None else "—")
            if impl == ref:
                row.append("1.0000")
                sp_refs.append(1.0)
            elif avg_t and ref_avg and avg_t > 0:
                sp = ref_avg / avg_t
                row.append(f"{sp:.4f}")
                sp_refs.append(sp)
            else:
                row.append("—")
        row.append(f"{_mean(sp_refs):.4f}" if sp_refs else "—")
        table_data.append(row)

    return _save_table_image(
        table_data, col_headers, row_headers, title, fname,
        col_colors=[c for _ in sizes for c in ("#F0F5FF", "#E2F0D9")] + [None],
    )


def build_raw_table_image(impl: Impl, all_reps: AllReps, sizes: list[int],
                          n_reps: int, title: str, fname: str) -> str:
    reps_data = all_reps.get(impl, {})
    col_headers = [_size_label(s) for s in sizes]
    row_headers, table_data = [], []

    for rep in range(1, n_reps + 1):
        row_headers.append(f"Rep {rep}")
        row = []
        for s in sizes:
            val = next((t for r, t, _, _ in reps_data.get(s, []) if r == rep), None)
            row.append(_fn(val) if val is not None else "—")
        table_data.append(row)

    for lbl, fn in [("Promedio", lambda v: _fn(_mean(v))),
                    ("Desv. Est.", lambda v: _fn(_std(v))),
                    ("CV (%)", lambda v: _fp(_cv(v))),
                    ("v̄ media", lambda v: _fn(_mean(v), d=4))]:
        row_headers.append(lbl)
        row = []
        for s in sizes:
            if lbl == "v̄ media":
                vals = [v for _, _, v, _ in reps_data.get(s, [])]
            else:
                vals = [t for _, t, _, _ in reps_data.get(s, [])]
            row.append(fn(vals) if vals else "—")
        table_data.append(row)

    return _save_table_image(table_data, col_headers, row_headers, title, fname)


def build_scaling_table_image(par_counts, avg_data, avg_tp, ref,
                               sizes, impl_name, title, fname) -> str:
    ref_avgs = avg_data.get(ref, {})
    col_headers = [f"N={_size_label(s)}\nTime(ms)"   for s in sizes] + \
                  [f"N={_size_label(s)}\nSpeedup"     for s in sizes] + \
                  [f"N={_size_label(s)}\nEff(%)"      for s in sizes] + \
                  [f"N={_size_label(s)}\nMcells/s"    for s in sizes]

    row_headers, table_data = [], []
    for p in par_counts:
        impl = Impl(impl_name, p)
        times = avg_data.get(impl, {})
        tps   = avg_tp.get(impl, {})
        row_headers.append(f"p={p}")
        row = []
        for cols_fn in [
            lambda s: (_fn(times.get(s)) if times.get(s) else "—"),
            lambda s: (f"{ref_avgs[s]/times[s]:.4f}" if times.get(s) and ref_avgs.get(s) else "—"),
            lambda s: (f"{ref_avgs[s]/times[s]/p*100:.1f}%" if times.get(s) and ref_avgs.get(s) else "—"),
            lambda s: (_fn(tps.get(s), d=2) if tps.get(s) else "—"),
        ]:
            for s in sizes:
                row.append(cols_fn(s))
        table_data.append(row)

    return _save_table_image(table_data, col_headers, row_headers, title, fname)


# ---------------------------------------------------------------------------
# Excel raw + speedup tables
# ---------------------------------------------------------------------------
def _write_raw_table_xl(ws, impls, all_reps, sizes, n_reps, start_row, n_cols):
    cur = start_row
    ws.merge_cells(f"A{cur}:{get_column_letter(n_cols)}{cur}")
    c = ws.cell(cur, 1, value="Tabla 1  —  Mediciones individuales (ms) y velocidad media (v̄)")
    c.font = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
    c.fill = PatternFill("solid", fgColor=C["dark"])
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[cur].height = 20
    cur += 1

    for impl_idx, impl in enumerate(impls):
        reps_data = all_reps.get(impl, {})

        ws.merge_cells(f"A{cur}:{get_column_letter(n_cols)}{cur}")
        bh = ws.cell(cur, 1, value=impl.label)
        bh.font      = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
        bh.fill      = PatternFill("solid", fgColor=C["impl_hdr"])
        bh.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        bh.border    = _thick_border()
        ws.row_dimensions[cur].height = 20
        cur += 1

        _hdr(ws.cell(cur, 1), "Rep", bg=C["mid"], size=9)
        for ci, size in enumerate(sizes, 2):
            _hdr(ws.cell(cur, ci), f"N={_size_label(size)}", bg=C["mid"], size=9)
        ws.row_dimensions[cur].height = 18
        cur += 1

        for rep in range(1, n_reps + 1):
            bg = C["alt"] if rep % 2 == 0 else "FFFFFF"
            _dat(ws.cell(cur, 1), rep, fmt="0", bg=C["light"], bold=True, align="center")
            for ci, size in enumerate(sizes, 2):
                val = next((t for r, t, _, _ in reps_data.get(size, []) if r == rep), None)
                if val is not None:
                    _dat(ws.cell(cur, ci), round(val, 3), fmt="#,##0.000", bg=bg)
                else:
                    _dat(ws.cell(cur, ci), "—", bg=bg, align="center")
            ws.row_dimensions[cur].height = 16
            cur += 1

        for s_label, fn, fmt in [
            ("Promedio",   lambda v: _mean(v), "#,##0.000"),
            ("Desv. Est.", lambda v: _std(v),  "#,##0.000"),
            ("CV (%)",     lambda v: _cv(v),   "0.00"),
            ("v̄ media",   lambda v: _mean(v), "0.000000"),
        ]:
            _hdr(ws.cell(cur, 1), s_label, bg=C["summary_bg"], fg=C["summary_fg"], size=9, align="left")
            for ci, size in enumerate(sizes, 2):
                if s_label == "v̄ media":
                    vals = [v for _, _, v, _ in reps_data.get(size, [])]
                else:
                    vals = [t for _, t, _, _ in reps_data.get(size, [])]
                if vals:
                    _sdat(ws.cell(cur, ci), round(fn(vals), 6), fmt=fmt, bold=(s_label == "Promedio"))
                else:
                    _sdat(ws.cell(cur, ci), "—")
            ws.row_dimensions[cur].height = 16
            cur += 1

        if impl_idx < len(impls) - 1:
            for ci in range(1, n_cols + 1):
                ws.cell(cur, ci).fill = PatternFill("solid", fgColor=C["sep"])
            ws.row_dimensions[cur].height = 6
            cur += 1

    return cur


def _write_speedup_table_xl(ws, impls, avg_data, ref, sizes, start_row):
    cur = start_row
    n_sp_cols = 1 + len(sizes) * 2 + 1

    ws.merge_cells(f"A{cur}:{get_column_letter(n_sp_cols)}{cur}")
    c = ws.cell(cur, 1, value="Tabla 2  —  Promedio y Speedup  (ref: seq_std)")
    c.font      = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
    c.fill      = PatternFill("solid", fgColor=C["dark"])
    c.alignment = Alignment(horizontal="left", vertical="center")
    ws.row_dimensions[cur].height = 20
    cur += 1

    _set_w(ws, 1, 32)
    for si in range(len(sizes)):
        _set_w(ws, 2 + si * 2, 13)
        _set_w(ws, 3 + si * 2, 11)
    _set_w(ws, n_sp_cols, 12)

    _hdr(ws.cell(cur, 1), "Implementación", bg=C["dark"], size=10)
    for si, size in enumerate(sizes):
        _hdr(ws.cell(cur, 2 + si * 2), f"N={_size_label(size)}\nAvg (ms)", bg=C["mid"], size=9)
        _hdr(ws.cell(cur, 3 + si * 2), f"N={_size_label(size)}\nSpeedup",  bg=C["mid"], size=9)
    _hdr(ws.cell(cur, n_sp_cols), "SpUp\nProm.", bg=C["dark"], size=9)
    ws.row_dimensions[cur].height = 28
    cur += 1

    ref_avgs = avg_data.get(ref, {})
    for ri, impl in enumerate(impls):
        bg     = C["alt"] if ri % 2 == 0 else "FFFFFF"
        is_ref = (impl == ref)
        times  = avg_data.get(impl, {})
        _dat(ws.cell(cur, 1), impl.label, bg=C["light"], bold=True, align="left")

        sp_list = []
        for si, size in enumerate(sizes):
            avg_t   = times.get(size)
            ref_avg = ref_avgs.get(size)
            c_avg = ws.cell(cur, 2 + si * 2)
            c_avg.value         = round(avg_t, 3) if avg_t else "N/A"
            c_avg.number_format = "#,##0.000"
            c_avg.font          = Font(name=FONT_NAME, size=10)
            c_avg.fill          = PatternFill("solid", fgColor=bg)
            c_avg.alignment     = Alignment(horizontal="right", vertical="center")
            c_avg.border        = _thin_border()

            c_sp = ws.cell(cur, 3 + si * 2)
            if is_ref:
                sp_val = 1.0
            elif avg_t and avg_t > 0 and ref_avg:
                sp_val = round(ref_avg / avg_t, 4)
                sp_list.append(sp_val)
            else:
                sp_val = "N/A"
            c_sp.value         = sp_val
            c_sp.number_format = "0.0000"
            c_sp.font          = Font(name=FONT_NAME, size=10, color=C["green_fg"])
            c_sp.fill          = PatternFill("solid", fgColor=C["green_bg"])
            c_sp.alignment     = Alignment(horizontal="right", vertical="center")
            c_sp.border        = _thin_border()

        c_avsp = ws.cell(cur, n_sp_cols)
        c_avsp.value         = round(_mean(sp_list), 4) if sp_list else (1.0 if is_ref else "N/A")
        c_avsp.number_format = "0.0000"
        c_avsp.font          = Font(name=FONT_NAME, bold=True, size=10, color=C["green_fg"])
        c_avsp.fill          = PatternFill("solid", fgColor=C["green_bg"])
        c_avsp.alignment     = Alignment(horizontal="right", vertical="center")
        c_avsp.border        = _thin_border()
        ws.row_dimensions[cur].height = 17
        cur += 1

    return cur


def write_sheet(wb, sheet_name, title, impls, all_reps, ref, sizes,
                chart_time_path, chart_sp_path, extra_chart_path=None):
    ws      = wb.create_sheet(sheet_name)
    avg_data = compute_avgs(all_reps)
    n_reps  = max((len(pairs)
                   for impl in impls
                   for pairs in all_reps.get(impl, {}).values()), default=5)
    n_cols  = 1 + len(sizes)

    _title_row(ws, title, n_cols)
    ws.row_dimensions[1].height = 26
    _set_w(ws, 1, 8)
    for ci in range(2, n_cols + 1):
        _set_w(ws, ci, 14)

    cur = _write_raw_table_xl(ws, impls, all_reps, sizes, n_reps, 2, n_cols)
    cur += 2
    cur = _write_speedup_table_xl(ws, impls, avg_data, ref, sizes, cur)

    anchor = cur + 3
    for a, path in [(f"A{anchor}", chart_time_path),
                    (f"L{anchor}", chart_sp_path)]:
        if path and os.path.exists(path):
            img        = XLImage(path)
            img.width  = 620
            img.height = 360
            ws.add_image(img, a)
    if extra_chart_path and os.path.exists(extra_chart_path):
        img        = XLImage(extra_chart_path)
        img.width  = 620
        img.height = 360
        ws.add_image(img, f"A{anchor + 22}")


def write_scaling_sheet(wb, all_reps, ref, par_counts, sizes,
                        chart_scale_path, impl_name="omp"):
    ws       = wb.create_sheet("3. Escalabilidad")
    avg_data = compute_avgs(all_reps)
    avg_tp   = compute_avg_tp(all_reps)
    ref_avgs = avg_data.get(ref, {})

    N_COLS = 5
    _title_row(ws, f"Escalabilidad OpenMP  |  speedup y eficiencia vs p  |  ref={ref.short_label}", N_COLS)
    ws.row_dimensions[1].height = 26
    for i, w in enumerate([8, 16, 14, 12, 16], 1):
        _set_w(ws, i, w)

    cur = 2
    for size in sizes:
        ref_t = ref_avgs.get(size)
        ws.merge_cells(f"A{cur}:{get_column_letter(N_COLS)}{cur}")
        bh = ws.cell(cur, 1, value=f"N = {_size_label(size)}  |  ref seq_std = {_fn(ref_t)} ms")
        bh.font      = Font(name=FONT_NAME, bold=True, size=11, color="FFFFFF")
        bh.fill      = PatternFill("solid", fgColor=C["impl_hdr"])
        bh.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        bh.border    = _thick_border()
        ws.row_dimensions[cur].height = 20
        cur += 1

        for ci, h in enumerate(["p", "Avg (ms)", "Speedup", "Eficiencia (%)", "Throughput (Mcells/s)"], 1):
            _hdr(ws.cell(cur, ci), h, bg=C["mid"], size=9)
        ws.row_dimensions[cur].height = 18
        cur += 1

        for pi, p in enumerate(par_counts):
            impl   = Impl(impl_name, p)
            avg_t  = avg_data.get(impl, {}).get(size)
            avg_t_ = avg_tp.get(impl, {}).get(size)
            sp     = ref_t / avg_t  if (avg_t  and ref_t) else None
            eff    = sp / p * 100   if sp is not None else None
            bg     = C["alt"] if pi % 2 == 0 else "FFFFFF"

            _dat(ws.cell(cur, 1), p, fmt="0", bg=C["light"], bold=True, align="center")
            _dat(ws.cell(cur, 2), round(avg_t,  3) if avg_t  else "—", fmt="#,##0.000", bg=bg)
            _dat(ws.cell(cur, 3), round(sp,  4) if sp  else "—", fmt="0.0000", bg=C["green_bg"], fg=C["green_fg"])
            _dat(ws.cell(cur, 4), round(eff, 2) if eff else "—", fmt="0.00",   bg=C["green_bg"], fg=C["green_fg"])
            _dat(ws.cell(cur, 5), round(avg_t_, 3) if avg_t_ else "—", fmt="#,##0.000", bg=bg)
            ws.row_dimensions[cur].height = 16
            cur += 1

        for ci in range(1, N_COLS + 1):
            ws.cell(cur, ci).fill = PatternFill("solid", fgColor=C["sep"])
        ws.row_dimensions[cur].height = 8
        cur += 1

    cur += 2
    if chart_scale_path and os.path.exists(chart_scale_path):
        img        = XLImage(chart_scale_path)
        img.width  = 860
        img.height = 520
        ws.add_image(img, f"A{cur}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    os.makedirs(CHARTS_DIR, exist_ok=True)
    os.makedirs(TABLES_DIR, exist_ok=True)

    print("Reading CSVs...")
    df_serial = load_csv("serial")
    df_omp    = load_csv("omp")
    df_mpi    = load_csv("mpi")

    frames = [df for df in [df_serial, df_omp, df_mpi] if df is not None]
    if not frames:
        print("No data found. Run benchmark.sh first.")
        sys.exit(1)

    all_reps  = build_all_reps(frames)
    avg_data  = compute_avgs(all_reps)
    avg_vel   = compute_avg_vel(all_reps)
    avg_tp    = compute_avg_tp(all_reps)
    sizes     = sorted({s for szs in all_reps.values() for s in szs})

    REF = Impl("seq_std", 0)

    par_counts   = sorted({i.parallelism for i in all_reps if i.parallelism > 0})
    omp_counts   = sorted({i.parallelism for i in all_reps if i.name == "omp"})
    mpi_counts   = sorted({i.parallelism for i in all_reps if i.name == "mpi"})

    def present(impl):
        return impl in all_reps

    impls_serial = [i for i in [REF, Impl("seq_opt", 0)] if present(i)]
    impls_omp    = [REF] + [Impl("omp", p) for p in omp_counts if present(Impl("omp", p))]
    impls_mpi    = [REF] + [Impl("mpi", p) for p in mpi_counts if present(Impl("mpi", p))]

    best_omp = best_parallel(avg_data, sizes, "omp", REF)
    best_mpi = best_parallel(avg_data, sizes, "mpi", REF)
    impls_final = [i for i in [REF, Impl("seq_opt", 0), best_omp, best_mpi]
                   if i is not None and present(i)]

    n_reps = max((len(pairs)
                  for szs in all_reps.values()
                  for pairs in szs.values()), default=5)

    print("\nGenerating charts...")

    ct1 = chart_time(impls_serial, avg_data, sizes,
                     "Tiempo  |  Variantes seriales", "serial_time.png")
    cs1 = chart_speedup(impls_serial, avg_data, REF, sizes,
                        "Speedup  |  serial_opt vs seq_std", "serial_sp.png")
    cv1 = chart_velocity(impls_serial, avg_vel, sizes,
                         "Velocidad media v̄  |  variantes seriales (ρ=0.50)", "serial_vel.png")

    ct2 = chart_time(impls_omp, avg_data, sizes,
                     "Tiempo  |  seq_std vs OpenMP(p)", "omp_time.png")
    cs2 = chart_speedup(impls_omp, avg_data, REF, sizes,
                        "Speedup  |  T(seq_std) / T(omp, p)", "omp_sp.png")

    csc = chart_scaling(par_counts, avg_data, REF, sizes,
                        "Escalabilidad OpenMP — Speedup y Eficiencia vs p", "scaling.png")

    ct5 = chart_time(impls_final, avg_data, sizes,
                     "Tiempo  |  Comparación final", "final_time.png")
    cs5 = chart_speedup(impls_final, avg_data, REF, sizes,
                        "Speedup  |  Mejor de cada estrategia", "final_sp.png")

    for p, label in [(ct1, "serial_time"), (cs1, "serial_sp"), (cv1, "serial_vel"),
                     (ct2, "omp_time"), (cs2, "omp_sp"), (csc, "scaling"),
                     (ct5, "final_time"), (cs5, "final_sp")]:
        print(f"  {os.path.basename(p)}")

    print("\nGenerating PNG table images...")
    # Serial raw tables
    for impl in impls_serial:
        build_raw_table_image(impl, all_reps, sizes, n_reps,
            f"Mediciones individuales — {impl.label}",
            f"raw_{impl.short_label}.png")

    # Serial speedup table
    build_speedup_table_image(impls_serial, avg_data, REF, sizes,
        "Speedup — Variantes seriales (ref: seq_std)",
        "speedup_serial.png")

    # OMP raw tables
    for impl in impls_omp:
        build_raw_table_image(impl, all_reps, sizes, n_reps,
            f"Mediciones individuales — {impl.label}",
            f"raw_{impl.short_label}.png")

    build_speedup_table_image(impls_omp, avg_data, REF, sizes,
        "Speedup — OpenMP vs seq_std",
        "speedup_omp.png")

    build_scaling_table_image(par_counts, avg_data, avg_tp, REF, sizes,
        "omp", "Escalabilidad OpenMP (speedup, eficiencia, throughput)",
        "scaling_omp.png")

    # Final comparison table
    build_speedup_table_image(impls_final, avg_data, REF, sizes,
        "Comparación final — Mejor de cada estrategia",
        "speedup_final.png")

    print(f"\nBuilding workbook: {OUTPUT_PATH}")
    wb = Workbook()
    if wb.active is not None:
        wb.remove(wb.active)

    write_sheet(wb, "1. Serial",
                "Serial  |  seq_std  vs  seq_opt",
                impls_serial, all_reps, REF, sizes, ct1, cs1, cv1)

    write_sheet(wb, "2. OpenMP",
                "OpenMP  |  seq_std  vs  omp(p)  |  ref = seq_std",
                impls_omp, all_reps, REF, sizes, ct2, cs2)

    write_scaling_sheet(wb, all_reps, REF, omp_counts if omp_counts else par_counts,
                        sizes, csc, impl_name="omp")

    if impls_mpi and len(impls_mpi) > 1:
        ct3 = chart_time(impls_mpi, avg_data, sizes,
                         "Tiempo  |  seq_std vs MPI(p)", "mpi_time.png")
        cs3 = chart_speedup(impls_mpi, avg_data, REF, sizes,
                            "Speedup  |  T(seq_std) / T(mpi, p)", "mpi_sp.png")
        write_sheet(wb, "3b. MPI",
                    "MPI  |  seq_std  vs  mpi(p)  |  ref = seq_std",
                    impls_mpi, all_reps, REF, sizes, ct3, cs3)

    write_sheet(wb, "4. Comparacion final",
                "Comparación final  |  Mejor de cada estrategia  |  ref = seq_std",
                impls_final, all_reps, REF, sizes, ct5, cs5)

    wb.save(OUTPUT_PATH)
    print(f"\nDone.")
    print(f"  XLSX   : {OUTPUT_PATH}")
    print(f"  Charts : {CHARTS_DIR}")
    print(f"  Tables : {TABLES_DIR}")


if __name__ == "__main__":
    main()
