# GDSIO Benchmark Methodology

This repo now contains two runners:

- `script/run_gdsio_suite.sh`: the original matrix runner
- `script/run_gdsio_methodology.sh`: a methodology-oriented runner that separates throughput and small-IO benchmarking

The new runner is designed around NVIDIA's current GDS guidance:

- large sequential IO should be used for throughput-oriented comparisons
- small random IO should be used for IOPS and latency comparisons
- benchmarking should be done only after checking topology and direct-path readiness

## Recommended process

1. Verify the platform first

Collect these before trusting any benchmark result:

- `gdscheck -p`
- `nvidia-smi topo -m`
- `lsblk -f`
- `mount`
- `lspci -tv`

The runner stores these in `results/<run_id>/meta/` when available.

2. Benchmark large sequential IO separately

Use this family to compare throughput:

- pattern: `read`, `write`
- IO sizes: `128K` to `4M`
- thread sweep IO size: `1M`
- primary metric: `throughput_gib_s`

3. Benchmark small random IO separately

Use this family to compare low-latency behavior:

- pattern: `randread`, `randwrite`
- IO sizes: `4K` to `128K`
- thread sweep IO size: `4K`
- primary metrics: `iops`, `avg_latency_us`

4. Repeat each case

The methodology runner defaults to `REPEATS=3` in the full config and keeps `repeat_id` in `summary.csv`.

5. Pre-create datasets

The runner supports `PREPARE_DATASETS=1` so benchmarked writes are not dominated by file creation or file-extension overhead. This matters because some file systems may fall back away from the ideal direct path when writes allocate or extend blocks.

## Dataset guidance

The benchmark uses `gdsio -D <dir>` rather than `-f <file>`.

That means `gdsio` manages the benchmark files under a target directory, which is a good fit for multi-threaded experiments where each thread needs its own working file.

Suggested dataset sizes:

- sequential throughput: at least `1G`
- small random IO: at least `1G`

If your SSD has a strong cache effect or burst behavior, increase dataset size further so results represent sustained behavior rather than short-lived cache bursts.

## Monitoring captured per case

When tools are available, each case captures:

- `mpstat.log`
- `pidstat.log`
- `iostat.log`
- `nvidia-smi-dmon.log`
- `gds_stats.log`
- `nvidia_fs_stats_before.txt`
- `nvidia_fs_stats_after.txt`
- `nvidia_fs_stats_samples.log`

Use these as supporting evidence, not the main result:

- `throughput_gib_s` is still the main metric for large sequential IO
- `iops` and `avg_latency_us` are the main metrics for small random IO
- CPU and device monitors help explain *why* a result changed

## Suggested workflow

Run a quick validation:

```bash
./script/run_gdsio_methodology.sh ./configs/methodology_smoke.env
```

Run the full benchmark:

```bash
./script/run_gdsio_methodology.sh ./configs/methodology_full.env
```

Generate plots:

```bash
python3 ./script/plot_gdsio_results.py ./results/<run_id>/summary.csv
```
