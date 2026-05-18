#!/usr/bin/env python3
"""Parse one gdsio sweep case directory and emit one CSV row."""

import csv
import re
import sys
from pathlib import Path


FIELDS = [
    "mode",
    "pattern",
    "io_size_kib",
    "threads",
    "rep",
    "dataset_size",
    "duration_s",
    "exit_code",
    "xfertype",
    "throughput_gibs",
    "avg_lat_us",
    "iops",
    "ops",
    "total_time_s",
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
    "pcie_min_gen",
    "pcie_max_gen",
    "pcie_saw_gen4",
    "pcie_saw_downshift",
]


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except FileNotFoundError:
        return ""


def active_window(values, warmup, duration):
    return values[warmup : warmup + duration]


def parse_gdsio(case_dir: Path, duration: int):
    text = read_text(case_dir / "gdsio.log")
    result = {
        "xfertype": "PARSE_ERR",
        "throughput_gibs": 0.0,
        "avg_lat_us": 0.0,
        "iops": 0.0,
        "ops": 0,
        "total_time_s": 0.0,
    }
    m = re.search(
        r"XferType:\s+(\S+).*?Throughput:\s+([\d.]+).*?"
        r"Avg_Latency:\s+([\d.]+).*?ops:\s+(\d+).*?"
        r"total_time\s+([\d.]+)\s+secs",
        text,
        re.S,
    )
    if not m:
        return result
    ops = int(m.group(4))
    result.update(
        {
            "xfertype": m.group(1),
            "throughput_gibs": float(m.group(2)),
            "avg_lat_us": float(m.group(3)),
            "iops": ops / duration if duration else 0.0,
            "ops": ops,
            "total_time_s": float(m.group(5)),
        }
    )
    return result


def parse_mpstat(case_dir: Path, warmup: int, duration: int):
    text = read_text(case_dir / "mpstat.log")
    busy_per_cpu = {}
    batches = 0
    sample_idx = -1
    batch = {}
    in_batch = False
    for line in text.splitlines():
        if "CPU" in line and "%idle" in line:
            if in_batch and batch and warmup <= sample_idx < warmup + duration:
                for cpu, busy in batch.items():
                    busy_per_cpu[cpu] = busy_per_cpu.get(cpu, 0.0) + busy
                batches += 1
            in_batch = True
            sample_idx += 1
            batch = {}
            continue
        parts = line.split()
        if len(parts) >= 12 and parts[1].isdigit():
            try:
                cpu = int(parts[1])
                idle = float(parts[-1])
            except ValueError:
                continue
            batch[cpu] = 100.0 - idle
    if in_batch and batch and warmup <= sample_idx < warmup + duration:
        for cpu, busy in batch.items():
            busy_per_cpu[cpu] = busy_per_cpu.get(cpu, 0.0) + busy
        batches += 1
    if not batches:
        return {"active_cores": 0, "total_cpu_pct": 0.0}
    avg_busy = {cpu: total / batches for cpu, total in busy_per_cpu.items()}
    return {
        "active_cores": sum(1 for value in avg_busy.values() if value >= 50.0),
        "total_cpu_pct": sum(avg_busy.values()),
    }


def parse_pidstat(case_dir: Path, warmup: int, duration: int):
    rows = []
    header = []
    for line in read_text(case_dir / "pidstat.log").splitlines():
        if not line.strip() or line.startswith("Linux") or "UID" in line or "Average:" in line:
            if "UID" in line and "%usr" in line and "%CPU" in line:
                header = line.split()
            continue
        parts = line.split()
        if not header or len(parts) < len(header):
            continue
        try:
            row = dict(zip(header, parts))
            command = row.get("Command", "")
            if command.startswith("|__"):
                continue
            usr = float(row["%usr"])
            system = float(row["%system"])
            cpu = float(row["%CPU"])
        except (KeyError, ValueError):
            continue
        rows.append((usr, system, cpu))
    rows = active_window(rows, warmup, duration)
    if not rows:
        return {"gdsio_cpu_pct": 0.0, "gdsio_usr_pct": 0.0, "gdsio_sys_pct": 0.0}
    return {
        "gdsio_usr_pct": sum(r[0] for r in rows) / len(rows),
        "gdsio_sys_pct": sum(r[1] for r in rows) / len(rows),
        "gdsio_cpu_pct": sum(r[2] for r in rows) / len(rows),
    }


def parse_perf(case_dir: Path, total_window: int):
    read_mib = 0.0
    write_mib = 0.0
    for line in read_text(case_dir / "perf.log").splitlines():
        cols = line.strip().split(",")
        if len(cols) < 3:
            continue
        try:
            value = float(cols[0])
        except ValueError:
            continue
        unit = cols[1]
        event = cols[2]
        if unit == "MiB":
            mib = value
        elif unit == "GiB":
            mib = value * 1024
        elif unit in ("KiB", "kB"):
            mib = value / 1024
        else:
            mib = value / (1024 * 1024)
        if "cas_count_read" in event:
            read_mib += mib
        if "cas_count_write" in event:
            write_mib += mib
    return {
        "dram_read_mibs": read_mib / total_window if total_window else 0.0,
        "dram_write_mibs": write_mib / total_window if total_window else 0.0,
    }


def parse_iostat(case_dir: Path, device: str, warmup: int, duration: int):
    def throughput_mibs(row, mb_key, kb_key):
        if mb_key in row:
            return float(row[mb_key])
        if kb_key in row:
            return float(row[kb_key]) / 1024.0
        return 0.0

    samples = []
    header = []
    dev_base = Path(device).name
    for line in read_text(case_dir / "iostat.log").splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "Device":
            header = parts
            continue
        if parts[0] != dev_base or not header:
            continue
        row = dict(zip(header, parts))
        try:
            samples.append(
                {
                    "ssd_r_mbs": throughput_mibs(row, "rMB/s", "rkB/s"),
                    "ssd_w_mbs": throughput_mibs(row, "wMB/s", "wkB/s"),
                    "ssd_r_await_ms": float(row.get("r_await", 0.0)),
                    "ssd_w_await_ms": float(row.get("w_await", 0.0)),
                    "ssd_aqu_sz": float(row.get("aqu-sz", row.get("avgqu-sz", 0.0))),
                    "ssd_util_pct": float(row.get("%util", 0.0)),
                }
            )
        except ValueError:
            continue
    samples = active_window(samples, warmup, duration)
    result = {
        "ssd_r_mbs": 0.0,
        "ssd_w_mbs": 0.0,
        "ssd_r_await_ms": 0.0,
        "ssd_w_await_ms": 0.0,
        "ssd_aqu_sz": 0.0,
        "ssd_util_pct": 0.0,
    }
    if not samples:
        return result
    for key in result:
        result[key] = sum(sample[key] for sample in samples) / len(samples)
    return result


def parse_pcie(case_dir: Path, warmup: int, duration: int):
    gens = []
    saw_gen4 = False
    saw_downshift = False
    for line in read_text(case_dir / "pcie_link.csv").splitlines():
        if line.startswith("timestamp"):
            continue
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 6:
            continue
        try:
            gen = int(parts[2])
        except ValueError:
            continue
        gens.append(gen)
        if gen >= 4:
            saw_gen4 = True
        if saw_gen4 and gen < 4:
            saw_downshift = True
    gens = active_window(gens, warmup, duration)
    saw_gen4 = any(gen >= 4 for gen in gens)
    saw_downshift = False
    seen_gen4 = False
    for gen in gens:
        if gen >= 4:
            seen_gen4 = True
        elif seen_gen4:
            saw_downshift = True
    return {
        "pcie_min_gen": min(gens) if gens else 0,
        "pcie_max_gen": max(gens) if gens else 0,
        "pcie_saw_gen4": int(saw_gen4),
        "pcie_saw_downshift": int(saw_downshift),
    }


def main():
    if len(sys.argv) != 13:
        sys.stderr.write(
            "usage: parse_gdsio_sweep_v3.py <case_dir> <mode> <pattern> <io_kib> "
            "<threads> <rep> <warmup> <duration> <cooldown> <dataset_size> "
            "<exit_code> <device>\n"
        )
        return 2
    case_dir = Path(sys.argv[1])
    row = {
        "mode": sys.argv[2],
        "pattern": sys.argv[3],
        "io_size_kib": int(sys.argv[4]),
        "threads": int(sys.argv[5]),
        "rep": int(sys.argv[6]),
        "dataset_size": sys.argv[10],
        "duration_s": int(sys.argv[8]),
        "exit_code": int(sys.argv[11]),
    }
    warmup = int(sys.argv[7])
    duration = int(sys.argv[8])
    cooldown = int(sys.argv[9])
    total_window = warmup + duration + cooldown
    device = sys.argv[12]
    row.update(parse_gdsio(case_dir, duration))
    row.update(parse_mpstat(case_dir, warmup, duration))
    row.update(parse_pidstat(case_dir, warmup, duration))
    row.update(parse_perf(case_dir, total_window))
    row.update(parse_iostat(case_dir, device, warmup, duration))
    row.update(parse_pcie(case_dir, warmup, duration))
    writer = csv.DictWriter(sys.stdout, fieldnames=FIELDS)
    writer.writerow({field: row.get(field, "") for field in FIELDS})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
