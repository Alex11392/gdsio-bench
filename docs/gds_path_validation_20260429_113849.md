# GDS Path Validation

## Purpose

- Confirm that the current platform can execute GDS workloads.
- Confirm that a real `gdsio -x 0` case uses the GDS/nvfs path rather than falling back to POSIX mode.
- Clarify the roles of:
  - `gdscheck`
  - `gdsio.log`
  - cuFile debug log
  - `nvidia_fs` stats

## Validation Run

- Run ID: `gds_path_validation_20260429_113849`
- GPU: `0`
- Test type: sequential write
- Parameters
  - `-D /mnt/nvme0/gds_path_validation_20260429_113849`
  - `-d 0`
  - `-I 1`
  - `-x 0`
  - `-m 0`
  - `-w 8`
  - `-s 1G`
  - `-i 1M`
  - `-T 5`

## Evidence 1: `gdscheck` shows the platform is GDS-capable

- Relevant output
  - `NVMe               : nvfs, compat`
  - `properties.use_compat_mode : true`
  - `properties.force_compat_mode : false`
  - `GPU index 0 ... supports GDS, IOMMU State: Disabled`
  - `Platform verification succeeded`

- Interpretation
  - `supports GDS` and `Platform verification succeeded` show that the platform is able to run GDS workloads.
  - `NVMe : nvfs, compat` means the NVMe path supports the `nvfs` path and also has compatibility fallback available.
  - `use_compat_mode : true` does **not** mean the current I/O was forced into POSIX fallback.
  - The key line is `force_compat_mode : false`, which means compat mode is available but not forced.

## Evidence 2: `gdsio.log` shows the tested case used `GPUD`

- Relevant output

```text
IoType: WRITE XferType: GPUD Threads: 8 DataSetSize: 29423616/8388608(KiB) IOSize: 1024(KiB) Throughput: 5.630276 GiB/sec, Avg_Latency: 1387.515205 usecs ops: 28734 total_time 4.983867 secs
```

- Interpretation
  - `XferType: GPUD` is the direct per-case proof that this `gdsio` invocation used the GDS direct path.
  - If this case had fallen back to the CPU bounce path, `XferType` would have been `CPU_GPU` instead.

## Evidence 3: cuFile debug log shows the I/O went through GDS/nvfs

- Relevant output

```text
DEBUG  cufio_core:2971 gds path taken with ODIRECT fd: 224
DEBUG  0:1933 nvfs_io_submit file_offset 583008256 size 1048576 gpu_offset 0 nvbuf 0x74d6c00020c0 is_unaligned 0
DEBUG  cufio:504 cuFileWrite invoked
```

- End-of-run summary

```text
GPU 0(...) Read: ... nvfs=0 posix=0 ...
Write: bw=5.66211 util(%)=778 n=28784 pcie p2pdma=0 nvfs=28784 posix=0 unalign=0 dr=0 err=0 MiB=28784 ...
```

- Interpretation
  - `gds path taken with ODIRECT` is direct low-level evidence from cuFile that the GDS path was selected.
  - `nvfs_io_submit` shows the request was submitted through the nvfs path.
  - In the final cuFile summary, `nvfs=28784` and `posix=0` show that this run accumulated nvfs I/O and did not use POSIX fallback.

## Evidence 4: `nvidia_fs` stats were present, but were weak per-case proof

- Relevant output

```text
before: Ops : Read=0 Write=0 BatchIO=0
after : Ops : Read=0 Write=0 BatchIO=0
before: GPU 0000:17:00.0 ... Registered_MiB=4096 Cache_MiB=2 max_pinned_MiB=4128
after : GPU 0000:17:00.0 ... Registered_MiB=4096 Cache_MiB=2 max_pinned_MiB=4128
```

- Interpretation
  - The `nvidia_fs` stats confirm that the `nvidia-fs` stack is present and the GPU has active registration state.
  - However, in this platform and with simple before/after snapshots, the per-case `Ops` counters did not move in a way that made them useful as primary proof.
  - Therefore, `nvidia_fs` stats were treated as background/supporting information, not the decisive runtime proof.

## Conclusion

- The current environment can run GDS workloads.
  - This is supported by `gdscheck`:
    - `supports GDS`
    - `Platform verification succeeded`
- The validation case actually used the GDS path.
  - This is directly shown by `gdsio.log`:
    - `XferType: GPUD`
- The I/O went through `nvfs`, not POSIX fallback.
  - This is shown by the cuFile debug log:
    - `gds path taken with ODIRECT`
    - `nvfs_io_submit`
    - `nvfs=28784`
    - `posix=0`
- Therefore, for this validation run, it is reasonable to conclude:
  - the environment is GDS-capable
  - the tested `-x 0` case really used the GDS path
  - the runtime data path was `nvfs`, not POSIX fallback

## `gdsio.log` vs cuFile log

- `gdsio.log`
  - Scope
    - Per-case
  - Best for
    - Confirming what path a specific benchmark case reported
    - Reading throughput, latency, ops, and `XferType`
  - Strength
    - Easy to map directly to one benchmark case
  - Limitation
    - It tells you the path label used by `gdsio`, but not the lower-level internal cuFile/nvfs activity

- cuFile debug log
  - Scope
    - Global runtime log
  - Best for
    - Confirming low-level cuFile behavior
    - Checking whether the path reached `nvfs`
    - Checking whether POSIX fallback was used
  - Strength
    - Can show evidence such as:
      - `gds path taken with ODIRECT`
      - `nvfs_io_submit`
      - `nvfs=...`
      - `posix=...`
  - Limitation
    - It is not naturally per-case
    - Multiple runs can be mixed together unless the log is captured carefully

- Practical recommendation
  - Use `gdsio.log` as the primary case-level proof.
  - Use cuFile debug log as the lower-level confirmation that the path was really `nvfs` and not POSIX fallback.
  - Use `gdscheck` to prove the platform is GDS-capable.
  - Treat simple `nvidia_fs` before/after snapshots as supporting context, not the decisive runtime proof.
