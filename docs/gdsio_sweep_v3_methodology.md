# GDSIO Sweep v3 Methodology

## Purpose

- Compare GDS path (`-x 0`) and CPU-GPU path (`-x 2`).
- Sweep IO size from `4K` to `4M`.
- Sweep thread count from `1` to `32`.
- Record CPU usage, CPU call graph, SSD utilization, PCIe link state, and optional DRAM traffic.
- Optionally run SSD preconditioning before the benchmark.

## Script

```bash
script/run_gdsio_sweep_v3.sh
```

Parser:

```bash
script/parse_gdsio_sweep_v3.py
```

## Default Matrix

```text
mode:       -x 0, -x 2
pattern:    -I 0, -I 2
io size:    4K, 8K, 16K, 32K, 64K, 128K, 256K, 512K, 1M, 2M, 4M
threads:    1, 2, 4, 8, 16, 32
repeats:    5
duration:   120s
GPU:        0
dataset:    1T
```

The default full matrix is large:

```text
2 modes * 2 patterns * 11 IO sizes * 6 thread counts * 5 repeats = 1320 cases
```

At `120s` per case, this is a long-running experiment. For a first run, reduce `REPS`, `MODES_STR`, `PATTERNS_STR`, `SIZES_KIB_STR`, or `THREADS_STR`.

## Dataset

Default dataset:

```text
TESTFILE=/mnt/nvme0/gds_test/testfile_v3
DATASET_SIZE=1T
```

The dataset is intentionally larger than the previous 10G file. At roughly `6.8 GiB/s`, a 120-second read can consume more than `800 GiB`, so a 10G dataset would repeatedly loop over the same small file region.

If `PRECONDITION=none`, the script requires the dataset file to already exist and be at least `DATASET_SIZE`.

## SSD Preconditioning

The preconditioning step is inspired by the paper *Quantifying Performance Gains of GPUDirect Storage*.

The paper's key idea is to put SSDs into a consistent, steady performance state before the formal GDS/CPU-GPU measurements. It describes two FIO-based preconditioning workloads:

```text
sequential write, 128K granularity
random write, 4K random writes
```

The paper states that the preconditioning process is performed twice and that the SSDs are filled completely. It does not provide exact FIO command lines, iodepth, numjobs, runtime, drop-cache behavior, or a rule saying preconditioning is repeated before every block size or every transfer mode.

Our script converts that method into an explicit, reproducible local workflow. The script supports three modes:

```text
PRECONDITION=none   # default; do not write SSD, require existing dataset
PRECONDITION=quick  # run FIO sequential + random write on PRECOND_SIZE
PRECONDITION=full   # run FIO sequential + random write on DATASET_SIZE
```

Quick mode defaults:

```text
PRECOND_SIZE=256G
PRECOND_ROUNDS=2
```

Each round runs:

```text
sequential write: rw=write,     bs=128k, direct=1, iodepth=32, numjobs=1
random write:     rw=randwrite, bs=4k,   direct=1, iodepth=32, numjobs=1
```

Important interpretation:

```text
PRECONDITION=quick
```

is partial preconditioning. It conditions only `PRECOND_SIZE`, so it should be described as a practical environment-check version, not as full-drive paper-equivalent preconditioning.

```text
PRECONDITION=full
```

uses `DATASET_SIZE` as the FIO target size. If `DATASET_SIZE` is set close to the usable test partition capacity and `PRECOND_ROUNDS=2`, it is closer to the paper method. If `DATASET_SIZE` is smaller, it is still a bounded-file precondition rather than true full-drive preconditioning.

Use larger preconditioning sizes and two rounds only when the additional runtime and SSD write wear are acceptable.

## CPU And System Monitoring

For each case, the script records:

```text
mpstat -P ALL 1
pidstat -t -u -r -d -p <gdsio_pid> 1
iostat -x <device> 1
nvidia-smi PCIe link query
sudo perf record -g -p <gdsio_pid> -- sleep 30
optional sudo perf stat uncore_imc_* counters
```

`htop` is intentionally not part of the script because it is useful for interactive observation but not good for reproducible logs.

`perf top -g` is an interactive tool, so the script records the equivalent call-graph data with `perf record -g`. You can inspect each case with:

```bash
sudo perf report -i raw/<case>/perf.data
```

## PCIe Link And Memory Clock

The script can lock the target GPU memory clock for the full sweep:

```text
LOCK_MEMORY_CLOCK=1
MEMORY_CLOCK=10001
```

This is enabled by default because prior diagnosis showed that GDS/NVFS reads may not keep the GPU PCIe link at Gen4 unless the GPU memory clock is held high.

The script resets memory/application clocks at exit using:

```text
nvidia-smi -rmc
nvidia-smi -rac
```

## Example Commands

Small smoke test:

```bash
PRECONDITION=none \
TESTFILE=/mnt/nvme0/gds_test/testfile \
DATASET_SIZE=10G \
MODES_STR=0 \
PATTERNS_STR=0 \
SIZES_KIB_STR=4096 \
THREADS_STR=8 \
REPS=1 \
DURATION=30 \
ENABLE_PERF=0 \
script/run_gdsio_sweep_v3.sh
```

Formal run with quick preconditioning:

```bash
PRECONDITION=quick \
PRECOND_SIZE=256G \
DATASET_SIZE=1T \
script/run_gdsio_sweep_v3.sh
```

Closer paper-style preconditioning, if runtime and SSD write wear are acceptable:

```bash
PRECONDITION=full \
PRECOND_ROUNDS=2 \
DATASET_SIZE=<close_to_usable_test_partition_size> \
script/run_gdsio_sweep_v3.sh
```
