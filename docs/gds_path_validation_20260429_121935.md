# GDS Path Validation

## Purpose

- Confirm that the current environment can execute GDS workloads.
- Confirm that a real `gdsio -x 0` case uses the GDS path and reaches `nvfs`.
- Re-run the validation with `nvidia_fs` stats enabled so that `/proc/driver/nvidia-fs/stats` can be used as supporting evidence.
- Clarify the difference between:
  - `gdscheck`
  - `gdsio.log`
  - cuFile debug log
  - `/proc/driver/nvidia-fs/stats`

## Validation Run

- Run ID: `gds_path_validation_20260429_121935`
- GPU: `0`
- Dataset directory
  - `/mnt/nvme0/gds_path_validation_20260429_121935`
- Tests
  - sequential write
  - sequential read
- Common parameters
  - `-D /mnt/nvme0/gds_path_validation_20260429_121935`
  - `-d 0`
  - `-x 0`
  - `-m 0`
  - `-w 8`
  - `-s 1G`
  - `-i 1M`
  - `-T 10`
- Write case
  - `-I 1`
- Read case
  - `-I 0`

## Module Parameter State

- Before the rerun
  - `rw_stats_before=1`
  - `peer_stats_before=1`
- During the rerun
  - `rw_stats_after=1`
  - `peer_stats_after=1`

## Evidence 1: `gdscheck` confirms the platform is GDS-capable

- Relevant output
  - `NVMe               : nvfs, compat`
  - `properties.use_compat_mode : true`
  - `properties.force_compat_mode : false`
  - `GPU index 0 ... supports GDS, IOMMU State: Disabled`
  - `Platform verification succeeded`

- Interpretation
  - The platform is capable of running GDS workloads.
  - `NVMe : nvfs, compat` means the NVMe stack supports the `nvfs` path and also has compatibility fallback available.
  - `use_compat_mode : true` does not mean the test was forced into fallback mode.
  - `force_compat_mode : false` means compatibility mode is available but not forced.

## Evidence 2: `gdsio.log` shows both cases used `GPUD`

- Write case

```text
IoType: WRITE XferType: GPUD Threads: 8 DataSetSize: 54675456/8388608(KiB) IOSize: 1024(KiB) Throughput: 5.655563 GiB/sec, Avg_Latency: 1381.371828 usecs ops: 53394 total_time 9.219697 secs
```

- Read case

```text
IoType: READ XferType: GPUD Threads: 8 DataSetSize: 67814400/8388608(KiB) IOSize: 1024(KiB) Throughput: 6.803043 GiB/sec, Avg_Latency: 1148.187468 usecs ops: 66225 total_time 9.506460 secs
```

- Interpretation
  - `XferType: GPUD` is the direct per-case proof that both test cases used the GDS direct path.
  - If these cases had fallen back to the CPU bounce path, `XferType` would have been `CPU_GPU`.

## Evidence 3: cuFile debug log shows the I/O reached `nvfs`

- Write case examples

```text
DEBUG  cufio_core:2971 gds path taken with ODIRECT fd: 224
DEBUG  0:1933 nvfs_io_submit file_offset 618659840 size 1048576 gpu_offset 0 nvbuf 0x7cfea000d850 is_unaligned 0
DEBUG  cufio:504 cuFileWrite invoked
```

- Write case summary

```text
Write: bw=5.67383 ... n=53440 ... nvfs=53440 posix=0 ...
```

- Read case examples

```text
DEBUG  cufio_core:2971 gds path taken with ODIRECT fd: 228
DEBUG  0:1933 nvfs_io_submit file_offset 115343360 size 1048576 gpu_offset 0 nvbuf 0x73f5380020c0 is_unaligned 0
DEBUG  cufio:438 cuFileRead invoked
```

- Read case summary

```text
Read: bw=6.85449 ... n=66272 ... nvfs=66272 posix=0 ...
```

- Interpretation
  - `gds path taken with ODIRECT` is direct cuFile evidence that the GDS path was selected.
  - `nvfs_io_submit` shows the request was submitted through the `nvfs` path.
  - `nvfs=...` together with `posix=0` shows that the recorded I/O was attributed to `nvfs`, not POSIX fallback.

## Evidence 4: `/proc/driver/nvidia-fs/stats` now shows `Reads/Writes`

- Before the rerun

```text
Reads  : n=66496 ok=66496 err=0 readMiB=66496 io_state_err=0
Writes : n=82112 ok=82112 err=0 writeMiB=82112 io_state_err=0 ...
Ops    : Read=0 Write=0 BatchIO=0
```

- After the write case

```text
Reads  : n=66496 ok=66496 err=0 readMiB=66496 io_state_err=0
Writes : n=135552 ok=135552 err=0 writeMiB=135552 io_state_err=0 ...
Ops    : Read=0 Write=0 BatchIO=0
```

- After the read case

```text
Reads  : n=132768 ok=132768 err=0 readMiB=132768 io_state_err=0
Writes : n=135552 ok=135552 err=0 writeMiB=135552 io_state_err=0 ...
Ops    : Read=0 Write=0 BatchIO=0
```

- Interpretation
  - In this environment, the useful per-run counters are `Reads` and `Writes`.
  - The write case increased the `Writes` counters.
  - The read case increased the `Reads` counters.
  - `Ops : Read=0 Write=0 BatchIO=0` remained unchanged, so `Ops` is not a useful primary runtime indicator for this workload on this platform.

## What matters for `nvidia_fs` stats

- The important setting for read/write accounting is `rw_stats_enabled`.
- In this rerun, `peer_stats_enabled` was also enabled.
- Based on the available evidence:
  - `rw_stats_enabled` is required if we want `/proc/driver/nvidia-fs/stats` to expose useful read/write accounting.
  - `peer_stats_enabled` appears to be supplementary.
    - It is relevant to peer-related accounting such as cross-root-port reporting.
    - It is not the primary evidence that the test used GDS.
- Therefore, the main conclusion is:
  - To make `/proc/driver/nvidia-fs/stats` useful in this report, the key switch is `rw_stats_enabled`.
  - `peer_stats_enabled` can be left on for richer visibility, but it is not the main proof that the path is GDS.

## Why `gdsio.log` and cuFile log are both needed

- `gdsio.log`
  - Scope
    - Per-case
  - Best for
    - Showing the path label used by the benchmark case
    - Showing throughput, latency, ops, threads, and I/O size
  - Key field
    - `XferType`
  - Example conclusion
    - `XferType: GPUD` means the tested benchmark case used the GDS direct path

- cuFile debug log
  - Scope
    - Global runtime log
  - Best for
    - Showing lower-level cuFile and `nvfs` behavior
    - Confirming whether the I/O reached `nvfs`
    - Confirming whether POSIX fallback was used
  - Key fields
    - `gds path taken with ODIRECT`
    - `nvfs_io_submit`
    - `nvfs=...`
    - `posix=...`
  - Example conclusion
    - `nvfs > 0` together with `posix = 0` means the runtime path was `nvfs`, not POSIX fallback

- Practical usage in this report
  - `gdscheck`
    - proves that the platform is GDS-capable
  - `gdsio.log`
    - proves that the tested case reported `GPUD`
  - cuFile log
    - proves that the runtime path reached `nvfs`
  - `/proc/driver/nvidia-fs/stats`
    - provides additional supporting evidence through `Reads/Writes`

## Final Conclusion

- The current platform can execute GDS workloads.
  - Supported by `gdscheck`
  - `supports GDS`
  - `Platform verification succeeded`
- The tested sequential write and sequential read cases both used the GDS path.
  - Supported by `gdsio.log`
  - `XferType: GPUD`
- The runtime I/O path reached `nvfs` and did not fall back to POSIX mode.
  - Supported by cuFile debug log
  - `gds path taken with ODIRECT`
  - `nvfs_io_submit`
  - `nvfs > 0`
  - `posix = 0`
- `/proc/driver/nvidia-fs/stats` can also show supporting runtime evidence in this environment.
  - The useful counters are `Reads` and `Writes`
  - `Ops` stayed at zero and should not be used as the main indicator for this workload on this platform
