# Methodology Run 20260424_131442

This note records the first full benchmark run completed with the simplified methodology runner and the `10s` default runtime.

## Run Summary

- Run ID: `methodology_full_20260424_131442`
- Summary CSV: [summary.csv](/home/poc/gds_bench/results/methodology_full_20260424_131442/summary.csv)
- Figures: [docs/figures/methodology_full_20260424_131442](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442)
- Total completed cases: `288`
- Repeats per configuration: `3`
- Modes: `read`, `write`
- Transfer modes: `-x 0`, `-x 2`

This run used the current canonical config in [configs/methodology_full.env](/home/poc/gds_bench/configs/methodology_full.env) with these practical settings:

- `RUNTIME=10`
- `PREPARE_DATASETS=1`
- `PREP_X_FLAG=2`
- `PREP_IO_SIZE=1M`
- `PREP_MAX_ATTEMPTS=6`

The `PREP_IO_SIZE=1M` and `PREP_MAX_ATTEMPTS=6` changes were necessary during this run because the large shared datasets used by the random-read and high-thread cases could not reliably reach the target fill ratio when the preparation phase used the smaller automatic IO size and fewer retries.

## Figures

Representative plots from this run:

- Sequential throughput by IO size, read: [io_size_sweep_throughput__read__throughput_gib_s.png](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442/io_size_sweep_throughput__read__throughput_gib_s.png)
- Sequential throughput by IO size, write: [io_size_sweep_throughput__write__throughput_gib_s.png](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442/io_size_sweep_throughput__write__throughput_gib_s.png)
- Random IOPS by IO size, write: [io_size_sweep_iops__write__iops.png](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442/io_size_sweep_iops__write__iops.png)
- Sequential throughput by threads, read: [thread_sweep_throughput__read__throughput_gib_s.png](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442/thread_sweep_throughput__read__throughput_gib_s.png)
- Sequential throughput by threads, write: [thread_sweep_throughput__write__throughput_gib_s.png](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442/thread_sweep_throughput__write__throughput_gib_s.png)
- Random IOPS by threads, write: [thread_sweep_iops__write__iops.png](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442/thread_sweep_iops__write__iops.png)

Important limitation: the current plotting script collapses the three repeats into a simple mean. That is useful for the main trend lines, but it can hide instability. The variability notes below should be read together with the plots.

## Main Findings

### 1. `-x 0` sequential read was the most stable part of the run

For `io_size_sweep_throughput`, `read`, `-x 0`, `th8`:

- `1M`: `6.829520`, `6.828706`, `6.829355 GiB/s`
- mean: `6.829194 GiB/s`
- standard deviation: `0.000351 GiB/s`

- `4M`: `6.817672`, `6.855022`, `6.828892 GiB/s`
- mean: `6.833862 GiB/s`
- standard deviation: `0.015648 GiB/s`

For `thread_sweep_throughput`, `read`, `-x 0`, `1M`:

- `th1` mean: `3.135271 GiB/s`
- `th8` mean: `6.770261 GiB/s`
- `th32` mean: `6.879050 GiB/s`

Interpretation:

- Sequential read saturates around `th8`
- Increasing to `th32` gives only a small gain over `th8`
- This is the cleanest and most repeatable section of the data

### 2. `-x 0` sequential write was also stable, but slower than sequential read

For `io_size_sweep_throughput`, `write`, `-x 0`, `th8`, `1M`:

- `5.638432`, `5.631362`, `5.640357 GiB/s`
- mean: `5.636717 GiB/s`
- standard deviation: `0.003867 GiB/s`

Interpretation:

- `-x 0` write is reasonably stable
- Throughput is clearly below the `-x 0` read plateau of about `6.83 GiB/s`

### 3. `-x 2` sequential write showed visible run-to-run spread

For `io_size_sweep_throughput`, `write`, `-x 2`, `th8`, `1M`:

- `3.687440`, `5.628243`, `5.375891 GiB/s`
- mean: `4.897191 GiB/s`
- standard deviation: `0.861605 GiB/s`

Interpretation:

- The average plot alone makes this line look reasonable
- The raw repeats show that one run was much lower than the other two
- This is exactly the kind of variability that the mean-only figures hide

### 4. Random read was stable but low

For `io_size_sweep_iops`, `read`, `-x 0`, `th32`, `4K`:

- `16774`, `16989`, `16267 IOPS`
- mean: `16677 IOPS`
- standard deviation: `303 IOPS`

Interpretation:

- Random read is much slower than random write on this platform
- But it is at least consistent across repeats

### 5. Random write with `-x 2` was fast, but variance was not small

For `io_size_sweep_iops`, `write`, `-x 2`, `th32`, `4K`:

- `272468`, `434106`, `397942 IOPS`
- mean: `368172 IOPS`
- standard deviation: `69265 IOPS`

Interpretation:

- The average line is strong
- The spread between repeats is still large enough that it should be called out in text

### 6. The largest instability was in write-oriented thread sweeps

Several `thread_sweep_throughput` write cases had the highest coefficient of variation in the whole run.

Examples:

- `write`, `-x 0`, `th2`, `1M`: `1.938931`, `5.278705`, `5.551532 GiB/s`
- `write`, `-x 2`, `th32`, `1M`: `5.630359`, `3.017003`, `2.741580 GiB/s`
- `write`, `-x 2`, `th4`, `1M`: `2.060514`, `4.129742`, `5.178768 GiB/s`

Interpretation:

- Write thread sweeps are the least stable family in this run
- The average curves are useful for trend reading, but they are not enough to judge repeatability
- Any conclusion about best thread count for write workloads should be made from both the mean plots and the per-repeat raw values

## Short Comparison Notes

Selected averages:

- Sequential read, `th8`, `1M`
  - `-x 0`: `6.829194 GiB/s`
  - `-x 2`: `6.887742 GiB/s`
- Sequential read, `th8`, `4M`
  - `-x 0`: `6.833862 GiB/s`
  - `-x 2`: `6.825522 GiB/s`
- Sequential write, `th8`, `1M`
  - `-x 0`: `5.636717 GiB/s`
  - `-x 2`: `4.897191 GiB/s`
- Random write, `th32`, `4K`
  - `-x 0`: `20104 IOPS`
  - `-x 2`: `368172 IOPS`

The two most defensible takeaways from this run are:

- Sequential read throughput is stable and saturates near `6.8 GiB/s`
- Write-heavy cases, especially thread sweeps, need the repeat-by-repeat view because the mean alone can hide large swings

## Recommendation

For future reports based on this repo:

- keep the mean plots as the main figure set
- add a variability section in Markdown like this one
- consider extending the plotting script later to show error bars or min/max bands for each repeated configuration
