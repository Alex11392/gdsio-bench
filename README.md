# gdsio-bench

Single-runner GDSIO benchmark repo for comparing GPUD (`-x 0`) and CPU bounce (`-x 2`) on the same platform.

## What Stays

- `script/run_gdsio_methodology.sh`: the only benchmark runner kept in this repo
- `script/plot_gdsio_results.py`: plot generator kept as-is
- `configs/methodology_full.env`: canonical experiment config
- `docs/benchmark-methodology.md`: experiment procedure and PCIe issue notes
- `docs/methodology_full_20260424_131442.md`: first full methodology run record with findings and repeat-to-repeat notes
- `docs/lmcache_gds_mode_validation_methodology.md`: methodology for validating LMCache direct GDS mode vs forced fallback mode
- `docs/lmcache_gds_mode_validation_20260429_123125.md`: committed run record showing both LMCache direct mode and forced fallback mode working
- `docs/data/lmcache_nvfs_cross_restart_20260429/summary.txt`: cross-restart proof that direct mode really performed cuFile write/read through `nvidia-fs`

## Run

```bash
./script/run_gdsio_methodology.sh ./configs/methodology_full.env
```

The canonical config now uses `RUNTIME=10` by default. That is deliberate: on this host, 30-second GPUD runs can trigger mid-run PCIe downshift and skew the result.

Completed run artifacts committed in this repo:

- report: [docs/methodology_full_20260424_131442.md](/home/poc/gds_bench/docs/methodology_full_20260424_131442.md)
- figures: [docs/figures/methodology_full_20260424_131442](/home/poc/gds_bench/docs/figures/methodology_full_20260424_131442)
- report: [docs/lmcache_gds_mode_validation_20260429_123125.md](/home/poc/gds_bench/docs/lmcache_gds_mode_validation_20260429_123125.md)
- curated data: [docs/data/lmcache_gds_mode_validation_20260429_123125](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125)
- direct nvfs proof: [docs/data/lmcache_nvfs_cross_restart_20260429/summary.txt](/home/poc/gds_bench/docs/data/lmcache_nvfs_cross_restart_20260429/summary.txt)

Generate plots from a finished run:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 ./script/plot_gdsio_results.py ./results/<run_id>/summary.csv
```

## Output

Each run writes to `results/<run_id>/`:

- `meta/`: platform snapshots collected before the run
- `cases/`: per-case raw logs and monitor outputs
- `summary.csv`: parsed benchmark summary

`results/` and `logs/` are intentionally git-ignored. Only the runner, config, plotting script, and Markdown notes are kept in git.
