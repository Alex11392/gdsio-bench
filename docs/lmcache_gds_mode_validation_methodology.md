# LMCache GDS Mode Validation Methodology

## Goal

- Verify that `vLLM + LMCache` can store and reuse KV cache with the GDS backend.
- Distinguish the two execution modes inside LMCache's `GdsBackend`:
  - direct cuFile path
  - forced fallback path without cuFile
- Confirm that both modes remain functionally correct:
  - first request stores cache
  - second identical request reuses cache

## Why two modes are required

- A successful LMCache hit alone does not prove that cuFile/GDS direct I/O was used.
- In LMCache `0.4.2`, `GdsBackend` supports two internal branches:
  - `use_cufile=true`
    - uses `cufile.CuFile(...)` for file I/O
  - `use_cufile=false`
    - falls back to `mmap + cudaMemcpy`
- Therefore the experiment must compare:
  - direct mode: `use_cufile=true`
  - forced fallback mode: `use_cufile=false`

## Fixed test conditions

- Model
  - `facebook/opt-125m`
- Python environment
  - `/home/poc/vllm_lmcache_gds/.venv`
- Request body
  - [`docs/data/lmcache_long_prompt_request.json`](/home/poc/gds_bench/docs/data/lmcache_long_prompt_request.json)
- `vLLM` startup option
  - `--gpu-memory-utilization 0.7`
- LMCache common config
  - `chunk_size: 256`
  - `local_cpu: false`
  - `cufile_buffer_size: 1024`
- Filesystem
  - target cache path must be on the NVMe-backed `xfs` mount

## Per-mode expectations

### Direct mode

- Config
  - `extra_config.use_cufile: true`
- Expected evidence
  - server log contains `Using cufile`
  - first request logs `Stored ...`
  - second request logs `LMCache hit tokens: ...`
  - cache files are created under the run-specific SSD cache directory

### Forced fallback mode

- Config
  - `extra_config.use_cufile: false`
- Expected evidence
  - server log contains `Not using cufile`
  - first request logs `Stored ...`
  - second request logs `LMCache hit tokens: ...`
  - cache files are created under the run-specific SSD cache directory

## What is considered success

- Functional success
  - both modes store on request 1
  - both modes hit on request 2
- Path distinction success
  - direct mode logs `Using cufile`
  - forced fallback mode logs `Not using cufile`
- Artifact success
  - per-mode cache files exist on SSD
  - per-mode logs and summary are captured under `results/<run_id>/`
  - curated evidence is copied into `docs/data/<run_id>/`

## Runner

- Script
  - [`script/run_lmcache_gds_mode_validation.sh`](/home/poc/gds_bench/script/run_lmcache_gds_mode_validation.sh)

## Output layout

- Raw run artifacts
  - `results/<run_id>/`
- Committed evidence
  - `docs/data/<run_id>/`
- Human-readable report
  - `docs/lmcache_gds_mode_validation_<run_id>.md`
