# GDS PCIe Link Diagnosis - 2026-05-17

## Goal

- Check whether long-duration GDS reads cause the GPU PCIe link to drop from Gen4 to lower speeds.
- Determine whether the behavior is caused by `gdsio` itself or by the GDS/NVFS path.
- Test whether GPU high-performance settings, especially memory clock locking, keep the PCIe link at Gen4.

## Test Setup

- SSD mount: `/mnt/nvme0`
- Filesystem: `ext4`, mounted read-only during the test
- Test file: `/mnt/nvme0/gds_test/testfile`
- Main GPU tested: GPU0, PCIe BDF `00000000:17:00.0`
- Main workload:
  - Read
  - IO size: `4M`
  - Threads: `8`
  - Dataset size: `10G`
  - Duration: `120s`
- PCIe monitoring:
  - `nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max`
- GDS path validation:
  - cuFile INFO log
  - `/proc/driver/nvidia-fs/stats`

## Key Findings

- `gdsio -x 0` showed `XferType: GPUD`, but the target GPU PCIe link did not always stay at Gen4.
- cuFile stats confirmed the path was real NVFS/GDS:
  - `nvfs > 0`
  - `posix=0`
  - `p2pdma=0`
  - `err=0`
- A custom cuFile test reproduced the same behavior without using `gdsio`.
- Therefore, the issue is not specific to `gdsio`.

## Custom GDS Test

- A temporary custom cuFile test program was used during diagnosis.
- The debug source and wrapper scripts were not committed to the repository.
- The test directly called:
  - `cudaMalloc`
  - `cuFileDriverOpen`
  - `cuFileHandleRegister`
  - `cuFileBufRegister`
  - `cuFileRead`

Baseline custom GDS read result:

```text
throughput: 3.25465 GiB/s
PCIe: mostly Gen1, short Gen4 window
NVFS: nvfs=100008, posix=0, err=0
```

This reproduced the same Gen1 behavior without `gdsio`.

## Memory Clock Diagnosis

The high-performance probe recorded GPU state, applied temporary clock settings, ran the custom GDS read test, then restored clocks using:

```text
nvidia-smi -rgc
nvidia-smi -rmc
nvidia-smi -rac
```

Ablation results:

| Setting | Throughput | PCIe Link During Test | Result |
|---|---:|---|---|
| Baseline, no clock lock | 3.25465 GiB/s | Mostly Gen1, short Gen4 | Bad |
| Lock graphics + memory clock | 6.8808 GiB/s | Gen4 x16 throughout | Good |
| Lock memory clock only | 6.87866 GiB/s | Gen4 x16 throughout | Good |
| Lock graphics clock only | 5.55715 GiB/s | Mostly Gen2, short Gen4 | Partial |

Conclusion:

- The key setting is the GPU memory clock.
- Locking memory clock to `10001 MHz` was sufficient to keep GPU0 PCIe at Gen4 x16 during GDS/NVFS reads.
- Locking graphics clock alone was not sufficient.

## Interpretation

- GDS/NVFS itself works correctly on this system.
- The observed low throughput is tied to GPU PCIe link power/performance state, not POSIX fallback.
- When GPU memory clock is left in the default power-managed state, GDS/NVFS traffic may not keep the GPU PCIe link at Gen4.
- When memory clock is locked high, the PCIe link remains Gen4 and throughput recovers.

## Operational Note

- Locking memory clock is useful as a benchmark control setting.
- It may increase idle power, temperature, and fan speed.
- It should not be left enabled permanently unless the power/thermal tradeoff is acceptable.
