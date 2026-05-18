# gdsio-bench

Benchmark suite for comparing **GPUDirect Storage (GDS)** (`-x 0`) and **CPU-bounce** (`-x 2`) I/O paths on a single platform, using NVIDIA's `gdsio` tool.

---

## Experiment Design (Sweep v3)

The sweep v3 experiment is the canonical benchmark. It is designed to reproduce the methodology from the paper *Quantifying Performance Gains of GPUDirect Storage* and extend it with system-level monitoring.

### Goal

Quantify the throughput, latency, and CPU/DRAM cost difference between:

| Path | Description |
|---|---|
| GDS (`-x 0`) | NVMe SSD → PCIe → GPU memory, bypassing CPU DRAM |
| CPU-bounce (`-x 2`) | NVMe SSD → CPU DRAM → PCIe → GPU memory |

### Benchmark Matrix

Two sweeps are run back-to-back in a single invocation:

```
IO size sweep  : io_size ∈ {4K..4M}, threads fixed at IO_SWEEP_THREADS (default 16)
Thread sweep   : threads ∈ {1,2,4,8,16,32}, io_size fixed at THREAD_SWEEP_SIZE_KIB (default 4K)
```

Each combination is repeated `REPS` times (default 3). The full default matrix:

```
2 modes × 2 patterns × (11 io sizes + 5 thread counts) × 3 reps = 192 cases
```

At 120 s per case ≈ 6.4 hours total.

### SSD Preconditioning

Preconditioning is performed **once before the entire sweep**, following the paper methodology:

```
PRECONDITION=full  (default)
  1. umount device
  2. mkfs.ext4 (fresh filesystem, clears FTL mapping)
  3. mount device
  4. compute fill size from EXT4 free space, leaving PRECOND_FREE_RESERVE
  5. run one preconditioning round by default:
     round N-a. FIO sequential write (bs=128K) — fills usable filesystem space to steady state
     round N-b. FIO random write    (bs=4K)   — stresses random-write FTL paths
  6. fallocate + dd to create the 1024G testfile with contiguous EXT4 extents
```

The paper uses two preconditioning rounds. This script defaults to one round to reduce runtime and SSD write amplification while still avoiding a fresh-filesystem state. Set `PRECOND_ROUNDS=2` when a closer paper-style run is required.

The `fallocate + dd` step is critical: FIO random-write preconditioning fragments the EXT4 free-block bitmap. If the testfile is created with `fio bs=128K` after preconditioning, physical extents become scattered and 4K read latency degrades 3×. `fallocate` reserves one contiguous region before the filesystem is fragmented.

### Per-case Monitoring

For every case the script collects:

| File | Tool | Purpose |
|---|---|---|
| `mpstat.log` | `mpstat -P ALL 1` | System-wide CPU breakdown |
| `pidstat.log` | `pidstat -t -u -r -d` | Per-thread CPU, memory, I/O for gdsio |
| `iostat.log` | `iostat -x <device> 1` | SSD utilisation, await, queue depth |
| `pcie_link.csv` | `nvidia-smi` (1 Hz) | PCIe gen/width over time |
| `perf.data` | `perf record -g` (30 s) | CPU call-graph, function-level hotspots |
| `perf.log` | `perf stat` | DRAM traffic via uncore IMC counters |

Call-graph analysis after the run:
```bash
sudo perf report -i results/<run_id>/raw/<case>/perf.data --stdio
```

### GPU Memory Clock Lock

The script locks the GPU memory clock for the entire sweep:
```
LOCK_MEMORY_CLOCK=1   MEMORY_CLOCK=10001
```
Without this, GDS/NVFS reads may not keep the PCIe link at Gen4, causing mid-run downshift and inflated latency. Clocks are restored automatically at exit.

---

## Quick Start

### Smoke test (no preconditioning, existing testfile)

```bash
PRECONDITION=none \
TESTFILE=/mnt/nvme0/gds_test/testfile \
DATASET_SIZE=10G \
MODES_STR="0 2" \
PATTERNS_STR=0 \
SIZES_KIB_STR=4096 \
THREADS_STR=16 \
REPS=1 \
DURATION=30 \
ENABLE_PERF=0 \
script/run_gdsio_sweep_v3.sh
```

### Formal run (full preconditioning, default matrix)

```bash
script/run_gdsio_sweep_v3.sh
```

Requires ~2 TB free on `DEVICE` and root access for `mkfs.ext4` and `perf`.

---

## Configuration Reference

All parameters are environment variables with defaults in the script.

| Variable | Default | Description |
|---|---|---|
| `GDSIO` | `/usr/local/cuda/gds/tools/gdsio` | Path to gdsio binary |
| `TESTFILE` | `/mnt/nvme0/gds_test/testfile_v3` | Test dataset path |
| `DEVICE` | `/dev/nvme0n1` | Target NVMe device |
| `MOUNT_POINT` | `/mnt/nvme0` | Filesystem mount point |
| `GPU` | `0` | GPU index |
| `DATASET_SIZE` | `1024G` | Test file size. Use `G` units because this gdsio build rejects `-s 1T`. |
| `DURATION` | `120` | gdsio run time per case (seconds) |
| `WARMUP` | `2` | Seconds before gdsio starts |
| `COOLDOWN` | `3` | Seconds after gdsio exits |
| `REPS` | `3` | Repeats per configuration |
| `MODES_STR` | `"0 2"` | gdsio `-x` values: 0=GDS, 2=CPU-bounce |
| `PATTERNS_STR` | `"0 2"` | gdsio `-I` values: 0=sequential, 2=random |
| `SIZES_KIB_STR` | `"4 8 16 32 64 128 256 512 1024 2048 4096"` | IO sizes (KiB) |
| `THREADS_STR` | `"1 2 4 8 16 32"` | Thread counts for thread sweep |
| `IO_SWEEP_THREADS` | `16` | Fixed thread count during IO size sweep |
| `THREAD_SWEEP_SIZE_KIB` | `4` | Fixed IO size (KiB) during thread sweep |
| `PRECONDITION` | `full` | `none` / `quick` / `full` |
| `PRECOND_ROUNDS` | `1` | FIO preconditioning rounds |
| `PRECOND_FREE_RESERVE` | `8G` | Free filesystem space left unused during full preconditioning |
| `LOCK_MEMORY_CLOCK` | `1` | Lock GPU memory clock |
| `ENABLE_PERF` | `1` | Collect DRAM counters via `perf stat` |
| `ENABLE_PERF_RECORD` | `1` | Collect call graph via `perf record -g` |
| `ENABLE_PIDSTAT` | `1` | Per-thread gdsio stats |
| `ENABLE_MPSTAT` | `1` | System-wide CPU stats |
| `ENABLE_IOSTAT` | `1` | SSD device stats |
| `ENABLE_PCIE_MONITOR` | `1` | PCIe link state |
| `PERF_RECORD_SECONDS` | `30` | Duration for `perf record` window |

---

## Output Layout

```
results/gdsio_sweep_v3_<timestamp>/
├── run_config.env          # all parameter values for this run
├── master.csv              # parsed summary of all cases
├── fio_precond_*_round*.log
├── testfile_create.log
└── raw/
    └── <mode>_<pattern>_<size>k_t<threads>_r<rep>/
        ├── case.env
        ├── gdsio.log
        ├── mpstat.log
        ├── pidstat.log
        ├── iostat.log
        ├── pcie_link.csv
        ├── perf.data
        ├── perf.log
        └── perf_record.log
```

`master.csv` columns include: throughput, latency, IOPS, per-process CPU (usr/sys), DRAM read/write, SSD utilisation, PCIe gen observed.

---

## Parsing

```bash
python3 script/parse_gdsio_sweep_v3.py <case_dir> <mode> <pattern> \
  <io_size_kib> <threads> <rep> <warmup> <duration> <cooldown> \
  <dataset_size> <exit_code> <device>
```

The script is called automatically for each case and appends one CSV row to `master.csv`.

---

## Key Findings (Smoke Test, PASCARI AI100E + RTX 6000 Ada)

| Metric | GDS (-x 0) | CPU-bounce (-x 2) |
|---|---|---|
| Throughput @ 4M, t16 | 6.87 GiB/s | 6.83 GiB/s |
| Throughput @ 4K, t32 | 2.57 GiB/s | 2.37 GiB/s |
| gdsio CPU (usr / sys) | 8.7% usr + 87.5% sys | 50.6% usr + 52.5% sys |
| DRAM read traffic | ~430 MiB/s (6%) | ~5,940 MiB/s (87%) |
| PCIe link | Gen4 × 16 | Gen4 × 16 |

GDS reduces DRAM traffic by ~14× at 4M sequential. At this IO size both paths are SSD-limited; the GDS advantage is most visible at smaller IO sizes and higher thread counts where DRAM bandwidth becomes the bottleneck on the CPU-bounce path.

---

## Legacy Experiments

Earlier scripts and methodology documents are preserved for reference:

- `script/run_gdsio_methodology.sh` — original single-config runner
- `configs/methodology_full.env` — canonical config for the original runner
- `docs/benchmark-methodology.md` — original procedure and PCIe issue notes
- `docs/methodology_full_20260424_131442.md` — first full run record
- `docs/lmcache_gds_mode_validation_*.md` — LMCache GDS vs fallback validation
