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

## Caveat: cuFile global log did not add usable per-run lines

- Both committed `cufile_delta.log` files are empty.
- Sources
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/direct/cufile_delta.log`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/direct/cufile_delta.log)
  - [`docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/cufile_delta.log`](/home/poc/gds_bench/docs/data/lmcache_gds_mode_validation_20260429_123125/forced_fallback/cufile_delta.log)

- Interpretation
  - For this run, the global cuFile log did not provide new per-process evidence.
  - That means the path distinction in this report relies on:
    - LMCache branch-selection logs (`Using cufile` vs `Not using cufile`)
    - successful store/hit behavior
    - SSD file creation
  - This is still sufficient to validate that forced fallback remained functional.

## Final Conclusion

- The current `vLLM + LMCache` setup successfully stores KV cache to SSD and reuses it on repeated requests.
- The current LMCache `GdsBackend` direct mode is functional on this host.
  - Supported by:
    - `Using cufile`
    - `Stored 768`
    - `LMCache hit tokens: 768`
    - cache files on SSD
- The current LMCache `GdsBackend` forced fallback mode is also functional on this host.
  - Supported by:
    - `Not using cufile`
    - `Stored 768`
    - `LMCache hit tokens: 768`
    - cache files on SSD
- Therefore, the experiment supports the claim that the current GDS fallback path is operating normally.
