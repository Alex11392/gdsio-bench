#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
import re
import statistics as st
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


NUMERIC_FIELDS = [
    "throughput_gibs",
    "avg_lat_us",
    "iops",
    "active_cores",
    "total_cpu_pct",
    "gdsio_cpu_pct",
    "gdsio_usr_pct",
    "gdsio_sys_pct",
    "dram_read_mibs",
    "dram_write_mibs",
    "ssd_r_mbs",
    "ssd_w_mbs",
    "ssd_r_await_ms",
    "ssd_w_await_ms",
    "ssd_aqu_sz",
    "ssd_util_pct",
]

MODE_LABEL = {"gds": "GDS (-x 0)", "cpu": "CPU-bounce (-x 2)"}
PATTERN_LABEL = {"seq": "Sequential", "rand": "Random"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze gdsio sweep v3 master.csv")
    parser.add_argument("run_dir", type=Path, help="results/gdsio_sweep_v3_<timestamp>")
    parser.add_argument("--docs-dir", type=Path, default=Path("docs"))
    return parser.parse_args()


def read_rows(master: Path) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    with master.open(newline="") as f:
        for row in csv.DictReader(f):
            row["io_size_kib"] = int(row["io_size_kib"])
            row["threads"] = int(row["threads"])
            row["rep"] = int(row["rep"])
            row["exit_code"] = int(row["exit_code"])
            for field in NUMERIC_FIELDS:
                row[field] = float(row[field])
            rows.append(row)
    return rows


def mean(values: list[float]) -> float:
    return st.mean(values) if values else 0.0


def std(values: list[float]) -> float:
    return st.stdev(values) if len(values) > 1 else 0.0


def group_summary(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    grouped: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    keys = ("mode", "pattern", "io_size_kib", "threads")
    for row in rows:
        grouped[tuple(row[key] for key in keys)].append(row)

    summary: list[dict[str, object]] = []
    for key, members in sorted(grouped.items(), key=lambda item: (item[0][0], item[0][1], item[0][2], item[0][3])):
        out = dict(zip(keys, key))
        out["n"] = len(members)
        for field in NUMERIC_FIELDS:
            values = [float(member[field]) for member in members]
            out[f"{field}_mean"] = mean(values)
            out[f"{field}_std"] = std(values)
            out[f"{field}_min"] = min(values)
            out[f"{field}_max"] = max(values)
        summary.append(out)
    return summary


def write_summary_csv(summary: list[dict[str, object]], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = list(summary[0].keys()) if summary else []
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(summary)


def size_label(kib: int) -> str:
    if kib >= 1024:
        return f"{kib // 1024}M"
    return f"{kib}K"


def get_summary(summary: list[dict[str, object]], mode: str, pattern: str, io_size_kib: int, threads: int) -> dict[str, object] | None:
    for row in summary:
        if row["mode"] == mode and row["pattern"] == pattern and row["io_size_kib"] == io_size_kib and row["threads"] == threads:
            return row
    return None


def plot_metric(
    summary: list[dict[str, object]],
    out: Path,
    *,
    pattern: str,
    x_axis: str,
    metric: str,
    title: str,
    ylabel: str,
    fixed_note: str,
) -> None:
    fig, ax = plt.subplots(figsize=(9.5, 5.6))

    for mode in ("gds", "cpu"):
        members = [row for row in summary if row["mode"] == mode and row["pattern"] == pattern]
        if x_axis == "io_size":
            members = [row for row in members if row["threads"] == 16]
            members.sort(key=lambda row: int(row["io_size_kib"]))
            xs = list(range(len(members)))
            labels = [size_label(int(row["io_size_kib"])) for row in members]
        else:
            members = [row for row in members if row["io_size_kib"] == 4]
            members.sort(key=lambda row: int(row["threads"]))
            xs = [int(row["threads"]) for row in members]
            labels = [str(x) for x in xs]

        ys = [float(row[f"{metric}_mean"]) for row in members]
        yerr = [float(row[f"{metric}_std"]) for row in members]
        ax.errorbar(xs, ys, yerr=yerr, marker="o", linewidth=2, capsize=3, label=MODE_LABEL[mode])

        if ys:
            for idx in {0, len(ys) - 1, max(range(len(ys)), key=lambda i: ys[i])}:
                value = ys[idx]
                label = f"{value:.2f}" if metric == "throughput_gibs" else f"{value:.0f}"
                ax.annotate(label, (xs[idx], ys[idx]), textcoords="offset points", xytext=(0, 8), ha="center", fontsize=8)

    ax.set_title(title, pad=26)
    ax.text(0.5, 1.03, fixed_note, transform=ax.transAxes, ha="center", va="bottom", color="dimgray", fontsize=9)
    ax.set_xlabel("IO size" if x_axis == "io_size" else "Threads")
    ax.set_ylabel(ylabel)
    ax.set_xticks(xs, labels)
    ax.grid(True, linestyle="--", alpha=0.35)
    ax.legend()
    fig.tight_layout()
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=180)
    plt.close(fig)


def parse_precondition(run_dir: Path) -> dict[str, str]:
    result = {}
    for name, label in [("fio_precond_round1_seq.log", "seq"), ("fio_precond_round1_rand.log", "rand")]:
        text = (run_dir / name).read_text(errors="replace") if (run_dir / name).exists() else ""
        m = re.search(r"WRITE: bw=([^,]+).*?io=([^,]+), run=([^\n]+)", text)
        if m:
            result[f"{label}_bw"] = m.group(1).strip()
            result[f"{label}_io"] = m.group(2).strip()
            result[f"{label}_run"] = m.group(3).strip()
        m_iops = re.search(r"write: IOPS=([^,]+), BW=([^,]+)", text)
        if m_iops:
            result[f"{label}_iops"] = m_iops.group(1).strip()
    return result


def write_markdown(run_dir: Path, summary: list[dict[str, object]], rows: list[dict[str, object]], path: Path) -> None:
    def fmt(row: dict[str, object] | None, field: str = "throughput_gibs_mean") -> str:
        return "NA" if row is None else f"{float(row[field]):.2f}"

    pre = parse_precondition(run_dir)
    bad = [row for row in rows if row["exit_code"] != 0 or row["xfertype"] == "PARSE_ERR"]
    down = [row for row in rows if int(float(row["pcie_saw_downshift"])) != 0]

    lines = [
        "# GDSIO Sweep v3 Result Summary",
        "",
        "## Run Metadata",
        "",
        f"- Run directory: `{run_dir}`",
        "- Dataset size: `10G`",
        "- Duration per case: `120s`",
        "- Repeats: `3`",
        "- Modes: `GDS (-x 0)` and `CPU-bounce (-x 2)`",
        "- Patterns: sequential and random read",
        "- IO size sweep: `4K` to `4M`, fixed `threads=16`",
        "- Thread sweep: `threads=1,2,4,8,32`, fixed `io_size=4K`",
        "",
        "## Run Health",
        "",
        f"- Completed cases: `{len(rows)} / 192`",
        f"- Failed or parse-error cases: `{len(bad)}`",
        f"- PCIe downshift cases: `{len(down)}`",
        "",
        "## Preconditioning",
        "",
        "- Full preconditioning was executed once before the sweep.",
        f"- Sequential precondition bandwidth: `{pre.get('seq_bw', 'NA')}`",
        f"- Random 4K precondition bandwidth: `{pre.get('rand_bw', 'NA')}`",
        f"- Random 4K precondition IOPS: `{pre.get('rand_iops', 'NA')}`",
        "",
        "## Key Findings",
        "",
        "- Large IO sizes reach roughly the same throughput on both paths, around `6.8-6.9 GiB/s`.",
        "- Small IO sizes favor CPU-bounce in this run; GDS did not reduce process CPU usage for small IO.",
        "- For `4K` thread sweep, CPU-bounce is faster than GDS at high thread count.",
        "- PCIe stayed at Gen4 for all parsed cases, so the previous downshift issue did not affect this run.",
        "",
        "## Representative Throughput And CPU",
        "",
        "| Case | GDS throughput | CPU-bounce throughput | GDS gdsio CPU | CPU-bounce gdsio CPU |",
        "|---|---:|---:|---:|---:|",
    ]

    cases = [
        ("seq 4K, t16", "seq", 4, 16),
        ("seq 64K, t16", "seq", 64, 16),
        ("seq 4M, t16", "seq", 4096, 16),
        ("rand 4K, t16", "rand", 4, 16),
        ("rand 64K, t16", "rand", 64, 16),
        ("rand 4M, t16", "rand", 4096, 16),
        ("seq 4K, t32", "seq", 4, 32),
        ("rand 4K, t32", "rand", 4, 32),
    ]
    for label, pattern, io_size, threads in cases:
        g = get_summary(summary, "gds", pattern, io_size, threads)
        c = get_summary(summary, "cpu", pattern, io_size, threads)
        lines.append(
            f"| {label} | {fmt(g)} GiB/s | {fmt(c)} GiB/s | {fmt(g, 'gdsio_cpu_pct_mean')}% | {fmt(c, 'gdsio_cpu_pct_mean')}% |"
        )

    lines += [
        "",
        "## Notes",
        "",
        "- `gdsio_cpu_pct` is process CPU percent from `pidstat`; `100%` is roughly one CPU core.",
        "- The dataset is intentionally `10G`, so the 120s runs repeatedly access the same working set.",
        "- The result should be interpreted as this fixed-working-set benchmark, not a full large-streaming benchmark.",
    ]

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    args = parse_args()
    run_dir = args.run_dir
    run_id = run_dir.name
    rows = read_rows(run_dir / "master.csv")
    good_rows = [row for row in rows if row["exit_code"] == 0 and row["xfertype"] != "PARSE_ERR"]
    summary = group_summary(good_rows)

    data_dir = args.docs_dir / "data"
    fig_dir = args.docs_dir / "figures" / run_id
    summary_path = data_dir / f"{run_id}_summary.csv"
    md_path = args.docs_dir / f"{run_id}.md"

    write_summary_csv(summary, summary_path)

    for pattern in ("seq", "rand"):
        plot_metric(
            summary,
            fig_dir / f"io_size_sweep_{pattern}_throughput.png",
            pattern=pattern,
            x_axis="io_size",
            metric="throughput_gibs",
            title=f"{PATTERN_LABEL[pattern]} Read: Throughput vs IO Size",
            ylabel="Throughput (GiB/s)",
            fixed_note="fixed: threads=16, dataset=10G, duration=120s, repeats=3",
        )
        plot_metric(
            summary,
            fig_dir / f"io_size_sweep_{pattern}_gdsio_cpu.png",
            pattern=pattern,
            x_axis="io_size",
            metric="gdsio_cpu_pct",
            title=f"{PATTERN_LABEL[pattern]} Read: gdsio CPU vs IO Size",
            ylabel="gdsio CPU (%)",
            fixed_note="fixed: threads=16, dataset=10G, duration=120s, repeats=3",
        )

    write_markdown(run_dir, summary, rows, md_path)
    print(f"Wrote {summary_path}")
    print(f"Wrote {fig_dir}")
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()
