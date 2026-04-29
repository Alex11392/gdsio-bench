# LMCache GDS Mode Validation

## Overview

- Run ID: `lmcache_gds_mode_validation_20260429_123125`
- Goal
  - Verify that `vLLM + LMCache` stores KV cache to SSD and reuses it on the second identical request.
  - Distinguish LMCache `GdsBackend` direct cuFile mode from forced fallback mode.
- Runner
  - [`script/run_lmcache_gds_mode_validation.sh`](/home/poc/gds_bench/script/run_lmcache_gds_mode_validation.sh)
- Methodology
  - [`docs/lmcache_gds_mode_validation_methodology.md`](/home/poc/gds_bench/docs/lmcache_gds_mode_validation_methodology.md)
- Curated data
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125)

## Test Conditions

- Model
  - `facebook/opt-125m`
- Python environment
  - `/home/poc/vllm_lmcache_gds/.venv`
- GPU used for the validation run
  - physical GPU `1`
  - this was chosen deliberately because GPU `0` was already occupied by a long-running vLLM service
- Shared LMCache settings
  - `chunk_size: 256`
  - `local_cpu: false`
  - `cufile_buffer_size: 1024`
- Filesystem type for SSD cache path
  - `xfs`
- Request body
  - [`docs/data/lmcache_long_prompt_request.json`](/home/poc/gds_bench/docs/data/lmcache_long_prompt_request.json)

## Modes

### 1. Direct

- Config
  - `extra_config.use_cufile: true`
- Cache path
  - `/mnt/nvme0/lmcache_gds_mode_validation_20260429_123125_direct_cache`

### 2. Forced Fallback

- Config
  - `extra_config.use_cufile: false`
- Cache path
  - `/mnt/nvme0/lmcache_gds_mode_validation_20260429_123125_forced_fallback_cache`

## Summary

- Raw summary
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/summary.csv`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/summary.csv)

| mode | use_cufile | first request ms | second request ms | stored tokens | LMCache hit tokens | cache files |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| direct | true | 272 | 199 | 768 | 768 | 6 |
| forced_fallback | false | 366 | 187 | 768 | 768 | 6 |

## Evidence 1: direct mode selected the cuFile branch

- Key log lines
  - `GDS backend using fstype 'xfs'`
  - `Using cufile`
- Source
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/direct/key_log_lines.txt`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/direct/key_log_lines.txt)

- Interpretation
  - The direct-mode run entered the `GdsBackend` branch that uses `cufile.CuFile(...)`.
  - Because the target filesystem is `xfs`, LMCache did not auto-disable cuFile.

## Addendum: direct mode was verified against per-process cuFile logs

- Supplemental cross-restart evidence
  - [`docs/data/lmcache_nvfs_cross_restart_20260429/summary.txt`](/home/poc/gds_bench/docs/data/lmcache_nvfs_cross_restart_20260429/summary.txt)

- Why this addendum was needed
  - The original same-process run proved direct vs forced-fallback branch selection.
  - It did not by itself prove that a later process reloaded SSD cache through `nvidia-fs/cuFile`.

- What the supplemental direct-only check did
  - started a first direct-mode service with `PYTHONHASHSEED=0`
  - stored cache to SSD
  - stopped that service
  - started a second direct-mode service with the same SSD cache path and the same `PYTHONHASHSEED=0`
  - sent the same request again

- LMCache evidence from the second service
  - `LMCache hit tokens: 768`
  - `need to load: 768`
  - `Retrieved 768 out of 768 required tokens`

- cuFile driver evidence from the second service's own `cufile_<pid>.log`
  - `nvidia_fs driver open invoked`
  - `NVMe : nvfs, compat`
  - `cuFileRead invoked`
  - `cuFileRead done`

- cuFile driver evidence from the first service's own `cufile_<pid>.log`
  - `nvidia_fs driver open invoked`
  - `NVMe : nvfs, compat`
  - `cuFileWrite invoked`
  - `cuFileWrite done`

- Interpretation
  - The direct-mode write path really went through `cuFile` on top of `nvidia-fs` to NVMe.
  - The direct-mode read path also really went through `cuFile` on top of `nvidia-fs` to reload SSD cache into a fresh process.
  - The three `cuFileRead invoked/done` pairs line up with the three 256-token LMCache chunks that make up the `768` loaded tokens.

## Evidence 2: forced fallback mode selected the non-cuFile branch

- Key log lines
  - `GDS backend using fstype 'xfs'`
  - `Not using cufile`
- Source
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/key_log_lines.txt`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/key_log_lines.txt)

- Interpretation
  - The fallback run still used `GdsBackend`, but forced the backend into the non-cuFile path.
  - In LMCache `0.4.2`, that path uses `mmap + cudaMemcpy` instead of `cufile.CuFile(...)`.

## Evidence 3: both modes stored cache on request 1

- Direct
  - `Stored 768 out of total 768 tokens`
- Forced fallback
  - `Stored 768 out of total 768 tokens`

- Interpretation
  - Both branches successfully persisted cache data to SSD-backed paths.

## Evidence 4: both modes reused cache on request 2

- Direct
  - `LMCache hit tokens: 768`
- Forced fallback
  - `LMCache hit tokens: 768`

- Interpretation
  - Both branches successfully reused previously stored prefix chunks.
  - The observed `768` token hit count matches three full LMCache chunks with `chunk_size: 256`.

## Evidence 5: both modes created SSD cache files

- Direct artifacts
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/direct/cache_files.txt`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/direct/cache_files.txt)
- Forced fallback artifacts
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/cache_files.txt`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/cache_files.txt)

- Interpretation
  - Each mode created 3 data files and 3 metadata files under its own cache directory.
  - This confirms that the store path was not just logically reported; it also materialized on SSD.

## Evidence 6: vLLM internal prefix cache and LMCache are separate signals

- In both modes, the metrics snapshot showed:
  - `vllm:prefix_cache_hits_total = 896`
  - `vllm:external_prefix_cache_hits_total = 0`
- Sources
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/direct/metrics_snippet.txt`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/direct/metrics_snippet.txt)
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/metrics_snippet.txt`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/metrics_snippet.txt)

- Interpretation
  - `prefix_cache_hits_total` is vLLM's own internal prefix cache metric.
  - The LMCache success criteria for this experiment came from request-level LMCache logs, not from the `external_prefix_cache_hits_total` counter.
  - On this version combination (`vLLM 0.18.0`, `LMCache 0.4.2`), the request-level LMCache hit signal was the reliable indicator.

## Caveat: the original `cufile_delta.log` artifacts were not the right source on this host

- The host's authoritative cuFile logs are under `/home/poc/cufile_log`, as configured by `/etc/cufile.json`.
- The original committed `cufile_delta.log` files from the first report run stayed empty because they were taken from the wrong global path.
- That issue does not change the direct/fallback functional conclusion.
- It does mean that the strongest nvfs proof comes from the supplemental per-process log summary above.

## Final Conclusion

- The current `vLLM + LMCache` setup successfully stores KV cache to SSD and reuses it on repeated requests.
- The current LMCache `GdsBackend` direct mode is functional on this host.
  - Supported by:
    - `Using cufile`
    - `Stored 768`
    - `LMCache hit tokens: 768`
    - cache files on SSD
    - cross-restart `Retrieved 768 out of 768 required tokens`
    - per-process cuFile log lines showing `cuFileWrite` and `cuFileRead` under `nvidia_fs`
- The current LMCache `GdsBackend` forced fallback mode is also functional on this host.
  - Supported by:
    - `Not using cufile`
    - `Stored 768`
    - `LMCache hit tokens: 768`
    - cache files on SSD
- Therefore, the experiment supports the claim that the current GDS fallback path is operating normally.
