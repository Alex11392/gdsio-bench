# gdsio-bench

GDSIO benchmark scripts and experiment configs for comparing GPUD (`-x 0`) and CPU_GPU (`-x 2`) paths.

## Layout

- `script/run_gdsio_suite.sh`: main benchmark runner
- `script/run_gds_bench.sh`: older lightweight runner kept for reference
- `configs/smoke.env`: minimal validation matrix
- `configs/full.env`: full benchmark matrix

## Usage

Run a smoke test:

```bash
./script/run_gdsio_suite.sh ./configs/smoke.env
```

Run the full suite:

```bash
./script/run_gdsio_suite.sh ./configs/full.env
```

Generate plots from a summary CSV:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python3 ./script/plot_gdsio_results.py ./results/<run_id>/summary.csv
```

## Output

Results are written under `results/<run_id>/` with:

- `meta/`: run-level environment snapshots
- `cases/`: per-case logs and monitoring outputs
- `summary.csv`: parsed benchmark summary

Raw benchmark outputs are intentionally ignored by git.

Version-controlled CSV summaries should be copied into `summaries/`.

## Versioned Summaries

- `summaries/`: curated `summary.csv` files suitable for git/GitHub

Keep raw per-case logs under `results/`, but store validated summary CSVs in `summaries/` before commit.
