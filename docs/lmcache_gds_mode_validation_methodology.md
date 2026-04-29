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
- Hash stability across processes
  - `PYTHONHASHSEED=0`
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
- cuFile log location
  - this host uses `/etc/cufile.json`
  - the actual per-process cuFile logs are written under `/home/poc/cufile_log`
  - `/usr/local/cuda/gds/tools/cufile.log` is not the authoritative per-process source on this machine

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

## Additional proof for direct nvfs I/O

- Same-process request 2 hits are enough to prove LMCache reuse, but not enough to prove SSD reload.
- To prove `cuFile` read/write against `nvfs`, run one extra direct-only cross-restart check:
  - service A starts with `use_cufile=true`
  - request 1 stores cache to SSD
  - service A exits
  - service B starts with the same config, same `PYTHONHASHSEED=0`, and the same SSD cache path
  - request 2 must show:
    - `LMCache hit tokens > 0`
    - `need to load > 0`
    - `Retrieved ...`
- Then inspect service B's per-process cuFile log under `/home/poc/cufile_log/cufile_<EngineCore pid>_*.log`
  - required evidence:
    - `nvidia_fs driver open invoked`
    - `NVMe : nvfs, compat`
    - `cuFileRead invoked`
    - `cuFileRead done`

## Why `PYTHONHASHSEED=0` is mandatory for cross-restart checks

- LMCache `0.4.2` warns when builtin hashing is used without `PYTHONHASHSEED`.
- Without a fixed hash seed, two different `vLLM` processes can generate different cache keys for the same prompt.
- In that case, cross-restart validation can fail even when SSD cache files exist and the GDS path itself is healthy.
- Therefore:
  - same-process direct/fallback checks can work without this
  - cross-process SSD reload checks should always fix `PYTHONHASHSEED=0`

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
