# GDSIO Experiment Notes

## 1. How We Run The Experiment

The repo now uses only one runner:

- `script/run_gdsio_methodology.sh`

The canonical config is:

- `configs/methodology_full.env`

The baseline command is:

```bash
./script/run_gdsio_methodology.sh ./configs/methodology_full.env
```

The runner is intentionally built around `gdsio -D <dir>` rather than `-f <file>`, because the directory mode matches the multi-threaded test layout better and lets `gdsio` manage per-thread working files.

Before trusting any benchmark result, we verify the platform first:

- `gdscheck -p`
- `nvidia-smi topo -m`
- `lsblk -f`
- `mount`
- `lspci -tv`

The full experiment is split into two benchmark families:

- Large sequential IO for throughput
  - patterns: `read`, `write`
  - IO sizes: `128K 256K 512K 1M 2M 4M`
  - thread sweep IO size: `1M`
  - primary metric: `throughput_gib_s`
- Small random IO for IOPS and latency
  - patterns: `randread`, `randwrite`
  - IO sizes: `4K 8K 16K 32K 64K 128K`
  - thread sweep IO size: `4K`
  - primary metrics: `iops`, `avg_latency_us`

The default full config uses:

- `RUNTIME=10`
- `REPEATS=3`
- `PREPARE_DATASETS=1`
- `X_FLAGS_STR="0 2"`

`PREPARE_DATASETS=1` is important because it makes the read path use already-written shared datasets instead of mixing the benchmark with file allocation or file extension overhead.

`RUNTIME=10` is also intentional on this platform. We verified that 10-second `-x 0` runs can bring all GPU links up to `Gen4 x16` and stay there for the full measurement window, while some 30-second runs downshift mid-run and distort the sustained result.

Each run writes to:

- `results/<run_id>/meta/`
- `results/<run_id>/cases/`
- `results/<run_id>/summary.csv`

The plotting step stays separate:

```bash
python3 ./script/plot_gdsio_results.py ./results/<run_id>/summary.csv
```

## 2. PCIe Link Problem And How We Checked It

The platform issue we saw was not a simple idle power-saving state. The GPU PCIe links were unstable under load and could downshift from `Gen4 x16` to `Gen2` or `Gen1 x16` during a live benchmark run.

The checks we used were:

- Functional GDS readiness
  - `gdscheck -p`
- Real GPU visibility
  - `nvidia-smi`
- Current PCIe link state per GPU
  - `cat /sys/bus/pci/devices/<bdf>/current_link_speed`
  - `cat /sys/bus/pci/devices/<bdf>/current_link_width`
  - `cat /sys/bus/pci/devices/<bdf>/max_link_speed`
  - `cat /sys/bus/pci/devices/<bdf>/max_link_width`
- Direct-path benchmark comparison
  - `gdsio` with `-x 0` versus `-x 2`
- Time-correlated PCIe monitoring during the benchmark
  - run `gdsio -T 10` and `gdsio -T 30` with the same IO settings
  - poll all GPU `current_link_speed` values every second during each benchmark window

That last check mattered because it showed the actual failure mode:

- at the start of the run, all monitored GPUs could come up at `Gen4 x16`
- during the same running `gdsio` job, multiple GPUs would downshift
- after roughly the middle of the run, the links could end up at `Gen1 x16`

So the issue was not only "the benchmark ended and the link later went idle". The downshift happened while the benchmark was still active.

The practical decision for this repo is:

- use `10s` as the default benchmark runtime
- avoid `30s` as the default until the platform-level PCIe instability is fixed

We also used `gdscheck -p` to track platform-level blockers:

- earlier runs reported `IOMMU: Pass-through or enabled`
- earlier runs reported `ACS enabled` on multiple switches
- after disabling those settings, `gdscheck -p` changed to `IOMMU: disabled` and stopped reporting the ACS warning

That improved the platform state, but it did not fully solve the PCIe instability. The remaining issue is the live PCIe link downshift under load, which still needs platform-level investigation through BIOS, root-port, switch, retimer, or AER/error analysis.
