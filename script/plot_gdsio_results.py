#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

import matplotlib.pyplot as plt


SIZE_UNITS = {"K": 1024, "M": 1024**2, "G": 1024**3}
XFLAG_LABELS = {"0": "GPUD (-x 0)", "2": "CPU_GPU (-x 2)"}
METRICS = {
    "throughput_gib_s": "Throughput (GiB/s)",
    "avg_latency_us": "Avg Latency (us)",
    "iops": "IOPS",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot gdsio summary.csv results.")
    parser.add_argument("summary_csv", type=Path, help="Path to summary.csv")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Directory for generated plots. Default: <summary_dir>/plots",
    )
    return parser.parse_args()


def parse_size_to_bytes(text: str) -> int:
    text = text.strip()
    if text[-1].isdigit():
      return int(text)
    unit = text[-1].upper()
    value = float(text[:-1])
    return int(value * SIZE_UNITS[unit])


def maybe_float(value: str) -> float | None:
    if value == "":
        return None
    return float(value)


def maybe_int(value: str) -> int | None:
    if value == "":
        return None
    return int(value)


def load_rows(path: Path) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            exit_code = maybe_int(row["exit_code"])
            xfer_match = maybe_int(row["xfer_match"]) if row["xfer_match"] != "NA" else None
            if exit_code != 0:
                continue
            if xfer_match not in (None, 1):
                continue
            row["threads"] = int(row["threads"])
            row["x_flag"] = str(row["x_flag"])
            row["throughput_gib_s"] = maybe_float(row["throughput_gib_s"])
            row["avg_latency_us"] = maybe_float(row["avg_latency_us"])
            row["iops"] = maybe_float(row["iops"])
            row["io_size_bytes"] = parse_size_to_bytes(row["io_size"])
            row["repeat_id"] = maybe_int(row["repeat_id"]) if "repeat_id" in row else None
            rows.append(row)
    return rows


def ensure_output_dir(summary_csv: Path, output_dir: Path | None) -> Path:
    final_dir = output_dir or summary_csv.parent / "plots"
    final_dir.mkdir(parents=True, exist_ok=True)
    return final_dir


def collapse_repeats(
    rows: Iterable[Dict[str, object]], x_key: str, metric: str
) -> Dict[Tuple[str, object], Dict[str, object]]:
    grouped: Dict[Tuple[str, object], List[Dict[str, object]]] = defaultdict(list)
    for row in rows:
        if row.get(metric) is None:
            continue
        grouped[(str(row["x_flag"]), row[x_key])].append(row)

    collapsed: Dict[Tuple[str, object], Dict[str, object]] = {}
    for key, members in grouped.items():
        base = dict(members[0])
        base[metric] = sum(float(member[metric]) for member in members) / len(members)
        collapsed[key] = base
    return collapsed


def series_by_xflag(rows: Iterable[Dict[str, object]], x_key: str, metric: str) -> Dict[str, List[Dict[str, object]]]:
    grouped: Dict[str, List[Dict[str, object]]] = defaultdict(list)
    collapsed = collapse_repeats(rows, x_key=x_key, metric=metric)
    for (_, _), row in collapsed.items():
        grouped[str(row["x_flag"])].append(row)
    for x_flag in grouped:
        grouped[x_flag].sort(key=lambda row: row[x_key])
    return grouped


def make_plot(
    rows: List[Dict[str, object]],
    metric: str,
    title: str,
    x_label: str,
    output_path: Path,
    x_key: str,
    x_display_key: str,
) -> None:
    plt.figure(figsize=(8, 5))
    grouped = series_by_xflag(rows, x_key=x_key, metric=metric)
    for x_flag, series in sorted(grouped.items()):
        xs = [row[x_key] for row in series]
        ys = [row[metric] for row in series]
        tick_labels = [str(row[x_display_key]) for row in series]
        plt.plot(xs, ys, marker="o", linewidth=2, label=XFLAG_LABELS.get(x_flag, f"-x {x_flag}"))
        plt.xticks(xs, tick_labels)
    plt.title(title)
    plt.xlabel(x_label)
    plt.ylabel(METRICS[metric])
    plt.grid(True, linestyle="--", alpha=0.35)
    plt.legend()
    plt.tight_layout()
    plt.savefig(output_path, dpi=180)
    plt.close()


def plot_group(rows: List[Dict[str, object]], output_dir: Path, mode: str, test_group: str) -> None:
    subset = [row for row in rows if row["mode"] == mode and row["test_group"] == test_group]
    if not subset:
        return

    if test_group.startswith("io_size_sweep"):
        x_key = "io_size_bytes"
        x_display_key = "io_size"
        x_label = "IO Size"
    else:
        x_key = "threads"
        x_display_key = "threads"
        x_label = "Threads"

    for metric in METRICS:
        output_path = output_dir / f"{test_group}__{mode}__{metric}.png"
        title = f"{test_group} | {mode} | {METRICS[metric]}"
        make_plot(
            subset,
            metric=metric,
            title=title,
            x_label=x_label,
            output_path=output_path,
            x_key=x_key,
            x_display_key=x_display_key,
        )


def write_manifest(rows: List[Dict[str, object]], output_dir: Path) -> None:
    manifest = output_dir / "README.txt"
    modes = sorted({str(row["mode"]) for row in rows})
    groups = sorted({str(row["test_group"]) for row in rows})
    with manifest.open("w") as f:
        f.write("Generated by plot_gdsio_results.py\n")
        f.write(f"Rows plotted: {len(rows)}\n")
        f.write(f"Modes: {', '.join(modes)}\n")
        f.write(f"Groups: {', '.join(groups)}\n")
        f.write("Files:\n")
        for path in sorted(output_dir.glob("*.png")):
            f.write(f"  {path.name}\n")


def main() -> None:
    args = parse_args()
    rows = load_rows(args.summary_csv)
    output_dir = ensure_output_dir(args.summary_csv, args.output_dir)

    test_groups = sorted({str(row["test_group"]) for row in rows})
    for mode in sorted({str(row["mode"]) for row in rows}):
        for test_group in test_groups:
            plot_group(rows, output_dir, mode, test_group)

    write_manifest(rows, output_dir)
    print(f"Wrote plots to {output_dir}")


if __name__ == "__main__":
    main()

